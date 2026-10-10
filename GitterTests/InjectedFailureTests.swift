import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// A failure at a chosen call (E3 Task 3): the reload a write ends with throws. `mutate` reloads
/// after every write; a reload that fails puts its error up (`loadSnapshot`'s `setError`) and
/// takes the banner's stickiness away, so the next reload that succeeds clears it.
@MainActor @Suite struct InjectedFailureTests {

    @Test(.timeLimit(.minutes(10))) func theReloadAfterACommitFailsAndTheNextOneRecovers() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.write("a.txt", "two\n")
        let backend = TestBackend()
        let failure = GitError.commandFailed(
            exitCode: 128, stderr: "fatal: injected by the test: the reload after the commit failed")
        let armed = Recorded(false)
        // Armed once the commit's write is in, so the reload that follows it is the first to throw.
        backend.hook(.commit, .after) { armed.set(true) }
        backend.hook(.snapshot, .before) { [weak backend] in
            guard armed.exchange(false) else { return }
            // Every reload after this one waits until the test lets it go, so none — the
            // watcher's own included — clears the banner before the test has read it.
            _ = backend?.hold(.snapshot)
            throw failure
        }
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        defer { backend.releaseAll() }

        store.draft.subject = "second"
        store.commit()
        await waitUntil("the failed reload's banner") { store.lastError != nil }

        #expect(store.lastError == RepositoryStore.describe(failure))
        // Only the reload failed: the commit is in.
        #expect(try repo.git("log", "-1", "--format=%s") == "second\n")

        backend.releaseAll()
        await store.refresh()
        await waitUntilIdle(store)

        #expect(store.lastError == nil)
        #expect(store.snapshot?.commits.first?.summary == "second")
        #expect(!armed.value)
    }

    /// Control: the same commit with no failure injected leaves no banner, so the check above
    /// is not met by every commit.
    @Test(.timeLimit(.minutes(10))) func theSameCommitWithNothingInjectedLeavesNoBanner() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.write("a.txt", "two\n")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        store.draft.subject = "second"
        store.commit()
        await waitUntilIdle(store)

        #expect(store.lastError == nil)
        #expect(store.snapshot?.commits.first?.summary == "second")
    }
}
