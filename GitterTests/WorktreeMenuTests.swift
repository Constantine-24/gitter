import GitCore
import Testing

@testable import Gitter

/// B3 Task 3: a worktree row's menu — Open Worktree, Reveal in Finder, Copy Path — and the
/// branches another worktree holds: which worktree holds a branch (`WorktreeWording.holder`),
/// the icon and the one reason its Switch, Delete and Fast-Forward show. Pure: no store, no git.
@Suite struct WorktreeMenuTests {
    static let sha = "1111111111111111111111111111111111111111"

    static func worktree(
        _ path: String, branch: String? = nil, isMain: Bool = false, isBare: Bool = false, missing: String? = nil,
        operation: [String] = []
    ) -> Worktree {
        Worktree(
            path: path, head: isBare ? nil : sha, branch: branch, isMain: isMain, isBare: isBare, lock: nil,
            missingReason: missing, operationBranches: operation)
    }

    static func branch(_ name: String, checkedOutAt: String? = nil, isHead: Bool = false) -> Branch {
        Branch(name: name, sha: sha, isHead: isHead, upstream: nil, checkedOutAt: checkedOutAt)
    }

    static let main = worktree("/r/main", branch: "refs/heads/main", isMain: true)
    static let feat = worktree("/r/wt-feat", branch: "refs/heads/feat")
    static let gone = worktree("/r/wt-gone", branch: "refs/heads/gone", missing: "gitdir file points to non-existent location")
    static let rebasing = worktree("/r/wt-rb", operation: ["refs/heads/rb", "refs/heads/rb-stack"])
    static let goneRebasing = worktree("/r/wt-grb", missing: "gone", operation: ["refs/heads/grb"])
    static let all = [main, feat, gone, rebasing, goneRebasing]

    // MARK: - The row's menu

    @Test func theItemTitles() {
        #expect(WorktreeWording.openTitle == "Open Worktree")
        #expect(WorktreeWording.revealTitle == "Reveal in Finder")
        #expect(WorktreeWording.copyPathTitle == "Copy Path")
    }

