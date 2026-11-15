import AppKit
import Foundation
import GitCore

/// Why a draft is kept but never written: something outside Gitter changed what it was read from.
enum DraftDetachment: Hashable, Sendable {
    /// The file or its index stages are no longer the draft's snapshot (a terminal, an editor).
    /// Still editable — Keep Editing — but never written over the newer file (Ruling 17).
    case changedOutside
    /// The path is no longer unmerged.
    case resolvedOutside
    /// The operation focus mode opened under has ended.
    case operationEnded

    /// A later detachment replaces an earlier one only when it says more: the operation's end
    /// over the file's resolution over a change.
    fileprivate var rank: Int {
        switch self {
        case .changedOutside: 1
        case .resolvedOutside: 2
        case .operationEnded: 3
        }
    }
}

/// One file's Result in focus mode: the document, the stages it was read with, the snapshot
/// every write carries, its undo history, and — when something outside changed the file — why
/// it can no longer be written (and, unless only the file changed, no longer edited).
struct ResolverDraft: Hashable, Sendable {
    var document: ResolverDocument
    let sides: ConflictSides
    let snapshot: ConflictSnapshot
    var history: ResolverHistory
    var detached: DraftDetachment?

    /// Anything taken or typed since it was read (never `==` between documents, Ruling 5).
    var hasUserChanges: Bool { !document.isPristine }

    /// Takes, typing, undo and redo work: attached, or changed outside — the spec's Keep
    /// Editing (Ruling 17). Resolved outside or left by its operation, the draft is read-only.
    var isEditable: Bool { detached == nil || detached == .changedOutside }

    /// Resolve File may write it: only while attached. A draft changed outside is never written
    /// over the newer file.
    var isWritable: Bool { detached == nil }
}

/// Focus mode's file, and the conflict (a chunk id of its draft) that keys and takes act on.
struct ResolverFocus: Hashable, Sendable {
    var path: String
    var currentChunk: Int?
}

/// A conflicted file's trailing text in focus mode's sidebar before its draft is read
/// (Ruling 19): how many conflicts it has, or that it has none to choose between.
enum ResolverFileSummary: Hashable, Sendable {
    case conflicts(Int)
    /// Binary, symlink, mode-only, a deletion, one side only, a merge attribute, unparsable, a
    /// submodule.
    case wholeFile
}

/// A summary and the status record it was read for: a reload re-reads only a file whose record
/// changed.
struct ResolverSummary: Hashable, Sendable {
    let record: ConflictedFile
    let summary: ResolverFileSummary
}

/// What Take Ours / Theirs for N Files… will do, read when its sheet opened.
struct TakeForFilesPlan: Hashable, Sendable {
    /// A selected file that is not taken, and why.
    struct Skipped: Hashable, Sendable {
        enum Reason: Hashable, Sendable {
            /// The side has no stage: it deleted the file.
            case noSide
            /// A submodule conflict, which Gitter does not resolve.
            case submodule
        }

        let path: String
        let reason: Reason
    }

    let side: ConflictSide
    /// The files taken, in status order, as their documents were read.
    let files: [ConflictSnapshot]
    /// Of `files`, those edited since git wrote the conflict: filed in the Stashes list first.
    let copies: [String]
    let skipped: [Skipped]
}

/// Focus mode (spec, "Conflict resolver"): the conflicted files of the operation, one draft per
/// file kept in memory until it is written, discarded or left at Done, takes and typing with
/// undo, the two writes, next and previous across files, several files at once, and drafts
/// that outlive outside changes, never written over them.
///
/// The focused file is also the working copy's selected file, so its conflict read
/// (`loadConflict`, which reads the draft's stages with the document), its failure state and
/// the whole-file writes are the existing ones. Every write goes through `runResolution` and its
/// safeguards — the snapshot check, the Replace sheet, the copies — and the marker question
/// comes before any of it. Every sentence is in `ConflictWording`.
extension RepositoryStore {

    // MARK: - State

    /// The conflicted files of the operation, in status order.
    var resolverFiles: [ConflictedFile] {
        snapshot?.status.files.compactMap(\.conflict) ?? []
    }

