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

// MARK: - Add and Remove Worktree (B3 Task 5)

/// The three things Add Worktree can check out (`AddWorktreeChoice` is the choice made).
enum AddWorktreeKind: Hashable, CaseIterable {
    /// A local branch no worktree has checked out.
    case existing
    /// A new branch created first at a start point's id.
    case newBranch
    /// A new local branch created at a remote branch's id, then set to track it.
    case tracking
}

/// What is at the folder Add Worktree is asked for, read by the store for the live check.
enum WorktreeFolderState: Hashable, Sendable {
    /// Nothing: git creates it, and any missing parent (R16).
    case missing
    /// A folder with nothing in it: git accepts it (R16).
    case empty
    case notEmpty
    /// A file or a link: never a folder git would fill.
    case notAFolder
    /// A folder that cannot be listed: not known to be empty.
    case unreadable
}

/// What an add did, for its notice: the sentence, the worktree Open switches to (nil when none
/// is listed at the path), and whether anything in it is not what was asked.
struct AddWorktreeReport: Hashable {
    let text: String
    let opens: String?
    let isProblem: Bool
}

/// One worktree of Remove All Missing…, after its turn: removed (with the kept branch made
/// first, if any) or not, in words.
struct MissingRemoval: Hashable {
    enum Outcome: Hashable {
        case removed(kept: [String])
        case notRemoved(String)
    }

    let worktree: Worktree
    let outcome: Outcome
}

/// Add Worktree… and Remove Worktree… (B3 Task 5): the menus' titles and reasons, the Add
/// sheet's choices, default folder and live folder check, the Remove sheet's check — every
/// refusal in place of the button, what git deletes with it, the commits a detached HEAD holds —
/// and every result, whole, partial or unknown. A worktree's path is shown through
/// `displayPath`; git's words through `RemoteWording.plain`.
extension WorktreeWording {

    // MARK: Titles

    static let addTitle = "Add Worktree…"
    static func newWorktreeTitle(_ branch: String) -> String { "New Worktree for \"\(branch)\"…" }
    static let removeTitle = "Remove Worktree…"
    static let removeAllMissingTitle = "Remove All Missing…"
    static let addSheetTitle = "Add Worktree"
    static let addButton = "Add Worktree"
    static let removeButton = "Remove Worktree"
    static func removeSheetTitle(_ worktree: Worktree) -> String { "Remove Worktree \"\(folderName(worktree.path))\"" }
    static let removeMissingSheetTitle = "Remove Missing Worktrees"
    /// The add notice's button: this window switches to the new worktree.
    static let openNoticeButton = "Open"

    // MARK: Why an item is off

    /// "New Worktree for <b>…" on a branch's menu: off for the branch checked out here and for one
    /// another worktree holds (`heldReason`, Task 3's sentence).
    static func newWorktreeBlocked(_ branch: String, isCurrent: Bool, heldReason: String?) -> String? {
        if isCurrent {
            return "\"\(branch)\" is checked out in this window, and a branch can be checked out in only one worktree."
        }
        return heldReason
    }

    /// Remove Worktree… on a row: off for the two git or Gitter refuse before any check.
    static func removeBlocked(_ worktree: Worktree, isOpenHere: Bool) -> String? {
        if worktree.isMain { return "The main worktree holds the repository itself, so it can't be removed." }
        if isOpenHere { return "This window has this worktree open. Open another one first, then remove it from there." }
        return nil
    }

    /// The linked worktrees whose folder is gone, in list order.
    static func missing(_ worktrees: [Worktree]) -> [Worktree] {
        worktrees.filter { !$0.isMain && $0.isMissing }
    }

    static let noneMissing = "No worktree's folder is missing."

    static func removeAllMissingBlocked(_ worktrees: [Worktree]) -> String? {
        missing(worktrees).isEmpty ? noneMissing : nil
    }

    // MARK: The Add sheet

    static func kindTitle(_ kind: AddWorktreeKind) -> String {
        switch kind {
        case .existing: "Existing branch"
        case .newBranch: "New branch"
        case .tracking: "Remote branch"
        }
    }

