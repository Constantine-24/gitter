import Foundation
import GitCore
import Testing

@testable import Gitter

/// B3 Task 3: what the Worktrees section says about a worktree — its folder, its branch line,
/// every mark with its text, symbol and tooltip — and the window title and the history's
/// "worktree:" pill. Pure: no store, no git.
@Suite struct WorktreeWordingTests {
    static let headA = "aaaaaaa1111111111111111111111111111111111"
    static let headB = "bbbbbbb2222222222222222222222222222222222"

    static func worktree(
        _ path: String, head: String? = headA, branch: String? = nil, isMain: Bool = false, isBare: Bool = false,
        lock: WorktreeLock? = nil, missing: String? = nil, operation: [String] = []
    ) -> Worktree {
        Worktree(
            path: path, head: head, branch: branch, isMain: isMain, isBare: isBare, lock: lock,
            missingReason: missing, operationBranches: operation)
    }

    static let main = worktree("/r/main", branch: "refs/heads/main", isMain: true)
    static let feat = worktree("/r/wt-feat", branch: "refs/heads/feat")
    static let detached = worktree("/r/wt-det", head: headB)

    // MARK: - The section, a row's names

    @Test func theSectionShowsWithMoreThanOneWorktree() {
        #expect(WorktreeWording.sectionTitle == "Worktrees")
        #expect(!WorktreeWording.showsSection([]))
        #expect(!WorktreeWording.showsSection([Self.main]))
        #expect(WorktreeWording.showsSection([Self.main, Self.feat]))
    }

    /// The folder's name, its whole path in the tooltip — a newline in either is drawn as a mark,
    /// never as a second line, and control characters are taken out.
    @Test func theFolderNameAndPathAreShownOnOneLine() {
        #expect(WorktreeWording.folderName("/r/wt-feat") == "wt-feat")
        #expect(WorktreeWording.folderName("/r/wt with space") == "wt with space")
        #expect(WorktreeWording.folderName("/r/wt-ünï") == "wt-ünï")
        #expect(WorktreeWording.folderName("/r/wt\nnewline") == "wt⏎newline")
        #expect(WorktreeWording.displayPath("/r/wt\nnew\u{1B}[31mline\u{7}") == "/r/wt⏎newline")
    }

    @Test func theBranchLineSaysWhatHEADIs() {
        #expect(WorktreeWording.branchLine(Self.feat) == "feat")
        #expect(WorktreeWording.branchLine(Self.worktree("/r/x", branch: "refs/heads/team/a")) == "team/a")
        #expect(WorktreeWording.branchLine(Self.detached) == "detached at bbbbbbb")
        #expect(WorktreeWording.branchLine(Self.worktree("/r/bare.git", head: nil, isMain: true, isBare: true)) == "bare repository")
        #expect(WorktreeWording.branchLine(Self.worktree("/r/new", head: nil)) == "no commits yet")
    }

    // MARK: - Marks

    @Test func aPlainWorktreeHasNoMarks() {
        #expect(WorktreeWording.marks(Self.feat, isOpenHere: false, changes: .read(.none), operation: nil).isEmpty)
        #expect(WorktreeWording.marks(Self.feat, isOpenHere: false, changes: .notRead, operation: nil).isEmpty)
    }

