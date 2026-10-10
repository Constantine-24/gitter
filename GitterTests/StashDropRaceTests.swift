import Foundation
import GitCoreTestSupport
import Testing

@testable import GitCore
@testable import Gitter

/// The stash list moving between a pop's clean apply and its drop (the E2 leftover, E3 Task 3):
/// git changes state between two of one backend call's own steps, which only `TestBackend`'s
/// `replacePop` reaches — through GitCore's `pop(_:at:beforeDrop:)` seam, where the test's own
/// git pushes a newer entry, so `stash@{index}` no longer names the one applied. GitCore keeps
/// the entry and says so (`.appliedButKept`, `CLIGitBackend.listChangedBeforeTheDrop`;
/// `StashWriteTests.aPopWhoseListMovesBeforeTheDropKeepsTheEntryAndSaysSo`); this is what the
/// store then shows and keeps.
@MainActor @Suite struct StashDropRaceTests {

    /// `a.txt` and `g.txt` committed, and `a.txt`'s change stashed as "the one popped".
    private static func repoWithAStash() throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "one\n", "first")
        try repo.commit("g.txt", "g\n", "second")
        try repo.write("a.txt", "mine\n")
        try repo.git("stash", "push", "-m", "the one popped")
        return repo
    }

    @Test(.timeLimit(.minutes(10))) func aPopWhoseListMovedBeforeTheDropSaysSoAndKeepsBothEntries() async throws {
        let repo = try Self.repoWithAStash()
        defer { repo.remove() }
        let backend = TestBackend()
        let newer = Recorded<String?>(nil)
        backend.replacePop { stash, root, real in
            try await real.pop(stash, at: root, beforeDrop: {
                // A push from a terminal, between the apply and the drop.
                try repo.write("g.txt", "g changed\n")
                try repo.git("stash", "push", "-q", "-m", "newer", "--", "g.txt")
                newer.set(try repo.git("rev-parse", "stash@{0}").trimmingCharacters(in: .newlines))
            })
        }
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        let stash = try #require(store.stashes.first)
        #expect(store.stashes.count == 1)

        store.popStash(stash)
        await waitUntilIdle(store)

        let newerSha = try #require(newer.value)
        #expect(
            store.lastError
                == StashWording.applyOutcome(
                    .appliedButKept(reason: CLIGitBackend.listChangedBeforeTheDrop), of: stash, popping: true))
        #expect(store.notice == nil, "not worded as a pop")
        // The applied entry is still listed, one down; the newer one is on top, untouched.
        #expect(store.stashes.map(\.sha) == [newerSha, stash.sha])
        #expect(try repo.git("rev-parse", "stash@{1}").trimmingCharacters(in: .newlines) == stash.sha)
        #expect(try repo.git("show", "stash@{0}:g.txt") == "g changed\n")
        // The changes are in the files: the popped entry's applied, the newer one's stashed away.
        #expect(try String(contentsOf: repo.url.appending(path: "a.txt"), encoding: .utf8) == "mine\n")
        #expect(try String(contentsOf: repo.url.appending(path: "g.txt"), encoding: .utf8) == "g\n")
        #expect(backend.calls.contains(.pop))
    }

    /// Control: the same pop through the same `TestBackend` with nothing replaced drops the entry
    /// and says so in a notice, so the checks above are not met by every pop.
    @Test(.timeLimit(.minutes(10))) func thePopWithNothingInBetweenDropsTheEntry() async throws {
        let repo = try Self.repoWithAStash()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        let stash = try #require(store.stashes.first)

        store.popStash(stash)
        await waitUntilIdle(store)

        #expect(store.lastError == nil)
        #expect(store.notice?.text == StashWording.applyOutcome(.applied, of: stash, popping: true))
        #expect(store.stashes.isEmpty)
        #expect(try String(contentsOf: repo.url.appending(path: "a.txt"), encoding: .utf8) == "mine\n")
    }
}
