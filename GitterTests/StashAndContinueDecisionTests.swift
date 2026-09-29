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
                    message: "Gitter: before switching to \"b\""))
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
        #expect(offer?.message == "Gitter: before merging \"b\"")
    }

    /// A pull's rebase refuses any tracked change, and never an untracked file (that one arrives
    /// as `.wouldOverwrite(untracked:)` instead, M 12).
    @Test func aDirtyTreeRefusingAPullOffersAStash() {
        let action = PendingBranchAction.pull(upstream: "origin/main", mode: .alwaysMergeCommit)
        let offer = StashAndContinue.offer(for: .treeNotClean, action: action)
        #expect(
            offer
                == StashAndContinueOffer(
                    action: action, includeUntracked: false, message: "Gitter: before pulling"))
    }

    @Test func aPullsMergeStepRefusedOverAFileOffersAStash() {
        let action = PendingBranchAction.pull(upstream: "origin/main", mode: .fastForwardIfPossible)
        let offer = StashAndContinue.offer(
            for: .wouldOverwrite(tracked: ["f"], untracked: []), action: action)
        #expect(offer?.action == action)
        #expect(offer?.message == "Gitter: before pulling")
    }

    @Test func eachActionNamesItselfInTheMessage() {
        let refusal = BranchOperationError.wouldOverwrite(tracked: ["f"], untracked: [])
        let messages: [(PendingBranchAction, String)] = [
            (.switchTo("feature/x"), "Gitter: before switching to \"feature/x\""),
            (.track("origin/b"), "Gitter: before checking out \"origin/b\""),
            (.detach("v1.0"), "Gitter: before checking out \"v1.0\""),
            (.merge("b", .fastForwardIfPossible), "Gitter: before merging \"b\""),
            (.merge("b", .squash), "Gitter: before merging \"b\""),
            (.createAndSwitch(name: "n", startPoint: "origin/b"), "Gitter: before switching to \"n\""),
            (.pull(upstream: "origin/main", mode: .alwaysMergeCommit), "Gitter: before pulling"),
        ]
        for (action, message) in messages {
            #expect(StashAndContinue.offer(for: refusal, action: action)?.message == message)
        }
    }

    // MARK: - Not offered

    /// Every other refusal: a stash cannot answer it (a name, a branch, an operation part-way
    /// through — where `stashAll` refuses anyway), or, for `.indexNotClean`, the spec does not
    /// list it (see the report).
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
            .indexNotClean,
            .noOperationInProgress,
            .operationMismatch(expected: .merge, actual: .rebase),
        ]
        for refusal in refusals {
            #expect(StashAndContinue.offer(for: refusal, action: .switchTo("b")) == nil)
            #expect(
                StashAndContinue.offer(
                    for: refusal, action: .pull(upstream: "origin/main", mode: .alwaysMergeCommit))
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
            StashWording.continued(stash: Self.stash("Gitter: before switching to \"b\""))
                == "Your changes are in stash \"Gitter: before switching to \"b\"\".")
    }

    @Test func nothingStashedSaysNothingWasTriedAgain() {
        #expect(
            StashWording.continueNothingStashed(.switchTo("b"))
                == "Nothing was stashed: there are no changes a stash can hold, so Gitter did "
                + "not try to switch to \"b\" again. If the changes are gone, try again; a "
                + "change inside a submodule has to be committed in the submodule.")
    }

    @Test func savedWithErrorSaysTheChangesMayBeInBothPlaces() {
        let stash = Self.stash("Gitter: before pulling")
        #expect(
            StashWording.continueSavedWithError(
                stash, gitsWords: "error: could not write index\n", trashed: [:],
                action: .pull(upstream: "origin/main", mode: .alwaysMergeCommit))
                == "Your changes are in stash \"Gitter: before pulling\"; git also said: error: "
                + "could not write index; some may still be in your files. Gitter did not try "
                + "to pull from \"origin/main\" again.")
    }

    @Test func theButtonIsNamed() {
        #expect(StashWording.continueButton == "Stash and Continue")
    }

    // MARK: - A store with no repository

    /// Nothing was refused, so nothing is offered, and the action does nothing and says nothing.
    @Test func aStoreWithNoRefusalOffersNothing() {
        let store = RepositoryStore()
        #expect(store.stashAndContinueOffer == nil)
        #expect(store.offeredStashAndContinue == nil)
        #expect(store.stashAndContinueBlockedReason == nil)
        store.stashAndContinue()
        #expect(store.lastError == nil)
        #expect(store.stickyNotice == nil)
        #expect(!store.isMutating)
    }
}
