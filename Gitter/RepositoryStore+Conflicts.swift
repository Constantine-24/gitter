import AppKit
import Foundation
import GitCore

/// What the resolver offers for a document (spec, "App"; Ruling 12): the whole-file writes, and
/// the actions on the file as it is. Resolve File is focus mode's, on the file's draft.
enum ResolverOffer {
    /// The buttons, in order. Delete only for a deletion (DU, UD, DD) and Keep only for DU/UD
    /// (Ruling 12); a one-sided add keeps its one side; Open in Editor and Mark Resolved only with
    /// a file on disk; a submodule gets nothing.
    static func actions(for document: ConflictDocument) -> [ResolverAction] {
        let file = document.snapshot.file
        var actions: [ResolverAction] = []
        switch document.presentation {
        case .submodule:
            return []
        case .blocks:
            actions += [.takeOurs, .takeTheirs]
        case .wholeFile:
            switch file.kind {
            case .deletedByUs, .deletedByThem: actions += [.keep, .delete]
            case .bothDeleted: actions += [.delete]
            case .addedByUs: actions += [.takeOurs]
            case .addedByThem: actions += [.takeTheirs]
            case .bothModified, .bothAdded: actions += [.takeOurs, .takeTheirs]
            }
        }
        if document.worktree != nil, file.kind != .bothDeleted { actions += [.openInEditor, .markResolved] }
        return actions
    }
}

/// A conflicted file whose read failed: its path and git's words (B4 item 4).
struct ConflictLoadFailure: Equatable {
    let path: String
    let message: String
}

/// The resolver: reading the selected conflict (and, in focus mode, its draft), and the writes —
/// Take Ours/Theirs, Delete, Keep, Mark Resolved, Reopen Conflict, and the one every write runs
/// through (`runResolution`), Resolve File's included (`RepositoryStore+Resolver`).
///
/// Nothing is written while the user chooses. Every write hands GitCore the `ConflictSnapshot`
/// the resolver showed, and GitCore refuses (`.changedSinceShown`) when the stages or the file
/// moved on. Bytes git did not write are never replaced silently: GitCore refuses
/// (`.wouldReplaceEdits`), the Replace sheet asks, and the confirmed write files them in the
/// Stashes list first. Every write goes through `mutate`; `ConflictWording` holds every sentence.
extension RepositoryStore {

    // MARK: - State

    /// The document for the working copy's selected file, while that file is unmerged and its
    /// read has landed — never a document about another path, or about a conflict since resolved.
    var selectedConflict: ConflictDocument? {
        guard selection == .workingCopy, let selectedPath, let document = conflictDocument,
            document.snapshot.file.path == selectedPath, selectedFileIsUnmerged
        else { return nil }
        return document
    }

    var conflictSides: SideLabels {
        ConflictWording.sides(operation: operationInProgress, progress: conflictProgress, branch: currentBranch)
    }

    /// Why the resolver's buttons are off: a sheet is up, or another change is running.
    var conflictActionBlockedReason: String? {
        if activeSheet != nil { return ConflictWording.blockedBySheet }
        if isMutating { return ConflictWording.busy }
        return nil
    }

    // MARK: - Loading

