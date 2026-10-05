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
