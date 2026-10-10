import Foundation
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

/// B3 final review, T3 m1: a branch another worktree holds is refused with the held reason, as
/// Gitter's banner, before `perform` runs anything — before the operation gate, the detached-HEAD
/// question and git — whichever way the switch is asked for: the row's double-click (which has no
/// disabled state to show the reason), the menu, the toolbar, or Stash and Continue's retry. No
/// repository is open, so nothing past the refusal can run: a banner can only be the refusal's.
@MainActor @Suite struct WorktreeHeldSwitchTests {
    static let sha = "1111111111111111111111111111111111111111"

    /// On a scratch defaults suite (`makeTestStore`); the caller runs `cleanup`.
    static func store() -> (RepositoryStore, cleanup: () -> Void) {
        let (store, _, cleanup) = makeTestStore()
        store.setSnapshot(
            RepoSnapshot(
                root: URL(fileURLWithPath: "/nonexistent"),
                status: WorkingCopyStatus(headSha: sha, branch: "main", upstream: nil, ahead: 0, behind: 0, files: []),
                refs: RefCollection(
                    localBranches: [
                        Branch(name: "main", sha: sha, isHead: true, upstream: nil),
                        Branch(name: "feat", sha: sha, isHead: false, upstream: nil, checkedOutAt: "/r/wt-feat"),
                        Branch(name: "spare", sha: sha, isHead: false, upstream: nil),
                    ],
                    remoteBranches: [], tags: []),
                commits: [], graph: []))
        return (store, cleanup)
    }

    static let reason = WorktreeWording.heldReason("feat", by: .checkedOut(path: "/r/wt-feat", missing: false))

    @Test func aSwitchToABranchAnotherWorktreeHoldsIsRefusedWithItsReason() {
        let (store, cleanup) = Self.store()
        defer { cleanup() }
        #expect(store.switchBlockedReason(for: "feat") == Self.reason, "the menu's reason")

        store.switchTo(branch: "feat")

        #expect(store.lastError == Self.reason)
        #expect(store.activeSheet == nil)
        // The control: the gate `perform` had says nothing about another worktree.
        withKnownIssue("the operation gate alone lets a held branch through") {
            #expect(store.branchSwitchingBlockedReason != nil)
        }
    }

    @Test func stashAndContinuesRetryIsRefusedTheSameWay() {
        let (store, cleanup) = Self.store()
        defer { cleanup() }
        store.retry(.switchTo("feat"))
        #expect(store.lastError == Self.reason)
        #expect(store.activeSheet == nil)
    }

    /// The baseline: a free branch puts up no banner (with no repository, `mutate` runs nothing).
    @Test func aFreeBranchIsNotRefused() {
        let (store, cleanup) = Self.store()
        defer { cleanup() }
        store.switchTo(branch: "spare")
        #expect(store.lastError == nil)
    }
}

/// E2 Task 4: a worktree's menu keeps Open Worktree, which switches this window, and adds Open in
/// New Window, routed as an open (`.worktreeNewWindow`): a window of its own, or — when a window
/// shows that worktree already — that window, brought to the front. Offered for any worktree this
/// window does not show (Ruling 12); off, with Open Worktree's reason, for a missing one.
@Suite struct WorktreeOpenInNewWindowWordingTests {
    @Test func theTitle() {
        #expect(WorktreeWording.openInNewWindowTitle == "Open in New Window")
    }

    /// Ruling 12: wherever Open Worktree is offered for a worktree this window does not show —
    /// the main worktree included, the natural thing to open beside a linked one.
    @Test func offeredForAnyWorktreeThisWindowDoesNotShow() {
        #expect(WorktreeWording.offersOpenInNewWindow(WorktreeMenuTests.feat, isOpenHere: false))
        #expect(WorktreeWording.offersOpenInNewWindow(WorktreeMenuTests.gone, isOpenHere: false))
        #expect(WorktreeWording.offersOpenInNewWindow(WorktreeMenuTests.main, isOpenHere: false))
        #expect(!WorktreeWording.offersOpenInNewWindow(WorktreeMenuTests.feat, isOpenHere: true))
        #expect(!WorktreeWording.offersOpenInNewWindow(WorktreeMenuTests.main, isOpenHere: true))
    }

    @Test func offForAMissingWorktreeWithOpenWorktreesReason() {
        #expect(WorktreeWording.openInNewWindowBlocked(WorktreeMenuTests.feat) == nil)
        #expect(
            WorktreeWording.openInNewWindowBlocked(WorktreeMenuTests.gone)
                == WorktreeWording.openBlocked(WorktreeMenuTests.gone, isOpenHere: false))
        #expect(WorktreeWording.openInNewWindowBlocked(WorktreeMenuTests.gone) != nil)
    }
}

