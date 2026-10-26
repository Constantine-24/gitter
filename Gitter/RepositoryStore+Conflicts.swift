import AppKit
import Foundation
import GitCore

/// The resolver's block choices: in memory only, for the `ConflictSnapshot` they were made
/// against. A different snapshot — other stages, other worktree bytes, another file, none —
/// drops them, so a choice can never be applied to a conflict it was not made for.
struct ResolverChoices: Equatable {
    private(set) var snapshot: ConflictSnapshot?
    private(set) var blockCount = 0
    /// Keyed by block index, 0-based.
    private(set) var choices: [Int: BlockChoice] = [:]

    /// The document now on screen, and how many blocks it shows (0 when it shows none).
    mutating func show(_ snapshot: ConflictSnapshot?, blockCount: Int) {
        let count = snapshot == nil ? 0 : blockCount
        if snapshot != self.snapshot || count != self.blockCount { choices = [:] }
        self.snapshot = snapshot
        self.blockCount = count
    }

    /// Ignored for a block that is not shown.
    mutating func choose(_ index: Int, _ choice: BlockChoice) {
        guard snapshot != nil, (0..<blockCount).contains(index) else { return }
        choices[index] = choice
    }

    /// One choice per block in order — what Resolve File writes — or nil while any is missing.
    var ordered: [BlockChoice]? {
        guard blockCount > 0 else { return nil }
        let list = (0..<blockCount).compactMap { choices[$0] }
        return list.count == blockCount ? list : nil
    }

    var remaining: Int { blockCount - choices.count }
}

/// What the resolver offers for a document (spec, "App"; Ruling 12).
enum ResolverOffer {
    /// The blocks the chooser shows: a `.blocks` document that is still what git wrote. In the
    /// "changed since the conflict" state there is no chooser.
    static func blocks(of document: ConflictDocument) -> [ConflictBlock]? {
        guard document.matchesGitsConflict, case .blocks(let segments) = document.presentation else { return nil }
        return segments.compactMap { if case .block(let block) = $0 { block } else { nil } }
    }

    /// The buttons, in order. Resolve File only with the chooser; Delete only for a deletion
    /// (DU, UD, DD) and Keep only for DU/UD (Ruling 12); a one-sided add keeps its one side; Open
    /// in Editor and Mark Resolved only with a file on disk; a submodule gets nothing.
    static func actions(for document: ConflictDocument) -> [ResolverAction] {
        let file = document.snapshot.file
        var actions: [ResolverAction] = []
        switch document.presentation {
        case .submodule:
            return []
        case .blocks:
            if blocks(of: document) != nil { actions.append(.resolveFile) }
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

/// What the chooser previews: GitCore's own composition (`ConflictBlock.composed`,
/// `ConflictSegment.composed`), the bytes Resolve File writes.
enum ResolverPreview {
    static func block(_ block: ConflictBlock, _ choice: BlockChoice?) -> Data? {
        choice.map(block.composed)
    }

    /// The whole file, once every block has a choice.
    static func file(_ segments: [ConflictSegment], _ choices: ResolverChoices) -> Data? {
        choices.ordered.flatMap { ConflictSegment.composed(segments, choices: $0) }
    }

    /// Bytes as the chooser shows them: UTF-8 (anything else replaced), line endings as plain
    /// line breaks, without the last one; `emptySide` for nothing at all.
    static func text(_ data: Data) -> String {
        guard !data.isEmpty else { return ConflictWording.emptySide }
        var text = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        if text.hasSuffix("\n") { text.removeLast() }
        return text
    }
}

/// A conflicted file whose read failed: its path and git's words (B4 item 4).
struct ConflictLoadFailure: Equatable {
    let path: String
    let message: String
}

/// The resolver: reading the selected conflict, the in-memory block choices, and the writes —
/// Resolve File, Take Ours/Theirs, Delete, Keep, Mark Resolved, Reopen Conflict.
///
/// Nothing is written while the user chooses. Every write hands GitCore the `ConflictSnapshot`
/// the resolver showed, and GitCore refuses (`.changedSinceShown`) when the stages or the file
/// moved on. Bytes git did not write are never replaced silently: GitCore refuses
/// (`.wouldReplaceEdits`), the Replace sheet asks, and the confirmed write files them in the
/// Stashes list first. Every write goes through `mutate`; `ConflictWording` holds every sentence.
extension RepositoryStore {

    // MARK: - State

    var blockChoices: [Int: BlockChoice] { resolverChoices.choices }

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
    /// last document stays on screen while the same path is read again, and the choices stay
    /// with it while its snapshot is the same.
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

    // MARK: - Choosing

    func chooseBlock(_ index: Int, _ choice: BlockChoice) {
        guard selectedConflict != nil else { return }
        setBlockChoice(index, choice)
    }

    // MARK: - Writes

    /// Resolve File: the chosen blocks, one per block, written and staged.
    func resolveSelectedFile() {
        guard let document = selectedConflict, resolverChoices.snapshot == document.snapshot,
            let choices = resolverChoices.ordered
        else { return }
        resolve(.blocks(choices), in: document)
    }

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

    /// The action the resolver offered for this document, or nothing: the buttons are the
    /// offer, and the debug hooks call straight in.
    private func resolve(_ pending: PendingResolution, in document: ConflictDocument) {
        guard conflictActionBlockedReason == nil else { return }
        let action: ResolverAction =
            switch pending {
            case .blocks: .resolveFile
            case .take(let side): side == .ours ? .takeOurs : .takeTheirs
            case .delete: .delete
            case .keep: .keep
            }
        guard ResolverOffer.actions(for: document).contains(action) else { return }
        runResolution(pending, document.snapshot, recordIfEdited: false)
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
    private func runResolution(_ pending: PendingResolution, _ snapshot: ConflictSnapshot, recordIfEdited: Bool) {
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
        })
    }

    private static func perform(
        _ pending: PendingResolution, _ snapshot: ConflictSnapshot, recordIfEdited: Bool, _ backend: Backend,
        _ root: URL
    ) async throws -> ConflictReceipt {
        switch pending {
        case .blocks(let choices):
            try await backend.resolve(snapshot, choices: choices, recordIfEdited: recordIfEdited, at: root)
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

    /// Mark Resolved: stages the file as it is, after counting the markers left in it.
    func markSelectedResolved() {
        guard let document = selectedConflict, conflictActionBlockedReason == nil,
            ResolverOffer.actions(for: document).contains(.markResolved)
        else { return }
        markResolved(document.snapshot, allowingMarkers: false)
    }

    /// The row's stage button on an unmerged file: the same Mark Resolved, so `git add` never
    /// takes leftover markers unasked (M 10). The snapshot is the stages the row shows and the
    /// file as it is at the click.
    func markResolved(_ file: ConflictedFile) {
        guard let root, conflictActionBlockedReason == nil else { return }
        let snapshot = ConflictSnapshot(file: file, worktreeHash: ConflictSnapshot.worktreeHash(of: file.path, at: root))
        markResolved(snapshot, allowingMarkers: false)
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