    static func kindExplanation(_ kind: AddWorktreeKind) -> String {
        switch kind {
        case .existing: "Check out a local branch that no worktree has checked out."
        case .newBranch: "Create a new branch at a start point, then check it out in the new worktree."
        case .tracking: "Create a new local branch that tracks a remote branch, then check it out in the new worktree."
        }
    }

    static let branchLabel = "Branch:"
    static let newNameLabel = "New branch:"
    static let startLabel = "From:"
    static let remoteLabel = "Remote branch:"
    static let folderLabel = "Folder:"
    static let chooseFolderTitle = "Choose…"
    static let chooseFolderMessage = "Choose an empty folder for the new worktree, or create one."
    static let noFreeBranches = "Every local branch is checked out in a worktree or held by a rebase or bisect."
    static let noRemoteBranches = "There is no fetched remote branch."

    /// The local branches Existing branch offers: not this window's own, not checked out in
    /// another worktree, not held by a rebase or bisect anywhere (R14) — this window's included.
    /// GitCore checks again right before git runs.
    static func freeBranches(_ branches: [Branch], current: String?, worktrees: [Worktree]) -> [String] {
        let held = Set(worktrees.flatMap(\.operationBranches) + worktrees.compactMap(\.branch))
        return branches.filter { branch in
            branch.name != current && branch.checkedOutAt == nil && !held.contains("refs/heads/" + branch.name)
        }.map(\.name)
    }

    /// A tracking branch's suggested name: the remote branch's own name after its remote.
    static func trackingName(_ remoteBranch: String, remote: String?) -> String {
        if let remote, remoteBranch.hasPrefix(remote + "/") { return String(remoteBranch.dropFirst(remote.count + 1)) }
        guard let slash = remoteBranch.firstIndex(of: "/") else { return remoteBranch }
        return String(remoteBranch[remoteBranch.index(after: slash)...])
    }

    /// A start point as the sheet and the notice name it: a branch by its short name, a commit
    /// (Ruling 3: its `ref` is its id) by its first seven digits.
    static func startLabel(_ tip: RefTip) -> String {
        if tip.ref.hasPrefix("refs/heads/") { return String(tip.ref.dropFirst("refs/heads/".count)) }
        if tip.ref.hasPrefix("refs/remotes/") { return String(tip.ref.dropFirst("refs/remotes/".count)) }
        return tip.ref == tip.id ? String(tip.id.prefix(7)) : tip.ref
    }

    /// The folder the sheet starts with: a sibling of the main worktree's, `<main folder>-<branch>`,
    /// with a branch's slashes made dashes (a bare `x.git` is `x`).
    static func defaultFolder(mainPath: String, branch: String) -> String {
        let main = URL(fileURLWithPath: mainPath)
        var name = main.lastPathComponent
        if name.hasSuffix(".git"), name.count > 4 { name.removeLast(4) }
        let slug = branch.replacingOccurrences(of: "/", with: "-")
        return main.deletingLastPathComponent().appendingPathComponent(name + "-" + (slug.isEmpty ? "worktree" : slug)).path
    }

    /// The folder field as the check and git get it: trimmed, a leading `~` expanded, a trailing
    /// slash off.
    static func normalizedFolder(_ text: String) -> String {
        var path = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.hasPrefix("~") { path = (path as NSString).expandingTildeInPath }
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        return path
    }

    /// The listed worktree whose folder holds `resolved` (or is it), both sides compared by real
    /// path (R23): its path as listed, or nil.
    static func containingWorktree(_ resolved: String, in listed: [(path: String, resolved: String)]) -> String? {
        listed.first { worktree in
            resolved == worktree.resolved
                || resolved.hasPrefix(worktree.resolved.hasSuffix("/") ? worktree.resolved : worktree.resolved + "/")
        }?.path
    }

    private static let chooseAnother = "Choose a folder that doesn't exist yet, or an empty one."

