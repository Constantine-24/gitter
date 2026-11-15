import Foundation
import GitCore

/// A row's trailing text in focus mode's sidebar (`ConflictWording.sidebarStatus`).
enum ResolverRowStatus: Hashable, Sendable {
    /// Its read has not landed: no text, never a guessed number (Ruling 19).
    case pending
    /// Conflicts still waiting: the draft's live count, else the file's summary.
    case left(Int)
    /// A kind with no blocks: binary, symlink, mode-only, a deletion, one side only, a merge
    /// attribute, unparsable, a submodule.
    case wholeFile
    /// Resolved in focus mode since it opened.
    case resolved
    /// A draft kept after its file was resolved or its operation ended: shown, never written.
    case readOnly
}

/// One row of focus mode's sidebar.
struct ResolverRow: Hashable, Identifiable, Sendable {
    let path: String
    let status: ResolverRowStatus
    /// Still unmerged: a whole-file take for several files can include it.
    let isConflicted: Bool

    var id: String { path }
    var name: String { (path as NSString).lastPathComponent }
    /// The folder, nil at the repository's top.
    var folder: String? {
        let folder = (path as NSString).deletingLastPathComponent
        return folder.isEmpty ? nil : folder
    }
}

/// A bar above the columns (`ConflictWording.bar`).
enum ResolverBar: Hashable, Sendable {
    /// The worktree is not what git wrote: the Result starts from git's conflict, and resolving
    /// replaces the edits (a copy is kept, through the Replace sheet).
    case editedAfterConflict
    /// The file or its stages changed under the draft: Reload, Keep Editing, Copy Result.
    case changedOutside
    /// The file is no longer unmerged: Copy Result.
    case resolvedOutside
    /// The operation ended: Copy Result.
    case operationEnded
    /// The Result can't be typed into, and why.
    case notEditable(NotEditable)
}

/// What focus mode's centre shows for the focused file.
enum ResolverCentre: Hashable, Sendable {
    /// The three columns, on the file's draft.
    case columns
    /// Today's whole-file explanation and choices, as large buttons.
    case wholeFile(WholeFileReason)
    case submodule
    /// Today's failed state (B4): git's words.
    case failed(String)
    /// Every file is resolved: nothing left to show.
    case allResolved
    /// The read, or the draft, is still to land.
    case loading
}

/// Where focus mode's focus goes from a path that has lost its conflict and its draft
/// (`ResolverShell.focusAfterLosing`).
enum ResolverFocusMove: Hashable, Sendable {
    /// The path still has a conflict record or a draft.
    case stay
    /// The next file with conflicts.
    case moveTo(String)
    /// No file has conflicts any more.
    case allResolved
}

/// ⌘Z or ⇧⌘Z in focus mode (`ResolverShell.undoKey`).
enum ResolverUndoKey: Hashable, Sendable { case undo, redo }

/// What Return and a double-click do to a working-copy row.
enum RowPrimaryAction: Hashable, Sendable {
    /// A conflicted file: focus mode on it.
    case openResolver
    /// Any other: stage or unstage, as the row's button does.
    case toggle
}

/// Focus mode's shell, decided without a view (spec, "Conflict resolver"): each function maps the
/// store's state to what a control shows or does. `ResolverShellTests` pins each one; every
/// sentence is `ConflictWording`'s.
enum ResolverShell {

    // MARK: - The card and the working copy

    /// The card's "N conflicts": the document's blocks, also for a file edited since git wrote
    /// the conflict (whose Result starts from git's conflict). Nil for a kind with no blocks.
    static func conflictCount(of document: ConflictDocument) -> Int? {
        guard case .blocks(let segments) = document.presentation else { return nil }
        return segments.count { if case .block = $0 { true } else { false } }
    }

    static func primaryAction(for file: FileStatus) -> RowPrimaryAction {
        file.conflict == nil ? .toggle : .openResolver
    }

    // MARK: - The toolbar and the bottom bar

    /// Abort… is there only with an operation to abort: a stash apply's conflicts have none.
    static func showsAbort(_ operation: RepositoryOperation?) -> Bool { operation != nil }

    /// Resolve File: a draft that may be written (Ruling 17), nothing waiting, nothing in the way.
    static func resolveFileEnabled(_ draft: ResolverDraft?, blocked: String?) -> Bool {
        guard let draft, blocked == nil else { return false }
        return draft.isWritable && draft.document.waitingCount == 0
    }