    /// Every mark at once, in the order the row draws them.
    @Test func everyMarkInOrder() {
        let changes = WorktreeChanges(staged: 1, unstaged: 0, untracked: 2, conflicted: 0)
        let all = Self.worktree(
            "/r/wt-rb", branch: nil, lock: WorktreeLock(reason: "on a USB disk"),
            operation: ["refs/heads/rb", "refs/heads/rb-base"])
        let marks = WorktreeWording.marks(all, isOpenHere: true, changes: .read(changes), operation: .rebase)
        #expect(
            marks == [
                .thisWindow, .locked(reason: "on a USB disk"), .operation(.rebase, branches: ["rb", "rb-base"]),
                .changes(changes),
            ])
    }

    /// A missing worktree has no folder to read changes from: "missing", never "changes unknown".
    @Test func aMissingWorktreeIsMissingAndNothingElseAboutItsFiles() {
        let gone = Self.worktree("/r/wt-gone", branch: "refs/heads/gone", missing: "gitdir file points to non-existent location")
        #expect(
            WorktreeWording.marks(gone, isOpenHere: false, changes: .unknown, operation: nil)
                == [.missing(reason: "gitdir file points to non-existent location")])
        let lockedGone = Self.worktree("/r/wt-lg", branch: "refs/heads/lg", lock: WorktreeLock(reason: nil), missing: "gone")
        #expect(
            WorktreeWording.marks(lockedGone, isOpenHere: false, changes: .notRead, operation: nil)
                == [.missing(reason: "gone"), .locked(reason: nil)])
    }

    @Test func aChangesReadThatFailedIsUnknown() {
        #expect(
            WorktreeWording.marks(Self.feat, isOpenHere: false, changes: .unknown, operation: nil) == [.changesUnknown])
    }

    @Test func eachMarksTextSymbolAndTooltip() {
        func check(_ mark: WorktreeMark, _ text: String, _ symbol: String, _ help: String) {
            #expect(WorktreeWording.markText(mark) == text, "\(mark)")
            #expect(WorktreeWording.markSymbol(mark) == symbol, "\(mark)")
            #expect(WorktreeWording.markHelp(mark) == help, "\(mark)")
        }
        check(.thisWindow, "this window", "macwindow", "This window has this worktree open.")
        check(
            .changes(WorktreeChanges(staged: 2, unstaged: 1, untracked: 3, conflicted: 1)), "7 changes", "pencil",
            "Not committed: 2 staged, 1 unstaged, 3 untracked, 1 conflicted.")
        check(
            .changes(WorktreeChanges(staged: 0, unstaged: 0, untracked: 1, conflicted: 0)), "1 change", "pencil",
            "Not committed: 1 untracked.")
        check(.changesUnknown, "changes unknown", "questionmark.circle", "Gitter could not read this worktree's changes.")
        check(.locked(reason: nil), "locked", "lock", "Locked, with no reason given. Gitter leaves a locked worktree alone.")
        check(
            .locked(reason: "line one\nline\ttwo \"q\""), "locked", "lock",
            "Locked: line one⏎line two \"q\". Gitter leaves a locked worktree alone.")
        check(
            .missing(reason: "gitdir file points to non-existent location"), "missing", "exclamationmark.triangle",
            "Its folder is gone (git: gitdir file points to non-existent location). git counts its branch as checked "
                + "out there until the worktree is removed.")
        check(
            .operation(.rebase, branches: ["rb"]), "rebasing rb", "arrow.triangle.2.circlepath",
            "A rebase is in progress there. Until it ends, git will not check out or delete \"rb\" anywhere else.")
        check(
            .operation(.rebase, branches: ["rb", "a", "b"]), "rebasing rb +2", "arrow.triangle.2.circlepath",
            "A rebase is in progress there. Until it ends, git will not check out or delete \"rb\", \"a\", \"b\" "
                + "anywhere else.")
        check(
            .operation(.bisect, branches: ["bis"]), "bisecting bis", "arrow.triangle.2.circlepath",
            "A bisect is in progress there. Until it ends, git will not check out or delete \"bis\" anywhere else.")
        check(
            .operation(nil, branches: ["x"]), "holds x", "arrow.triangle.2.circlepath",
            "A rebase or bisect is in progress there. Until it ends, git will not check out or delete \"x\" "
                + "anywhere else.")
    }

    @Test func theRowsTooltipAndVoiceOverLabel() {
        let marks: [WorktreeMark] = [.thisWindow, .changesUnknown]
        #expect(
            WorktreeWording.rowHelp(Self.main, marks: marks)
                == "/r/main\nThe main worktree.\nThis window has this worktree open.\n"
                + "Gitter could not read this worktree's changes.")
        #expect(WorktreeWording.rowHelp(Self.feat, marks: []) == "/r/wt-feat")
        #expect(
            WorktreeWording.rowAccessibility(Self.main, marks: marks)
                == "main, main, main worktree, this window, changes unknown")
        #expect(WorktreeWording.rowAccessibility(Self.detached, marks: []) == "wt-det, detached at bbbbbbb")
    }

    // MARK: - The window title

    @Test func theTitleNamesTheMainWorktreeOfALinkedOne() {
        #expect(WorktreeWording.windowTitle(folder: "wt-feat", mainFolder: "main") == "wt-feat (worktree of main)")
        #expect(WorktreeWording.windowTitle(folder: "main", mainFolder: nil) == "main")
    }

    // MARK: - The history pill

    /// Another worktree's detached HEAD — a missing one's too, `log --all` still shows it (R27) —
    /// and never this window's own HEAD, a branch worktree's or a bare repository's.
    @Test func thePillMarksOtherWorktreesDetachedHeads() {
        let gone = Self.worktree("/r/wt-gone", head: Self.headB, missing: "gone")
        let bare = Self.worktree("/r/bare.git", head: nil, isMain: true, isBare: true)
        let open = Self.worktree("/r/wt-open", head: Self.headA)
        let heads = WorktreeWording.detachedHeads([bare, Self.feat, Self.detached, gone, open], openPath: "/r/wt-open")
        #expect(heads.mapValues { $0.map(\.path) } == [Self.headB: ["/r/wt-det", "/r/wt-gone"]])
        #expect(WorktreeWording.pillText(Self.detached) == "worktree: wt-det")
        #expect(WorktreeWording.pillHelp(Self.detached) == "The detached HEAD of the worktree at /r/wt-det.")
    }
}

/// B3 Task 5: the Add Worktree and Remove Worktree sheets — the choices Add offers, the default
/// folder and the folder's live check, every result of an add (the partial ones included), every
/// refusal of the removal check, the removal's results whole, partial and unknown, and Remove All
/// Missing… with its report. Pure: no store, no git.
@Suite struct WorktreeSheetWordingTests {
    typealias T = WorktreeWordingTests
    static let sha = "1111111111111111111111111111111111111111"
    static let head = "abcdef0123456789abcdef0123456789abcdef01"

    static func branch(_ name: String, checkedOutAt: String? = nil, isHead: Bool = false) -> Branch {
        Branch(name: name, sha: sha, isHead: isHead, upstream: nil, checkedOutAt: checkedOutAt)
    }

    static let feat = T.worktree("/r/wt-feat", branch: "refs/heads/feat")
    static let detached = T.worktree("/r/wt-det", head: head)
    static let gone = T.worktree("/r/wt-gone", branch: "refs/heads/gone", missing: "gitdir file points to non-existent location")
    static let goneDetached = T.worktree("/r/wt-gd", head: head, missing: "gone")

    static func removal(
        _ worktree: Worktree, changes: WorktreeChanges? = WorktreeChanges.none, ignored: IgnoredSummary = .none,
        stranded: StrandedCommits = .none, refusals: [WorktreeRemovalRefusal] = []
    ) -> WorktreeRemoval {
        WorktreeRemoval(worktree: worktree, changes: changes, ignored: ignored, stranded: stranded, refusals: refusals)
    }

    static func stranded(_ count: Int, holder: String) -> StrandedCommits {
        StrandedCommits(
            count: count, commits: (0..<min(count, 2)).map { CommitRef(sha: head, subject: "c\($0)") }, holders: [holder])
    }