/// The same, on real repositories: a main repository with a linked worktree (`git worktree add`),
/// a scratch registry whose new windows are recorded (`OpenRoutingTests.launchedRegistry`).
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct WorktreeOpenInNewWindowTests {
    @Test(.timeLimit(.minutes(10))) func openInNewWindowRoutesAsAWorktreeOpen() async throws {
        let repo = try ScratchRepo("main")
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let linked = repo.directory.appending(path: "wt-feat")
        _ = try repo.git("worktree", "add", "-b", "feat", linked.path)
        let (test, recorder) = OpenRoutingTests.launchedRegistry()
        defer { test.remove() }
        let here = await test.opened(repo)
        let feat = try #require(here.worktrees.first { !$0.isMain })
        let main = try #require(here.worktrees.first { $0.isMain })

        #expect(WorktreeWording.offersOpenInNewWindow(feat, isOpenHere: here.isOpenHere(feat)))
        #expect(!WorktreeWording.offersOpenInNewWindow(main, isOpenHere: here.isOpenHere(main)), "this window's own")

        // A window of its own; this window keeps its repository (Open Worktree would switch it).
        #expect(here.openWorktreeInNewWindow(feat, in: test.registry) == .newWindow(RepositoryWindow(url: linked)))
        #expect(recorder.asked == [RepositoryWindow(url: linked)])
        #expect(here.root.map(RepositoryWindow.init(url:)) == RepositoryWindow(url: repo.url))

        // Shown in another window: that one comes to the front, and no window is made.
        let there = test.registry.makeStore()
        await open(there, linked)
        #expect(here.openWorktreeInNewWindow(feat, in: test.registry) == .front(there))
        #expect(recorder.asked.count == 1)

        // A Worktree value whose folder is gone: refused with the reason, nothing routed.
        let gone = Worktree(
            path: repo.directory.appending(path: "wt-gone").path, head: feat.head, branch: "refs/heads/gone",
            isMain: false, isBare: false, lock: nil, missingReason: "gitdir file points to non-existent location",
            operationBranches: [])
        #expect(here.openWorktreeInNewWindow(gone, in: test.registry) == nil)
        #expect(here.lastError == WorktreeWording.openInNewWindowBlocked(gone))
        #expect(recorder.asked.count == 1)
    }
}

/// Ruling 11: Open Worktree — the row's menu, its double-click, the add notice's Open — is routed
/// too (`.worktreeHere`): a worktree another window already shows brings that window to the front
/// and this window keeps its repository (two stores on one worktree would be two watchers and two
/// write lanes on one index); otherwise this window switches to it, as before.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct WorktreeOpenHereTests {
    @Test(.timeLimit(.minutes(10))) func openWorktreeFrontsTheWindowShowingItAndOtherwiseSwitchesHere() async throws {
        let repo = try ScratchRepo("main")
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let linked = repo.directory.appending(path: "wt-feat")
        _ = try repo.git("worktree", "add", "-b", "feat", linked.path)
        let (test, recorder) = OpenRoutingTests.launchedRegistry()
        defer { test.remove() }
        let here = await test.opened(repo)
        let there = test.registry.makeStore()
        await open(there, linked)
        let feat = try #require(here.worktrees.first { !$0.isMain })

        // Shown in another window: that one comes to the front; nothing changes here.
        #expect(here.openWorktree(feat) == .front(there))
        #expect(here.root.map(RepositoryWindow.init(url:)) == RepositoryWindow(url: repo.url))
        #expect(recorder.asked.isEmpty)

        // Shown nowhere else: this window switches to it, as Open Worktree always did.
        test.registry.windowClosed(there)
        #expect(here.openWorktree(feat) == .useFront(here))
        await waitUntilIdle(here)
        #expect(here.root.map(RepositoryWindow.init(url:)) == RepositoryWindow(url: linked))
        #expect(recorder.asked.isEmpty, "no window is made for a switch here")
    }

    /// The add notice's Open goes the same way (`openAddedWorktree` → `openWorktree`).
    @Test(.timeLimit(.minutes(10))) func theAddNoticesOpenFrontsTheWindowShowingIt() async throws {
        let repo = try ScratchRepo("main")
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let linked = repo.directory.appending(path: "wt-feat")
        _ = try repo.git("worktree", "add", "-b", "feat", linked.path)
        let (test, _) = OpenRoutingTests.launchedRegistry()
        defer { test.remove() }
        let here = await test.opened(repo)
        let there = test.registry.makeStore()
        await open(there, linked)
        let feat = try #require(here.worktrees.first { !$0.isMain })

        here.perform(.openWorktree(feat.path))
        #expect(here.root.map(RepositoryWindow.init(url:)) == RepositoryWindow(url: repo.url))
        #expect(there.root.map(RepositoryWindow.init(url:)) == RepositoryWindow(url: linked))
    }

    /// A store made outside a registry (`makeTestStore`) has nowhere to route: it switches itself,
    /// the fallback.
    @Test(.timeLimit(.minutes(10))) func aStoreWithNoRegistrySwitchesItself() async throws {
        let repo = try ScratchRepo("main")
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let linked = repo.directory.appending(path: "wt-feat")
        _ = try repo.git("worktree", "add", "-b", "feat", linked.path)
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let feat = try #require(store.worktrees.first { !$0.isMain })

        #expect(store.openWorktree(feat) == .useFront(store))
        await waitUntilIdle(store)
        #expect(store.root.map(RepositoryWindow.init(url:)) == RepositoryWindow(url: linked))
    }
}
