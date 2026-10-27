import Foundation
import GitCore
import Testing

@testable import Gitter

/// Which refusals offer Stash and Continue, what the offer stashes and under which message, and
/// the sentences around it. Pure: no repository, no store state beyond a fresh store with none,
/// and nothing touches `UserDefaults`. The store half — stash, retry, the notice — is verified in
/// the harness against real git.
@MainActor @Suite struct StashAndContinueDecisionTests {

    private static func stash(_ message: String, index: Int = 0) -> Stash {
        Stash(
            sha: String(repeating: "c", count: 40), index: index,
            reflogSubject: "On main: \(message)", parents: ["p1", "p2"],
            date: Date(timeIntervalSince1970: 1_800_000_000))
    }

    // MARK: - Offered

    @Test func aTrackedFileInTheWayOffersAStashWithoutUntrackedFiles() {
        let offer = StashAndContinue.offer(
            for: .wouldOverwrite(tracked: ["f"], untracked: []), action: .switchTo("b"))
        #expect(
            offer
                == StashAndContinueOffer(
                    action: .switchTo("b"), includeUntracked: false,
                    message: "Gitter: before switching to b",
                    refusal: .wouldOverwrite(tracked: ["f"], untracked: [])))
    }

    /// The refusal named an untracked file: a stash without `-u` would leave it where it is and
    /// the retry would be refused over it again.
    @Test func anUntrackedFileInTheWayStashesUntrackedFilesToo() {
        let offer = StashAndContinue.offer(
            for: .wouldOverwrite(tracked: [], untracked: ["n"]), action: .switchTo("b"))
        #expect(offer?.includeUntracked == true)
        #expect(offer?.action == .switchTo("b"))
    }

    @Test func bothKindsInTheWayStashUntrackedFilesToo() {
        let offer = StashAndContinue.offer(
            for: .wouldOverwrite(tracked: ["f"], untracked: ["n"]),
            action: .merge("b", .alwaysMergeCommit))
        #expect(offer?.includeUntracked == true)
        #expect(offer?.message == "Gitter: before merging b")
    }

    /// A pull's rebase refuses any tracked change, and never an untracked file (that one arrives
    /// as `.wouldOverwrite(untracked:)` instead, M 12).
    @Test func aDirtyTreeRefusingAPullOffersAStash() {
        let action = PendingBranchAction.pull(branch: "main", upstream: "origin/main", answer: .rebase)
        let offer = StashAndContinue.offer(for: .treeNotClean, action: action)
        #expect(
            offer
                == StashAndContinueOffer(
                    action: action, includeUntracked: false, message: "Gitter: before pulling",
                    refusal: .treeNotClean))
    }

    @Test func aPullsMergeStepRefusedOverAFileOffersAStash() {
        let action = PendingBranchAction.pull(branch: "main", upstream: "origin/main", answer: nil)
        let offer = StashAndContinue.offer(
            for: .wouldOverwrite(tracked: ["f"], untracked: []), action: action)
        #expect(offer?.action == action)
        #expect(offer?.message == "Gitter: before pulling")
    }

    @Test func eachActionNamesItselfInTheMessage() {
        let refusal = BranchOperationError.wouldOverwrite(tracked: ["f"], untracked: [])
        let messages: [(PendingBranchAction, String)] = [
            (.switchTo("feature/x"), "Gitter: before switching to feature/x"),
            (.track("origin/b"), "Gitter: before checking out origin/b"),
            (.detach("v1.0"), "Gitter: before checking out v1.0"),
            (.merge("b", .fastForwardIfPossible), "Gitter: before merging b"),
            (.merge("b", .squash), "Gitter: before merging b"),
            (.createAndSwitch(name: "n", startPoint: "origin/b"), "Gitter: before switching to n"),
            (.pull(branch: "main", upstream: "origin/main", answer: .merge), "Gitter: before pulling"),
            (.pull(branch: "main", upstream: "origin/main", answer: .rebase), "Gitter: before pulling"),
            (.pull(branch: "main", upstream: "origin/main", answer: nil), "Gitter: before pulling"),
        ]
        for (action, message) in messages {
            #expect(StashAndContinue.offer(for: refusal, action: action)?.message == message)
        }
    }

    /// A true merge (or a squash) refused over a staged change, even to a file the merge never
    /// touches: a stash resets the index to HEAD, so the retry passes merge-ort's index check
    /// and the squash's own. The refusal names no file, so no `-u`.
    @Test func aStagedChangeRefusingAMergeOffersAStashWithoutUntrackedFiles() {
        let action = PendingBranchAction.pull(branch: "main", upstream: "origin/main", answer: .merge)
        #expect(
            StashAndContinue.offer(for: .indexNotClean, action: action)
                == StashAndContinueOffer(
                    action: action, includeUntracked: false, message: "Gitter: before pulling",
                    refusal: .indexNotClean))
        #expect(
            StashAndContinue.offer(for: .indexNotClean, action: .merge("b", .squash))
                == StashAndContinueOffer(
                    action: .merge("b", .squash), includeUntracked: false,
                    message: "Gitter: before merging b", refusal: .indexNotClean))
    }

    /// The answer is kept with the offer and named nowhere in the stash's message: whichever it
    /// was, the entry is filed before pulling.
    @Test func aPullsAnswerIsKeptAndTheMessageIsTheSame() {
        for answer: PullMode? in [nil, .merge, .rebase] {
            let action = PendingBranchAction.pull(branch: "main", upstream: "origin/main", answer: answer)
            #expect(StashWording.continueMessage(for: action) == "Gitter: before pulling")
            #expect(StashAndContinue.offer(for: .treeNotClean, action: action)?.action == action)
        }
        #expect(
            PendingBranchAction.pull(branch: "main", upstream: "origin/main", answer: .rebase)
                != .pull(branch: "main", upstream: "origin/main", answer: .merge))
        #expect(
            PendingBranchAction.pull(branch: "main", upstream: "origin/main", answer: .merge)
                != .pull(branch: "main", upstream: "origin/main", answer: nil))
    }

    // MARK: - Not offered

    /// Every other refusal: a stash cannot answer it (a name, a branch, a moved tip, an
    /// operation part-way through — where `stashAll` refuses anyway).
    @Test func noOtherRefusalOffersAStash() {
        let refusals: [BranchOperationError] = [
            .operationInProgress("merging"),
            .invalidName("a..b"),
            .branchExists("b"),
            .cannotDeleteCurrent("main"),
            .branchMoved(
                name: "b", expected: String(repeating: "1", count: 40),
                actual: String(repeating: "2", count: 40)),
            .noSuchBranch("b"),
            .noOperationInProgress,
            .operationMismatch(expected: .merge, actual: .rebase),
        ]
        for refusal in refusals {
            #expect(StashAndContinue.offer(for: refusal, action: .switchTo("b")) == nil)
            #expect(
                StashAndContinue.offer(
                    for: refusal, action: .pull(branch: "main", upstream: "origin/main", answer: .merge))
                    == nil)
        }
    }

    // MARK: - The error that carries it

    /// The banner reads exactly as the refusal did before; the offer rides along.
    @Test func anOfferedRefusalKeepsItsSentenceAndCarriesTheOffer() {
        let failure = BranchActionFailure(
            verb: .switchTo, target: "b", refusal: .wouldOverwrite(tracked: ["f"], untracked: []))
        let error = StashAndContinue.offering(failure, for: .switchTo("b"))
        let carried = error as? RefusalWithStashOffer
        #expect(carried?.offer.action == .switchTo("b"))
        #expect(RepositoryStore.describe(error) == RepositoryStore.describe(failure))
        #expect(RepositoryStore.describe(error).hasPrefix("Can't switch to \"b\": your changes"))
    }

    @Test func aRefusalWithoutAnOfferPassesThroughUnchanged() {
        let failure = BranchActionFailure(
            verb: .switchTo, target: "b", refusal: .operationInProgress("merging"))
        let error = StashAndContinue.offering(failure, for: .switchTo("b"))
        #expect(!(error is RefusalWithStashOffer))
        #expect(error is BranchActionFailure)
    }

    /// git's own words (`GitError`) are never dressed up as a refusal, so never offered either.
    @Test func gitsOwnWordsAreNeverOffered() {
        let error = StashAndContinue.offering(
            GitError.commandFailed(exitCode: 1, stderr: "fatal: something"), for: .switchTo("b"))
        #expect(!(error is RefusalWithStashOffer))
    }

    // MARK: - Wording

    @Test func theNoticeSaysWhereTheChangesAre() {
        #expect(
            StashWording.continued(stash: Self.stash("Gitter: before switching to b"))
                == "Your changes are in stash \"Gitter: before switching to b\".")
    }

    /// The same sentence Stash Changes… says for a filed entry, so the two cannot drift.
    @Test func theNoticeIsStashChangesOwnSentence() {
        let stash = Self.stash("Gitter: before merging b")
        #expect(
            StashWording.continued(stash: stash)
                == StashWording.pushOutcome(
                    .saved(stash), includeUntracked: false, onlySelected: false))
    }

    /// A switch or merge: git refused over files, and a stash that found nothing means they are
    /// gone. Submodules are not mentioned — nothing on this path refuses over one.
    @Test func nothingStashedForASwitchSaysNothingWasTriedAgain() {
        let offer = StashAndContinue.offer(
            for: .wouldOverwrite(tracked: ["f"], untracked: []), action: .switchTo("b"))
        #expect(
            offer.map(StashWording.continueNothingStashed)
                == "Nothing was stashed: there are no changes a stash can hold, so Gitter did "
                + "not try to switch to \"b\" again. If the changes are gone, try again.")
    }

    @Test func nothingStashedForAMergeDoesNotMentionSubmodules() {
        for refusal: BranchOperationError in [
            .wouldOverwrite(tracked: ["f"], untracked: []), .indexNotClean,
        ] {
            let offer = StashAndContinue.offer(for: refusal, action: .merge("b", .alwaysMergeCommit))
            let text = offer.map(StashWording.continueNothingStashed) ?? ""
            #expect(text.hasPrefix("Nothing was stashed:"))
            #expect(!text.contains("submodule"))
        }
    }

    /// The pull's rebase: Gitter's own clean-tree check refuses over a submodule with changes
    /// inside it, which a stash leaves where it is — the one path where that is the likely cause.
    @Test func nothingStashedForAPullsRebaseMentionsSubmodules() {
        let offer = StashAndContinue.offer(
            for: .treeNotClean,
            action: .pull(branch: "main", upstream: "origin/main", answer: .rebase))
        #expect(
            offer.map(StashWording.continueNothingStashed)
                == "Nothing was stashed: there are no changes a stash can hold, so Gitter did "
                + "not try to pull from \"origin/main\" again. If the changes are gone, try "
                + "again; a change inside a submodule has to be committed in the submodule.")
    }

    @Test func savedWithErrorSaysTheChangesMayBeInBothPlaces() {
        let stash = Self.stash("Gitter: before pulling")
        #expect(
            StashWording.continueSavedWithError(
                stash, gitsWords: "error: could not write index\n", trashed: [:],
                action: .pull(branch: "main", upstream: "origin/main", answer: .merge))
                == "Your changes are in stash \"Gitter: before pulling\"; git also said: error: "
                + "could not write index; some may still be in your files. Gitter did not try "
                + "to pull from \"origin/main\" again.")
    }

    @Test func theButtonIsNamed() {
        #expect(StashWording.continueButton == "Stash and Continue")
    }

    // MARK: - A retried pull's gates (final review I2)

    private static func pullGate(
        activity: RemoteActivity? = nil, isDetached: Bool = false,
        tracking: Tracking = .counts(ahead: 0, behind: 1), remotes: [Remote]? = nil
    ) -> RemoteWording.Gate {
        let branch = Branch(
            name: "main", sha: String(repeating: "1", count: 40), isHead: true, upstream: "origin/main",
            tracking: tracking, upstreamRemote: "origin", upstreamRef: "refs/heads/main", pushRemote: nil)
        return RemoteWording.Gate(
            hasRepository: true, activity: activity, isMutating: false, operation: nil,
            isDetached: isDetached, branch: isDetached ? nil : branch,
            remotes: remotes ?? [Remote(name: "origin", fetchURL: "/srv/o.git", pushURL: "/srv/o.git")])
    }

    /// A retried pull runs no fetch: neither a busy lane nor a remote with no fetch URL stops
    /// it, though both stop Pull.
    @Test func aRetriedPullIgnoresWhatOnlyTheFetchNeeds() {
        let lane = Self.pullGate(activity: RemoteActivity(kind: .fetch, remote: "origin", progress: nil))
        #expect(RemoteWording.pullBlocked(lane) != nil)
        #expect(RemoteWording.pullRetryBlocked(lane) == nil)
        let noURL = Self.pullGate(remotes: [Remote(name: "origin", fetchURL: nil, pushURL: nil)])
        #expect(RemoteWording.pullBlocked(noURL) == RemoteWording.remoteHasNoURL("origin"))
        #expect(RemoteWording.pullRetryBlocked(noURL) == nil)
    }

    /// Everything else Pull is refused for stops the retry too, before a stash is filed.
    @Test func aRetriedPullKeepsThePullsOtherGates() throws {
        #expect(RemoteWording.pullRetryBlocked(Self.pullGate(isDetached: true)) == RemoteWording.detachedPull)
        let gone = Self.pullGate(tracking: .gone)
        #expect(RemoteWording.pullRetryBlocked(gone) == RemoteWording.upstreamGone(try #require(gone.branch)))
        #expect(RemoteWording.pullRetryBlocked(Self.pullGate(tracking: .none)) == RemoteWording.noUpstream("main"))
        var unborn = Self.pullGate()
        unborn.branch = nil
        #expect(RemoteWording.pullRetryBlocked(unborn) == RemoteWording.noCommitsYet)
        var rebasing = Self.pullGate()
        rebasing.operation = .rebase
        #expect(RemoteWording.pullRetryBlocked(rebasing) == RepositoryOperation.rebase.movingHeadBlocked)
        #expect(RemoteWording.pullRetryBlocked(Self.pullGate()) == nil)
    }

    // MARK: - A store with no repository

    /// Nothing was refused, so nothing is offered, and the action does nothing and says nothing.
    @Test func aStoreWithNoRefusalOffersNothing() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        #expect(store.stashAndContinueOffer == nil)
        #expect(store.offeredStashAndContinue == nil)
        #expect(store.stashAndContinueBlockedReason == nil)
        store.stashAndContinue()
        #expect(store.lastError == nil)
        #expect(store.stickyNotice == nil)
        #expect(!store.isMutating)
    }
}