    /// Resolve File's tooltip: what is in the way, else why the draft can't be written (a
    /// detached one, Ruling 17), else what it does or how many conflicts are left.
    static func resolveFileHelp(_ draft: ResolverDraft, blocked: String?) -> String {
        if let blocked { return blocked }
        if let detached = draft.detached { return ConflictWording.notWritableHelp(detached) }
        return ConflictWording.resolveHelp(remaining: draft.document.waitingCount)
    }

    /// Done is the default button once every file is resolved — what is left is Continue, in the
    /// normal window — and once the operation has ended (Ruling 24).
    static func doneIsDefault(allResolved: Bool, ended: Bool) -> Bool { allResolved || ended }

    /// The operation that ended while focus mode kept drafts from it: the one remembered, while a
    /// draft is still `.operationEnded` (Ruling 24).
    static func endedOperation(_ drafts: [String: ResolverDraft], remembered: RepositoryOperation?)
        -> RepositoryOperation?
    {
        guard let remembered, drafts.values.contains(where: { $0.detached == .operationEnded }) else { return nil }
        return remembered
    }

    /// The line under the title: that the operation ended (Ruling 24), else the operation's own
    /// words, else where conflicts with no operation come from (Ruling 20).
    static func subtitle(
        _ operation: RepositoryOperation?, _ progress: OperationProgress?, branch: String?, ended: RepositoryOperation?
    ) -> String {
        if let ended { return ConflictWording.operationEndedOutside(ended) }
        return ConflictWording.focusSubtitle(operation, progress, branch: branch)
    }

    /// "Conflict N of M" in the focused file, nil without a draft or a current conflict.
    static func position(_ draft: ResolverDraft?, current: Int?) -> String? {
        guard let draft, let current else { return nil }
        let ids = RepositoryStore.conflictIDs(draft.document)
        guard let index = ids.firstIndex(of: current) else { return nil }
        return ConflictWording.position(index, of: ids.count)
    }

    /// The sidebar footer's line: until every file is resolved, that the operation's Continue
    /// comes back then (Ruling 21; none for `git am`, which Gitter does not continue, nor with no
    /// operation); after, the spec's all-resolved line; none once the operation has ended.
    static func footerLine(_ operation: RepositoryOperation?, allResolved: Bool, ended: Bool) -> String? {
        // The operation ended: neither line is true any more (Ruling 24).
        if ended { return nil }
        if allResolved { return ConflictWording.allResolved(withOperation: operation != nil) }
        guard let operation, operation != .applyingPatches else { return nil }
        return ConflictWording.comesBack(operation.commitButtonTitle)
    }

    // MARK: - The sidebar

    /// A row's trailing text: Resolved first; then a draft's live state (a draft changed outside
    /// is still edited, Ruling 17; one resolved outside or left by its operation is read-only);
    /// then the cached summary (Ruling 19); else nothing yet.
    static func rowStatus(resolved: Bool, draft: ResolverDraft?, summary: ResolverFileSummary?) -> ResolverRowStatus {
        if resolved { return .resolved }
        if let draft {
            return draft.isEditable ? .left(draft.document.waitingCount) : .readOnly
        }
        switch summary {
        case .conflicts(let count)?: return .left(count)
        case .wholeFile?: return .wholeFile
        case nil: return .pending
        }
    }