    /// Reads the selected file's conflict — or, for a resolved file during an operation, whether
    /// it can be reopened. Called with every diff load (a selection, a side, a snapshot). The
    /// last document stays on screen while the same path is read again; focus mode's draft is
    /// opened from the read, and never replaced by a later one.
    // internal (not private): used by +Detail.swift's `loadDiff()`
    func loadConflict() {
        conflictTask?.cancel()
        guard let root, selection == .workingCopy, let path = selectedPath,
            let file = snapshot?.status.files.first(where: { $0.path == path })
        else {
            setConflict(nil, progress: nil)
            setConflictLoadFailure(nil)
            setReopenablePath(nil)
            return
        }
        if conflictDocument?.snapshot.file.path != path { setConflict(nil, progress: nil) }
        // Kept while the same path is read again, as the document is.
        if conflictLoadFailure?.path != path { setConflictLoadFailure(nil) }
        if reopenablePath != path { setReopenablePath(nil) }
        let generation = self.generation
        let operation = operationInProgress

        if let conflicted = file.conflict {
            setReopenablePath(nil)
            conflictTask = Task { [self] in
                do {
                    #if DEBUG
                        if DebugLaunchHooks.conflictReadFails { throw DebugLaunchHooks.ConflictReadFailed() }
                    #endif
                    let document = try await backend.conflictDocument(for: conflicted, at: root)
                    let progress = operation == nil ? nil : try? await backend.operationProgress(at: root)
                    guard !Task.isCancelled, self.generation == generation, selectedPath == path,
                        selection == .workingCopy
                    else { return }
                    setConflict(document, progress: progress)
                    setConflictLoadFailure(nil)
                    // Focus mode's draft: the stages for its columns, read with the document
                    // (a failure is this read's failed state, below).
                    if resolverFocus?.path == path, resolverDrafts[path] == nil, case .blocks = document.presentation {
                        let sides = try await backend.conflictSides(document.snapshot, at: root)
                        guard !Task.isCancelled, self.generation == generation, selectedPath == path,
                            selection == .workingCopy
                        else { return }
                        openDraft(document, sides: sides)
                    }
                    // A whole-file kind's side columns show its stages (Ruling 23); a failed read
                    // leaves them their short descriptions, never the failed state.
                    if resolverFocus?.path == path, case .wholeFile = document.presentation,
                        resolverWholeFileSides?.file != conflicted
                    {
                        let sides = try? await backend.conflictSides(document.snapshot, at: root)
                        guard !Task.isCancelled, self.generation == generation, selectedPath == path,
                            selection == .workingCopy
                        else { return }
                        setResolverWholeFileSides(sides.map { ResolverWholeFileSides(file: conflicted, sides: $0) })
                    }
                } catch {
                    guard !Task.isCancelled, self.generation == generation, selectedPath == path,
                        selection == .workingCopy
                    else { return }
                    // The failed state carries the message; a banner would be erased by the next
                    // reload within moments.
                    setConflict(nil, progress: nil)
                    setConflictLoadFailure(
                        ConflictLoadFailure(
                            path: path,
                            message: Self.describe(error).trimmingCharacters(in: .whitespacesAndNewlines)))
                }
            }
            return
        }

        setConflict(nil, progress: nil)
        setConflictLoadFailure(nil)
        // Only a resolved path can be reopened, and only while its operation is in progress.
        guard operation != nil, file.staged != nil, !isUnmerged(file) else {
            setReopenablePath(nil)
            return
        }
        conflictTask = Task { [self] in
            let reopenable = (try? await backend.canReopen(path, at: root)) ?? false
            guard !Task.isCancelled, self.generation == generation, selectedPath == path else { return }
            setReopenablePath(reopenable ? path : nil)
        }
    }

    // MARK: - Writes

    func takeSide(_ side: ConflictSide) {
        guard let document = selectedConflict else { return }
        resolve(.take(side), in: document)
    }

    func deleteConflictedFile() {
        guard let document = selectedConflict else { return }
        resolve(.delete, in: document)
    }

    func keepConflictedFile() {
        guard let document = selectedConflict else { return }
        resolve(.keep, in: document)
    }

    /// The whole-file write the resolver offered for this document, or nothing: the buttons are
    /// the offer, and the debug hooks call straight in. Resolve File is not one of these. A draft
    /// of the file with changes is asked about first (`confirmDiscardingDrafts`, Task 7).
    private func resolve(_ pending: PendingResolution, in document: ConflictDocument) {
        guard conflictActionBlockedReason == nil else { return }
        let action: ResolverAction? =
            switch pending {
            case .blocks, .text: nil
            case .take(let side): side == .ours ? .takeOurs : .takeTheirs
            case .delete: .delete
            case .keep: .keep
            }
        guard let action, ResolverOffer.actions(for: document).contains(action) else { return }
        confirmDiscardingDrafts(for: [document.snapshot.file.path]) { [self] in
            runResolution(pending, document.snapshot, recordIfEdited: false)
        }
    }

