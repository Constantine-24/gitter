import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// E2 Task 1: the isolation GitterTests' git runs under, and the helpers the store-flow suites are
/// built on (`ScratchRepo`, `waitUntilIdle`, `openedTestStore`), each with a control that shows its
/// check can fail.
@MainActor @Suite struct GitterTestIsolationTests {

    /// Every origin `git config --show-origin --list` names, read through the store's own git
    /// (`gitPath`) from the repository, as the git a store starts would read it.
    private static func origins(of store: RepositoryStore, in repo: ScratchRepo) async throws -> (text: String, origins: Set<String>) {
        let data = try await ProcessRunner().run(
            store.gitPath, ["config", "--show-origin", "--list"], cwd: repo.url)
        let text = String(decoding: data, as: UTF8.self)
        let origins = text.split(separator: "\n").compactMap {
            $0.split(separator: "\t", maxSplits: 1).first.map(String.init)
        }
        return (text, Set(origins))
    }

    private static func expectOnlyTheRepositorysOwnConfig(
        _ read: (text: String, origins: Set<String>), sourceLocation: SourceLocation = #_sourceLocation
    ) {
        // A baseline that can fail: the repository's own config really is listed, so an empty
        // answer below would be a broken probe and not isolation.
        #expect(read.text.contains("user.name="), "\(read.text)", sourceLocation: sourceLocation)
        #expect(!read.origins.isEmpty, sourceLocation: sourceLocation)
        for origin in read.origins {
            #expect(
                origin == "file:.git/config" || origin == "command line:",
                "configuration reached the store from \(origin)", sourceLocation: sourceLocation)
        }
    }

    @Test(.timeLimit(.minutes(10))) func noConfigurationReachesAStoreFromOutsideItsRepository() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        Self.expectOnlyTheRepositorysOwnConfig(try await Self.origins(of: store, in: repo))
        #expect(ProcessInfo.processInfo.environment["SSH_AUTH_SOCK"] == nil)
    }

    /// Control: a config that includes a file outside the repository is reported by the same
    /// check, so the check can fail.
    @Test(.timeLimit(.minutes(10))) func anIncludeFromOutsideTheRepositoryIsCaught() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let outside = repo.url.deletingLastPathComponent().appending(path: "outside.gitconfig")
        try "[marker]\n\tkey = outside\n".write(to: outside, atomically: true, encoding: .utf8)
        try repo.git("config", "include.path", outside.path)
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        let read = try await Self.origins(of: store, in: repo)
        #expect(read.text.contains("marker.key=outside"), "\(read.text)")
        withKnownIssue("the config includes a file outside the repository") {
            Self.expectOnlyTheRepositorysOwnConfig(read)
        } matching: { $0.comments.contains { $0.rawValue.contains("configuration reached the store from file:") } }
    }

    /// E3 Task 2: the isolation and the hang guard are GitCore's own, from the one shared
    /// test-support target, not copies kept here. Named by module, so a copy in GitterTests would
    /// not stand in for them.
    @Test func theIsolationAndTheHangGuardComeFromGitCoreTestSupport() {
        #expect(GitCoreTestSupport.TestGitEnvironment.isolated)
        #expect(ProcessInfo.processInfo.environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
        let stuck = GitCoreTestSupport.StuckCall()
        #expect(!stuck.waiting)
    }

    @Test func theNetworkGuardsAreSetInTheTestProcess() {
        #expect(TestGitEnvironment.isolated)
        let environment = ProcessInfo.processInfo.environment
        #expect(environment["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #expect(environment["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(environment["GIT_ALLOW_PROTOCOL"] == "file:ssh")
        #expect(environment["GIT_SSH"] == "/usr/bin/false")
        #expect(environment["GIT_SSH_COMMAND"] == nil)
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")
    }
}

@MainActor @Suite struct ScratchGitHelperTests {