    /// Focus mode is up and no file is conflicted any more: the all-resolved footer.
    var resolverAllResolved: Bool { resolverFocus != nil && resolverFiles.isEmpty }

    /// The draft of the focused file, once it is read.
    var focusedDraft: ResolverDraft? { resolverFocus.flatMap { resolverDrafts[$0.path] } }

    // MARK: - Entering and leaving

    /// Focus mode on `path`, or (nil) on the first file with conflicts. A file that is not
    /// conflicted and has no draft is not opened.
    func openResolver(at path: String? = nil) {
        guard root != nil, !isClosed else { return }
        let files = resolverFiles.map(\.path)
        guard let target = path ?? files.first, files.contains(target) || resolverDrafts[target] != nil else {
            return
        }
        let entering = resolverFocus == nil
        if entering {
            setResolvedThisSession([])
            if resolverDrafts.isEmpty || resolverOperation == nil { setResolverOperation(operationInProgress) }
        }
        moveFocus(to: target)
        if entering { refreshResolverSummaries() }
    }

    /// Done: back to the normal window. Drafts with changes are kept for next time; pristine
    /// ones go, and so do detached ones (a detached draft lasts until Done).
    func closeResolver() {
        guard resolverFocus != nil else { return }
        setResolverFocus(nil)
        setResolverLandsOnLast(false)
        setResolvedThisSession([])
        setResolverDrafts(resolverDrafts.filter { $0.value.hasUserChanges && $0.value.detached == nil })
        if resolverDrafts.isEmpty { setResolverOperation(nil) }
        resolverSummaryTask?.cancel()
        setResolverSummaries([:])
        setResolverSummariesReading([])
    }

    /// Another file in focus mode; its draft, if any, is as it was left.
    func focusResolverFile(_ path: String) {
        guard resolverFocus != nil, resolverFiles.contains(where: { $0.path == path }) || resolverDrafts[path] != nil
        else { return }
        moveFocus(to: path)
    }

    /// Focuses `path` at its first (or last) conflict, and selects it, which reads it.
    private func moveFocus(to path: String, landOnLast: Bool = false) {
        let ids = resolverDrafts[path].map { Self.conflictIDs($0.document) } ?? []
        setResolverFocus(ResolverFocus(path: path, currentChunk: landOnLast ? ids.last : ids.first))
        setResolverLandsOnLast(landOnLast)
        if selection != .workingCopy { select(.workingCopy) }
        select(path, staged: false)
    }

    /// The draft `loadConflict` read for the focused file: `document` and `sides` were read
    /// together, and are refused — no draft, the write's own "changed after it was shown" —
    /// unless the file and its stages are still what the document was read from. A draft that
    /// exists is never replaced.
    // internal (not private): used by +Conflicts.swift's `loadConflict()`
    func openDraft(_ document: ConflictDocument, sides: ConflictSides) {
        let path = document.snapshot.file.path
        guard resolverFocus?.path == path, resolverDrafts[path] == nil else { return }
        guard isCurrent(document.snapshot) else {
            showStickyError(ConflictWording.error(.changedSinceShown(path)))
            return
        }
        guard let result = ResolverDocument(document: document, sides: sides) else { return }
        setResolverDraft(
            path,
            ResolverDraft(
                document: result, sides: sides, snapshot: document.snapshot, history: ResolverHistory(),
                detached: nil))
        if resolverFocus?.currentChunk == nil {
            let ids = Self.conflictIDs(result)
            setResolverFocus(ResolverFocus(path: path, currentChunk: resolverLandsOnLast ? ids.last : ids.first))
        }
        setResolverLandsOnLast(false)
    }

    /// Whether `snapshot` is still the path's: its stages are the last snapshot's record of it,
    /// and its file hashes the same now.
    ///
    /// This does not catch everything (Ruling 16). The document was read from that same record,
    /// so the stage half only notices a reload that landed during the reads, and an index change
    /// between reading the document and reading the sides can slip through. That is accepted, not
    /// fixed with a second read: such a draft can never be written, because the write checks the
    /// stages again and refuses with "changed after it was shown", and the reload the change
    /// sets off detaches the draft as changed outside.
    private func isCurrent(_ snapshot: ConflictSnapshot) -> Bool {
        guard let root else { return false }
        let path = snapshot.file.path
        let record = self.snapshot?.status.files.first { $0.path == path }?.conflict
        return record == snapshot.file && ConflictSnapshot.worktreeHash(of: path, at: root) == snapshot.worktreeHash
    }

