import Foundation
import GitCore
import Testing

@testable import Gitter

/// A1's apply and pop of a stash, run on real git (E2 Task 1): the outcomes git gives that no
/// double does, as the store words them. `popStash` reports every outcome but a clean one in the
/// sticky banner (`lastError`, kept by `errorIsSticky`), word for word `StashWording.applyOutcome`.
@MainActor @Suite struct StashFlowTests {

    /// `a.txt` committed, changed and stashed, then given a conflicting commit.
    private static func repoWithAConflictingStash() throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "one\n", "first")
        try repo.write("a.txt", "mine\n")
        try repo.git("stash")
        try repo.commit("a.txt", "theirs\n", "second")
        return repo
    }

    @Test(.timeLimit(.minutes(10))) func aPopThatConflictsKeepsTheStashAndSaysSo() async throws {
        let repo = try Self.repoWithAConflictingStash()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let stash = try #require(store.stashes.first)

        store.popStash(stash)
        await waitUntilIdle(store)

        #expect(store.lastError == StashWording.applyOutcome(.conflicts(["a.txt"]), of: stash, popping: true))
        #expect(store.stashes.map(\.sha) == [stash.sha])
        let file = try #require(store.snapshot?.status.files.first { $0.path == "a.txt" })
        #expect(store.isUnmerged(file))
    }

    /// Control: the same flow without the conflict pops cleanly, so the checks above are not
    /// satisfied by every pop. The entry is gone and no banner is up.
    @Test(.timeLimit(.minutes(10))) func aPopThatDoesNotConflictDropsTheStash() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.write("a.txt", "mine\n")
        try repo.git("stash")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let stash = try #require(store.stashes.first)

        store.popStash(stash)
        await waitUntilIdle(store)

        #expect(store.lastError == nil)
        #expect(store.notice?.text == StashWording.applyOutcome(.applied, of: stash, popping: true))
        #expect(store.stashes.isEmpty)
    }

    @Test(.timeLimit(.minutes(10))) func anUntrackedFileThatCameBackInTheMeantimeIsLeftAlone() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.write("a.txt", "mine\n")
        try repo.write("u.txt", "from the stash\n")
        try repo.git("stash", "-u")
        try repo.write("u.txt", "made since\n")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let stash = try #require(store.stashes.first)

        store.popStash(stash)
        await waitUntilIdle(store)

        #expect(
            store.lastError
                == StashWording.applyOutcome(.partiallyApplied(untrackedNotRestored: ["u.txt"]), of: stash, popping: true))
        #expect(store.stashes.map(\.sha) == [stash.sha])
        #expect(try String(contentsOf: repo.url.appending(path: "u.txt"), encoding: .utf8) == "made since\n")
        #expect(try String(contentsOf: repo.url.appending(path: "a.txt"), encoding: .utf8) == "mine\n")
    }

    /// git applies the entry and cannot drop it: `stash drop` takes `refs/stash.lock` first.
    /// The words after the colon are git's, so the sentence is matched around them.
    @Test(.timeLimit(.minutes(10))) func anEntryGitCouldNotDropIsAppliedButKept() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.write("a.txt", "mine\n")
        try repo.git("stash")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let stash = try #require(store.stashes.first)
        let lock = repo.url.appending(path: ".git/refs/stash.lock")
        try "".write(to: lock, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: lock) }

        store.popStash(stash)
        await waitUntilIdle(store)
        try FileManager.default.removeItem(at: lock)

        let marker = "\u{1}"
        let template = StashWording.applyOutcome(.appliedButKept(reason: marker), of: stash, popping: true)
        let parts = template.components(separatedBy: marker)
        let banner = try #require(store.lastError)
        #expect(parts.count == 2)
        #expect(banner.hasPrefix(parts[0]), "\(banner)")
        #expect(banner.hasSuffix(parts[1]), "\(banner)")
        #expect(banner.count > template.count - 1, "git's own words are in the sentence: \(banner)")
        #expect(store.stashes.map(\.sha) == [stash.sha])
        #expect(try String(contentsOf: repo.url.appending(path: "a.txt"), encoding: .utf8) == "mine\n")
    }
}
