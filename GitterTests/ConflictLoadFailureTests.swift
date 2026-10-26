import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// B4 item 4 on real git: a conflicted file whose read fails is a state of its own
/// (`conflictLoadFailure`), not a spinner and a banner the next reload erases.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct ConflictLoadFailureTests {

    struct ReadFailed: Error, LocalizedError, Sendable {
        var errorDescription: String? { "git went away" }
    }

    /// A merge of `topic` into `main`, stopped on a conflict in `a.txt`; `b.txt` conflicts too.
    static func stoppedMerge() throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "base\n", "base")
        try repo.commit("b.txt", "base\n", "base b")
        try repo.git("switch", "-c", "topic")
        try repo.commit("a.txt", "topic\n", "topic a")
        try repo.commit("b.txt", "topic\n", "topic b")
        try repo.git("switch", "main")
        try repo.commit("a.txt", "main\n", "main a")
        try repo.commit("b.txt", "main\n", "main b")
        try repo.gitExpectingFailure("merge", "topic")
        return repo
    }

    /// A backend whose conflict reads throw while the returned flag is true.
    static func failingBackend() -> (TestBackend, Recorded<Bool>) {
        let backend = TestBackend()
        let failing = Recorded(true)
        backend.hook(.conflictDocument) { if failing.value { throw ReadFailed() } }
        return (backend, failing)
    }

    @Test(.timeLimit(.minutes(10))) func aFailedReadIsAStateNotABanner() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (backend, _) = Self.failingBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        let before = store.lastError

        store.select("a.txt", staged: false)
        await store.conflictTask?.value

        #expect(store.conflictLoadFailure == ConflictLoadFailure(path: "a.txt", message: "git went away"))
        #expect(store.selectedConflict == nil)
        #expect(store.lastError == before)
    }

    @Test(.timeLimit(.minutes(10))) func theFailureStaysWhileTheSameFileIsReadAgainAndLeavesWhenItReads() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (backend, failing) = Self.failingBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        store.select("a.txt", staged: false)
        await store.conflictTask?.value
        #expect(store.conflictLoadFailure?.path == "a.txt")

        // Read again and failing again: still the failure, never a gap.
        store.loadConflict()
        #expect(store.conflictLoadFailure?.path == "a.txt")
        await store.conflictTask?.value
        #expect(store.conflictLoadFailure?.path == "a.txt")

        failing.set(false)
        await store.refresh()
        await store.conflictTask?.value
        #expect(store.selectedConflict?.snapshot.file.path == "a.txt")
        #expect(store.conflictLoadFailure == nil)
    }

    @Test(.timeLimit(.minutes(10))) func selectingAnotherFileClearsTheFailure() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (backend, failing) = Self.failingBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        store.select("a.txt", staged: false)
        await store.conflictTask?.value
        #expect(store.conflictLoadFailure?.path == "a.txt")

        failing.set(false)
        store.select("b.txt", staged: false)
        #expect(store.conflictLoadFailure == nil)
        await store.conflictTask?.value
        #expect(store.selectedConflict?.snapshot.file.path == "b.txt")
        #expect(store.conflictLoadFailure == nil)
    }

    /// RF3, the control: a failing read that lands after a commit was selected records nothing.
    @Test(.timeLimit(.minutes(10))) func aFailingReadThatLandsAfterTheSelectionMovedRecordsNothing() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let started = Recorded(false)
        let landed = Recorded(false)
        // The read starts, waits for the test, then fails.
        backend.hook(.conflictDocument) {
            started.set(true)
            while !landed.value { try await Task.sleep(for: .milliseconds(10)) }
            throw ReadFailed()
        }
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        defer { landed.set(true) }

        store.select("a.txt", staged: false)
        #expect(await waitUntil("the read started") { started.value })
        let sha = try #require(store.snapshot?.commits.first?.sha)
        // `select(_:)` moves `selection` first and cancels the read only when its detail load
        // calls `loadDiff()`, a task later: the read can land in between, not cancelled. Written
        // directly, so that window is the whole test and `selection == .workingCopy` is the only
        // thing between the failing read and the failed state.
        store.selection = .commit(sha)
        let read = try #require(store.conflictTask)
        landed.set(true)
        await read.value

        #expect(store.selection == .commit(sha))
        #expect(store.conflictLoadFailure == nil)
    }
}