    // MARK: - Taking and typing

    /// Takes `choice` for `chunk`, or (nil) the current conflict — or, with none, the first one
    /// waiting. Taking again replaces the text; undo brings it back. Takes, typing, undo and redo
    /// work on an editable draft (`ResolverDraft.isEditable`): one changed outside included.
    func resolverTake(_ choice: BlockChoice, chunk: Int? = nil) {
        guard let path = resolverFocus?.path, var draft = resolverDrafts[path], draft.isEditable,
            let id = chunk ?? resolverFocus?.currentChunk
                ?? draft.document.chunks.first(where: { $0.state == .waiting })?.id
        else { return }
        var document = draft.document
        guard document.take(choice, chunk: id) else { return }
        draft.history.record(draft.document, coalescingTypingIn: nil, at: Date())
        draft.document = document
        setResolverDraft(path, draft)
        setResolverFocus(ResolverFocus(path: path, currentChunk: id))
    }

    /// Use Ours (Theirs) for the rest: every waiting conflict of the file; taken and edited ones
    /// stay.
    func resolverTakeRest(_ side: ConflictSide) {
        guard let path = resolverFocus?.path, var draft = resolverDrafts[path], draft.isEditable,
            draft.document.waitingCount > 0
        else { return }
        draft.history.record(draft.document, coalescingTypingIn: nil, at: Date())
        draft.document.takeRest(side)
        setResolverDraft(path, draft)
    }

    /// Typing in the Result: `range` (UTF-16) replaced with `text`. Keystrokes in one chunk
    /// within a second are one undo step.
    func resolverReplace(_ range: NSRange, with text: String) {
        guard let path = resolverFocus?.path, var draft = resolverDrafts[path], draft.isEditable else { return }
        var document = draft.document
        guard let id = document.replace(range, with: text) else { return }
        draft.history.record(draft.document, coalescingTypingIn: id, at: Date())
        draft.document = document
        setResolverDraft(path, draft)
        let typedIn = document.chunks.first { $0.id == id }.map { !$0.blocks.isEmpty } ?? false
        setResolverFocus(
            ResolverFocus(path: path, currentChunk: typedIn ? id : Self.anchored(resolverFocus?.currentChunk, in: document)))
    }

    func resolverUndo() {
        step { history, current in history.undo(current) }
    }

    func resolverRedo() {
        step { history, current in history.redo(current) }
    }

    private func step(_ move: (inout ResolverHistory, ResolverDocument) -> ResolverDocument?) {
        guard let path = resolverFocus?.path, var draft = resolverDrafts[path], draft.isEditable,
            let document = move(&draft.history, draft.document)
        else { return }
        draft.document = document
        setResolverDraft(path, draft)
        setResolverFocus(ResolverFocus(path: path, currentChunk: Self.anchored(resolverFocus?.currentChunk, in: document)))
    }

    // MARK: - Next and previous

    /// The next conflict; past the file's last, the next file with conflicts (its first).
    func resolverNextConflict() { moveConflict(forward: true) }

    /// The previous conflict; before the file's first, the previous file with conflicts (its last).
    func resolverPreviousConflict() { moveConflict(forward: false) }

    private func moveConflict(forward: Bool) {
        guard let focus = resolverFocus else { return }
        let ids = resolverDrafts[focus.path].map { Self.conflictIDs($0.document) } ?? []
        let next: Int? =
            if let current = focus.currentChunk {
                forward ? ids.first { $0 > current } : ids.last { $0 < current }
            } else {
                forward ? ids.first : ids.last
            }
        if let next {
            setResolverFocus(ResolverFocus(path: focus.path, currentChunk: next))
            return
        }
        let files = resolverFiles.map(\.path).filter { $0 != focus.path }
        guard !files.isEmpty else { return }
        let after = files.filter { Self.sorts($0, after: focus.path) }
        let before = files.filter { !Self.sorts($0, after: focus.path) }
        let target = forward ? (after.first ?? before.first) : (before.last ?? after.last)
        if let target { moveFocus(to: target, landOnLast: !forward) }
    }