    /// The Replace sheet's destructive button, **only** as the answer to the sheet that asked
    /// about this snapshot and this resolution. GitCore files the edited bytes first.
    func confirmReplaceHandEdited(_ snapshot: ConflictSnapshot, _ pending: PendingResolution) {
        guard case .replaceHandEdited(let shown, let asked) = activeSheet, shown == snapshot, asked == pending
        else { return }
        activeSheet = nil
        runResolution(pending, snapshot, recordIfEdited: true)
    }

    /// Runs one resolving write. Without `recordIfEdited`, bytes git did not write make GitCore
    /// refuse before anything is written, and the Replace sheet asks instead.
    // internal (not private): used by +Resolver.swift's `resolveFocusedFile`
    func runResolution(_ pending: PendingResolution, _ snapshot: ConflictSnapshot, recordIfEdited: Bool) {
        let sides = conflictSides
        mutate(result: { backend, root -> ConflictReceipt? in
            do {
                return try await Self.perform(pending, snapshot, recordIfEdited: recordIfEdited, backend, root)
            } catch let refusal as ConflictError {
                if case .wouldReplaceEdits = refusal, !recordIfEdited { return nil }
                throw refusal
            }
        }, onSuccess: { [self] receipt in
            guard let receipt else {
                if activeSheet == nil { activeSheet = .replaceHandEdited(snapshot, pending) }
                return
            }
            announce(ConflictWording.done(pending, receipt, sides), recorded: receipt.recorded)
            resolverDidResolve([receipt.path])
        })
    }

    private static func perform(
        _ pending: PendingResolution, _ snapshot: ConflictSnapshot, recordIfEdited: Bool, _ backend: Backend,
        _ root: URL
    ) async throws -> ConflictReceipt {
        switch pending {
        case .blocks(let choices):
            try await backend.resolve(snapshot, choices: choices, recordIfEdited: recordIfEdited, at: root)
        case .text(let bytes):
            try await backend.resolve(snapshot, text: bytes, recordIfEdited: recordIfEdited, at: root)
        case .take(let side):
            try await backend.take(side, snapshot, recordIfEdited: recordIfEdited, at: root)
        case .delete:
            try await backend.delete(snapshot, recordIfEdited: recordIfEdited, at: root)
        case .keep:
            try await backend.keep(snapshot, recordIfEdited: recordIfEdited, at: root)
        }
    }

    /// A transient notice, or — when an entry was filed — a sticky one that offers it.
    private func announce(_ text: String, recorded: Stash?) {
        if let recorded {
            showStickyNotice(Notice(text: text, actions: [.showStash(recorded)]))
        } else {
            showNotice(text)
        }
    }

    // MARK: - Mark Resolved

    /// Mark Resolved: stages the file as it is, after counting the markers left in it — and,
    /// first, asking about a draft of it with changes (Task 7).
    func markSelectedResolved() {
        guard let document = selectedConflict, conflictActionBlockedReason == nil,
            ResolverOffer.actions(for: document).contains(.markResolved)
        else { return }
        confirmDiscardingDrafts(for: [document.snapshot.file.path]) { [self] in
            markResolved(document.snapshot, allowingMarkers: false)
        }
    }

