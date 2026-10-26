import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// B4 item 2 on real git: the notices that hold the only way back stay (`keep`), a staged revert
/// is a warning, and the two refusals that mean "look again" (`headMoved`, `planChanged`) offer
/// Ask Again, which plans the action again and puts its sheet back up.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct StayingNoticeFlowTests {

    /// `main`: first, second (a.txt). `feature`, from first: one commit (f.txt). HEAD on `main`.
    static func repository() throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "one\n", "first")
        try repo.git("switch", "-c", "feature")
        try repo.commit("f.txt", "f\n", "feature work")
        try repo.git("switch", "main")
        try repo.commit("a.txt", "two\n", "second")
        return repo
    }

    // MARK: - Kept notices

    @Test(.timeLimit(.minutes(10))) func aRebasesUndoNoticeStays() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        try repo.git("switch", "feature")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.requestRebaseOnto("refs/heads/main")
        await waitUntil("the plan's sheet") { store.activeSheet != nil }
        guard case .rebaseOnto(let plan) = try #require(store.activeSheet) else {
            Issue.record("not the rebase sheet: \(String(describing: store.activeSheet))")
            return
        }
        store.confirmRebaseOnto(plan)
        await waitUntilIdle(store)

        let sticky = try #require(store.stickyNotice)
        #expect(sticky.text.hasPrefix("Rebased "))
        #expect(sticky.text.contains("to undo: git reset --keep \(plan.head)"))
        #expect(sticky.keep && sticky.tone == .done)
        #expect(store.notice == nil)
    }

    /// The control: a rebase that only fast-forwards has nothing to undo, and fades.
    @Test(.timeLimit(.minutes(10))) func aFastForwardRebaseFades() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        try repo.git("switch", "-c", "behind", "main~1")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.requestRebaseOnto("refs/heads/main")
        await waitUntil("the plan's sheet") { store.activeSheet != nil }
        guard case .rebaseOnto(let plan) = try #require(store.activeSheet) else {
            Issue.record("not the rebase sheet: \(String(describing: store.activeSheet))")
            return
        }
        store.confirmRebaseOnto(plan)
        await waitUntilIdle(store)

        #expect(store.notice?.text.hasPrefix("Fast-forwarded ") == true)
        #expect(store.stickyNotice == nil)
    }

    @Test(.timeLimit(.minutes(10))) func aCherryPicksUndoNoticeStays() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.requestHistoryAction(.cherryPick, shas: [store.featureTip])
        await waitUntil("the plan's sheet") { store.activeSheet != nil }
        guard case .historyAction(let plan) = try #require(store.activeSheet) else {
            Issue.record("not the plan's sheet: \(String(describing: store.activeSheet))")
            return
        }
        store.confirmHistoryAction(plan)
        await waitUntilIdle(store)

        let sticky = try #require(store.stickyNotice)
        #expect(sticky.text.hasPrefix("Cherry-picked 1 commit onto "))
        #expect(sticky.text.hasSuffix("to undo: git reset --keep \(plan.head)"))
        #expect(sticky.keep && sticky.tone == .done)
        #expect(store.notice == nil)
    }

    @Test(.timeLimit(.minutes(10))) func aRevertLeftStagedIsAWarning() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        let hook = repo.url.appending(path: ".git/hooks/prepare-commit-msg")
        try "#!/bin/sh\necho 'refused by the test'\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.requestHistoryAction(.revert, shas: [store.mainTip])
        await waitUntil("the plan's sheet") { store.activeSheet != nil }
        guard case .historyAction(let plan) = try #require(store.activeSheet) else {
            Issue.record("not the plan's sheet: \(String(describing: store.activeSheet))")
            return
        }
        store.confirmHistoryAction(plan)
        await waitUntilIdle(store)

        let sticky = try #require(store.stickyNotice)
        #expect(sticky.tone == .warning)
        #expect(store.stagedRevertNotice == sticky)
    }

    @Test(.timeLimit(.minutes(10))) func aForceDeletesRecreateNoticeStays() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let tip = store.featureTip

        store.requestDelete("feature")
        await waitUntil("the unmerged warning") { store.activeSheet != nil }
        guard case .deleteUnmerged = try #require(store.activeSheet) else {
            Issue.record("not the unmerged warning: \(String(describing: store.activeSheet))")
            return
        }
        store.confirmForceDelete("feature")
        await waitUntilIdle(store)

        let sticky = try #require(store.stickyNotice)
        #expect(sticky.text == "Deleted \"feature\". Recreate it with: git branch feature \(tip)")
        #expect(sticky.keep && sticky.tone == .done)
        #expect(store.notice == nil)
    }

    @Test(.timeLimit(.minutes(10))) func commitsLeftBehindKeepTheirRecoverNotice() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        try repo.git("switch", "--detach", "main")
        try repo.commit("d.txt", "d\n", "detached work")
        let detached = try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.switchTo(branch: "main")
        await waitUntil("the leave-detached warning") { store.activeSheet != nil }
        guard case .leaveDetached = try #require(store.activeSheet) else {
            Issue.record("not the leave-detached warning: \(String(describing: store.activeSheet))")
            return
        }
        store.confirmLeaveDetached()
        await waitUntilIdle(store)

        let sticky = try #require(store.stickyNotice)
        #expect(sticky.text.hasSuffix("Recover it with: git branch <name> \(detached)"))
        #expect(sticky.keep && sticky.tone == .done)
        #expect(store.notice == nil)
    }

    /// The control: the same ending (`perform`'s `.acted`) with nothing left behind — a merge —
    /// fades.
    @Test(.timeLimit(.minutes(10))) func anEndingThatLeavesNothingBehindFades() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.merge("feature", mode: .fastForwardIfPossible)
        await waitUntilIdle(store)

        #expect(store.notice == Notice(text: "Merged \"feature\"."))
        #expect(store.stickyNotice == nil)
    }

    // MARK: - Ask Again

    @Test(.timeLimit(.minutes(10))) func aRebaseWhosePlanChangedOffersAskAgain() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        try repo.git("switch", "feature")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        store.requestRebaseOnto("refs/heads/main")
        await waitUntil("the plan's sheet") { store.activeSheet != nil }
        guard case .rebaseOnto(let plan) = try #require(store.activeSheet) else {
            Issue.record("not the rebase sheet: \(String(describing: store.activeSheet))")
            return
        }
        backend.fail(.rebaseWithPlan, with: HistoryRefusal.planChanged)
        store.confirmRebaseOnto(plan)
        await waitUntilIdle(store)

        #expect(store.lastError == HistoryWording.rebaseRefusal(.planChanged, target: "refs/heads/main"))
        #expect(store.offeredAskAgain == .rebaseOnto("refs/heads/main"))
        #expect(HistoryWording.askAgain == "Ask Again")

        store.askAgain()
        await waitUntil("the sheet again") { store.activeSheet != nil }
        guard case .rebaseOnto(let again) = try #require(store.activeSheet) else {
            Issue.record("not the rebase sheet: \(String(describing: store.activeSheet))")
            return
        }
        #expect(again.targetName == "refs/heads/main")
        #expect(store.offeredAskAgain == nil)
    }

    @Test(.timeLimit(.minutes(10))) func aCherryPickWhoseHeadMovedOffersAskAgain() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        let sha = store.featureTip

        store.requestHistoryAction(.cherryPick, shas: [sha])
        await waitUntil("the plan's sheet") { store.activeSheet != nil }
        guard case .historyAction(let plan) = try #require(store.activeSheet) else {
            Issue.record("not the plan's sheet: \(String(describing: store.activeSheet))")
            return
        }
        backend.fail(.run, with: HistoryRefusal.headMoved)
        store.confirmHistoryAction(plan)
        await waitUntilIdle(store)

        #expect(store.lastError == HistoryWording.refusal(.headMoved, action: .cherryPick, count: 1))
        #expect(store.offeredAskAgain == .history(.cherryPick, [sha]))

        store.askAgain()
        await waitUntil("the sheet again") { store.activeSheet != nil }
        guard case .historyAction(let again) = try #require(store.activeSheet) else {
            Issue.record("not the plan's sheet: \(String(describing: store.activeSheet))")
            return
        }
        #expect(again.commits.map(\.sha) == [sha])
    }

    /// The control: another refusal offers no Ask Again, and dismissing an offered one takes the
    /// offer with it.
    @Test(.timeLimit(.minutes(10))) func anotherRefusalOffersNoAskAgain() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        try repo.git("switch", "feature")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        store.requestRebaseOnto("refs/heads/main")
        await waitUntil("the plan's sheet") { store.activeSheet != nil }
        guard case .rebaseOnto(let plan) = try #require(store.activeSheet) else {
            Issue.record("not the rebase sheet: \(String(describing: store.activeSheet))")
            return
        }
        backend.fail(.rebaseWithPlan, with: HistoryRefusal.unbornHead)
        store.confirmRebaseOnto(plan)
        await waitUntilIdle(store)
        #expect(store.lastError != nil)
        #expect(store.offeredAskAgain == nil)

        store.dismissError()
        store.requestRebaseOnto("refs/heads/main")
        await waitUntil("the plan's sheet") { store.activeSheet != nil }
        guard case .rebaseOnto(let second) = try #require(store.activeSheet) else {
            Issue.record("not the rebase sheet: \(String(describing: store.activeSheet))")
            return
        }
        backend.fail(.rebaseWithPlan, with: HistoryRefusal.planChanged)
        store.confirmRebaseOnto(second)
        await waitUntilIdle(store)
        #expect(store.offeredAskAgain != nil)
        store.dismissError()
        #expect(store.offeredAskAgain == nil)
    }
}