    /// Every conflicted file, every file resolved this session and every draft kept after its
    /// file stopped being conflicted, once each, in git's order (bytes), so a row never moves
    /// when its file is resolved.
    static func rows(
        files: [ConflictedFile], resolved: [String], drafts: [String: ResolverDraft],
        summaries: [String: ResolverFileSummary]
    ) -> [ResolverRow] {
        let conflicted = Set(files.map(\.path))
        let paths = conflicted.union(resolved).union(drafts.keys)
        return paths.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }.map { path in
            ResolverRow(
                path: path,
                // Resolved wins while the reload after the write is still to land.
                status: rowStatus(resolved: resolved.contains(path), draft: drafts[path], summary: summaries[path]),
                isConflicted: conflicted.contains(path))
        }
    }

    /// Which file a sidebar selection focuses: one file clicked moves focus mode to it; several
    /// (⌘- or ⇧-click) are the selection for a take and move nothing; the focused file again,
    /// nothing.
    static func focusAfterSelection(_ selection: Set<String>, focused: String?) -> String? {
        guard selection.count == 1, let path = selection.first, path != focused else { return nil }
        return path
    }

    /// "K of N files resolved": a read-only row (resolved outside, or its operation ended) is
    /// neither to do nor resolved here, so it counts in neither (Ruling 24).
    static func progress(_ rows: [ResolverRow]) -> (resolved: Int, total: Int) {
        let counted = rows.filter { $0.status != .readOnly }
        return (counted.count { $0.status == .resolved }, counted.count)
    }

    /// Where the focus goes from `path` when it has neither a conflict record nor a draft (its
    /// draft discarded, or dropped as read-only): the next file with conflicts in git's order,
    /// wrapping round, else the all-resolved state — never a read that will not come (Ruling 26).
    static func focusAfterLosing(_ path: String, files: [String], drafts: Set<String>) -> ResolverFocusMove {
        if files.contains(path) || drafts.contains(path) { return .stay }
        let sorted = files.sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        guard let next = sorted.first(where: { path.utf8.lexicographicallyPrecedes($0.utf8) }) ?? sorted.first else {
            return .allResolved
        }
        return .moveTo(next)
    }

    // MARK: - Above the columns

    /// The Result menu's Reload…: only for a draft changed outside, the one state with something
    /// newer to read (Ruling 26).
    static func offersReload(_ draft: ResolverDraft) -> Bool { draft.detached == .changedOutside }

    /// Reload asks first when it would discard what the user took or typed.
    static func reloadAsks(_ draft: ResolverDraft) -> Bool { draft.hasUserChanges }


    /// Whether Keep Editing was pressed for this draft: it is kept per draft snapshot, so a
    /// draft read again is a new one (Ruling 18).
    static func keptEditing(_ draft: ResolverDraft, kept: ConflictSnapshot?) -> Bool {
        kept == draft.snapshot
    }

    /// The bars over the focused draft, top to bottom: one bar for the draft's state, then why
    /// the Result can't be typed into (a separate kind). The state's bar is the detachment's when
    /// the draft is detached — changed outside (unless Keep Editing hid it), resolved, ended — and
    /// never "edited after the conflict" as well; attached, it is "edited after the conflict" when
    /// the file is not what git wrote.
    static func bars(_ draft: ResolverDraft, matchesGitsConflict: Bool, keptEditing: Bool) -> [ResolverBar] {
        var bars: [ResolverBar] = []
        switch draft.detached {
        case .changedOutside?: if !keptEditing { bars.append(.changedOutside) }
        case .resolvedOutside?: bars.append(.resolvedOutside)
        case .operationEnded?: bars.append(.operationEnded)
        case nil: if !matchesGitsConflict { bars.append(.editedAfterConflict) }
        }
        if let reason = draft.document.notEditable { bars.append(.notEditable(reason)) }
        return bars
    }

    // MARK: - The centre

    /// The draft's columns; else what the focused file's read says, if it is this file's; else
    /// the all-resolved state or a read still to land.
    static func centre(
        path: String?, draft: ResolverDraft?, document: ConflictDocument?, failure: ConflictLoadFailure?,
        allResolved: Bool
    ) -> ResolverCentre {
        if draft != nil { return .columns }
        if let path, let failure, failure.path == path { return .failed(failure.message) }
        if let path, let document, document.snapshot.file.path == path {
            switch document.presentation {
            case .wholeFile(let reason): return .wholeFile(reason)
            case .submodule: return .submodule
            case .blocks: return .loading
            }
        }
        return allResolved ? .allResolved : .loading
    }

    // MARK: - Escape

    /// Escape is Done in focus mode's own window, with no sheet up, no modifier, and no text
    /// being edited (the Result's text view, a field editor): there it is the text's.
    static func escapeIsDone(isEscape: Bool, modified: Bool, ownWindow: Bool, sheetUp: Bool, editingText: Bool) -> Bool {
        isEscape && !modified && ownWindow && !sheetUp && !editingText
    }

    /// ⌘Z (undo) and ⇧⌘Z (redo) are the store's in focus mode's own window with no sheet up,
    /// wherever the keys are, but in a text field being edited other than the Result (a sheet's,
    /// a search field's), whose undo is its own.
    static func undoKey(
        key: String, command: Bool, shift: Bool, otherModifiers: Bool, ownWindow: Bool, sheetUp: Bool,
        editingOtherText: Bool
    ) -> ResolverUndoKey? {
        guard key.lowercased() == "z", command, !otherModifiers, ownWindow, !sheetUp, !editingOtherText else { return nil }
        return shift ? .redo : .undo
    }
}
