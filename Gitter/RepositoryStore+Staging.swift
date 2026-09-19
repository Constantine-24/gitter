import Foundation
import GitCore

/// Staging, unstaging and committing: everything that writes to the index or to HEAD.
///
/// Every mutation goes through `mutate`, which serializes them behind `isMutating` and ends
/// each one with a refresh, so the views only ever see git's own state — this layer never
/// predicts the outcome of a command.
extension RepositoryStore {

    // MARK: - Derived state for the UI

    /// Files with an index-side change. A file changed on both sides appears in both lists.
    ///
    /// An unmerged file counts as staged (`staged == .unmerged`) even though its index entry is
    /// a conflict rather than a change. That is deliberate: with it counted, `commitButtonTitle`
    /// never falls through to "Commit All Tracked" mid-merge, and so `git commit -a` — which
    /// would commit the conflict markers verbatim — is never what the button does.
    var stagedFiles: [FileStatus] {
        snapshot?.status.files.filter { $0.staged != nil } ?? []
    }

    /// Files with a worktree-side change, including untracked ones (`unstaged == .untracked`).
    var unstagedFiles: [FileStatus] {
        snapshot?.status.files.filter { $0.unstaged != nil } ?? []
    }

    /// True while at least one file is conflicted, i.e. a merge is in progress.
    ///
    /// Unstaging during a merge destroys state that cannot be reconstructed from the worktree:
    /// `git reset` deletes `MERGE_HEAD`, which ends the merge silently while the conflict
    /// markers stay in the files, and `git restore --staged` on a conflicted path collapses its
    /// three index stages into one. Both leave a repository that looks unremarkable and holds
    /// marker text ready to be committed.
    var hasUnmergedFiles: Bool {
        snapshot?.status.files.contains(where: isUnmerged) ?? false
    }

    /// Whether `file` is one side of an unresolved conflict. `git status` reports both sides as
    /// `U`, but either alone is enough to mean "do not unstage this".
    func isUnmerged(_ file: FileStatus) -> Bool {
        file.staged == .unmerged || file.unstaged == .unmerged
    }

    /// Which way hunk- and line-level operations run: the staged view shows what is already in
    /// the index, so acting on it takes changes out again.
    ///
    /// Derived from `diffIsStaged`, not `stagedView`: the patch is built from the diff that is
    /// on screen, and for the moment between clicking the other side and its `git diff`
    /// landing, that is still the previous side's parse.
    var patchDirection: PatchDirection {
        diffIsStaged ? .unstage : .stage
    }

    var commitButtonTitle: String {
        if draft.amend { return "Amend Commit" }
        switch stagedFiles.count {
        case 0: return "Commit All Tracked"
        case 1: return "Commit 1 File"
        case let count: return "Commit \(count) Files"
        }
    }

    /// True when amending would rewrite a commit that has already been pushed: the branch
    /// tracks an upstream and has nothing of its own ahead of it, so HEAD is the published
    /// commit itself.
    var amendRewritesPublishedHistory: Bool {
        guard draft.amend, let status = snapshot?.status else { return false }
        return status.upstream != nil && status.ahead == 0
    }

    /// Whether the diff currently on screen can be staged or unstaged hunk- or line-wise.
    ///
    /// Beyond what the patch builder supports, the app excludes untracked files (nothing to
    /// patch against) and unmerged ones (their "diff" is a conflict, not a change).
    func canPartiallyStage(_ file: FileDiff) -> Bool {
        guard selection == .workingCopy,
            PatchBuilder.supportsPartial(file, direction: patchDirection),
            let status = snapshot?.status.files.first(where: { $0.path == selectedPath })
        else { return false }
        return !status.isUntracked && status.staged != .unmerged && status.unstaged != .unmerged
    }

    // MARK: - File-level staging

    func stage(_ file: FileStatus) {
        let path = file.path
        // `git add` on a path whose worktree side is a deletion stages the deletion, so a
        // removed file needs no special case here.
        mutate { backend, root in try await backend.stage(paths: [path], at: root) }
    }

    func unstage(_ file: FileStatus) {
        // Defence in depth behind the disabled button: the debug hooks call straight in, and
        // `git restore --staged` on a conflicted path would throw its three stages away.
        guard !isUnmerged(file) else { return }
        // A staged rename occupies two index entries — the new path and the one it came from —
        // and restoring only one of them would leave half a rename staged.
        var paths = [file.path]
        if let originalPath = file.originalPath { paths.append(originalPath) }
        mutate { backend, root in try await backend.unstage(paths: paths, at: root) }
    }

    func stageAll() {
        mutate { backend, root in try await backend.stageAll(at: root) }
    }

    func unstageAll() {
        // Same defence, for the whole-index command: `git reset` would remove `MERGE_HEAD` and
        // end the merge without saying so.
        guard !hasUnmergedFiles else { return }
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

    // MARK: - Committing

    func commit() {
        guard draft.canCommit else { return }
        let message = draft.message
        let amend = draft.amend
        // With nothing staged, commit every tracked modification and deletion (`git commit
        // -a`), which never sweeps in untracked files. Amending keeps HEAD's tree instead.
        // When there is nothing to commit at all, git says so and that becomes the banner.
        let allTracked = stagedFiles.isEmpty && !amend

        mutate { backend, root in
            _ = try await backend.commit(
                message: message, amend: amend, allTracked: allTracked, at: root)
        } onSuccess: { [self] in
            // Only reached when git accepted the commit — a rejection (hook, signing, nothing
            // to commit) throws and leaves the draft exactly as the user typed it — and only
            // while this is still the repository that was committed to: a commit that finishes
            // after the user opened another one must not wipe *that* repository's draft.
            draft.reset()
            select(.workingCopy)
        }
    }

    /// Turns amending on or off, prefilling an untouched draft with HEAD's message.
    ///
    /// Not routed through `mutate`: it writes no git state, and the draft has to stay editable
    /// while a mutation is in flight. Turning amend back off keeps the prefilled message,
    /// which the user may have edited by then.
    func setAmend(_ on: Bool) {
        draft.amend = on
        guard on, draft.subject.isEmpty, draft.body.isEmpty, let root else { return }
        let generation = self.generation
        Task {
            guard let message = try? await backend.headMessage(at: root) else { return }
            // Amending may have been switched off again, or another repository opened, while
            // `git log` ran: HEAD's message belongs to neither of those drafts.
            guard draft.amend, self.generation == generation else { return }
            draft.prefill(from: message)
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
    /// runs only when git accepted the write *and* the generation it was started under is still
    /// current — the same test `finishMutation` applies — because a mutation that finishes
    /// after the user opened another repository would otherwise reset the new one's state.
    private func mutate(
        _ work: @escaping @MainActor (any GitBackend & GitWorkingCopyBackend, URL) async throws ->
            Void,
        onSuccess: (@MainActor () -> Void)? = nil
    ) {
        guard let root, let generation = beginMutation() else { return }

        Task { @MainActor in
            var failure: Error?
            do {
                try await work(backend, root)
            } catch {
                failure = error
            }

            await refresh()
            if failure == nil, self.generation == generation { onSuccess?() }
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