    /// The folder's live check, or nil when Add may go ahead: a full path, outside every
    /// worktree (`insideWorktree`), and nothing there but an empty folder (R16).
    static func folderProblem(_ path: String, state: WorktreeFolderState, insideWorktree: String?) -> String? {
        if path.isEmpty { return "Choose a folder for the worktree." }
        if !path.hasPrefix("/") { return "Enter a full path, beginning with /." }
        if let inside = insideWorktree {
            return "This is inside the worktree at \(displayPath(inside)), where the new one would show as untracked "
                + "files. Choose a folder outside every worktree."
        }
        switch state {
        case .missing, .empty: return nil
        case .notEmpty: return "This folder is not empty. " + chooseAnother
        case .notAFolder: return "Something that is not a folder is at this path. " + chooseAnother
        case .unreadable: return "Gitter can't read this folder, so it can't tell whether it is empty. Choose another."
        }
    }

    // MARK: What an add did

    /// The notice after an add that left a worktree listed — or, for `.unexpected` with nothing
    /// listed, the banner. Every partial state is said (Ruling 3): the upstream not set, git's
    /// error after a complete worktree (R19), a worktree not on the branch asked for.
    static func added(_ result: AddWorktreeResult, choice: AddWorktreeChoice, upstreamProblem: String?) -> AddWorktreeReport {
        let upstream = upstreamProblem.map {
            " Setting its upstream did not work either: \($0). Set it with Set Upstream… in the branch's menu."
        } ?? ""
        switch result {
        case .added(let worktree):
            let base = addedBase(choice, path: worktree.path, upstreamFailed: upstreamProblem != nil)
            guard let upstreamProblem else { return AddWorktreeReport(text: base + ".", opens: worktree.path, isProblem: false) }
            return AddWorktreeReport(
                text: base + ", but setting its upstream did not work: \(upstreamProblem). Set it with Set Upstream… "
                    + "in the branch's menu.",
                opens: worktree.path, isProblem: true)
        case .addedWithError(let worktree, let words):
            let base = addedBase(choice, path: worktree.path, upstreamFailed: upstreamProblem != nil)
            let said = RemoteWording.plain(words)
            return AddWorktreeReport(
                text: base + ", but git exited with an error after making it" + (said.isEmpty ? "" : ": \(said)")
                    + ". A post-checkout hook may have failed — check the files there." + upstream,
                opens: worktree.path, isProblem: true)
        case .unexpected(let worktree?, let words):
            let what = worktree.branch.map { "on \"\(shortName($0))\"" } ?? branchLine(worktree)
            let said = RemoteWording.plain(words)
            return AddWorktreeReport(
                text: "git added a worktree at \(displayPath(worktree.path)), but it is \(what), not on "
                    + "\"\(choice.branch)\" as asked\(said.isEmpty ? "" : " (\(said))"). Gitter changed nothing there: "
                    + "open it to look, or remove it." + created(choice),
                opens: worktree.path, isProblem: true)
        case .unexpected(nil, let words):
            let said = RemoteWording.plain(words)
            return AddWorktreeReport(
                text: "git said it added the worktree, but nothing is listed at the folder you chose"
                    + (said.isEmpty ? "." : " (\(said)).") + created(choice),
                opens: nil, isProblem: true)
        }
    }

    private static func addedBase(_ choice: AddWorktreeChoice, path: String, upstreamFailed: Bool) -> String {
        let at = " at \(displayPath(path))"
        switch choice {
        case .existing(let branch):
            return "Added a worktree for \"\(branch)\"" + at
        case .newBranch(let name, let start):
            return "Created \"\(name)\" from \(startLabel(start)) and added a worktree for it" + at
        case .tracking(let name, let remote):
            let how = upstreamFailed ? "from \(startLabel(remote))" : "tracking \"\(startLabel(remote))\""
            return "Created \"\(name)\" \(how) and added a worktree for it" + at
        }
    }

    /// " The branch "x" was created first and stays." for a choice that created one.
    private static func created(_ choice: AddWorktreeChoice) -> String {
        guard choice.createsBranch else { return "" }
        return " The branch \"\(choice.branch)\" was created first and stays."
    }

