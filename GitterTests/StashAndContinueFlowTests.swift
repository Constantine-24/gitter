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

    // MARK: - A retried pull keeps its answer (B4 Task 4)

    /// `main` tracking `origin/main` (a local bare repository), whose new commit changing `a.txt`
    /// has not been fetched yet, and an uncommitted edit of `a.txt`. `diverged`: `main` also has
    /// a commit of its own, on `b.txt`, so the pull asks Merge or Rebase; otherwise it would
    /// fast-forward. Returns the remote commit's sha.
    private static func repoBehindOrigin(diverged: Bool) throws -> (ScratchRepo, remoteSha: String) {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "base\n", "base")
        let bare = try repo.makeBareRemote()
        try repo.git("remote", "add", "origin", bare.path)
        try repo.git("push", "-u", "origin", "main")
        try repo.commit("a.txt", "remote\n", "remote change")
        let sha = try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.git("push", "origin", "main")
        try repo.git("reset", "--hard", "HEAD~1")
        // Unfetched: the pull's own fetch is what brings the commit in.
        try repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
        if diverged { try repo.commit("b.txt", "local\n", "local change") }
        try repo.write("a.txt", "local edit\n")
        return (repo, sha)
    }

    /// A store on `repo` through a `TestBackend` whose `fetch` hook counts every fetch (Ruling 2;
    /// `Recorded` is a `Mutex<Int>` that a tuple can carry).
    private static func countingStore(_ repo: ScratchRepo) async
        -> (RepositoryStore, TestBackend, fetches: Recorded<Int>, cleanup: () -> Void)
    {
        let backend = TestBackend()
        let fetches = Recorded(0)
        backend.hook(.fetch) { fetches.update { $0 += 1 } }
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        return (store, backend, fetches, cleanup)
    }

    /// The pull, up to its Merge-or-Rebase sheet: one fetch, and the question about
    /// `origin/main`.
    private static func pullUpToTheSheet(
        _ store: RepositoryStore, fetches: Recorded<Int>,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        store.pull()
        await waitUntilIdle(store)
        #expect(
            store.activeSheet == .pullDiverged(ahead: 1, behind: 1, upstream: "origin/main"),
            sourceLocation: sourceLocation)
        #expect(fetches.value == 1, sourceLocation: sourceLocation)
    }

    private static func parents(of revision: String, in repo: ScratchRepo) throws -> Int {
        try repo.git("rev-list", "--parents", "-n", "1", revision)
            .split(separator: " ").count - 1
    }

    /// Rebase answered, refused over the edit, then stashed: the retry rebases without asking
    /// again and without a second fetch, and Pop Stash stays the sticky notice beside the
    /// rebase's own (RF1).
    @Test(.timeLimit(.minutes(10))) func aRetriedPullKeepsItsRebaseAnswer() async throws {
        let (repo, remoteSha) = try Self.repoBehindOrigin(diverged: true)
        defer { repo.remove() }
        let (store, _, fetches, cleanup) = await Self.countingStore(repo)
        defer { cleanup() }

        await Self.pullUpToTheSheet(store, fetches: fetches)
        try await Self.refusedThenStashedAndContinued(
            store, expected: .pull(branch: "main", upstream: "origin/main", answer: .rebase), stashesBefore: 0
        ) { store.confirmPull(.rebase) }

        #expect(store.activeSheet == nil, "the answer was kept, not asked for again")
        #expect(store.lastError == nil)
        try repo.git("merge-base", "--is-ancestor", remoteSha, "HEAD")
        #expect(try Self.parents(of: "HEAD", in: repo) == 1, "rebased, not merged")
        #expect(try repo.git("log", "-1", "--format=%s").hasPrefix("local change"))
        #expect(store.notice?.text == RemoteWording.rebaseNotice(.rebased, branch: "main", upstream: "origin/main"))
        #expect(fetches.value == 1, "the retry ran no fetch")
        #expect(store.defaults.string(forKey: RepositoryStore.pullModeKey) == PullMode.rebase.rawValue)
        #expect(store.stickyNotice?.actions.count == 1, "Pop Stash")
    }

    /// Merge answered: the same, ending with a merge commit.
    @Test(.timeLimit(.minutes(10))) func aRetriedPullKeepsItsMergeAnswer() async throws {
        let (repo, remoteSha) = try Self.repoBehindOrigin(diverged: true)
        defer { repo.remove() }
        let (store, _, fetches, cleanup) = await Self.countingStore(repo)
        defer { cleanup() }

        await Self.pullUpToTheSheet(store, fetches: fetches)
        try await Self.refusedThenStashedAndContinued(
            store, expected: .pull(branch: "main", upstream: "origin/main", answer: .merge), stashesBefore: 0
        ) { store.confirmPull(.merge) }

        #expect(store.activeSheet == nil, "the answer was kept, not asked for again")
        #expect(store.lastError == nil)
        #expect(try Self.parents(of: "HEAD", in: repo) == 2, "a merge commit")
        try repo.git("merge-base", "--is-ancestor", remoteSha, "HEAD")
        #expect(fetches.value == 1, "the retry ran no fetch")
        #expect(store.defaults.string(forKey: RepositoryStore.pullModeKey) == PullMode.merge.rawValue)
    }

    /// Control: a pull refused at its fast-forward asked nothing, and its retry fast-forwards
    /// with no sheet, no fetch and no pull mode remembered.
    @Test(.timeLimit(.minutes(10))) func aRetriedFastForwardAsksNothing() async throws {
        let (repo, remoteSha) = try Self.repoBehindOrigin(diverged: false)
        defer { repo.remove() }
        let (store, _, fetches, cleanup) = await Self.countingStore(repo)
        defer { cleanup() }

        try await Self.refusedThenStashedAndContinued(
            store, expected: .pull(branch: "main", upstream: "origin/main", answer: nil), stashesBefore: 0
        ) { store.pull() }

        #expect(store.activeSheet == nil)
        #expect(store.lastError == nil)
        #expect(store.headSha == remoteSha)
        #expect(fetches.value == 1, "the retry ran no fetch")
        #expect(store.defaults.string(forKey: RepositoryStore.pullModeKey) == nil)
    }

    /// RF4: the branch's upstream changed between the answer and the retry. The answer was about
    /// `origin/main`, so the retry asks again, about the new upstream.
    @Test(.timeLimit(.minutes(10))) func aRetriedPullAsksAgainWhenTheUpstreamChanged() async throws {
        let (repo, remoteSha) = try Self.repoBehindOrigin(diverged: true)
        defer { repo.remove() }
        let (store, _, fetches, cleanup) = await Self.countingStore(repo)
        defer { cleanup() }

        await Self.pullUpToTheSheet(store, fetches: fetches)
        store.confirmPull(.rebase)
        await waitUntilIdle(store)
        #expect(store.offeredStashAndContinue?.action == .pull(branch: "main", upstream: "origin/main", answer: .rebase))

        try repo.git("branch", "other", remoteSha)
        try repo.git("branch", "--set-upstream-to=other", "main")
        await store.refresh()
        await waitUntilIdle(store)
        let head = try #require(store.headSha)
        store.stashAndContinue()
        await waitUntilIdle(store)

        #expect(store.stashes.count == 1)
        #expect(store.activeSheet == .pullDiverged(ahead: 1, behind: 1, upstream: "other"))
        // Rebasing onto `other` would also leave one parent and the same subject: the sha is
        // what proves nothing ran (Ruling 11).
        #expect(store.headSha == head, "nothing ran")
        #expect(try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines) == head)
        #expect(throws: (any Error).self) { try repo.git("merge-base", "--is-ancestor", remoteSha, "HEAD") }
        #expect(fetches.value == 1)
    }

    /// Ruling 9: the answer was about `main`. A terminal switching to another branch that tracks
    /// the same upstream, and is diverged from it too, gets the question, not `main`'s answer.
    @Test(.timeLimit(.minutes(10))) func aRetriedPullAsksAgainOnAnotherBranch() async throws {
        let (repo, remoteSha) = try Self.repoBehindOrigin(diverged: true)
        defer { repo.remove() }
        let (store, _, fetches, cleanup) = await Self.countingStore(repo)
        defer { cleanup() }

        await Self.pullUpToTheSheet(store, fetches: fetches)
        store.confirmPull(.rebase)
        await waitUntilIdle(store)
        #expect(store.offeredStashAndContinue?.action == .pull(branch: "main", upstream: "origin/main", answer: .rebase))

        // The edit of `a.txt` comes along; only `c.txt` is committed.
        try repo.git("switch", "-c", "feature")
        try repo.commit("c.txt", "feature\n", "feature change")
        try repo.git("branch", "--set-upstream-to=origin/main", "feature")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.offeredStashAndContinue != nil, "the offer outlives the reload")
        let head = try #require(store.headSha)
        store.stashAndContinue()
        await waitUntilIdle(store)

        #expect(store.stashes.count == 1)
        #expect(store.currentBranch == "feature")
        #expect(store.activeSheet == .pullDiverged(ahead: 2, behind: 1, upstream: "origin/main"))
        #expect(store.headSha == head, "feature was not rebased")
        #expect(throws: (any Error).self) { try repo.git("merge-base", "--is-ancestor", remoteSha, "HEAD") }
        #expect(fetches.value == 1)
    }

    /// Ruling 10: a retried fast-forward is decided on the stash's reload, and the lane is free
    /// meanwhile, so a fetch can force-move the upstream before the merge runs. The merge must
    /// not become a merge commit nobody asked for: nothing is merged and the banner says why.
    ///
    /// `main` has a commit of its own (`b.txt`) that `origin/main` contains, plus one more on
    /// `a.txt`: a fast-forward, refused over the edit of `a.txt`. As the retry's mutation makes
    /// its first git call, `origin/main` is moved to a commit on `base` that lacks `main`'s.
    @Test(.timeLimit(.minutes(10))) func aRetriedFastForwardThatDivergedMeanwhileMakesNoMergeCommit() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "base\n", "base")
        let base = try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        let bare = try repo.makeBareRemote()
        try repo.git("remote", "add", "origin", bare.path)
        try repo.git("push", "-u", "origin", "main")
        try repo.commit("b.txt", "local\n", "local change")
        try repo.git("push", "origin", "main")
        try repo.commit("a.txt", "remote\n", "remote change")
        try repo.git("push", "origin", "main")
        try repo.git("reset", "--hard", "HEAD~1")
        try repo.git("update-ref", "refs/remotes/origin/main", "HEAD")
        try repo.write("a.txt", "local edit\n")
        let forced = try repo.git("commit-tree", "\(base)^{tree}", "-p", base, "-m", "forced")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        let (store, backend, _, cleanup) = await Self.countingStore(repo)
        defer { cleanup() }
        store.pull()
        await waitUntilIdle(store)
        #expect(store.offeredStashAndContinue?.action == .pull(branch: "main", upstream: "origin/main", answer: nil))
        let head = try #require(store.headSha)

        // A concurrent fetch landing as late as it can: at the retry's first git call after the
        // stash, whichever that is (the re-check, or the merge itself without one).
        let moved = Recorded(false)
        let forceMove: @Sendable () async throws -> Void = {
            guard !moved.exchange(true) else { return }
            try repo.git("update-ref", "refs/remotes/origin/main", forced)
        }
        backend.hook(.commitCount, .before, forceMove)
        backend.hook(.merge, .before, forceMove)
        store.stashAndContinue()
        await waitUntilIdle(store)

        #expect(store.stashes.count == 1)
        #expect(moved.value, "the upstream was moved during the retry")
        #expect(try Self.parents(of: "HEAD", in: repo) == 1, "no merge commit")
        #expect(store.headSha == head, "nothing was merged")
        #expect(store.lastError == RemoteWording.pullNoLongerFastForward("origin/main"))
        #expect(
            RemoteWording.pullNoLongerFastForward("origin/main")
                == "\"origin/main\" and this branch both have new commits now, so nothing was "
                + "merged. Pull again to choose Merge or Rebase.")
        #expect(store.activeSheet == nil)
        #expect(store.stickyNotice?.actions.count == 1, "Pop Stash")
    }

    /// Whether the retried pull's rebase has landed on `remoteSha`, or the store said why not.
    private static func retryEnded(_ store: RepositoryStore, _ repo: ScratchRepo, onto remoteSha: String) -> Bool {
        guard !store.isMutating else { return false }
        if store.lastError != nil { return true }
        guard store.stashes.count == 1 else { return false }
        return (try? repo.git("merge-base", "--is-ancestor", remoteSha, "HEAD")) != nil
            && (try? Self.parents(of: "HEAD", in: repo)) == 1
    }

    /// M4 (BACKLOG "A manual Fetch can pre-empt Stash and Continue's retried pull"): a Fetch
    /// clicked while the stash runs takes the lane, and the retry, which needs only the mutation
    /// slot, still runs while the fetch is held.
    @Test(.timeLimit(.minutes(10))) func aFetchStartedDuringTheStashDoesNotPreemptTheRetry() async throws {
        let (repo, remoteSha) = try Self.repoBehindOrigin(diverged: true)
        defer { repo.remove() }
        let (store, backend, fetches, cleanup) = await Self.countingStore(repo)
        defer { cleanup() }
        defer { await releaseAndSettle([backend], [store]) }

        await Self.pullUpToTheSheet(store, fetches: fetches)
        store.confirmPull(.rebase)
        await waitUntilIdle(store)
        #expect(store.offeredStashAndContinue?.action == .pull(branch: "main", upstream: "origin/main", answer: .rebase))

        let stash = backend.hold(.stashAll)
        store.stashAndContinue()
        #expect(await waitUntil("the stash parked") { stash.waiting })
        let fetch = backend.hold(.fetch)
        store.fetch()
        #expect(await waitUntil("the fetch parked") { fetch.waiting })
        stash.release()
        #expect(await waitUntil("the stash and its retry") { Self.retryEnded(store, repo, onto: remoteSha) })

        #expect(store.lastError == nil)
        try repo.git("merge-base", "--is-ancestor", remoteSha, "HEAD")
        #expect(store.remoteActivity != nil, "the fetch is still held: the retry did not wait for it")
        #expect(store.activeSheet == nil)

        fetch.release()
        await waitUntilIdle(store)
        #expect(store.lastError == nil)
        #expect(store.stickyNotice?.actions.count == 1, "Pop Stash")
        #expect(fetches.value == 2, "the pull's fetch and the manual one, none for the retry")
    }

    /// A pull offer is ready while the lane is busy: refused while a Fetch runs, Stash and
    /// Continue is not turned off by it (the pull's own gate is), and the retry runs under the
    /// held fetch.
    @Test(.timeLimit(.minutes(10))) func aPullOfferIsReadyWhileTheLaneIsBusy() async throws {
        let (repo, remoteSha) = try Self.repoBehindOrigin(diverged: true)
        defer { repo.remove() }
        let (store, backend, fetches, cleanup) = await Self.countingStore(repo)
        defer { cleanup() }
        defer { await releaseAndSettle([backend], [store]) }

        await Self.pullUpToTheSheet(store, fetches: fetches)
        let fetch = backend.hold(.fetch)
        store.fetch()
        #expect(await waitUntil("the fetch parked") { fetch.waiting })
        store.confirmPull(.rebase)
        #expect(await waitUntil("the refusal") { !store.isMutating && store.offeredStashAndContinue != nil })
        #expect(store.offeredStashAndContinue?.action == .pull(branch: "main", upstream: "origin/main", answer: .rebase))

        #expect(store.pullBlockedReason != nil, "the lane is busy")
        #expect(store.stashAndContinueBlockedReason == nil)
        store.stashAndContinue()
        #expect(await waitUntil("the stash and its retry") { Self.retryEnded(store, repo, onto: remoteSha) })

        #expect(store.lastError == nil)
        try repo.git("merge-base", "--is-ancestor", remoteSha, "HEAD")
        #expect(store.remoteActivity != nil, "the fetch is still held")
        fetch.release()
        await waitUntilIdle(store)
        #expect(store.stickyNotice?.actions.count == 1, "Pop Stash")
    }

    // MARK: - A pull offer keeps the pull's other gates (final review I2)

    /// A fast-forward refused over the edit, offering Stash and Continue, then `move` from a
    /// terminal and a reload: the offer is still up, and returns the store.
    private static func pullOfferThen(
        _ repo: ScratchRepo, _ move: () throws -> Void
    ) async throws -> (RepositoryStore, cleanup: () -> Void) {
        let (store, _, _, cleanup) = await Self.countingStore(repo)
        store.pull()
        await waitUntilIdle(store)
        #expect(store.offeredStashAndContinue?.action == .pull(branch: "main", upstream: "origin/main", answer: nil))
        try move()
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.offeredStashAndContinue != nil, "the offer outlives the reload")
        return (store, cleanup)
    }

    /// Stash and Continue for a pull that can no longer start is off with the pull's own reason,
    /// and a stale call files nothing.
    private static func expectBlockedBeforeStashing(
        _ store: RepositoryStore, _ reason: String, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        #expect(store.stashAndContinueBlockedReason == reason, sourceLocation: sourceLocation)
        store.stashAndContinue()
        await waitUntilIdle(store)
        #expect(store.stashes.isEmpty, "no stash filed", sourceLocation: sourceLocation)
        #expect(store.lastError == reason, sourceLocation: sourceLocation)
    }

    /// The helpers' control: with nothing moved the offer is ready, so `expectBlockedBeforeStashing`
    /// records its issues (and the stash it could not prevent is filed).
    @Test(.timeLimit(.minutes(10))) func theBlockedCheckFailsForAPullThatCanStillStart() async throws {
        let (repo, _) = try Self.repoBehindOrigin(diverged: false)
        defer { repo.remove() }
        let (store, cleanup) = try await Self.pullOfferThen(repo) {}
        defer { cleanup() }
        #expect(store.stashAndContinueBlockedReason == nil)

        await withKnownIssue("nothing blocks this pull's retry") {
            await Self.expectBlockedBeforeStashing(store, RemoteWording.detachedPull)
        }
    }

    @Test(.timeLimit(.minutes(10))) func aPullOfferOnADetachedHeadIsBlockedBeforeStashing() async throws {
        let (repo, _) = try Self.repoBehindOrigin(diverged: false)
        defer { repo.remove() }
        let (store, cleanup) = try await Self.pullOfferThen(repo) { try repo.git("checkout", "--detach") }
        defer { cleanup() }
        #expect(store.isDetached)

        await Self.expectBlockedBeforeStashing(store, RemoteWording.detachedPull)
    }

    @Test(.timeLimit(.minutes(10))) func aPullOfferWhoseUpstreamIsGoneIsBlockedBeforeStashing() async throws {
        let (repo, _) = try Self.repoBehindOrigin(diverged: false)
        defer { repo.remove() }
        let (store, cleanup) = try await Self.pullOfferThen(repo) {
            try repo.git("update-ref", "-d", "refs/remotes/origin/main")
        }
        defer { cleanup() }
        let branch = try #require(store.currentBranchRef)
        #expect(branch.tracking == .gone)

        await Self.expectBlockedBeforeStashing(store, RemoteWording.upstreamGone(branch))
    }

    @Test(.timeLimit(.minutes(10))) func aPullOfferWithNoUpstreamIsBlockedBeforeStashing() async throws {
        let (repo, _) = try Self.repoBehindOrigin(diverged: false)
        defer { repo.remove() }
        let (store, cleanup) = try await Self.pullOfferThen(repo) { try repo.git("branch", "--unset-upstream") }
        defer { cleanup() }

        await Self.expectBlockedBeforeStashing(store, RemoteWording.noUpstream("main"))
    }
}
