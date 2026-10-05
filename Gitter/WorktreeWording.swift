import Foundation
import GitCore

/// Which operation holds a worktree's branches (`Worktree.operationBranches`): GitCore reads the
/// branches, and the app reads which of the two it is from the worktree's own git directory, for
/// the mark's words (`WorktreeOperationKind.read`, in `RepositoryStore+Worktrees`).
enum WorktreeOperationKind: Hashable, Sendable {
    case rebase
    case bisect
}

/// What is known about a worktree's changes for its row's mark.
enum WorktreeChangesReading: Hashable, Sendable {
    /// Not read: the main worktree, a missing one, one past the 20 read with each refresh.
    case notRead
    case read(WorktreeChanges)
    /// The read failed: "changes unknown", never a refresh failure (carried note 3).
    case unknown
}

/// One mark on a worktree's row, in the order `WorktreeWording.marks` gives them.
enum WorktreeMark: Hashable {
    case thisWindow
    case changes(WorktreeChanges)
    case changesUnknown
    case locked(reason: String?)
    case missing(reason: String)
    /// A rebase or bisect there (`nil` when which could not be read), with the short names of
    /// every branch it holds — the one it started from first.
    case operation(WorktreeOperationKind?, branches: [String])
}

/// Why a local branch cannot be switched to, deleted or fast-forwarded here: another worktree
/// holds it.
enum BranchHolder: Hashable {
    /// Checked out in the worktree at `path` (`Branch.checkedOutAt`, R14). `missing`: that
    /// worktree's folder is gone, and git still counts the branch as checked out there.
    case checkedOut(path: String, missing: Bool)
    /// Held by a rebase or bisect in the worktree at `path` (`Worktree.operationBranches`).
    case operation(path: String, kind: WorktreeOperationKind?, missing: Bool)
}

/// Every sentence of the worktree reading (B3 Task 3): the Worktrees section, a row's marks and
/// menu, the branches another worktree holds, the window title of a linked worktree and the
/// history's "worktree:" pill. Pure, and tested in `WorktreeWordingTests` and `WorktreeMenuTests`.
///
/// A worktree's path is shown as git printed it, with one exception: a newline (git allows one,
/// R13) is drawn as ⏎ and control characters are taken out (`displayPath`), so a row, a tooltip
/// or a menu reason stays one line. Copy Path copies the path itself.
enum WorktreeWording {

    // MARK: - The section and a row

    static let sectionTitle = "Worktrees"

    /// The section shows when there is more than one worktree: one is just the repository.
    static func showsSection(_ worktrees: [Worktree]) -> Bool {
        worktrees.count > 1
    }

    /// `path` on one line: a newline as ⏎, escape sequences and control characters out.
    static func displayPath(_ path: String) -> String {
        RemoteWording.stripped(path.replacingOccurrences(of: "\r\n", with: "⏎").replacingOccurrences(of: "\n", with: "⏎"))
    }

    /// The folder's name, as the row shows it.
    static func folderName(_ path: String) -> String {
        displayPath(URL(fileURLWithPath: path).lastPathComponent)
    }

    /// The row's second line: the branch, or where a detached HEAD is.
    static func branchLine(_ worktree: Worktree) -> String {
        if worktree.isBare { return "bare repository" }
        if let branch = worktree.branch { return shortName(branch) }
        if let head = worktree.head { return "detached at \(head.prefix(7))" }
        return "no commits yet"
    }

    /// The row's marks: this window, missing, locked, the operation there, then its changes —
    /// read only for a worktree whose folder is there.
    static func marks(
        _ worktree: Worktree, isOpenHere: Bool, changes: WorktreeChangesReading, operation: WorktreeOperationKind?
    ) -> [WorktreeMark] {
        var marks: [WorktreeMark] = []
        if isOpenHere { marks.append(.thisWindow) }
        if let reason = worktree.missingReason { marks.append(.missing(reason: reason)) }
        if let lock = worktree.lock { marks.append(.locked(reason: lock.reason)) }
        if !worktree.operationBranches.isEmpty {
            marks.append(.operation(operation, branches: worktree.operationBranches.map(shortName)))
        }
        if !worktree.isMissing {
            switch changes {
            case .read(let read) where !read.isClean: marks.append(.changes(read))
            case .unknown: marks.append(.changesUnknown)
            case .read, .notRead: break
            }
        }
        return marks
    }