    /// Why setting a new tracking branch's upstream did not work (B2's `setUpstream`, read back),
    /// as a clause.
    static func upstreamProblem(_ error: Error) -> String {
        switch error {
        case UpstreamRefusal.notFetched(let ref):
            return "\"\(RemoteAdminWording.shortUpstream(ref))\" doesn't exist here any more"
        case UpstreamRefusal.notABranch(let ref):
            return "\"\(RemoteAdminWording.shortUpstream(ref))\" is not a branch a remote fetches into"
        case UpstreamRefusal.ambiguousNamespace(let ref):
            return "two remotes fetch into \"\(RemoteAdminWording.shortUpstream(ref))\""
        case UpstreamRefusal.ownUpstream:
            return "a branch can't track itself"
        case UpstreamRefusal.mergeMismatch(let expected, let written):
            return "git set it to \(RemoteWording.plain(written)) on the server, not \(RemoteWording.plain(expected)), "
                + "because overlapping fetch refspecs map it elsewhere"
        case RemoteAdminPartial.upstreamChangedThenFailed(let branch, let remote, let merge, let words):
            let remoteNow = remote.map { "branch.\(branch).remote = \(RemoteWording.plain($0))" } ?? "no branch.\(branch).remote"
            let mergeNow = merge.map { "branch.\(branch).merge = \(RemoteWording.plain($0))" } ?? "no branch.\(branch).merge"
            return "git failed part-way (\(RemoteWording.plain(words))), leaving \(remoteNow) and \(mergeNow)"
        case RemoteAdminPartial.upstreamOutcomeUnknown:
            return "Gitter was stopped while setting it, so whether it is set is not known"
        case BranchOperationError.noSuchBranch(let name):
            return "there is no branch named \"\(name)\" any more"
        case GitError.commandFailed(let code, let stderr):
            return gitsWords(stderr, code: code)
        default:
            return RemoteWording.plain(error.localizedDescription)
        }
    }

    /// An add that threw: nothing is listed at the path. A branch created first stays, and is
    /// named (Ruling 3) — and a tracking branch whose upstream was not set says so too (fix round
    /// 1, M1).
    static func addFailure(
        _ error: Error, choice: AddWorktreeChoice, path: String, branchCreated: Bool, upstreamProblem: String?
    ) -> String {
        let branch = choice.branch
        let at = displayPath(path)
        let text: String
        switch error {
        case AddWorktreeRefusal.noSuchBranch(let name):
            text = "There is no local branch \"\(name)\" any more, so no worktree was added."
        case AddWorktreeRefusal.branchInUse(let other):
            text = "\"\(branch)\" is checked out in \(displayPath(other)) now, so no worktree was added."
        case AddWorktreeRefusal.branchHeldByOperation(let other):
            text = "\"\(branch)\" is held by a rebase or bisect in \(displayPath(other)), so no worktree was added."
        case AddWorktreeRefusal.pathExists(let p):
            text = "Something is at \(displayPath(p)) now, so no worktree was added. " + chooseAnother
        case AddWorktreeRefusal.pathInsideWorktree(let p):
            text = "\(displayPath(p)) is inside a worktree, so no worktree was added."
        case AddWorktreeRefusal.pathNotAbsolute(let p):
            text = "\(displayPath(p)) is not a full path, so no worktree was added."
        case GitError.commandFailed(let code, let stderr):
            text = "git didn't add the worktree at \(at): \(gitsWords(stderr, code: code)). Nothing is listed there."
        case is CancellationError:
            text = "Stopped before the worktree was added. Nothing is listed at \(at)."
        default:
            text = RemoteWording.failure(error, attempt: "add a worktree at \(at)", isWrite: false)
        }
        let created = branchCreated ? " The branch \"\(branch)\" was created first and stays." : ""
        let upstream = upstreamProblem.map { " Setting its upstream did not work either: \($0)." } ?? ""
        return text + created + upstream
    }

    /// The add notice's Open, for a worktree no longer listed.
    static func notListedAnyMore(_ path: String) -> String {
        "The worktree at \(displayPath(path)) is no longer listed, so there is nothing to open."
    }

