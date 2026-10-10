import Foundation
import GitCore
import Testing

@testable import Gitter

/// A1's Stash and Continue, on real git (E2 Task 1): a switch refused over a local change makes
/// `perform` offer it (`RefusalWithStashOffer`, held as `offeredStashAndContinue`), and
/// `stashAndContinue()` stashes, puts up the sticky notice with Pop Stash and runs the action
/// again.
@MainActor @Suite struct StashAndContinueFlowTests {

    /// `main` with `a.txt`, an `origin` (a local bare repository) that has `feature` changing
    /// `a.txt`, no local `feature`, and an uncommitted edit of `a.txt`: every action that moves
    /// HEAD to `origin/feature` is refused over it.
    private static func repoWithAFeatureOnOrigin() throws -> (ScratchRepo, featureSha: String) {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "base\n", "base")
        let bare = try repo.makeBareRemote()
        try repo.git("remote", "add", "origin", bare.path)
        try repo.git("push", "origin", "main")
        try repo.git("switch", "-c", "feature")
        try repo.commit("a.txt", "feature\n", "feature change")
        let sha = try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.git("push", "origin", "feature")
        try repo.git("switch", "main")
        try repo.git("branch", "-D", "feature")
        try repo.write("a.txt", "local edit\n")
        return (repo, sha)
    }

    /// Runs `action`, expects the refusal with the offer for `expected`, then Stash and Continue,
    /// and returns once the retry is over.
    private static func refusedThenStashedAndContinued(
        _ store: RepositoryStore, expected: PendingBranchAction, stashesBefore: Int,
        sourceLocation: SourceLocation = #_sourceLocation, _ action: () -> Void
    ) async throws {
        action()
        await waitUntilIdle(store)
        let offer = try #require(store.offeredStashAndContinue, sourceLocation: sourceLocation)
        #expect(offer.action == expected, sourceLocation: sourceLocation)
        #expect(offer.includeUntracked == false, sourceLocation: sourceLocation)
        #expect(store.stashes.count == stashesBefore, sourceLocation: sourceLocation)
        #expect(store.stashAndContinueBlockedReason == nil, sourceLocation: sourceLocation)

        store.stashAndContinue()
        await waitUntilIdle(store)

        #expect(store.stashes.count == stashesBefore + 1, sourceLocation: sourceLocation)
        let filed = try #require(store.stashes.first, sourceLocation: sourceLocation)
        let notice = try #require(store.stickyNotice, sourceLocation: sourceLocation)
        #expect(notice.text == StashWording.continued(stash: filed), sourceLocation: sourceLocation)
        #expect(notice.actions == [.popStash(filed)], sourceLocation: sourceLocation)
        #expect(store.offeredStashAndContinue == nil, sourceLocation: sourceLocation)
    }

    @Test(.timeLimit(.minutes(10))) func trackingARemoteBranchOverALocalChange() async throws {
        let (repo, sha) = try Self.repoWithAFeatureOnOrigin()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        try await Self.refusedThenStashedAndContinued(
            store, expected: .track("origin/feature"), stashesBefore: 0
        ) { store.track(remoteBranch: "origin/feature") }

        #expect(store.currentBranch == "feature")
        #expect(store.headSha == sha)
        #expect(try String(contentsOf: repo.url.appending(path: "a.txt"), encoding: .utf8) == "feature\n")
    }

    @Test(.timeLimit(.minutes(10))) func detachingOverALocalChange() async throws {
        let (repo, sha) = try Self.repoWithAFeatureOnOrigin()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        try await Self.refusedThenStashedAndContinued(
            store, expected: .detach(sha), stashesBefore: 0
        ) { store.detach(at: sha) }

        #expect(store.isDetached)
        #expect(store.headSha == sha)
    }

    @Test(.timeLimit(.minutes(10))) func creatingAndSwitchingOverALocalChange() async throws {
        let (repo, sha) = try Self.repoWithAFeatureOnOrigin()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        try await Self.refusedThenStashedAndContinued(
            store, expected: .createAndSwitch(name: "topic", startPoint: "origin/feature"), stashesBefore: 0
        ) { store.createBranch(named: "topic", startPoint: "origin/feature", switchTo: true) }

        #expect(store.currentBranch == "topic")
        #expect(store.headSha == sha)
    }

    /// Control: a switch no change stands in the way of makes no offer and files no stash, so the
    /// offer above is the refusal's and not something every action leaves behind.
    @Test(.timeLimit(.minutes(10))) func aSwitchWithNothingInTheWayOffersNothing() async throws {
        let (repo, sha) = try Self.repoWithAFeatureOnOrigin()
        defer { repo.remove() }
        try repo.git("restore", "a.txt")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.detach(at: sha)
        await waitUntilIdle(store)

        #expect(store.offeredStashAndContinue == nil)
        #expect(store.stashes.isEmpty)
        #expect(store.isDetached)
    }
}