    // MARK: - Titles and the menus' reasons

    @Test func theTitles() {
        #expect(WorktreeWording.addTitle == "Add Worktree…")
        #expect(WorktreeWording.newWorktreeTitle("feat") == "New Worktree for \"feat\"…")
        #expect(WorktreeWording.removeTitle == "Remove Worktree…")
        #expect(WorktreeWording.removeAllMissingTitle == "Remove All Missing…")
        #expect(WorktreeWording.addSheetTitle == "Add Worktree")
        #expect(WorktreeWording.addButton == "Add Worktree")
        #expect(WorktreeWording.removeButton == "Remove Worktree")
        #expect(WorktreeWording.removeSheetTitle(Self.feat) == "Remove Worktree \"wt-feat\"")
        #expect(WorktreeWording.removeMissingSheetTitle == "Remove Missing Worktrees")
        #expect(WorktreeWording.openNoticeButton == "Open")
        #expect(NoticeWording.title(.openWorktree("/r/wt-feat")) == "Open")
    }

    @Test func newWorktreeForABranchIsOffWhereItIsCheckedOut() {
        #expect(WorktreeWording.newWorktreeBlocked("feat", isCurrent: false, heldReason: nil) == nil)
        #expect(
            WorktreeWording.newWorktreeBlocked("main", isCurrent: true, heldReason: nil)
                == "\"main\" is checked out in this window, and a branch can be checked out in only one worktree.")
        #expect(
            WorktreeWording.newWorktreeBlocked("feat", isCurrent: false, heldReason: "held elsewhere.")
                == "held elsewhere.")
    }

    @Test func removeIsOffForTheMainAndThisWindowsWorktree() {
        #expect(WorktreeWording.removeBlocked(Self.feat, isOpenHere: false) == nil)
        #expect(WorktreeWording.removeBlocked(Self.gone, isOpenHere: false) == nil)
        #expect(
            WorktreeWording.removeBlocked(T.main, isOpenHere: true)
                == "The main worktree holds the repository itself, so it can't be removed.")
        #expect(
            WorktreeWording.removeBlocked(Self.feat, isOpenHere: true)
                == "This window has this worktree open. Open another one first, then remove it from there.")
    }

    @Test func removeAllMissingIsOffWithNothingMissing() {
        #expect(WorktreeWording.missing([T.main, Self.feat, Self.gone, Self.goneDetached]) == [Self.gone, Self.goneDetached])
        #expect(WorktreeWording.removeAllMissingBlocked([T.main, Self.gone]) == nil)
        #expect(WorktreeWording.removeAllMissingBlocked([T.main, Self.feat]) == "No worktree's folder is missing.")
    }

    // MARK: - Add: the choices

    /// Only branches no worktree has checked out and no rebase or bisect holds — this window's
    /// own branch and its own operation's included.
    @Test func theExistingChoiceOffersOnlyFreeBranches() {
        let branches = [
            Self.branch("main", isHead: true), Self.branch("feat", checkedOutAt: "/r/wt-feat"), Self.branch("free"),
            Self.branch("rb"), Self.branch("mine"), Self.branch("also-free"),
        ]
        let worktrees = [
            T.worktree("/r/main", branch: nil, isMain: true, operation: ["refs/heads/mine"]), Self.feat,
            T.worktree("/r/wt-rb", operation: ["refs/heads/rb"]),
        ]
        #expect(
            WorktreeWording.freeBranches(branches, current: "main", worktrees: worktrees) == ["free", "also-free"])
        #expect(
            WorktreeWording.noFreeBranches
                == "Every local branch is checked out in a worktree or held by a rebase or bisect.")
        #expect(WorktreeWording.noRemoteBranches == "There is no fetched remote branch.")
    }

    @Test func theKindsAreWorded() {
        #expect(WorktreeWording.kindTitle(.existing) == "Existing branch")
        #expect(WorktreeWording.kindTitle(.newBranch) == "New branch")
        #expect(WorktreeWording.kindTitle(.tracking) == "Remote branch")
        #expect(
            WorktreeWording.kindExplanation(.existing)
                == "Check out a local branch that no worktree has checked out.")
        #expect(
            WorktreeWording.kindExplanation(.newBranch)
                == "Create a new branch at a start point, then check it out in the new worktree.")
        #expect(
            WorktreeWording.kindExplanation(.tracking)
                == "Create a new local branch that tracks a remote branch, then check it out in the new worktree.")
    }

    /// A remote branch's own name after its remote: `origin/feat/x` → `feat/x`.
    @Test func aTrackingBranchIsNamedAfterTheRemoteBranch() {
        #expect(WorktreeWording.trackingName("origin/feat", remote: "origin") == "feat")
        #expect(WorktreeWording.trackingName("origin/team/a/b", remote: "origin") == "team/a/b")
        #expect(WorktreeWording.trackingName("my/remote/x", remote: "my/remote") == "x")
        #expect(WorktreeWording.trackingName("up/x", remote: nil) == "x")
    }

    @Test func aStartPointIsShownByItsShortName() {
        #expect(WorktreeWording.startLabel(RefTip(ref: "refs/heads/main", id: Self.sha)) == "main")
        #expect(WorktreeWording.startLabel(RefTip(ref: "refs/remotes/origin/x", id: Self.sha)) == "origin/x")
        #expect(WorktreeWording.startLabel(RefTip(ref: Self.head, id: Self.head)) == "abcdef0")
    }

    // MARK: - Add: the folder

    /// A sibling of the main worktree's folder, named `<main folder>-<branch>`, a branch's slashes
    /// made dashes; a bare `x.git` is `x`.
    @Test func theDefaultFolderIsASiblingOfTheMainWorktree() {
        #expect(WorktreeWording.defaultFolder(mainPath: "/r/main", branch: "feat") == "/r/main-feat")
        #expect(WorktreeWording.defaultFolder(mainPath: "/r/main", branch: "team/a/b") == "/r/main-team-a-b")
        #expect(WorktreeWording.defaultFolder(mainPath: "/r/main/", branch: "x") == "/r/main-x")
        #expect(WorktreeWording.defaultFolder(mainPath: "/r/repo.git", branch: "x") == "/r/repo-x")
        #expect(WorktreeWording.defaultFolder(mainPath: "/r/my repo", branch: "ü") == "/r/my repo-ü")
        #expect(WorktreeWording.defaultFolder(mainPath: "/r/main", branch: "") == "/r/main-worktree")
    }

    /// What the field holds, as the check and git get it: trimmed, `~` expanded, a trailing slash
    /// off.
    @Test func theFolderFieldIsTrimmedAndTildeExpanded() {
        #expect(WorktreeWording.normalizedFolder("  /r/x  ") == "/r/x")
        #expect(WorktreeWording.normalizedFolder("/r/x/") == "/r/x")
        #expect(WorktreeWording.normalizedFolder("~/wt") == NSHomeDirectory() + "/wt")
        #expect(WorktreeWording.normalizedFolder("/") == "/")
        #expect(WorktreeWording.normalizedFolder("rel/x") == "rel/x")
    }

    /// The live check: it must not exist or must be an empty folder, and must lie outside every
    /// worktree (R16: git accepts one inside, where it shows as untracked).
    @Test func theFolderIsCheckedLive() {
        func problem(_ path: String, _ state: WorktreeFolderState, inside: String? = nil) -> String? {
            WorktreeWording.folderProblem(path, state: state, insideWorktree: inside)
        }
        #expect(problem("/r/new", .missing) == nil)
        #expect(problem("/r/empty", .empty) == nil)
        #expect(problem("", .missing) == "Choose a folder for the worktree.")
        #expect(problem("rel/x", .missing) == "Enter a full path, beginning with /.")
        #expect(
            problem("/r/full", .notEmpty)
                == "This folder is not empty. Choose a folder that doesn't exist yet, or an empty one.")
        #expect(
            problem("/r/file", .notAFolder)
                == "Something that is not a folder is at this path. Choose a folder that doesn't exist yet, or an "
                + "empty one.")
        #expect(
            problem("/r/locked", .unreadable)
                == "Gitter can't read this folder, so it can't tell whether it is empty. Choose another.")
        #expect(
            problem("/r/main/sub", .missing, inside: "/r/main")
                == "This is inside the worktree at /r/main, where the new one would show as untracked files. Choose "
                + "a folder outside every worktree.")
    }

    /// Which worktree a path is inside, by real path both sides (R23): itself included, a sibling
    /// with a common prefix not.
    @Test func whichWorktreeAPathIsInside() {
        let listed = [(path: "/var/r/main", resolved: "/private/var/r/main"), (path: "/r/wt", resolved: "/r/wt")]
        #expect(WorktreeWording.containingWorktree("/private/var/r/main/sub", in: listed) == "/var/r/main")
        #expect(WorktreeWording.containingWorktree("/r/wt", in: listed) == "/r/wt")
        #expect(WorktreeWording.containingWorktree("/r/wt-feat", in: listed) == nil)
        #expect(WorktreeWording.containingWorktree("/elsewhere", in: listed) == nil)
    }

    // MARK: - Add: what happened

    static let start = RefTip(ref: "refs/heads/main", id: sha)
    static let remoteTip = RefTip(ref: "refs/remotes/origin/feat", id: sha)

    @Test func anAddThatWorkedOffersOpen() {
        let added = AddWorktreeResult.added(T.worktree("/r/main-feat", branch: "refs/heads/feat"))
        let existing = WorktreeWording.added(added, choice: .existing("feat"), upstreamProblem: nil)
        #expect(existing.text == "Added a worktree for \"feat\" at /r/main-feat.")
        #expect(existing.opens == "/r/main-feat")
        #expect(!existing.isProblem)
        let new = WorktreeWording.added(added, choice: .newBranch(name: "feat", start: Self.start), upstreamProblem: nil)
        #expect(new.text == "Created \"feat\" from main and added a worktree for it at /r/main-feat.")
        let tracking = WorktreeWording.added(
            added, choice: .tracking(name: "feat", remote: Self.remoteTip), upstreamProblem: nil)
        #expect(
            tracking.text == "Created \"feat\" tracking \"origin/feat\" and added a worktree for it at /r/main-feat.")
        #expect(!tracking.isProblem)
    }

    /// Ruling 3: the worktree was added, its upstream was not set.
    @Test func aTrackingAddWhoseUpstreamWasNotSet() {
        let added = AddWorktreeResult.added(T.worktree("/r/main-feat", branch: "refs/heads/feat"))
        let report = WorktreeWording.added(
            added, choice: .tracking(name: "feat", remote: Self.remoteTip),
            upstreamProblem: WorktreeWording.upstreamProblem(UpstreamRefusal.notFetched("refs/remotes/origin/feat")))
        #expect(
            report.text
                == "Created \"feat\" from origin/feat and added a worktree for it at /r/main-feat, but setting its upstream "
                + "did not work: \"origin/feat\" doesn't exist here any more. Set it with Set Upstream… in the "
                + "branch's menu.")
        #expect(report.isProblem)
        #expect(report.opens == "/r/main-feat")
    }

    @Test func everyReasonAnUpstreamWasNotSet() {
        #expect(
            WorktreeWording.upstreamProblem(UpstreamRefusal.notABranch("refs/remotes/origin/x"))
                == "\"origin/x\" is not a branch a remote fetches into")
        #expect(
            WorktreeWording.upstreamProblem(UpstreamRefusal.ambiguousNamespace("refs/remotes/origin/x"))
                == "two remotes fetch into \"origin/x\"")
        #expect(
            WorktreeWording.upstreamProblem(UpstreamRefusal.mergeMismatch(expected: "refs/heads/x", written: "refs/heads/y"))
                == "git set it to refs/heads/y on the server, not refs/heads/x, because overlapping fetch refspecs "
                + "map it elsewhere")
        #expect(
            WorktreeWording.upstreamProblem(
                RemoteAdminPartial.upstreamChangedThenFailed(branch: "x", remote: "origin", merge: nil, gitsWords: "lock held"))
                == "git failed part-way (lock held), leaving branch.x.remote = origin and no branch.x.merge")
        #expect(
            WorktreeWording.upstreamProblem(RemoteAdminPartial.upstreamOutcomeUnknown(branch: "x"))
                == "Gitter was stopped while setting it, so whether it is set is not known")
        #expect(
            WorktreeWording.upstreamProblem(GitError.commandFailed(exitCode: 128, stderr: "fatal: no"))
                == "fatal: no")
    }

    /// R19: git exited non-zero with the worktree complete — a failing `post-checkout` hook.
    @Test func anAddGitReportedAnErrorAfter() {
        let result = AddWorktreeResult.addedWithError(
            T.worktree("/r/main-feat", branch: "refs/heads/feat"), gitsWords: "hook says no")
        let report = WorktreeWording.added(result, choice: .existing("feat"), upstreamProblem: nil)
        #expect(
            report.text
                == "Added a worktree for \"feat\" at /r/main-feat, but git exited with an error after making it: hook "
                + "says no. A post-checkout hook may have failed — check the files there.")
        #expect(report.isProblem)
        #expect(report.opens == "/r/main-feat")
        let empty = WorktreeWording.added(
            .addedWithError(T.worktree("/r/x", branch: "refs/heads/x"), gitsWords: ""),
            choice: .newBranch(name: "x", start: Self.start), upstreamProblem: nil)
        #expect(
            empty.text
                == "Created \"x\" from main and added a worktree for it at /r/x, but git exited with an error after "
                + "making it. A post-checkout hook may have failed — check the files there.")
    }

    /// Not what was asked: listed on another branch or detached, or not listed at all.
    @Test func anAddThatDidSomethingElse() {
        let other = WorktreeWording.added(
            .unexpected(T.worktree("/r/main-feat", head: Self.head), gitsWords: ""), choice: .existing("feat"),
            upstreamProblem: nil)
        #expect(
            other.text
                == "git added a worktree at /r/main-feat, but it is detached at abcdef0, not on \"feat\" as asked. "
                + "Gitter changed nothing there: open it to look, or remove it.")
        #expect(other.isProblem)
        #expect(other.opens == "/r/main-feat")
        let none = WorktreeWording.added(
            .unexpected(nil, gitsWords: "odd"), choice: .newBranch(name: "x", start: Self.start), upstreamProblem: nil)
        #expect(
            none.text
                == "git said it added the worktree, but nothing is listed at the folder you chose (odd). The branch "
                + "\"x\" was created first and stays.")
        #expect(none.isProblem)
        #expect(none.opens == nil)
    }

    /// Ruling 3: a branch created, then no worktree.
    @Test func everyAddFailureSaysWhatWasLeft() {
        func failure(_ error: Error, _ choice: AddWorktreeChoice = .existing("feat"), created: Bool = false) -> String {
            WorktreeWording.addFailure(
                error, choice: choice, path: "/r/main-feat", branchCreated: created, upstreamProblem: nil)
        }
        #expect(
            failure(AddWorktreeRefusal.noSuchBranch("feat"))
                == "There is no local branch \"feat\" any more, so no worktree was added.")
        #expect(
            failure(AddWorktreeRefusal.branchInUse(path: "/r/wt-x"))
                == "\"feat\" is checked out in /r/wt-x now, so no worktree was added.")
        #expect(
            failure(AddWorktreeRefusal.branchHeldByOperation(path: "/r/wt-x"))
                == "\"feat\" is held by a rebase or bisect in /r/wt-x, so no worktree was added.")
        #expect(
            failure(AddWorktreeRefusal.pathExists("/r/main-feat"))
                == "Something is at /r/main-feat now, so no worktree was added. Choose a folder that doesn't exist "
                + "yet, or an empty one.")
        #expect(
            failure(AddWorktreeRefusal.pathInsideWorktree("/r/main-feat"))
                == "/r/main-feat is inside a worktree, so no worktree was added.")
        #expect(
            failure(AddWorktreeRefusal.pathNotAbsolute("x"))
                == "x is not a full path, so no worktree was added.")
        #expect(
            failure(GitError.commandFailed(exitCode: 128, stderr: "fatal: smudge filter lfs failed"))
                == "git didn't add the worktree at /r/main-feat: fatal: smudge filter lfs failed. Nothing is listed "
                + "there.")
        #expect(
            failure(GitError.commandFailed(exitCode: 128, stderr: ""))
                == "git didn't add the worktree at /r/main-feat: git exited with code 128. Nothing is listed there.")
        #expect(
            failure(CancellationError())
                == "Stopped before the worktree was added. Nothing is listed at /r/main-feat.")
        #expect(
            failure(GitError.commandFailed(exitCode: 128, stderr: "fatal: x"), .newBranch(name: "x", start: Self.start), created: true)
                == "git didn't add the worktree at /r/main-feat: fatal: x. Nothing is listed there. The branch \"x\" "
                + "was created first and stays.")
        #expect(
            failure(
                AddWorktreeRefusal.pathExists("/r/main-feat"), .tracking(name: "feat", remote: Self.remoteTip),
                created: true)
                == "Something is at /r/main-feat now, so no worktree was added. Choose a folder that doesn't exist "
                + "yet, or an empty one. The branch \"feat\" was created first and stays.")
    }

    @Test func openOnANoticeForAWorktreeNoLongerListed() {
        #expect(
            WorktreeWording.notListedAnyMore("/r/main-feat")
                == "The worktree at /r/main-feat is no longer listed, so there is nothing to open.")
    }

    /// Fix round 1 (M1): a tracking branch created, its upstream not set, then no worktree — both
    /// partial states are said.
    @Test func aTrackingAddThatFailedAfterItsUpstreamDidNotSaysBoth() {
        #expect(
            WorktreeWording.addFailure(
                AddWorktreeRefusal.pathExists("/r/main-strayx"), choice: .tracking(name: "strayx", remote: Self.remoteTip),
                path: "/r/main-strayx", branchCreated: true,
                upstreamProblem: "\"stray/x\" is not a branch a remote fetches into")
                == "Something is at /r/main-strayx now, so no worktree was added. Choose a folder that doesn't exist "
                + "yet, or an empty one. The branch \"strayx\" was created first and stays. Setting its upstream did "
                + "not work either: \"stray/x\" is not a branch a remote fetches into.")
    }

    @Test func aBranchThatCouldNotBeCreated() {
        #expect(
            WorktreeWording.branchNotCreated(BranchOperationError.branchExists("x"), name: "x")
                == "A branch named \"x\" already exists. No worktree was added.")
        #expect(
            WorktreeWording.branchNotCreated(GitError.commandFailed(exitCode: 128, stderr: "fatal: bad"), name: "x")
                == "Couldn't create \"x\": fatal: bad. No worktree was added.")
    }

    // MARK: - Remove: the sheet

    @Test func theRemoveSheetSaysWhatGoesAndWhatStays() {
        let clean = Self.removal(Self.feat)
        #expect(WorktreeWording.removeIntro(clean) == "This deletes its folder, above, and everything in it.")
        #expect(WorktreeWording.branchStays(clean) == "The branch \"feat\" stays.")
        #expect(WorktreeWording.strandedLine(clean) == nil)
        #expect(WorktreeWording.ignoredLine(clean.ignored) == nil)
        #expect(WorktreeWording.checking == "Checking what removing it would lose…")
        #expect(WorktreeWording.refusalsHeading == "Gitter won't remove it:")
    }

    @Test func aMissingWorktreesFolderIsGone() {
        let gone = Self.removal(Self.gone, changes: nil)
        #expect(
            WorktreeWording.removeIntro(gone)
                == "Its folder is gone. Removing it takes it off git's list, so its branch can be checked out "
                + "elsewhere; nothing on disk changes.")
        #expect(WorktreeWording.branchStays(gone) == "The branch \"gone\" stays.")
    }

    @Test func theIgnoredEntriesGitDeletesWithIt() {
        #expect(
            WorktreeWording.ignoredLine(IgnoredSummary(entries: ["build/"]))
                == "git also deletes 1 ignored entry with it — files and folders git doesn't track, each folder "
                + "with everything in it — without asking: build/")
        #expect(
            WorktreeWording.ignoredLine(
                IgnoredSummary(entries: ["build/", "debug.log", "sub/a.log", "sub/b.log", "sub/c/d.log"]))
                == "git also deletes 5 ignored entries with it — files and folders git doesn't track, each folder "
                + "with everything in it — without asking: build/, debug.log, sub/")
        let forty = (1...40).map { "d\($0)/x.log" }
        #expect(
            WorktreeWording.ignoredLine(IgnoredSummary(entries: forty))?.hasSuffix("d9/, d10/, …") == true)
    }

    /// R22: a detached HEAD's own commits, and the keep box's words.
    @Test func aDetachedWorktreesCommits() {
        let none = Self.removal(Self.detached)
        #expect(WorktreeWording.branchStays(none) == nil)
        #expect(
            WorktreeWording.strandedLine(none)
                == "Its detached HEAD (abcdef0) is also on a branch, tag, remote or another worktree, so no commit is "
                + "lost.")
        let one = Self.removal(Self.detached, stranded: Self.stranded(1, holder: "/r/wt-det"))
        #expect(
            WorktreeWording.strandedLine(one)
                == "Its detached HEAD holds 1 commit no branch, tag, remote or other worktree has. Removing it deletes "
                + "its HEAD's history, so the commit would be on no branch:")
        let three = Self.removal(Self.detached, stranded: Self.stranded(3, holder: "/r/wt-det"))
        #expect(
            WorktreeWording.strandedLine(three)
                == "Its detached HEAD holds 3 commits no branch, tag, remote or other worktree has. Removing it deletes "
                + "its HEAD's history, so they would be on no branch:")
        #expect(WorktreeWording.keepHeading == "Keep a branch at its HEAD, so these commits stay on a branch:")
        #expect(WorktreeWording.keepLabel("/r/wt-det") == "Keep \"wt-det\" as")
    }

    /// Ruling 1's rule for a worktree: its folder's name made a branch name, `-kept` when taken.
    @Test func theSuggestedKeepName() {
        #expect(WorktreeWording.suggestedKeepName(folder: "wt-det", taken: []) == "wt-det")
        #expect(WorktreeWording.suggestedKeepName(folder: "wt-det", taken: ["WT-DET"]) == "wt-det-kept")
        #expect(WorktreeWording.suggestedKeepName(folder: "wt-det", taken: ["wt-det", "wt-det-kept"]) == "wt-det-kept-2")
        #expect(WorktreeWording.suggestedKeepName(folder: "my wt:1", taken: []) == "my-wt-1")
        #expect(WorktreeWording.suggestedKeepName(folder: "..x..y.lock", taken: []) == "x-y")
        #expect(WorktreeWording.suggestedKeepName(folder: "-~^", taken: []) == "kept-worktree")
        #expect(WorktreeWording.suggestedKeepName(folder: "wt\nnl", taken: []) == "wt-nl")
        #expect(WorktreeWording.suggestedKeepName(folder: "wt-ü", taken: []) == "wt-ü")
    }

    /// Every refusal of the check, in place of the button, each with its next step.
    @Test func everyRefusalIsWorded() {
        func check(_ refusal: WorktreeRemovalRefusal, _ text: String) {
            #expect(WorktreeWording.refusal(refusal) == text, "\(refusal)")
        }
        check(.isMain, "It is the main worktree, which holds the repository itself.")
        check(.isOpenHere, "This window has it open. Open another worktree first, then remove this one from there.")
        check(
            .locked(reason: "on a USB disk"),
            "It is locked (\"on a USB disk\"). Gitter leaves locked worktrees alone; unlock it in Terminal "
                + "(git worktree unlock) if you mean to remove it.")
        check(
            .locked(reason: nil),
            "It is locked, with no reason given. Gitter leaves locked worktrees alone; unlock it in Terminal "
                + "(git worktree unlock) if you mean to remove it.")
        check(
            .operationInProgress("rebase"),
            "A rebase is in progress there, and git would remove it with the worktree. Finish or abort it there first.")
        check(
            .operationInProgress("am"),
            "An am is in progress there, and git would remove it with the worktree. Finish or abort it there first.")
        check(
            .operationInProgress("sequencer"),
            "A cherry-pick or revert is between its steps there, and git would remove it with the worktree. Finish "
                + "or abort it there first.")
        check(
            .changes(WorktreeChanges(staged: 1, unstaged: 0, untracked: 2, conflicted: 0)),
            "It has changes that are not committed: 1 staged, 2 untracked. Commit, stash or discard them there first.")
        check(
            .assumeUnchanged(["a.txt", "b.txt"]),
            "2 files there are marked assume-unchanged (\"a.txt\", \"b.txt\"): an edit to them is hidden from git, "
                + "and removing would delete it. Clear the mark in Terminal (git update-index --no-assume-unchanged) "
                + "first.")
        check(
            .skipWorktreePresent(["s.txt"]),
            "1 file there is marked skip-worktree and present (\"s.txt\"): an edit to it is hidden from git, and "
                + "removing would delete it. Clear the mark in Terminal (git update-index --no-skip-worktree) first.")
        check(
            .nestedRepository(["vendor/lib"]),
            "It holds another repository, in \"vendor/lib\": removing would delete it, history and all. Move it out "
                + "first.")
        check(
            .nestedRepository(["a", "b", "c", "d", "e"]),
            "It holds other repositories, in \"a\", \"b\", \"c\" and 2 more: removing would delete them, history and "
                + "all. Move them out first.")
        check(
            .tooLargeToCheck,
            "It holds too many files for Gitter to check for repositories inside it. Remove it in Terminal after "
                + "checking it yourself.")
        check(
            .unreadable("/r/wt-feat/secret"),
            "Gitter couldn't read /r/wt-feat/secret, so it can't tell what removing would lose. Check its "
                + "permissions.")
    }

    // MARK: - Remove: what happened

    @Test func aRemovalThatWorked() {
        #expect(
            WorktreeWording.removed(Self.removal(Self.feat), kept: [])
                == "Removed the worktree at /r/wt-feat. The branch \"feat\" stays.")
        #expect(
            WorktreeWording.removed(Self.removal(Self.feat, ignored: IgnoredSummary(entries: ["b/", "x.log", "y.log"])), kept: [])
                == "Removed the worktree at /r/wt-feat, with the 3 ignored entries in it. The branch \"feat\" stays.")
        #expect(
            WorktreeWording.removed(
                Self.removal(Self.detached, stranded: Self.stranded(2, holder: "/r/wt-det")), kept: ["wt-det"])
                == "Removed the worktree at /r/wt-det. Its 2 commits are on the kept branch \"wt-det\".")
        #expect(
            WorktreeWording.removed(Self.removal(Self.detached), kept: [])
                == "Removed the worktree at /r/wt-det.")
        #expect(
            WorktreeWording.removed(Self.removal(Self.gone, changes: nil), kept: [])
                == "Removed the missing worktree /r/wt-gone from git's list. The branch \"gone\" stays.")
    }

    /// Every partial and unknown result, naming the kept branches.
    @Test func everyRemovalFailureSaysWhatWasLeft() {
        let shown = Self.removal(Self.detached, stranded: Self.stranded(1, holder: "/r/wt-det"))
        func failure(_ error: Error) -> String { WorktreeWording.removeFailure(error, removal: shown) }
        #expect(
            failure(WorktreeRemovalPartial.changedSinceShown)
                == "The worktree at /r/wt-det changed since the sheet checked it — a file, a commit, a lock or its "
                + "list entry. Nothing was removed and no branch was created. Remove it again to see what it holds "
                + "now.")
        #expect(
            failure(WorktreeRemovalPartial.keptBranchesThenStopped(kept: ["k"], gitsWords: "cannot run git"))
                == "Created the kept branch \"k\", then the removal could not go on: cannot run git. Nothing was "
                + "removed; \"k\" stays.")
        #expect(
            failure(WorktreeRemovalPartial.refusedByGit(gitsWords: "fatal: contains modified or untracked files", keptBranches: ["k"]))
                == "git refused to remove the worktree at /r/wt-det: fatal: contains modified or untracked files. It "
                + "is still listed, but git checks as it deletes, so some files may be gone — look in the folder. "
                + "The kept branch \"k\" stays.")
        #expect(
            failure(WorktreeRemovalPartial.refusedByGit(gitsWords: "", keptBranches: []))
                == "git refused to remove the worktree at /r/wt-det. It is still listed, but git checks as it "
                + "deletes, so some files may be gone — look in the folder.")
        #expect(
            failure(WorktreeRemovalPartial.removedWithLeftovers(gitsWords: "failed to delete 'x'", keptBranches: ["k", "k2"]))
                == "git took the worktree at /r/wt-det off its list but did not finish deleting its folder: failed "
                + "to delete 'x'. What is left is still on disk; delete it yourself once you've checked it. The kept "
                + "branches \"k\", \"k2\" stay.")
        #expect(
            failure(WorktreeRemovalPartial.outcomeUnknown(keptBranches: []))
                == "Whether the worktree at /r/wt-det was removed is not known: git was stopped, or the list could "
                + "not be read back. Refresh to see.")
        #expect(
            failure(WorktreeRemovalPartial.outcomeUnknown(keptBranches: ["k"]))
                == "Whether the worktree at /r/wt-det was removed is not known: git was stopped, or the list could "
                + "not be read back. Refresh to see. The kept branch \"k\" stays.")
        // B2's own words for a kept branch whose creation was stopped (outcome unknown).
        #expect(
            failure(RemoteAdminPartial.keptBranchesCancelled(kept: [], unknown: "k"))
                == "Stopped while creating the kept branch \"k\": it may or may not have been created — check the "
                + "branch list. Nothing was removed.")
        #expect(
            failure(RemoteAdminRefusal.branchExists("k"))
                == "Couldn't keep \"k\": a branch, tag or remote has that name now. Nothing was removed.")
        #expect(
            failure(RemoteAdminRefusal.invalidBranchName("k k"))
                == "Couldn't keep \"k k\": that is not a valid branch name. Nothing was removed.")
        #expect(
            failure(WorktreeRemovalRefusal.locked(reason: nil))
                == "Didn't remove the worktree at /r/wt-det: it is locked, with no reason given. Gitter leaves "
                + "locked worktrees alone; unlock it in Terminal (git worktree unlock) if you mean to remove it.")
        #expect(
            failure(CancellationError()) == "Stopped before anything was removed or created.")
        #expect(
            failure(GitError.commandFailed(exitCode: 128, stderr: "fatal: bad"))
                == "Couldn't remove the worktree at /r/wt-det: fatal: bad. Nothing was removed.")
    }

    @Test func aCheckThatFailed() {
        #expect(
            WorktreeWording.checkFailure(WorktreeRemovalPartial.changedSinceShown, worktree: Self.feat)
                == "The worktree at /r/wt-feat is no longer listed — removed or moved since the last refresh. Nothing "
                + "was changed.")
        #expect(
            WorktreeWording.checkFailure(GitError.commandFailed(exitCode: 128, stderr: "fatal: x"), worktree: Self.feat)
                == "Couldn't check what removing the worktree at /r/wt-feat would lose: fatal: x. Nothing was changed.")
    }

    // MARK: - Remove All Missing…

    @Test func theMissingSheet() {
        #expect(
            WorktreeWording.removeMissingIntro(2)
                == "These 2 worktrees' folders are gone. Removing them takes them off git's list one at a time, so "
                + "their branches can be checked out elsewhere; nothing on disk changes.")
        #expect(
            WorktreeWording.removeMissingIntro(1)
                == "This worktree's folder is gone. Removing it takes it off git's list, so its branch can be checked "
                + "out elsewhere; nothing on disk changes.")
        #expect(WorktreeWording.removeMissingButton(1) == "Remove 1 Worktree")
        #expect(WorktreeWording.removeMissingButton(3) == "Remove 3 Worktrees")
        #expect(WorktreeWording.noneRemovable == "None of them can be removed: see why under each.")
        #expect(WorktreeWording.checkingMissing == "Checking the worktrees whose folder is gone…")
        #expect(
            WorktreeWording.missingKeepHeading
                == "Keep a branch at each detached HEAD, so their commits stay on a branch:")
    }

    @Test func theMissingReportNamesEachOne() {
        let report = [
            MissingRemoval(worktree: Self.gone, outcome: .removed(kept: [])),
            MissingRemoval(worktree: Self.goneDetached, outcome: .removed(kept: ["wt-gd"])),
        ]
        #expect(
            WorktreeWording.removedMissing(report)
                == "Removed 2 missing worktrees from git's list:\n/r/wt-gone — the branch \"gone\" stays.\n/r/wt-gd — "
                + "its commits are on the kept branch \"wt-gd\".")
        #expect(!WorktreeWording.missingReportHasProblems(report))
        let mixed = [
            MissingRemoval(worktree: Self.gone, outcome: .removed(kept: [])),
            MissingRemoval(worktree: Self.goneDetached, outcome: .notRemoved("It is locked, with no reason given.")),
        ]
        #expect(
            WorktreeWording.removedMissing(mixed)
                == "Removed 1 of 2 missing worktrees from git's list:\n/r/wt-gone — the branch \"gone\" stays.\n"
                + "/r/wt-gd — not removed: It is locked, with no reason given.")
        #expect(WorktreeWording.missingReportHasProblems(mixed))
    }
}