    // MARK: - Resolve File

    /// Resolve File: the Result, written exactly — through the block choices when it is exactly
    /// what they compose (the byte-exact path, and the only one for a file that is not editable),
    /// else as its text. Leftover markers ask first; bytes git did not write raise the Replace
    /// sheet. Refused on any detached draft (`isWritable`), changed outside included, and while a
    /// conflict waits.
    func resolveFocusedFile() {
        guard let path = resolverFocus?.path, let draft = resolverDrafts[path], draft.isWritable,
            draft.document.waitingCount == 0, conflictActionBlockedReason == nil
        else { return }
        let pending: PendingResolution
        if let choices = draft.document.blockChoices() {
            pending = .blocks(choices)
        } else if let bytes = draft.document.bytes(sides: draft.sides) {
            pending = .text(bytes)
        } else {
            return
        }
        if draft.document.leftoverMarkerLines(markerSize: draft.sides.markerSize) > 0 {
            activeSheet = .resolveWithMarkers(draft.snapshot, pending)
            return
        }
        runResolution(pending, draft.snapshot, recordIfEdited: false)
    }

    /// The marker question's button, only as the answer to the question about this snapshot
    /// and this write, and only while its draft is still writable.
    func confirmResolveWithMarkers(_ snapshot: ConflictSnapshot, _ pending: PendingResolution) {
        guard case .resolveWithMarkers(let shown, let asked) = activeSheet, shown == snapshot, asked == pending
        else { return }
        activeSheet = nil
        guard resolverDrafts[snapshot.file.path]?.isWritable ?? true else { return }
        runResolution(pending, snapshot, recordIfEdited: false)
    }

    /// After any resolving write of `paths`: their drafts go, focus mode lists them as Resolved,
    /// and the focus moves on from a resolved focused file — to the next file with a conflict
    /// waiting (wrapping round), else the next conflicted one, else it stays for the
    /// all-resolved footer.
    // internal (not private): used by +Conflicts.swift's writes
    func resolverDidResolve(_ paths: [String]) {
        for path in paths { setResolverDraft(path, nil) }
        guard let focus = resolverFocus else { return }
        setResolvedThisSession(resolvedThisSession + paths.filter { !resolvedThisSession.contains($0) })
        guard paths.contains(focus.path) else { return }
        let files = resolverFiles.map(\.path).filter { !paths.contains($0) }
        let order = files.filter { Self.sorts($0, after: focus.path) } + files.filter { !Self.sorts($0, after: focus.path) }
        let waiting = order.first { path in
            guard let draft = resolverDrafts[path] else { return true }
            return draft.document.waitingCount > 0
        }
        guard let next = waiting ?? order.first else {
            setResolverFocus(ResolverFocus(path: focus.path, currentChunk: nil))
            return
        }
        moveFocus(to: next)
    }

    // MARK: - Several files

    /// Take Ours / Theirs for N Files…: reads each file, then asks with a sheet listing them,
    /// the copies that will be filed first, and the files skipped — a side with no stage (a
    /// deletion) or a submodule — by name.
    func takeSideForFiles(_ paths: [String], _ side: ConflictSide) {
        guard let root, conflictActionBlockedReason == nil else { return }
        let files = resolverFiles.filter { paths.contains($0.path) }
        guard !files.isEmpty else { return }
        let generation = self.generation
        Task { [self] in
            var taken: [ConflictSnapshot] = []
            var copies: [String] = []
            var skipped: [TakeForFilesPlan.Skipped] = []
            do {
                for file in files {
                    if file.isSubmodule {
                        skipped.append(.init(path: file.path, reason: .submodule))
                    } else if (side == .ours ? file.ours : file.theirs) == nil {
                        skipped.append(.init(path: file.path, reason: .noSide))
                    } else {
                        let document = try await backend.conflictDocument(for: file, at: root)
                        taken.append(document.snapshot)
                        if !document.matchesGitsConflict { copies.append(file.path) }
                    }
                }
            } catch {
                guard self.generation == generation else { return }
                showStickyError(Self.describe(error))
                return
            }
            guard self.generation == generation, activeSheet == nil else { return }
            let plan = TakeForFilesPlan(side: side, files: taken, copies: copies, skipped: skipped)
            guard !taken.isEmpty else {
                showStickyError(ConflictWording.takeForFiles(plan, conflictSides).joined(separator: " "))
                return
            }
            activeSheet = .takeForFiles(plan)
        }
    }

