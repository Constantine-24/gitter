import Foundation
import GitCore
import Testing

@testable import Gitter

/// A2's Continue, on real git (E2 Task 1): the two confirmations the bar's Continue can ask first,
/// and what the confirmations do when git or the index has moved on since they were asked.
///
/// A change the test makes with its own git is followed by `await store.refresh()`; the watcher's
/// debounce is not waited for.
@MainActor @Suite struct ContinueFlowTests {

    // MARK: - Ruling 16: another staged file does not ride into the commit unasked

    /// A cherry-pick of `topic`'s commit stopped on a conflict in `a.txt`, resolved and staged,
    /// with `b.txt` staged beside it.
    private static func cherryPickStoppedWithOneOtherStaged() throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "base\n", "base")
        try repo.git("switch", "-c", "topic")
        try repo.commit("a.txt", "topic\n", "topic change")
        try repo.git("switch", "main")
        try repo.commit("a.txt", "main\n", "main change")
        try repo.gitExpectingFailure("cherry-pick", "topic")
        try repo.write("a.txt", "resolved\n")
        try repo.git("add", "a.txt")
        try repo.write("b.txt", "b\n")
        try repo.git("add", "b.txt")
        return repo
    }

    private static func othersSheet(_ store: RepositoryStore) -> (RepositoryOperation, CommitRef?, [String])? {
        guard case .continueOthers(let operation, let current, let paths)? = store.activeSheet else { return nil }
        return (operation, current, paths)
    }

    /// "an unrelated staged
    /// change must not ride silently into a continued commit". Continue asks first and names the
    /// path; a path staged while the sheet is up is asked about again; the last confirm commits.
    @Test(.timeLimit(.minutes(10))) func anotherStagedFileIsAskedAboutAndAskedAgainWhenAnotherJoinsIt() async throws {
        let repo = try Self.cherryPickStoppedWithOneOtherStaged()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        #expect(store.operationInProgress == .cherryPick)
        #expect(store.continueState == .enabled)

        store.continueOperation()
        let first = try #require(Self.othersSheet(store), "no sheet: \(String(describing: store.activeSheet))")
        #expect(first.0 == .cherryPick)
        #expect(first.2 == ["b.txt"])

        try repo.write("c.txt", "c\n")
        try repo.git("add", "c.txt")
        await store.refresh()
        await waitUntilIdle(store)
        store.confirmContinueOthers()
        await waitUntilIdle(store)

        let again = try #require(Self.othersSheet(store), "not asked again: \(String(describing: store.activeSheet))")
        #expect(again.0 == .cherryPick)
        #expect(again.1 == first.1)
        #expect(again.2.sorted() == ["b.txt", "c.txt"])
        #expect(store.operationInProgress == .cherryPick, "nothing was continued")
        #expect(store.lastError == nil)

        store.confirmContinueOthers()
        await waitUntilIdle(store)

        #expect(store.activeSheet == nil)
        #expect(store.operationInProgress == nil)
        #expect(store.notice?.text == ContinueWording.finished(.cherryPick))
        let committed = try repo.git("show", "--name-only", "--format=", "HEAD")
        #expect(Set(committed.split(separator: "\n").map(String.init)) == ["a.txt", "b.txt", "c.txt"])
    }

    /// Refusal, sheet, retry: a sheet that is cancelled leaves the stop as it was, and Continue
    /// asks again.
    @Test(.timeLimit(.minutes(10))) func aCancelledSheetIsAskedAgainByTheNextContinue() async throws {
        let repo = try Self.cherryPickStoppedWithOneOtherStaged()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.continueOperation()
        let first = try #require(store.activeSheet)
        store.activeSheet = nil
        #expect(store.operationInProgress == .cherryPick)
        #expect(store.continueState == .enabled)

        store.continueOperation()
        #expect(store.activeSheet == first)
    }

    /// Control: with nothing else staged, Continue asks nothing and finishes.
    @Test(.timeLimit(.minutes(10))) func withNothingElseStagedContinueJustRuns() async throws {
        let repo = try Self.cherryPickStoppedWithOneOtherStaged()
        defer { repo.remove() }
        try repo.git("restore", "--staged", "b.txt")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.continueOperation()
        await waitUntilIdle(store)

        #expect(store.activeSheet == nil)
        #expect(store.operationInProgress == nil)
        #expect(store.notice?.text == ContinueWording.finished(.cherryPick))
    }

    // MARK: - Ruling 20: the empty result, and an acknowledgement gone stale

    /// A rebase of `topic` onto `main` stopped on `a.txt`, resolved to exactly what `main` has: the
    /// commit is empty. `b.txt` is staged beside it.
    private static func rebaseStoppedOnAnEmptyResultWithOneOtherStaged() throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "base\n", "base")
        try repo.git("switch", "-c", "topic")
        try repo.commit("a.txt", "topic\n", "topic change")
        try repo.git("switch", "main")
        try repo.commit("a.txt", "main\n", "main change")
        try repo.git("switch", "topic")
        try repo.gitExpectingFailure("rebase", "main")
        try repo.write("a.txt", "main\n")
        try repo.git("add", "a.txt")
        try repo.write("b.txt", "b\n")
        try repo.git("add", "b.txt")
        return repo
    }

    /// Ruling 20 (same ledger): "at a rebase `.emptyResult` the UI must ALSO check for other staged
    /// files ... BEFORE showing 'the commit will be left out' — if other staged files exist, the
    /// confirmation must say the commit keeps them". So the sheet carries `otherStaged`.
    /// And when they are all unstaged before the button is pressed, the acknowledgement names
    /// files that are no longer staged: GitCore refuses it (`.notReady(.otherStagedChanges([]))`,
    /// "A non-empty acknowledgement with nothing else staged now") and the store says the staged
    /// files changed (`ContinueWording.acknowledgementStale`), continuing nothing.
    @Test(.timeLimit(.minutes(10))) func anEmptyResultAcknowledgementThatWentStaleContinuesNothing() async throws {
        let repo = try Self.rebaseStoppedOnAnEmptyResultWithOneOtherStaged()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        #expect(store.operationInProgress == .rebase)
        #expect(store.continueState == .enabled)

        store.continueOperation()
        guard case .continueEmpty(let current, let otherStaged)? = store.activeSheet else {
            Issue.record("no empty-result sheet: \(String(describing: store.activeSheet))")
            return
        }
        #expect(otherStaged == ["b.txt"])
        #expect(current.subject == "topic change")

        try repo.git("restore", "--staged", ".")
        await store.refresh()
        await waitUntilIdle(store)
        store.confirmContinueEmpty()
        await waitUntilIdle(store)

        #expect(store.lastError == ContinueWording.acknowledgementStale)
        #expect(store.operationInProgress == .rebase, "nothing was continued")
        #expect(store.activeSheet == nil)
        #expect(try repo.git("log", "--format=%s", "main..HEAD").isEmpty, "no commit was made")
    }

    /// Control: the same stop, acknowledged while the file is still staged, finishes the rebase
    /// and the commit keeps `b.txt` under its own title.
    @Test(.timeLimit(.minutes(10))) func anEmptyResultAcknowledgedInTimeKeepsTheOtherStagedFile() async throws {
        let repo = try Self.rebaseStoppedOnAnEmptyResultWithOneOtherStaged()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.continueOperation()
        guard case .continueEmpty? = store.activeSheet else {
            Issue.record("no empty-result sheet: \(String(describing: store.activeSheet))")
            return
        }
        store.confirmContinueEmpty()
        await waitUntilIdle(store)

        #expect(store.lastError == nil)
        #expect(store.operationInProgress == nil)
        #expect(try repo.git("log", "-1", "--format=%s").trimmingCharacters(in: .whitespacesAndNewlines) == "topic change")
        #expect(try repo.git("show", "--name-only", "--format=", "HEAD").split(separator: "\n").map(String.init) == ["b.txt"])
    }
}