    /// The new branch could not be created: nothing was done.
    static func branchNotCreated(_ error: Error, name: String) -> String {
        switch error {
        case let refusal as BranchOperationError:
            return refusal.sentence(refusing: "create \"\(name)\"") + " No worktree was added."
        case GitError.commandFailed(let code, let stderr):
            return "Couldn't create \"\(name)\": \(gitsWords(stderr, code: code)). No worktree was added."
        default:
            return RemoteWording.failure(error, attempt: "create \"\(name)\"", isWrite: false) + " No worktree was added."
        }
    }

    // MARK: The Remove sheet

    static let checking = "Checking what removing it would lose…"
    static let checkingMissing = "Checking the worktrees whose folder is gone…"
    static let refusalsHeading = "Gitter won't remove it:"
    static let keepHeading = "Keep a branch at its HEAD, so these commits stay on a branch:"
    static let missingKeepHeading = "Keep a branch at each detached HEAD, so their commits stay on a branch:"

    /// `Keep "<folder>" as` — a keep box's label; the holder is the worktree's path as listed.
    static func keepLabel(_ path: String) -> String { "Keep \"\(folderName(path))\" as" }

    /// The check found no folder: a missing worktree (R25), or a locked one whose folder is gone
    /// — anything but a folder the check could not read.
    static func folderIsGone(_ removal: WorktreeRemoval) -> Bool {
        if removal.worktree.isMissing { return true }
        guard !removal.worktree.isMain, removal.changes == nil else { return false }
        return !removal.refusals.contains { if case .unreadable = $0 { true } else { false } }
    }

    static func removeIntro(_ removal: WorktreeRemoval) -> String {
        guard folderIsGone(removal) else {
            return "This deletes its folder, above, and everything in it."
        }
        return removal.worktree.branch == nil
            ? "Its folder is gone. Removing it takes it off git's list; nothing on disk changes."
            : "Its folder is gone. Removing it takes it off git's list, so its branch can be checked out elsewhere; "
                + "nothing on disk changes."
    }

    /// R22: a branch worktree's branch is never deleted.
    static func branchStays(_ removal: WorktreeRemoval) -> String? {
        removal.worktree.branch.map { "The branch \"\(shortName($0))\" stays." }
    }

    /// A detached HEAD's own commits (R22), counted as B2's union is.
    static func strandedLine(_ removal: WorktreeRemoval) -> String? {
        guard removal.worktree.branch == nil, let head = removal.worktree.head else { return nil }
        switch removal.stranded.count {
        case 0:
            return "Its detached HEAD (\(head.prefix(7))) is also on a branch, tag, remote or another worktree, so no "
                + "commit is lost."
        case 1:
            return "Its detached HEAD holds 1 commit no branch, tag, remote or other worktree has. Removing it deletes "
                + "its HEAD's history, so the commit would be on no branch:"
        case let count:
            return "Its detached HEAD holds \(count) commits no branch, tag, remote or other worktree has. Removing it "
                + "deletes its HEAD's history, so they would be on no branch:"
        }
    }

    /// R21: what git's remove deletes without asking — the count, and the top names. An ignored
    /// folder is one entry and goes with everything in it, which the sentence says.
    static func ignoredLine(_ ignored: IgnoredSummary) -> String? {
        guard ignored.count > 0 else { return nil }
        let entries = ignored.count == 1 ? "1 ignored entry" : "\(ignored.count) ignored entries"
        let names = ignored.topLevel.map(displayPath).joined(separator: ", ")
            + (ignored.topLevel.count >= IgnoredSummary.topLevelLimit ? ", …" : "")
        return "git also deletes \(entries) with it — files and folders git doesn't track, each folder with "
            + "everything in it — without asking: \(names)"
    }

