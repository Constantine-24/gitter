import Foundation
import GitCore

/// Staging and unstaging: everything that writes to the index short of a commit.
///
/// Every mutation goes through `mutate`, which serializes them behind `isMutating` and ends
/// each one with a refresh, so the views only ever see git's own state — this layer never
/// predicts the outcome of a command.
extension RepositoryStore {

    // MARK: - File-level staging

    func stage(_ file: FileStatus) {
        // An unmerged file goes through Mark Resolved: `git add` would take leftover conflict
        // markers without a word (M 10). A submodule has none, and staging it is how its
        // conflict is resolved (`ConflictWording.submodule`).
        if let conflict = file.conflict, !conflict.isSubmodule {
            markResolved(conflict)
            return
        }
        let path = file.path
        // `git add` on a path whose worktree side is a deletion stages the deletion, so a
        // removed file needs no special case here.
        mutate { backend, root in try await backend.stage(paths: [path], at: root) }
    }

    func unstage(_ file: FileStatus) {
        // Defence in depth behind the disabled button (the debug hooks call straight in).
        // See `operationInProgress` for why the whole operation is off limits and not only
        // its conflicts, and `RepositoryOperation.blocksUnstaging` for why a pending squash
        // is included too, despite this specific command (`git restore --staged`) leaving it
        // untouched: the same gate also covers `unstageAll()`, where it would not.
        guard operationInProgress?.blocksUnstaging != true, !isUnmerged(file) else { return }
        // A staged rename occupies two index entries — the new path and the one it came from —
        // and restoring only one of them would leave half a rename staged.
        var paths = [file.path]
        if let originalPath = file.originalPath { paths.append(originalPath) }
        mutate { backend, root in try await backend.unstage(paths: paths, at: root) }
    }

    /// Stages everything but an unmerged path (GitCore, M 22), and says how many conflicted
    /// files it left out. Not confirmed: the button goes through `requestStageAll`, which asks
    /// first during an operation (`RepositoryStore+Continue`).
    func stageAll() {
        let conflicted = Set(unmergedPaths)
        mutate({ backend, root in try await backend.stageAll(at: root) }, onSuccess: { [self] in
            announceStageAllSkipped(conflicted)
        })
    }

    /// The notice after a Stage All: how many of the files that were conflicted before it are
    /// still unmerged (left out).
    // internal (not private): used by +Continue.swift's `confirmStageAll()`
    func announceStageAllSkipped(_ conflicted: Set<String>) {
        let left = snapshot?.status.files.filter { conflicted.contains($0.path) && isUnmerged($0) } ?? []
        if !left.isEmpty { showNotice(ConflictWording.stageAllSkipped(left.count)) }
    }

    func unstageAll() {
        // Same defence: `git reset` removes `MERGE_HEAD`/`CHERRY_PICK_HEAD`/`REVERT_HEAD` and
        // ends the operation silently — including after the last conflict has been staged,
        // which is exactly when nothing is unmerged any more. It does the same to a pending
        // squash's `SQUASH_MSG`, which is the case this gate exists to catch: see
        // `RepositoryOperation.blocksUnstaging`.
        guard operationInProgress?.blocksUnstaging != true else { return }
        mutate { backend, root in try await backend.unstageAll(at: root) }
    }

    // MARK: - Hunk- and line-level staging

    func applyHunk(_ hunk: Hunk, in file: FileDiff) {
        apply(file: file, hunkIDs: [hunk.id], lineIDs: nil)
    }

    func applyLines(_ ids: Set<DiffLine.ID>, of hunk: Hunk, in file: FileDiff) {
        apply(file: file, hunkIDs: [hunk.id], lineIDs: ids)
    }