    @Test func aScratchRepositoryIsAnInitialisedMainBranchWithFixedIdentity() throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        #expect(try repo.git("rev-parse", "--abbrev-ref", "HEAD").trimmingCharacters(in: .whitespacesAndNewlines) == "main")
        #expect(try repo.git("config", "gc.auto").trimmingCharacters(in: .whitespacesAndNewlines) == "0")
        #expect(try repo.git("log", "-1", "--format=%an <%ae>").trimmingCharacters(in: .whitespacesAndNewlines).contains("@"))
        #expect(try String(contentsOf: repo.url.appending(path: "a.txt"), encoding: .utf8) == "one\n")
    }

    /// Control: `git` throws when git exits non-zero, and `gitExpectingFailure` throws when it
    /// does not.
    @Test func gitThrowsOnAFailureAndExpectingFailureThrowsOnSuccess() throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        #expect(throws: (any Error).self) { try repo.git("rev-parse", "--verify", "no-such-ref") }
        try repo.gitExpectingFailure("rev-parse", "--verify", "no-such-ref")
        #expect(throws: (any Error).self) { try repo.gitExpectingFailure("status") }
    }

    @Test func aBareRemoteIsASiblingInsideTheSameTemporaryDirectory() throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let bare = try repo.makeBareRemote()
        #expect(bare.deletingLastPathComponent().standardizedFileURL == repo.directory.standardizedFileURL)
        try repo.commit("a.txt", "one\n", "first")
        try repo.git("remote", "add", "origin", bare.path)
        try repo.git("push", "origin", "main")
        #expect(try repo.git("ls-remote", "origin").contains("refs/heads/main"))
    }

    @Test func removeLeavesNothing() throws {
        let repo = try ScratchRepo()
        _ = try repo.makeBareRemote()
        let directory = repo.directory
        #expect(FileManager.default.fileExists(atPath: directory.path))
        repo.remove()
        #expect(!FileManager.default.fileExists(atPath: directory.path))
        #expect(!FileManager.default.fileExists(atPath: repo.url.path))
    }

    /// Control for `remove()`: it takes the directory away and nothing else.
    @Test func removeTakesOnlyItsOwnDirectory() throws {
        let one = try ScratchRepo()
        let two = try ScratchRepo()
        defer { two.remove() }
        one.remove()
        #expect(FileManager.default.fileExists(atPath: two.url.path))
    }

    @Test(.timeLimit(.minutes(10))) func waitUntilIdleReturnsOnceARefreshEnds() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        #expect(store.snapshot != nil)

        try repo.commit("b.txt", "two\n", "second")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.snapshot?.commits.count == 2)
        #expect(!store.isMutating)
        #expect(store.remoteActivity == nil)
        #expect(!store.refreshIsQueued)
    }

    /// Control: a store that stays busy is caught by the hang guard, which is what the test's
    /// time limit is in a real hang. The wait is cancelled as `.timeLimit` cancels it, and what
    /// is recorded is the guard's own issue.
    @Test(.timeLimit(.minutes(10))) func aStoreHeldBusyIsCaughtByTheTimeLimit() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let generation = try #require(store.beginMutation())

        await withKnownIssue("the store is held busy and never goes idle") {
            let waiter = Task { @MainActor in await waitUntilIdle(store) }
            try? await Task.sleep(for: .milliseconds(150))
            waiter.cancel()
            await waiter.value
        } matching: { $0.isNeverCameBack }
        store.finishMutation(generation: generation, failure: nil)
        await waitUntilIdle(store)
    }

    /// Control for the wait the hang guard exists for: the store's reload never ends (a stuck
    /// `refreshTask`), which nothing but the cancel of the waiting task can stop. Awaited outside
    /// `CallUnderTest` this would freeze the test; through it the cancel ends the wait and the
    /// guard's own issue is recorded.
    @Test(.timeLimit(.minutes(10))) func aStuckRefreshIsCaughtByTheTimeLimit() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let stuck = StuckCall()
        store.refreshTask = Task { await stuck.wait() }
        defer { stuck.release() }

        await withKnownIssue("the store's reload never ends") {
            let waiter = Task { @MainActor in await waitUntilIdle(store) }
            while !stuck.waiting { try? await Task.sleep(for: .milliseconds(5)) }
            try? await Task.sleep(for: .milliseconds(150))
            waiter.cancel()
            await waiter.value
        } matching: { $0.isNeverCameBack }
        stuck.release()
        await store.refreshTask?.value
        await waitUntilIdle(store)
    }

    /// `scheduleRefresh` replaces `refreshTask` while a wait is on the old one: the wait must not
    /// return until the replacement has run too.
    @Test(.timeLimit(.minutes(10))) func waitUntilIdleWaitsForAReplacementOfTheRefreshTask() async throws {
        final class Flag: @unchecked Sendable { var ran = false }
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let first = StuckCall()
        store.refreshTask = Task { await first.wait() }
        let flag = Flag()

        let waiter = Task { @MainActor in
            await waitUntilIdle(store)
            return flag.ran
        }
        while !first.waiting { try await Task.sleep(for: .milliseconds(5)) }
        try await Task.sleep(for: .milliseconds(100))
        store.refreshTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(300))
            flag.ran = true
        }
        first.release()

        #expect(await waiter.value, "the wait returned before the replacing reload ran")
    }

    /// Control: `open` failing is recorded promptly, at the caller, and not waited out.
    @Test(.timeLimit(.minutes(10))) func aFailedOpenIsRecordedInsteadOfHanging() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try FileManager.default.removeItem(at: repo.url.appending(path: ".git"))
        await withKnownIssue("the directory is not a repository") {
            let (_, cleanup) = await openedTestStore(repo)
            cleanup()
        } matching: { $0.comments.contains { $0.rawValue.contains("open failed: Not a Git repository") } }
    }

    /// The shared hang guard behaves here, on the main actor, as it does in GitCoreTests.
    @Test(.timeLimit(.minutes(10))) func theSharedHangGuardReportsAStuckCall() async throws {
        let stuck = StuckCall()
        let call = CallUnderTest { () -> Int in
            await stuck.wait()
            return 1
        }
        while !stuck.waiting { try await Task.sleep(for: .milliseconds(5)) }
        await withKnownIssue("the call never returns, so the cancelled wait reports it") {
            let waiter = Task { await call.value("the stuck call") }
            try? await Task.sleep(for: .milliseconds(100))
            waiter.cancel()
            #expect(await waiter.value == nil, "the stuck call came back")
        } matching: { $0.isNeverCameBack }
        stuck.release()
        #expect(await call.value() == 1)
    }

    // MARK: - HeldTransport (E2 Task 3, Ruling 2)

    /// The hold holds: a push through a held `receive-pack` keeps the lane, and the remote's
    /// branch where it was, until `letGo()`; then the push lands.
    @Test(.timeLimit(.minutes(10))) func aHeldPushLandsOnlyOnceLetGo() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let held = try HeldTransport.heldPush(in: repo)
        defer { held.letGo() }
        let bare = repo.directory.appending(path: "origin.git")
        let before = try repo.git("-C", bare.path, "rev-parse", "main")
        let local = try repo.git("rev-parse", "main")
        #expect(before != local)
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.push()
        #expect(await held.waitUntilHeld())
        #expect(store.remoteActivity?.kind == .push)
        #expect(try repo.git("-C", bare.path, "rev-parse", "main") == before)

        held.letGo()
        await waitUntilIdle(store)
        #expect(store.remoteActivity == nil)
        #expect(store.lastError == nil)
        #expect(try repo.git("-C", bare.path, "rev-parse", "main") == local)
    }

    /// Control: a transport that never starts is caught by the hang guard, which is what the
    /// test's time limit is in a real hang.
    @Test(.timeLimit(.minutes(10))) func aTransportThatNeverStartsIsCaughtByTheTimeLimit() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let held = try HeldTransport.heldPush(in: repo)
        defer { held.letGo() }

        await withKnownIssue("nothing ever pushes, so the transport never starts") {
            let waiter = Task { @MainActor in await held.waitUntilHeld() }
            try? await Task.sleep(for: .milliseconds(150))
            waiter.cancel()
            #expect(await waiter.value == false)
        } matching: { $0.isNeverCameBack }
    }

    /// The scratch directory going while a push is held — `letGo()` and then `repo.remove()`, the
    /// order every test's `defer`s run in — ends the push: the script gives up when its directory
    /// is gone instead of waiting for a release file that can no longer appear.
    @Test(.timeLimit(.minutes(10))) func aHeldPushEndsWhenItsDirectoryIsRemoved() async throws {
        let repo = try ScratchRepo()
        let held = try HeldTransport.heldPush(in: repo)
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        store.push()
        #expect(await held.waitUntilHeld())

        held.letGo()
        repo.remove()

        await waitUntilLaneFree(store)
        #expect(store.remoteActivity == nil)
        store.close()
    }

    // MARK: - The waits (E2 Task 3 fix round 1)

    @Test(.timeLimit(.minutes(10))) func waitUntilReturnsOnceTheConditionHolds() async {
        var looks = 0
        let met = await waitUntil("the third look") {
            looks += 1
            return looks >= 3
        }
        #expect(met)
        #expect(looks >= 3)
    }

    /// Control: a condition that never holds is caught by the hang guard.
    @Test(.timeLimit(.minutes(10))) func aConditionThatNeverHoldsIsCaughtByTheTimeLimit() async {
        await withKnownIssue("the condition never holds") {
            let waiter = Task { @MainActor in await waitUntil("a condition that never holds") { false } }
            try? await Task.sleep(for: .milliseconds(150))
            waiter.cancel()
            #expect(await waiter.value == false)
        } matching: { $0.isNeverCameBack }
    }

    /// Control: a lane held by a push that is never let go is caught by the hang guard.
    @Test(.timeLimit(.minutes(10))) func aLaneThatNeverFreesIsCaughtByTheTimeLimit() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let held = try HeldTransport.heldPush(in: repo)
        defer { held.letGo() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        store.push()
        await held.waitUntilHeld()

        await withKnownIssue("the push is held, so the lane never frees") {
            let waiter = Task { @MainActor in await waitUntilLaneFree(store) }
            try? await Task.sleep(for: .milliseconds(150))
            waiter.cancel()
            await waiter.value
        } matching: { $0.isNeverCameBack }
        held.letGo()
        await waitUntilIdle(store)
    }

    /// Control: a store whose window never closes never leaves its registry, and the wait for it
    /// is caught by the hang guard.
    @Test(.timeLimit(.minutes(10))) func aStoreThatNeverLeavesIsCaughtByTheTimeLimit() async {
        let test = TestRegistry()
        defer { test.remove() }
        let store = test.registry.makeStore()

        await withKnownIssue("the store's window never closes") {
            let waiter = Task { @MainActor in await waitUntilGone(store, from: test.registry) }
            try? await Task.sleep(for: .milliseconds(150))
            waiter.cancel()
            await waiter.value
        } matching: { $0.isNeverCameBack }
        #expect(test.registry.stores.contains { $0 === store })
    }
}