    /// Ruling 1 for a worktree: its folder's name made a branch name, then `-kept`, `-kept-2`, …
    /// while a branch, tag or remote has it (compared ignoring case). GitCore checks the name
    /// again (`keepBranchNameProblem`), live and before it creates it.
    static func suggestedKeepName(folder: String, taken: Set<String>) -> String {
        var name = ""
        for character in folder {
            let fits = character.isLetter || character.isNumber || character == "-" || character == "_" || character == "."
            if fits {
                name.append(character)
            } else if name.last != "-" {
                name.append("-")
            }
        }
        while name.contains("..") { name = name.replacingOccurrences(of: "..", with: "-") }
        while name.contains("--") { name = name.replacingOccurrences(of: "--", with: "-") }
        if name.hasSuffix(".lock") { name.removeLast(".lock".count) }
        name = name.trimmingCharacters(in: CharacterSet(charactersIn: "-."))
        let base = name.isEmpty ? "kept-worktree" : name
        let lowered = Set(taken.map { $0.lowercased() })
        guard lowered.contains(base.lowercased()) else { return base }
        var candidate = base + "-kept"
        var n = 2
        while lowered.contains(candidate.lowercased()) {
            candidate = "\(base)-kept-\(n)"
            n += 1
        }
        return candidate
    }

    /// One refusal of the check, shown in place of the button, with the next step where there is
    /// one.
    static func refusal(_ refusal: WorktreeRemovalRefusal) -> String {
        switch refusal {
        case .isMain:
            return "It is the main worktree, which holds the repository itself."
        case .isOpenHere:
            return "This window has it open. Open another worktree first, then remove this one from there."
        case .locked(let reason):
            let what = reason.flatMap { $0.isEmpty ? nil : "It is locked (\"\(displayPath($0))\")." }
                ?? "It is locked, with no reason given."
            return what + " Gitter leaves locked worktrees alone; unlock it in Terminal (git worktree unlock) if you "
                + "mean to remove it."
        case .operationInProgress("sequencer"):
            return "A cherry-pick or revert is between its steps there, and git would remove it with the worktree. "
                + "Finish or abort it there first."
        case .operationInProgress(let operation):
            let article = operation.first.map { "aeiou".contains($0) } == true ? "An" : "A"
            return "\(article) \(RemoteWording.plain(operation)) is in progress there, and git would remove it with the "
                + "worktree. Finish or abort it there first."
        case .changes(let changes):
            let parts = [
                (changes.staged, "staged"), (changes.unstaged, "unstaged"), (changes.untracked, "untracked"),
                (changes.conflicted, "conflicted"),
            ].filter { $0.0 > 0 }.map { "\($0.0) \($0.1)" }
            return "It has changes that are not committed: \(parts.joined(separator: ", ")). Commit, stash or discard "
                + "them there first."
        case .assumeUnchanged(let paths):
            return hiddenEdits(paths, mark: "assume-unchanged", flag: "--no-assume-unchanged")
        case .skipWorktreePresent(let paths):
            return hiddenEdits(paths, mark: "skip-worktree and present", flag: "--no-skip-worktree")
        case .nestedRepository(let paths):
            return paths.count == 1
                ? "It holds another repository, in \(quoted(paths)): removing would delete it, history and all. Move "
                    + "it out first."
                : "It holds other repositories, in \(quoted(paths)): removing would delete them, history and all. "
                    + "Move them out first."
        case .tooLargeToCheck:
            return "It holds too many files for Gitter to check for repositories inside it. Remove it in Terminal "
                + "after checking it yourself."
        case .unreadable(let path):
            return "Gitter couldn't read \(displayPath(path)), so it can't tell what removing would lose. Check its "
                + "permissions."
        case .perWorktreeRefs(let refs):
            let more = refs.count >= WorktreeRemovalRefusal.pathLimit ? " or more" : ""
            return refs.count == 1 && more.isEmpty
                ? "The ref \(quoted(refs)) lives only in this worktree, and removing would delete it with any commit "
                    + "only it holds. Copy it to a branch or delete it there in Terminal first."
                : "The refs \(quoted(refs))\(more) live only in this worktree, and removing would delete them with any "
                    + "commit only they hold. Copy them to branches or delete them there in Terminal first."
        }
    }