    @Test func openIsOffForThisWindowsAMissingAndABareWorktree() {
        #expect(WorktreeWording.openBlocked(Self.feat, isOpenHere: false) == nil)
        #expect(WorktreeWording.openBlocked(Self.main, isOpenHere: false) == nil)
        #expect(WorktreeWording.openBlocked(Self.feat, isOpenHere: true) == "This window already has this worktree open.")
        #expect(WorktreeWording.openBlocked(Self.gone, isOpenHere: false) == "Its folder is gone, so there is nothing to open.")
        #expect(
            WorktreeWording.openBlocked(Self.worktree("/r/b.git", isMain: true, isBare: true), isOpenHere: false)
                == "A bare repository has no working files to open.")
    }

    @Test func revealIsOffOnlyForAMissingWorktree() {
        #expect(WorktreeWording.revealBlocked(Self.feat) == nil)
        #expect(WorktreeWording.revealBlocked(Self.main) == nil)
        #expect(WorktreeWording.revealBlocked(Self.gone) == "Its folder is gone, so Finder has nothing to show.")
    }

    // MARK: - Which worktree holds a branch

    @Test func aBranchCheckedOutElsewhereIsHeldThere() {
        let feat = Self.branch("feat", checkedOutAt: "/r/wt-feat")
        #expect(
            WorktreeWording.holder(of: feat, worktrees: Self.all, openPath: "/r/main", operations: [:])
                == .checkedOut(path: "/r/wt-feat", missing: false))
        // A missing worktree still holds its branch (R14).
        let gone = Self.branch("gone", checkedOutAt: "/r/wt-gone")
        #expect(
            WorktreeWording.holder(of: gone, worktrees: Self.all, openPath: "/r/main", operations: [:])
                == .checkedOut(path: "/r/wt-gone", missing: true))
        // Before the list has loaded, `checkedOutAt` alone is enough.
        #expect(
            WorktreeWording.holder(of: feat, worktrees: [], openPath: nil, operations: [:])
                == .checkedOut(path: "/r/wt-feat", missing: false))
    }

    /// Every branch an operation holds, not only the first (carried note 2).
    @Test func everyBranchAnOperationElsewhereHoldsIsHeld() {
        for name in ["rb", "rb-stack"] {
            #expect(
                WorktreeWording.holder(
                    of: Self.branch(name), worktrees: Self.all, openPath: "/r/main", operations: ["/r/wt-rb": .rebase])
                    == .operation(path: "/r/wt-rb", kind: .rebase, missing: false), "\(name)")
        }
        #expect(
            WorktreeWording.holder(of: Self.branch("grb"), worktrees: Self.all, openPath: "/r/main", operations: [:])
                == .operation(path: "/r/wt-grb", kind: nil, missing: true))
    }

    /// This window's own worktree holds nothing "elsewhere": its rebase is the operation bar's.
    @Test func thisWindowsOwnWorktreeHoldsNothingElsewhere() {
        #expect(
            WorktreeWording.holder(of: Self.branch("rb"), worktrees: Self.all, openPath: "/r/wt-rb", operations: [:])
                == nil)
        #expect(
            WorktreeWording.holder(of: Self.branch("main", isHead: true), worktrees: Self.all, openPath: "/r/main", operations: [:])
                == nil)
        #expect(
            WorktreeWording.holder(of: Self.branch("free"), worktrees: Self.all, openPath: "/r/main", operations: [:])
                == nil)
    }

    // MARK: - The reasons and the icon

    @Test func everyHeldReason() {
        #expect(
            WorktreeWording.heldReason("feat", by: .checkedOut(path: "/r/wt-feat", missing: false))
                == "\"feat\" is checked out in /r/wt-feat — open that worktree.")
        #expect(
            WorktreeWording.heldReason("gone", by: .checkedOut(path: "/r/wt-gone", missing: true))
                == "\"gone\" is checked out in /r/wt-gone, whose folder is gone — git counts it as checked out "
                + "there until that worktree is removed.")
        #expect(
            WorktreeWording.heldReason("rb", by: .operation(path: "/r/wt-rb", kind: .rebase, missing: false))
                == "\"rb\" is held by the rebase in /r/wt-rb — open that worktree.")
        #expect(
            WorktreeWording.heldReason("bis", by: .operation(path: "/r/wt-b", kind: .bisect, missing: false))
                == "\"bis\" is held by the bisect in /r/wt-b — open that worktree.")
        #expect(
            WorktreeWording.heldReason("x", by: .operation(path: "/r/wt-x", kind: nil, missing: false))
                == "\"x\" is held by a rebase or bisect in /r/wt-x — open that worktree.")
        #expect(
            WorktreeWording.heldReason("grb", by: .operation(path: "/r/wt-grb", kind: nil, missing: true))
                == "\"grb\" is held by a rebase or bisect in /r/wt-grb, whose folder is gone — git counts it as "
                + "held there until that worktree is removed.")
        // A newline in the path stays on one line.
        #expect(
            WorktreeWording.heldReason("nl", by: .checkedOut(path: "/r/wt\nnl", missing: false))
                == "\"nl\" is checked out in /r/wt⏎nl — open that worktree.")
    }

    @Test func theIconSaysWhichKindOfHold() {
        #expect(WorktreeWording.holderSymbol(.checkedOut(path: "/r/a", missing: false)) == "macwindow.on.rectangle")
        #expect(WorktreeWording.holderSymbol(.checkedOut(path: "/r/a", missing: true)) == "macwindow.on.rectangle")
        #expect(
            WorktreeWording.holderSymbol(.operation(path: "/r/a", kind: .rebase, missing: false))
                == "arrow.triangle.2.circlepath")
    }
}