    /// The sheet's button, only as the answer to the sheet about this plan: each file taken
    /// whole, those it named as copies filed first. One file refused (it moved on since the
    /// sheet) does not stop the others; its refusal is the banner.
    func confirmTakeForFiles(_ plan: TakeForFilesPlan) {
        guard case .takeForFiles(let shown) = activeSheet, shown == plan else { return }
        activeSheet = nil
        let sides = conflictSides
        mutate(result: { backend, root -> (receipts: [ConflictReceipt], failures: [String]) in
            var receipts: [ConflictReceipt] = []
            var failures: [String] = []
            for snapshot in plan.files {
                do {
                    receipts.append(
                        try await backend.take(
                            plan.side, snapshot, recordIfEdited: plan.copies.contains(snapshot.file.path), at: root))
                } catch {
                    failures.append(Self.describe(error))
                }
            }
            return (receipts, failures)
        }, onSuccess: { [self] outcome in
            if !outcome.receipts.isEmpty {
                let text = ConflictWording.tookForFiles(plan, outcome.receipts, sides)
                if let recorded = outcome.receipts.compactMap(\.recorded).first {
                    showStickyNotice(Notice(text: text, actions: [.showStash(recorded)]))
                } else {
                    show(Notice(text: text, keep: !plan.skipped.isEmpty))
                }
            }
            if !outcome.failures.isEmpty { showStickyError(outcome.failures.joined(separator: " ")) }
            resolverDidResolve(outcome.receipts.map(\.path))
        })
    }

    // MARK: - Drafts

    /// Discard Changes: the draft goes; the focused file is read again from git's conflict.
    func discardDraft(_ path: String) {
        setResolverDraft(path, nil)
        if resolverFocus?.path == path {
            setResolverFocus(ResolverFocus(path: path, currentChunk: nil))
            loadConflict()
        }
    }

    /// Reload, on a draft something outside changed: the file as it is now, read again.
    func reloadDraft(_ path: String) {
        discardDraft(path)
    }

    /// Copy Result: the draft's Result as it is shown. `pasteboard` is the general one from a
    /// menu; a test or the harness passes one of its own.
    func copyResult(_ path: String, to pasteboard: NSPasteboard = .general) {
        guard let draft = resolverDrafts[path] else { return }
        Clipboard.copy(draft.document.resultText, to: pasteboard)
    }

    // MARK: - The sidebar's summaries

    /// While focus mode is up, after it opens and after every reload: each conflicted file's
    /// summary (Ruling 19) — "whole file" straight from its status record where that decides it,
    /// else from its document, read off the main actor through the backend like every other read.
    /// A summary is kept while the file's record is the same, so a reload reads only files whose
    /// record changed; one whose file is no longer conflicted goes. A file with a draft is read
    /// too, but its row shows the draft's own count. A read that fails leaves the row without a
    /// count, never a guess.
    func refreshResolverSummaries() {
        guard let root, resolverFocus != nil, !isClosed else { return }
        let files = resolverFiles
        var summaries = resolverSummaries.filter { entry in files.contains(entry.value.record) }
        var unread: [ConflictedFile] = []
        for file in files where summaries[file.path]?.record != file {
            if let decided = Self.decidedSummary(file) {
                summaries[file.path] = ResolverSummary(record: file, summary: decided)
            } else {
                unread.append(file)
            }
        }
        if summaries != resolverSummaries { setResolverSummaries(summaries) }
        // A read already under way for these files is left to land.
        guard !unread.isEmpty, !Set(unread).isSubset(of: resolverSummariesReading) else { return }
        resolverSummaryTask?.cancel()
        setResolverSummariesReading(unread)
        let generation = self.generation
        resolverSummaryTask = Task { [self] in
            defer { if self.generation == generation, resolverSummariesReading == unread { setResolverSummariesReading([]) } }
            for file in unread {
                // Replaced by a newer read, Done, or another repository: stop reading.
                guard !Task.isCancelled, self.generation == generation, resolverFocus != nil else { return }
                guard let document = try? await backend.conflictDocument(for: file, at: root) else { continue }
                guard !Task.isCancelled, self.generation == generation, resolverFocus != nil else { return }
                guard resolverFiles.contains(file) else { continue }
                let summary: ResolverFileSummary = ResolverShell.conflictCount(of: document).map { .conflicts($0) } ?? .wholeFile
                var next = resolverSummaries
                next[file.path] = ResolverSummary(record: file, summary: summary)
                setResolverSummaries(next)
            }
        }
    }