    private static func hiddenEdits(_ paths: [String], mark: String, flag: String) -> String {
        let more = paths.count >= WorktreeRemovalRefusal.pathLimit ? " or more" : ""
        let files = paths.count == 1 && more.isEmpty ? "1 file there is" : "\(paths.count)\(more) files there are"
        let them = paths.count == 1 && more.isEmpty ? "it" : "them"
        return "\(files) marked \(mark) (\(quoted(paths))): an edit to \(them) is hidden from git, and removing would "
            + "delete it. Clear the mark in Terminal (git update-index \(flag)) first."
    }

    /// `"a", "b", "c" and 2 more`.
    private static func quoted(_ paths: [String]) -> String {
        let shown = paths.prefix(3).map { "\"\(displayPath($0))\"" }.joined(separator: ", ")
        return paths.count > 3 ? "\(shown) and \(paths.count - 3) more" : shown
    }

    /// A check that could not be made: the sheet closes, nothing was changed.
    static func checkFailure(_ error: Error, worktree: Worktree) -> String {
        let at = displayPath(worktree.path)
        switch error {
        case WorktreeRemovalPartial.changedSinceShown:
            return "The worktree at \(at) is no longer listed — removed or moved since the last refresh. Nothing was "
                + "changed."
        case GitError.commandFailed(let code, let stderr):
            return "Couldn't check what removing the worktree at \(at) would lose: \(gitsWords(stderr, code: code)). "
                + "Nothing was changed."
        default:
            return RemoteWording.failure(error, attempt: "check what removing the worktree at \(at) would lose", isWrite: false)
                + " Nothing was changed."
        }
    }

    // MARK: What a removal did

    /// A removal git finished and `list` confirmed: what went, what stays, and the kept branch.
    static func removed(_ removal: WorktreeRemoval, kept: [String]) -> String {
        let at = displayPath(removal.worktree.path)
        var text: String
        if folderIsGone(removal) {
            text = "Removed the missing worktree \(at) from git's list."
        } else {
            let ignored = removal.ignored.count
            let with = ignored == 0 ? "" : ", with the \(ignored == 1 ? "1 ignored entry" : "\(ignored) ignored entries") in it"
            text = "Removed the worktree at \(at)\(with)."
        }
        if let stays = branchStays(removal) { text += " " + stays }
        if let name = kept.first {
            let count = removal.stranded.count
            text += count == 1
                ? " Its 1 commit is on the kept branch \"\(name)\"."
                : " Its \(count) commits are on the kept branch \"\(name)\"."
        }
        return text
    }

    /// A removal that threw: every refusal, the partial and unknown results (each naming the
    /// kept branches, which stay), and B2's own words for a kept branch whose creation was
    /// stopped.
    static func removeFailure(_ error: Error, removal: WorktreeRemoval) -> String {
        let at = displayPath(removal.worktree.path)
        switch error {
        case WorktreeRemovalPartial.changedSinceShown:
            return "The worktree at \(at) changed since the sheet checked it — a file, a commit, a lock or its list "
                + "entry. Nothing was removed and no branch was created. Remove it again to see what it holds now."
        case WorktreeRemovalPartial.keptBranchesThenStopped(let kept, let words):
            let names = quotedNames(kept)
            let made = kept.count == 1 ? "the kept branch \(names)" : "the kept branches \(names)"
            return "Created \(made), then the removal could not go on: \(RemoteWording.plain(words)). Nothing was "
                + "removed; \(names) \(kept.count == 1 ? "stays" : "stay")."
        case WorktreeRemovalPartial.refusedByGit(let words, let kept):
            let said = RemoteWording.plain(words)
            // Still listed: git stopped before deleting anything. A deletion that fails part-way has
            // already taken the worktree off the list (`removedWithLeftovers`).
            return "git refused to remove the worktree at \(at)\(said.isEmpty ? "" : ": \(said)"). It is still listed, "
                + "so git stopped before deleting anything: nothing was removed." + keptStay(kept)
        case WorktreeRemovalPartial.removedWithLeftovers(let words, let kept):
            let said = RemoteWording.plain(words)
            return "git took the worktree at \(at) off its list but did not finish deleting its folder"
                + "\(said.isEmpty ? "" : ": \(said)"). What is left is still on disk; delete it yourself once you've "
                + "checked it." + keptStay(kept)
        case WorktreeRemovalPartial.outcomeUnknown(let kept):
            return "Whether the worktree at \(at) was removed is not known: git was stopped, or the list could not be "
                + "read back. Refresh to see." + keptStay(kept)
        case RemoteAdminPartial.keptBranchesCancelled(let kept, let unknown):
            return RemoteAdminWording.keptCancelled(kept: kept, unknown: unknown, nothing: "removed")
        case RemoteAdminRefusal.branchExists(let name):
            return "Couldn't keep \"\(name)\": a branch, tag or remote has that name now. Nothing was removed."
        case RemoteAdminRefusal.invalidBranchName(let name):
            return "Couldn't keep \"\(name)\": that is not a valid branch name. Nothing was removed."
        case let refusal as WorktreeRemovalRefusal:
            let text = Self.refusal(refusal)
            let lowered = text.hasPrefix("It ") ? "i" + text.dropFirst() : text
            return "Didn't remove the worktree at \(at): \(lowered)"
        case BranchOperationError.invalidName:
            return "Gitter asked to keep a branch for something other than this worktree, so nothing was removed."
        case is CancellationError:
            return "Stopped before anything was removed or created."
        case GitError.commandFailed(let code, let stderr):
            return "Couldn't remove the worktree at \(at): \(gitsWords(stderr, code: code)). Nothing was removed."
        default:
            return RemoteWording.failure(error, attempt: "remove the worktree at \(at)", isWrite: false)
                + " Nothing was removed."
        }
    }

