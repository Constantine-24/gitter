import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// E3 Task 6 (spec Structure tidy-ups 5): every request whose sheet writes refuses while a change
/// runs (`isMutating`) — it leaves `activeSheet` as it was and says `changeRunningReason`, in the
/// banner and in the `…BlockedReason` the menus show — and opens its sheet once the change has
/// ended. The change is a commit held mid-run on a `TestBackend`; each case's after-release half
/// is its control: the very request that was refused does open its sheet, so the assertion can see
/// one. Compare Branches, a read, stays open during the change.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct RequestsDuringChangeTests {

    /// One request, the reason its menu shows, and the sheet it opens when nothing runs.
    struct Case: CustomTestStringConvertible, Sendable {
        let name: String
        let request: @MainActor @Sendable (RepositoryStore) -> Void
        let reason: @MainActor @Sendable (RepositoryStore) -> String?
        let opens: @MainActor @Sendable (BranchSheet) -> Bool
        var testDescription: String { name }
    }

    nonisolated static let cases: [Case] = [
        Case(
            name: "New Branch", request: { $0.requestNewBranch() }, reason: { $0.changeRunningBlockedReason },
            opens: { if case .newBranch = $0 { true } else { false } }),
        Case(
            name: "Rename", request: { $0.requestRename("feature") }, reason: { $0.changeRunningBlockedReason },
            opens: { if case .rename = $0 { true } else { false } }),
        Case(
            name: "Merge", request: { $0.requestMerge("feature") },
            reason: { $0.mergeBlockedReason(for: "feature") },
            opens: { if case .merge = $0 { true } else { false } }),
        Case(
            name: "New Tag", request: { store in store.headSha.map { store.requestNewTag(at: $0) } },
            reason: { $0.changeRunningBlockedReason },
            opens: { if case .newTag = $0 { true } else { false } }),
        Case(
            name: "Delete Tag", request: { store in store.tag(named: "v1").map { store.requestDeleteTag($0) } },
            reason: { store in store.tag(named: "v1").flatMap { store.deleteTagBlockedReason($0) } },
            opens: { if case .deleteTag = $0 { true } else { false } }),
        Case(
            name: "Add Worktree", request: { $0.requestAddWorktree(branch: nil) },
            reason: { $0.addWorktreeBlockedReason },
            opens: { if case .addWorktree = $0 { true } else { false } }),
        Case(
            name: "Add Worktree for a branch", request: { $0.requestAddWorktree(branch: "feature") },
            reason: { $0.newWorktreeBlockedReason("feature") },
            opens: { if case .addWorktree = $0 { true } else { false } }),
        Case(
            name: "Remove Worktree",
            request: { store in store.worktrees.first { !$0.isMain && !$0.isMissing }.map { store.requestRemoveWorktree($0) } },
            reason: { store in store.worktrees.first { !$0.isMain && !$0.isMissing }.flatMap { store.removeWorktreeBlockedReason($0) } },
            opens: { if case .checkingWorktreeRemoval = $0 { true } else { false } }),
        Case(
            name: "Remove All Missing", request: { $0.requestRemoveAllMissing() },
            reason: { $0.removeAllMissingBlockedReason },
            opens: { if case .checkingWorktreeRemoval = $0 { true } else { false } }),
        Case(
            name: "Delete Branch", request: { $0.requestDelete("feature") },
            reason: { $0.deleteBlockedReason(for: "feature") },
            opens: { if case .deleteUnmerged = $0 { true } else { false } }),
        Case(
            name: "Cherry-Pick",
            request: { store in store.requestHistoryAction(.cherryPick, shas: [store.featureTip]) },
            reason: { store in store.historyBlockedReason(for: [store.featureTip]) },
            opens: { if case .historyAction = $0 { true } else { false } }),
        Case(
            name: "Revert",
            request: { store in store.requestHistoryAction(.revert, shas: [store.mainTip]) },
            reason: { store in store.historyBlockedReason(for: [store.mainTip]) },
            opens: { if case .historyAction = $0 { true } else { false } }),
        Case(
            name: "Rebase Onto a commit", request: { store in store.requestRebaseOnto(store.featureTip) },
            reason: { store in store.rebaseOntoCommitBlockedReason([store.featureTip]) },
            opens: { if case .rebaseOnto = $0 { true } else { false } }),
        Case(
            name: "Rebase Onto", request: { $0.requestRebaseOnto("refs/heads/feature") },
            reason: { $0.rebaseOntoBranchBlockedReason("feature") },
            opens: { if case .rebaseOnto = $0 { true } else { false } }),
    ]

    /// main (two commits), `feature` one commit ahead of the first, the tag `v1`, a linked
    /// worktree `wt-live` and one whose folder is gone, `wt-gone`.
    static func repository() throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "one\n", "first")
        try repo.git("switch", "-c", "feature")
        try repo.commit("f.txt", "f\n", "feature work")
        try repo.git("switch", "main")
        try repo.commit("a.txt", "two\n", "second")
        try repo.git("tag", "v1")
        try repo.git("worktree", "add", "-b", "live", repo.directory.appending(path: "wt-live").path)
        try repo.git("worktree", "add", "-b", "gone", repo.directory.appending(path: "wt-gone").path)
        try FileManager.default.removeItem(at: repo.directory.appending(path: "wt-gone"))
        return repo
    }

    /// A store on `repo` with a commit (an amend of the tip, so the working copy stays clean for
    /// the plans) held mid-run.
    static func storeWithAHeldCommit(
        _ repo: ScratchRepo
    ) async -> (store: RepositoryStore, backend: TestBackend, gate: StuckCall, cleanup: () -> Void) {
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        let gate = backend.hold(.commit)
        store.draft.amend = true
        store.draft.subject = "second"
        store.commit()
        await waitUntil("the commit parked") { gate.waiting }
        return (store, backend, gate, cleanup)
    }

    @Test(.timeLimit(.minutes(10)), arguments: cases) func aRequestDuringAChangeLeavesTheSheetAlone(_ test: Case) async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        let (store, backend, gate, cleanup) = await Self.storeWithAHeldCommit(repo)
        defer { cleanup() }
        defer { backend.releaseAll() }
        #expect(store.isMutating)
        #expect(store.activeSheet == nil)

        test.request(store)
        // An open that went through anyway comes a moment later (a plan, a read): give it that.
        try await Task.sleep(for: .milliseconds(150))

        #expect(store.activeSheet == nil, "\(test.name) opened its sheet over a running change")
        #expect(test.reason(store) == RepositoryStore.changeRunningReason)
        #expect(store.lastError == RepositoryStore.changeRunningReason)

        // The control: released, the same request opens its sheet.
        gate.release()
        await waitUntilIdle(store)
        store.dismissError()
        #expect(test.reason(store) == nil)
        test.request(store)
        await waitUntil("\(test.name) opening its sheet") { store.activeSheet != nil }
        let sheet = try #require(store.activeSheet)
        #expect(test.opens(sheet), "\(test.name) opened \(sheet)")
    }

    /// Abort needs an operation in progress that a held commit would end, so the change held is a
    /// stage: a merge stopped before its commit, one more file staged mid-run.
    @Test(.timeLimit(.minutes(10))) func abortDuringAChangeLeavesTheSheetAlone() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.commit("b.txt", "b\n", "b")
        try repo.git("switch", "-c", "other")
        try repo.commit("o.txt", "o\n", "other work")
        try repo.git("switch", "main")
        try repo.git("merge", "--no-commit", "--no-ff", "other")
        try repo.write("b.txt", "changed\n")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        defer { backend.releaseAll() }
        #expect(store.operationInProgress == .merge)
        let file = try #require(store.snapshot?.status.files.first { $0.path == "b.txt" })
        let gate = backend.hold(.stage)
        store.stage(file)
        await waitUntil("the stage parked") { gate.waiting }
        #expect(store.isMutating)

        store.requestAbort()
        try await Task.sleep(for: .milliseconds(150))

        #expect(store.activeSheet == nil)
        #expect(store.abortState.reason == RepositoryStore.changeRunningReason)
        #expect(store.lastError == RepositoryStore.changeRunningReason)

        gate.release()
        await waitUntilIdle(store)
        store.dismissError()
        #expect(store.abortState == .enabled)
        store.requestAbort()
        #expect(store.activeSheet == .abort(.merge))
    }

    @Test(.timeLimit(.minutes(10))) func compareBranchesStaysOpenDuringAChange() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        let (store, backend, gate, cleanup) = await Self.storeWithAHeldCommit(repo)
        defer { cleanup() }
        defer { backend.releaseAll() }
        #expect(store.isMutating)

        store.requestCompareBranches(a: nil, b: nil)

        guard case .compareBranches = store.activeSheet else {
            Issue.record("Compare Branches did not open during the change: \(String(describing: store.activeSheet))")
            gate.release()
            await waitUntilIdle(store)
            return
        }
        #expect(store.compareBranchesBlockedReason == nil)
        gate.release()
        await waitUntilIdle(store)
    }

    /// The refusal is a sticky banner and it stays when the change ends (the same as every
    /// request that was gated before; BACKLOG): what is on screen after the release is the
    /// sentence, until it is dismissed.
    @Test(.timeLimit(.minutes(10))) func theRefusalBannerStaysAfterTheChangeEnds() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        let (store, backend, gate, cleanup) = await Self.storeWithAHeldCommit(repo)
        defer { cleanup() }
        defer { backend.releaseAll() }
        store.requestNewBranch()
        #expect(store.lastError == RepositoryStore.changeRunningReason)

        gate.release()
        await waitUntilIdle(store)

        #expect(!store.isMutating)
        #expect(store.lastError == RepositoryStore.changeRunningReason)
    }

    /// The remote branch menu's Rebase item reads this: off while a change runs, with the same
    /// sentence (the name need not exist; the reason does not look it up).
    @Test(.timeLimit(.minutes(10))) func aRemoteBranchRebaseMenuItemIsOffDuringAChange() async throws {
        let repo = try Self.repository()
        defer { repo.remove() }
        let (store, backend, gate, cleanup) = await Self.storeWithAHeldCommit(repo)
        defer { cleanup() }
        defer { backend.releaseAll() }
        #expect(store.rebaseOntoRemoteBranchBlockedReason == RepositoryStore.changeRunningReason)

        gate.release()
        await waitUntilIdle(store)
        #expect(store.rebaseOntoRemoteBranchBlockedReason == nil)
    }
}

extension RepositoryStore {
    /// The full id of the commit HEAD is on, which a revert can undo (the feature tip is not in
    /// main's history).
    @MainActor var mainTip: String { headSha ?? "" }

    /// The full id of `feature`'s tip in the snapshot, for the history cases.
    @MainActor var featureTip: String {
        localBranches.first { $0.name == "feature" }?.sha ?? ""
    }
}