    /// The row's stage button on an unmerged file (Space, the + button): the same Mark Resolved,
    /// so `git add` never takes leftover markers unasked (M 10), and a draft with changes is asked
    /// about first (Task 7). The snapshot is the stages the row shows and the file as it is at
    /// the click.
    func markResolved(_ file: ConflictedFile) {
        guard let root, conflictActionBlockedReason == nil else { return }
        let snapshot = ConflictSnapshot(file: file, worktreeHash: ConflictSnapshot.worktreeHash(of: file.path, at: root))
        confirmDiscardingDrafts(for: [file.path]) { [self] in
            markResolved(snapshot, allowingMarkers: false)
        }
    }

    /// The Mark Resolved sheet's destructive button, only as the answer to the sheet about
    /// this snapshot.
    func confirmMarkResolved(_ snapshot: ConflictSnapshot) {
        guard case .markResolved(let shown, _) = activeSheet, shown == snapshot else { return }
        activeSheet = nil
        markResolved(snapshot, allowingMarkers: true)
    }

    private func markResolved(_ snapshot: ConflictSnapshot, allowingMarkers: Bool) {
        let path = snapshot.file.path
        mutate(result: { backend, root -> Int? in
            do {
                try await backend.markResolved(snapshot, allowingMarkers: allowingMarkers, at: root)
                return nil
            } catch let refusal as ConflictError {
                if case .leftoverMarkers(let count) = refusal, !allowingMarkers { return count }
                throw refusal
            }
        }, onSuccess: { [self] markers in
            guard let markers else {
                showNotice(ConflictWording.marked(path))
                resolverDidResolve([path])
                return
            }
            if activeSheet == nil { activeSheet = .markResolved(snapshot, markers: markers) }
        })
    }

    // MARK: - Reopen

    /// Reopen Conflict…: offered only for the file `canReopen` said yes to, and always asked.
    /// The sheet carries the file's hash now — a change while it is up is refused by GitCore —
    /// what `restore --merge` will write (text gets markers, a binary the ours side's bytes, a
    /// mode-only add the ours side's mode), and the side names to say it with: a resolved file
    /// has no conflict read, so the operation's progress is read here too.
    func requestReopen(_ path: String) {
        guard reopenablePath == path, let root, conflictActionBlockedReason == nil else { return }
        let hash = ConflictSnapshot.worktreeHash(of: path, at: root)
        let generation = self.generation
        let operation = operationInProgress
        let branch = currentBranch
        Task { [self] in
            let comesBack: ReopenedFile?
            do {
                comesBack = try await backend.reopenedFile(path, at: root)
            } catch {
                guard self.generation == generation else { return }
                showStickyError(Self.describe(error))
                return
            }
            let progress = operation == nil ? nil : try? await backend.operationProgress(at: root)
            guard self.generation == generation, activeSheet == nil, reopenablePath == path else { return }
            guard let comesBack else {
                showStickyError(ConflictWording.error(.notAvailable(path)))
                return
            }
            let sides = ConflictWording.sides(operation: operation, progress: progress, branch: branch)
            activeSheet = .reopen(path: path, hash: hash, comesBack: comesBack, sides: sides)
        }
    }

    func confirmReopen(_ path: String) {
        guard case .reopen(let shown, let hash, _, _) = activeSheet, shown == path else { return }
        activeSheet = nil
        mutate(result: { backend, root in
            try await backend.reopen(path, expectingWorktreeHash: hash, at: root)
        }, onSuccess: { [self] receipt in
            announce(ConflictWording.reopened(receipt), recorded: receipt.recorded)
        })
    }

    // MARK: - Elsewhere

    /// Open in Editor: the file in its default app.
    func openInEditor(_ path: String) {
        guard let root else { return }
        NSWorkspace.shared.open(root.appendingPathComponent(path))
    }

    /// A notice's Show Copy: the entry, found again by sha, in the detail pane.
    func showOfferedStash(_ offered: Stash) {
        guard let current = StashList.resolve(sha: offered.sha, in: stashes) else {
            showStickyNotice(Notice(text: StashWording.offeredStashGone))
            return
        }
        select(.stash(current.sha))
    }
}