    private func apply(file: FileDiff, hunkIDs: Set<Hunk.ID>, lineIDs: Set<DiffLine.ID>?) {
        let direction = patchDirection
        // Defence in depth behind the disabled button, as in `unstage(_:)`: the whole-file
        // branch below reaches `git restore --staged` without passing that guard.
        guard !operationBlocksApplying(file, hunkIDs: hunkIDs, lineIDs: lineIDs) else { return }

        // Selecting the whole change of a file that is being added or removed cannot go
        // through a patch (its header is always a plain modification, which would leave an
        // empty blob in the index); the file-level commands do exactly the right thing.
        if PatchBuilder.isWholeFileChange(
            file: file, hunkIDs: hunkIDs, lineIDs: lineIDs, direction: direction),
            let path = file.newPath ?? file.oldPath
        {
            switch direction {
            case .stage: mutate { backend, root in try await backend.stage(paths: [path], at: root) }
            case .unstage: mutate { backend, root in try await backend.unstage(paths: [path], at: root) }
            }
            return
        }

        // A nil patch for any other reason means the selection leaves nothing to apply.
        guard
            let patch = PatchBuilder.patch(
                file: file, hunkIDs: hunkIDs, lineIDs: lineIDs, direction: direction)
        else { return }

        let reverse = direction == .unstage
        mutate { backend, root in
            do {
                try await backend.applyToIndex(patch: patch, reverse: reverse, at: root)
            } catch let GitError.commandFailed(_, stderr) {
                throw PatchDidNotApply(stderr: stderr)
            }
        }
    }

    // MARK: - Running a mutation

    /// Runs one git write, then reloads.
    ///
    /// Mutations are serialized: while one runs, every entry point here is a no-op, which is
    /// also what disables the buttons. The reload is unconditional — after a failure the
    /// working copy may still have moved (a patch that applied halfway cannot happen, but a
    /// hook can change files) — and the banner goes up after it, so the message the user ends
    /// up reading is the one that belongs to the state now on screen. `finishMutation` also
    /// marks it as the mutation's own, which is what keeps the watcher-driven reload racing
    /// this one from erasing it.
    ///
    /// `onSuccess` is for side effects on the store's own state (the draft, the selection). It
    /// runs only when git accepted the write *and* the generation it started under is still
    /// current — the same test `finishMutation` applies — since a mutation finishing after the
    /// user opened another repository would otherwise reset the new one's state.
    // internal (not private): used by RepositoryStore+Commit.swift's `commit()`
    func mutate(
        _ work: @escaping @MainActor (Backend, URL) async throws -> Void,
        onSuccess: (@MainActor () -> Void)? = nil
    ) {
        mutate(result: work) { (_: Void) in onSuccess?() }
    }

    /// `mutate`, for a command that answers something the store then has to act on — a merge's
    /// outcome, a delete git refused and reported on instead of doing.
    ///
    /// Identical in every other respect, and deliberately the same code path rather than a
    /// parallel one: the serialization, the unconditional reload, the generation check and the
    /// sticky banner are exactly what a branch operation needs too. `onSuccess` is not optional
    /// here because a caller that ignores the answer wants the plain `mutate` above.
    // internal (not private): used by RepositoryStore+Branches.swift and +BranchSheets.swift
    func mutate<Result>(
        result work: @escaping @MainActor (Backend, URL) async throws -> Result,
        onSuccess: @escaping @MainActor (Result) -> Void
    ) {
        guard let root, let generation = beginMutation() else { return }

        Task { @MainActor in
            var failure: Error?
            var result: Result?
            do {
                result = try await work(backend, root)
            } catch {
                failure = error
            }

            await refresh()
            if let result, failure == nil, self.generation == generation { onSuccess(result) }
            finishMutation(generation: generation, failure: failure)
        }
    }
}

/// A patch that no longer matches the index, reworded for the banner.
///
/// Git's own message ("error: patch failed…") describes the mechanics, not the situation: the
/// file moved on after the diff was loaded. `git apply` leaves the index untouched in this
/// case, and the refresh that follows reloads the diff the user was looking at.
private struct PatchDidNotApply: LocalizedError {
    let stderr: String

    var errorDescription: String? {
        let detail =
            stderr.split(whereSeparator: \.isNewline).first
            .map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return "The file changed since this diff was loaded. \(detail)"
            .trimmingCharacters(in: .whitespaces)
    }
}