    /// "Whole file" from the status record alone: a submodule, a symlink, a mode-only add, or a
    /// side with no stage (a deletion, one side only). Anything else needs its document.
    static func decidedSummary(_ file: ConflictedFile) -> ResolverFileSummary? {
        let whole = file.isSubmodule || file.isSymlink || file.isModeOnly || file.ours == nil || file.theirs == nil
        return whole ? .wholeFile : nil
    }

    // MARK: - Outside changes

    /// After every reload: a draft whose file or stages are not its snapshot's any more is kept,
    /// `.changedOutside` — still editable (Keep Editing), never written; one whose path is no longer unmerged `.resolvedOutside`; and
    /// when the operation focus mode opened under has ended, every draft `.operationEnded` —
    /// pristine ones go, focus mode stays only while a draft has changes, and a kept notice says
    /// so. A draft is never re-attached or dropped with changes in it.
    ///
    /// During one of Gitter's own writes this waits for the write to finish (`finishMutation`
    /// calls it again with `afterGitterWrite`): the file that write resolved is not resolved
    /// "outside", and an operation it ended (Abort, Continue) gets no "outside" notice.
    func reconcileResolverDrafts(afterGitterWrite: Bool = false) {
        guard let root, resolverFocus != nil || !resolverDrafts.isEmpty else { return }
        if isMutating {
            setResolverReconcilePending(true)
            return
        }
        let files = snapshot?.status.files ?? []
        let ended = resolverOperation.map { $0 != operationInProgress } ?? false
        var drafts = resolverDrafts
        for (path, draft) in resolverDrafts {
            let record = files.first { $0.path == path }?.conflict
            let reason: DraftDetachment
            if ended {
                reason = .operationEnded
            } else if record == nil {
                reason = .resolvedOutside
            } else if record != draft.snapshot.file
                || ConflictSnapshot.worktreeHash(of: path, at: root) != draft.snapshot.worktreeHash
            {
                reason = .changedOutside
            } else {
                continue
            }
            if !draft.hasUserChanges, reason == .operationEnded || (reason == .resolvedOutside && afterGitterWrite) {
                drafts[path] = nil
            } else if (draft.detached?.rank ?? 0) < reason.rank {
                drafts[path]?.detached = reason
            }
        }
        setResolverDrafts(drafts)
        guard ended, let operation = resolverOperation else { return }
        setResolverOperation(nil)
        guard let focus = resolverFocus else { return }
        if let kept = drafts.keys.sorted().first {
            if drafts[focus.path] == nil { setResolverFocus(ResolverFocus(path: kept, currentChunk: nil)) }
        } else {
            closeResolver()
        }
        if !afterGitterWrite { show(Notice(text: ConflictWording.operationEndedOutside(operation), keep: true)) }
    }

    // MARK: - Helpers

    /// The ids of the chunks that hold a conflict, in order.
    nonisolated static func conflictIDs(_ document: ResolverDocument) -> [Int] {
        document.chunks.filter { !$0.blocks.isEmpty }.map(\.id)
    }

    /// `current` when it is still a conflict of `document`, else the conflict before it (an
    /// edit merged it), else the first.
    private static func anchored(_ current: Int?, in document: ResolverDocument) -> Int? {
        let ids = conflictIDs(document)
        guard let current else { return ids.first }
        if ids.contains(current) { return current }
        return ids.last { $0 < current } ?? ids.first
    }

    /// Whether `path` comes after `other` in git's order (bytes), as the status lists them.
    private static func sorts(_ path: String, after other: String) -> Bool {
        other.utf8.lexicographicallyPrecedes(path.utf8)
    }
}