    /// " The kept branch "k" stays." — or nothing.
    private static func keptStay(_ kept: [String]) -> String {
        switch kept.count {
        case 0: ""
        case 1: " The kept branch \(quotedNames(kept)) stays."
        default: " The kept branches \(quotedNames(kept)) stay."
        }
    }

    private static func quotedNames(_ names: [String]) -> String {
        names.map { "\"\($0)\"" }.joined(separator: ", ")
    }

    // MARK: Remove All Missing…

    static func removeMissingIntro(_ count: Int) -> String {
        count == 1
            ? "This worktree's folder is gone. Removing it takes it off git's list, so its branch can be checked out "
                + "elsewhere; nothing on disk changes."
            : "These \(count) worktrees' folders are gone. Removing them takes them off git's list one at a time, so "
                + "their branches can be checked out elsewhere; nothing on disk changes."
    }

    static func removeMissingButton(_ count: Int) -> String {
        count == 1 ? "Remove 1 Worktree" : "Remove \(count) Worktrees"
    }

    static let noneRemovable = "None of them can be removed: see why under each."

    /// Each one, removed or not, in the order they were taken.
    static func removedMissing(_ report: [MissingRemoval]) -> String {
        let removed = report.filter { if case .removed = $0.outcome { true } else { false } }.count
        let noun = report.count == 1 ? "missing worktree" : "missing worktrees"
        let head = removed == report.count
            ? "Removed \(report.count) \(noun) from git's list:"
            : "Removed \(removed) of \(report.count) \(noun) from git's list:"
        let lines = report.map { item -> String in
            let at = displayPath(item.worktree.path)
            switch item.outcome {
            case .removed(let kept):
                if let name = kept.first { return "\(at) — its commits are on the kept branch \"\(name)\"." }
                if let branch = item.worktree.branch { return "\(at) — the branch \"\(shortName(branch))\" stays." }
                return "\(at) — removed."
            case .notRemoved(let why):
                return "\(at) — not removed: \(why)"
            }
        }
        return ([head] + lines).joined(separator: "\n")
    }

    static func missingReportHasProblems(_ report: [MissingRemoval]) -> Bool {
        report.contains { if case .notRemoved = $0.outcome { true } else { false } }
    }

    // MARK: Pieces

    /// git's own words, one line, or its exit code when it said nothing.
    private static func gitsWords(_ stderr: String, code: Int32) -> String {
        let words = RemoteWording.plainJoined(stderr.split(whereSeparator: \.isNewline).map(String.init))
        return words.isEmpty ? "git exited with code \(code)" : words
    }
}