    static func markText(_ mark: WorktreeMark) -> String {
        switch mark {
        case .thisWindow: "this window"
        case .changes(let changes):
            total(changes) == 1 ? "1 change" : "\(total(changes)) changes"
        case .changesUnknown: "changes unknown"
        case .locked: "locked"
        case .missing: "missing"
        case .operation(let kind, let branches):
            operationText(kind, branches.first ?? "") + (branches.count > 1 ? " +\(branches.count - 1)" : "")
        }
    }

    static func markSymbol(_ mark: WorktreeMark) -> String {
        switch mark {
        case .thisWindow: "macwindow"
        case .changes: "pencil"
        case .changesUnknown: "questionmark.circle"
        case .locked: "lock"
        case .missing: "exclamationmark.triangle"
        case .operation: "arrow.triangle.2.circlepath"
        }
    }

    static func markHelp(_ mark: WorktreeMark) -> String {
        switch mark {
        case .thisWindow:
            return "This window has this worktree open."
        case .changes(let changes):
            let parts = [
                (changes.staged, "staged"), (changes.unstaged, "unstaged"), (changes.untracked, "untracked"),
                (changes.conflicted, "conflicted"),
            ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
            return "Not committed: \(parts.joined(separator: ", "))."
        case .changesUnknown:
            return "Gitter could not read this worktree's changes."
        case .locked(let reason):
            let what = reason.map { "Locked: \(displayPath($0))." } ?? "Locked, with no reason given."
            return what + " Gitter leaves a locked worktree alone."
        case .missing(let reason):
            return "Its folder is gone (git: \(displayPath(reason))). git counts its branch as checked out there "
                + "until the worktree is removed."
        case .operation(let kind, let branches):
            let names = branches.map { "\"\($0)\"" }.joined(separator: ", ")
            return "\(operationName(kind, article: "A")) is in progress there. Until it ends, git will not check out "
                + "or delete \(names) anywhere else."
        }
    }

    /// The row's tooltip: the whole path, "The main worktree." for that one, then each mark's
    /// own sentence.
    static func rowHelp(_ worktree: Worktree, marks: [WorktreeMark]) -> String {
        ([displayPath(worktree.path)] + (worktree.isMain ? ["The main worktree."] : []) + marks.map(markHelp))
            .joined(separator: "\n")
    }

    /// What VoiceOver reads for the row: the folder, the branch line, then the marks.
    static func rowAccessibility(_ worktree: Worktree, marks: [WorktreeMark]) -> String {
        ([folderName(worktree.path), branchLine(worktree)] + (worktree.isMain ? ["main worktree"] : [])
            + marks.map(markText)).joined(separator: ", ")
    }

    // MARK: - A row's menu

    static let openTitle = "Open Worktree"
    static let revealTitle = "Reveal in Finder"
    static let copyPathTitle = "Copy Path"

    /// Why Open Worktree is off, or nil.
    static func openBlocked(_ worktree: Worktree, isOpenHere: Bool) -> String? {
        if isOpenHere { return "This window already has this worktree open." }
        if worktree.isMissing { return "Its folder is gone, so there is nothing to open." }
        if worktree.isBare { return "A bare repository has no working files to open." }
        return nil
    }

    /// Why Reveal in Finder is off, or nil.
    static func revealBlocked(_ worktree: Worktree) -> String? {
        worktree.isMissing ? "Its folder is gone, so Finder has nothing to show." : nil
    }

    // MARK: - Branches another worktree holds

    /// Which other worktree holds `branch`, or nil: the one it is checked out in
    /// (`checkedOutAt`, which is never this window's), else one whose rebase or bisect holds it
    /// — any branch of `operationBranches`, not only the first (carried note 2). This window's
    /// own worktree holds nothing "elsewhere": `openPath` is skipped.
    static func holder(
        of branch: Branch, worktrees: [Worktree], openPath: String?, operations: [String: WorktreeOperationKind]
    ) -> BranchHolder? {
        if let path = branch.checkedOutAt {
            let missing = worktrees.first { $0.path == path }?.isMissing ?? false
            return .checkedOut(path: path, missing: missing)
        }
        let ref = "refs/heads/" + branch.name
        guard let worktree = worktrees.first(where: { $0.path != openPath && $0.operationBranches.contains(ref) })
        else { return nil }
        return .operation(path: worktree.path, kind: operations[worktree.path], missing: worktree.isMissing)
    }

    /// The one reason Switch, Delete and Fast-Forward of a held branch show, and its icon's
    /// tooltip.
    static func heldReason(_ branch: String, by holder: BranchHolder) -> String {
        switch holder {
        case .checkedOut(let path, false):
            return "\"\(branch)\" is checked out in \(displayPath(path)) — open that worktree."
        case .checkedOut(let path, true):
            return "\"\(branch)\" is checked out in \(displayPath(path)), whose folder is gone — git counts it as "
                + "checked out there until that worktree is removed."
        case .operation(let path, let kind, false):
            return "\"\(branch)\" is held by \(operationName(kind, article: "the")) in \(displayPath(path)) — open "
                + "that worktree."
        case .operation(let path, let kind, true):
            return "\"\(branch)\" is held by \(operationName(kind, article: "the")) in \(displayPath(path)), whose "
                + "folder is gone — git counts it as held there until that worktree is removed."
        }
    }

    /// The icon beside a held branch's name.
    static func holderSymbol(_ holder: BranchHolder) -> String {
        switch holder {
        case .checkedOut: "macwindow.on.rectangle"
        case .operation: "arrow.triangle.2.circlepath"
        }
    }

    // MARK: - The window title

    /// "wt-feat (worktree of main)" for a linked worktree, the folder alone otherwise.
    static func windowTitle(folder: String, mainFolder: String?) -> String {
        mainFolder.map { "\(folder) (worktree of \($0))" } ?? folder
    }

    // MARK: - The history pill

    /// Other worktrees' detached HEADs by commit: `log --all` lists their commits (R27), and
    /// the pill says whose HEAD each is. A missing worktree's counts — git keeps its HEAD — but
    /// not this window's (its HEAD is the log's own), a worktree on a branch (the branch's pill
    /// says it) or a bare repository (no HEAD).
    static func detachedHeads(_ worktrees: [Worktree], openPath: String?) -> [String: [Worktree]] {
        var heads: [String: [Worktree]] = [:]
        for worktree in worktrees where worktree.branch == nil && !worktree.isBare && worktree.path != openPath {
            guard let head = worktree.head else { continue }
            heads[head, default: []].append(worktree)
        }
        return heads
    }

    static func pillText(_ worktree: Worktree) -> String {
        "worktree: \(folderName(worktree.path))"
    }

    static func pillHelp(_ worktree: Worktree) -> String {
        "The detached HEAD of the worktree at \(displayPath(worktree.path))."
    }

    // MARK: - Pieces

    private static func shortName(_ ref: String) -> String {
        ref.hasPrefix("refs/heads/") ? String(ref.dropFirst("refs/heads/".count)) : ref
    }

    private static func total(_ changes: WorktreeChanges) -> Int {
        changes.staged + changes.unstaged + changes.untracked + changes.conflicted
    }

    private static func operationText(_ kind: WorktreeOperationKind?, _ branch: String) -> String {
        switch kind {
        case .rebase: "rebasing \(branch)"
        case .bisect: "bisecting \(branch)"
        case nil: "holds \(branch)"
        }
    }

    /// "A rebase", "the bisect", "a rebase or bisect" — `article` is "A" or "the".
    private static func operationName(_ kind: WorktreeOperationKind?, article: String) -> String {
        switch kind {
        case .rebase: "\(article) rebase"
        case .bisect: "\(article) bisect"
        case nil: "\(article == "A" ? "A" : "a") rebase or bisect"
        }
    }
}
