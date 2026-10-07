import Foundation
import GitCore
import Testing

@testable import Gitter

/// E1 Task 4 (S2): a test's store reads and writes its own scratch suite, never the user's real
/// `dev.penzin.Gitter` domain, and the launch's reopen is refused under the test host and in a
/// scripted launch.
///
/// The test host is the app, so `.standard` here *is* the user's domain. The suite as a whole, and
/// each of its tests, is checked against it (RF5, `.leavesTheRealDefaultsAlone` and
/// `…InEachTest`): read before and after, never written. The checks' controls watch a scratch
/// suite named like the real one.
///
/// No git runs: the one store that opens a repository is given `/usr/bin/false` for git, and the
/// repository is a folder with an empty `.git` in it — enough for `open(_:)` to accept it.
@MainActor @Suite(.leavesTheRealDefaultsAlone, .leavesTheRealDefaultsAloneInEachTest)
struct DefaultsIsolationTests {

    /// A folder `open(_:)` accepts (it has a `.git`), or one it refuses (no `.git`), removed with
    /// `remove()`.
    struct ScratchFolder {
        let url: URL

        init(withDotGit: Bool) throws {
            url = FileManager.default.temporaryDirectory
                .appending(path: "gitter-defaults-\(UUID().uuidString)")
            let inside = withDotGit ? url.appending(path: ".git") : url
            try FileManager.default.createDirectory(at: inside, withIntermediateDirectories: true)
        }

        func remove() { try? FileManager.default.removeItem(at: url) }
    }

    /// A backend whose every command is `/usr/bin/false`: the store's loads fail at once, and no
    /// git is started.
    static let noGit = CLIGitBackend(gitPath: "/usr/bin/false")

    // MARK: - The test store

    @Test func aTestStoreAndItsScheduleAreOnTheirOwnSuite() {
        let (store, defaults, cleanup) = makeTestStore()
        defer { cleanup() }
        #expect(store.defaults === defaults)
        #expect(store.autoFetchScheduler.defaults === defaults)
        // Identity only: nothing is read from `.standard`.
        #expect(defaults !== UserDefaults.standard)
        // What RF5 watches is what `.standard` is in this process: the host is the app.
        #expect(Bundle.main.bundleIdentifier == LeavesTheDomainUnchanged.realDomain)
    }

    /// The factory's control: what a test writes is gone after `cleanup`, and the suite's domain
    /// with it. `DefaultsDomainSnapshot` reads what another instance wrote.
    @Test func cleanupRemovesTheScratchSuite() {
        let (store, defaults, cleanup) = makeTestStore()
        RepositoryStore.rememberMergeMode(.squash, in: store.defaults)
        #expect(defaults.string(forKey: RepositoryStore.mergeModeKey) == MergeMode.squash.rawValue)
        cleanup()
        #expect(defaults.string(forKey: RepositoryStore.mergeModeKey) == nil)

        let scratch = ScratchDefaults()
        #expect(scratch.suiteName.hasPrefix("dev.penzin.Gitter.tests."))
        scratch.defaults.set("x", forKey: "k")
        #expect(DefaultsDomainSnapshot.read(scratch.suiteName).contents.keys.sorted() == ["k"])
        scratch.remove()
        #expect(DefaultsDomainSnapshot.read(scratch.suiteName).contents.isEmpty)
    }

    // MARK: - What the store writes

    @Test func openWritesTheLastPathToTheScratchSuite() async throws {
        let folder = try ScratchFolder(withDotGit: true)
        defer { folder.remove() }
        let (store, defaults, cleanup) = makeTestStore(backend: Self.noGit)
        defer { cleanup() }
        let real = DefaultsDomainSnapshot.read(LeavesTheDomainUnchanged.realDomain)

        store.open(folder.url)

        #expect(store.root == folder.url.standardizedFileURL)
        #expect(
            defaults.string(forKey: RepositoryStore.lastRepositoryPathKey) == folder.url.standardizedFileURL.path)
        expectUnchanged(real, DefaultsDomainSnapshot.read(LeavesTheDomainUnchanged.realDomain))
        // The open's load, failed against `/usr/bin/false`, settles before the folder goes.
        await store.refresh()
    }

    @Test func theMergeModeRoundTripsThroughTheScratchSuite() {
        let (store, defaults, cleanup) = makeTestStore()
        defer { cleanup() }
        #expect(store.rememberedMergeMode == .fastForwardIfPossible, "a fresh suite has none")
        RepositoryStore.rememberMergeMode(.squash, in: store.defaults)
        #expect(store.rememberedMergeMode == .squash)
        #expect(defaults.string(forKey: RepositoryStore.mergeModeKey) == MergeMode.squash.rawValue)
    }

    @Test func thePullModeRoundTripsThroughTheScratchSuite() {
        let (store, defaults, cleanup) = makeTestStore()
        defer { cleanup() }
        #expect(store.rememberedPullMode == .merge, "a fresh suite has none")
        RepositoryStore.rememberPullMode(.rebase, in: store.defaults)
        #expect(store.rememberedPullMode == .rebase)
        #expect(defaults.string(forKey: RepositoryStore.pullModeKey) == PullMode.rebase.rawValue)
    }

    @Test func fetchAutomaticallyIsReadFromTheScratchSuite() {
        let (store, defaults, cleanup) = makeTestStore()
        defer { cleanup() }
        #expect(store.autoFetchScheduler.isEnabled, "absent means on")
        defaults.set(false, forKey: AutoFetchScheduler.enabledKey)
        #expect(!store.autoFetchScheduler.isEnabled)
        #expect(store.autoFetchSkipReason == "turned off")
    }

    // MARK: - RF5's check can fail

    /// The control for `.leavesTheRealDefaultsAlone`: a store that is not isolated from the domain
    /// being watched — here a scratch suite named like the real one, never the real one — writes
    /// its keys, and the same check fails.
    @Test func theUnchangedCheckSeesAStoreThatWritesTheWatchedDomain() {
        let watched = ScratchDefaults()
        defer { watched.remove() }
        let store = RepositoryStore(backend: Self.noGit, defaults: watched.defaults)
        let before = DefaultsDomainSnapshot.read(watched.suiteName)

        RepositoryStore.rememberMergeMode(.squash, in: store.defaults)
        RepositoryStore.rememberPullMode(.rebase, in: store.defaults)

        let after = DefaultsDomainSnapshot.read(watched.suiteName)
        #expect(after.changedKeys(since: before) == [RepositoryStore.mergeModeKey, RepositoryStore.pullModeKey])
        withKnownIssue("a store writing the watched domain fails the unchanged check") {
            expectUnchanged(before, after)
        }
        // A value changed under a key that was already there counts too.
        RepositoryStore.rememberMergeMode(.alwaysMergeCommit, in: store.defaults)
        let later = DefaultsDomainSnapshot.read(watched.suiteName)
        #expect(later.changedKeys(since: after) == [RepositoryStore.mergeModeKey])
    }

    /// Both scopes themselves, run by hand over a scratch suite named like the real one: a write
    /// inside either fails it, and a scope that writes nothing passes.
    @Test func bothScopesFailWhenTheirDomainIsWritten() async throws {
        let watched = ScratchDefaults()
        defer { watched.remove() }
        let test = try #require(Test.current)
        let store = RepositoryStore(backend: Self.noGit, defaults: watched.defaults)
        let wholeSuite = LeavesTheDomainUnchanged(domain: watched.suiteName)
        let eachTest = LeavesTheDomainUnchangedInEachTest(domain: watched.suiteName)

        await withKnownIssue("a store writing the watched domain inside the suite's scope fails it") {
            try await wholeSuite.provideScope(for: test, testCase: nil) {
                await MainActor.run { RepositoryStore.rememberPullMode(.rebase, in: store.defaults) }
            }
        }
        await withKnownIssue("a store writing the watched domain inside a test's scope fails it") {
            try await eachTest.provideScope(for: test, testCase: Test.Case.current) {
                await MainActor.run { RepositoryStore.rememberMergeMode(.squash, in: store.defaults) }
            }
        }
        try await wholeSuite.provideScope(for: test, testCase: nil) {}
        try await eachTest.provideScope(for: test, testCase: Test.Case.current) {}
    }

    // MARK: - The reopen guard

    @Test func theTestHostNeverReopens() {
        #expect(RepositoryStore.reopenRefusal(testHost: true, environment: [:]) == .testHost)
        #expect(
            RepositoryStore.reopenRefusal(testHost: true, environment: ["GITTER_DEBUG_THEN": "idle"]) == .testHost)
        // This process is a test host, and is refused as one.
        #expect(
            RepositoryStore.reopenRefusal(
                testHost: TestHost.isRunningTests, environment: ProcessInfo.processInfo.environment) == .testHost)
    }

    #if DEBUG
        @Test func aScriptedLaunchNeverReopens() {
            #expect(
                RepositoryStore.reopenRefusal(testHost: false, environment: ["GITTER_DEBUG_THEN": ""])
                    == .scriptedLaunch)
            #expect(
                RepositoryStore.reopenRefusal(
                    testHost: false, environment: ["GITTER_DEBUG_OPEN": "/private/tmp/fixture"]) == .scriptedLaunch)
        }
    #endif

    /// The decision's control: a launch a person made reopens.
    @Test func anOrdinaryLaunchReopens() {
        #expect(
            RepositoryStore.reopenRefusal(testHost: false, environment: ["HOME": "/Users/someone", "GITTER_OTHER": "1"])
                == nil)
    }

    /// What would be reopened is read from the store's own suite: a folder, and nothing else.
    @Test func theRepositoryToReopenComesFromTheStoresSuite() throws {
        let folder = try ScratchFolder(withDotGit: false)
        defer { folder.remove() }
        let (store, defaults, cleanup) = makeTestStore(backend: Self.noGit)
        defer { cleanup() }
        #expect(RepositoryStore.lastRepositoryToReopen(in: store.defaults) == nil, "nothing stored")

        defaults.set(folder.url.path, forKey: RepositoryStore.lastRepositoryPathKey)
        #expect(RepositoryStore.lastRepositoryToReopen(in: store.defaults)?.path == folder.url.path)

        let file = folder.url.appending(path: "file")
        try Data().write(to: file)
        defaults.set(file.path, forKey: RepositoryStore.lastRepositoryPathKey)
        #expect(RepositoryStore.lastRepositoryToReopen(in: store.defaults) == nil, "a file")

        defaults.set(folder.url.appending(path: "missing").path, forKey: RepositoryStore.lastRepositoryPathKey)
        #expect(RepositoryStore.lastRepositoryToReopen(in: store.defaults) == nil, "nothing there")
    }

    /// The wiring, with no reopen possible: the store's suite names a folder with no `.git`, so a
    /// broken guard would reach `open(_:)` and be refused there, with a banner. Nothing is opened
    /// and nothing is said: the guard stopped it first.
    @Test func reopenLastRepositoryStopsAtTheGuardUnderTheTestHost() throws {
        let folder = try ScratchFolder(withDotGit: false)
        defer { folder.remove() }
        let (store, defaults, cleanup) = makeTestStore(backend: Self.noGit)
        defer { cleanup() }
        defaults.set(folder.url.path, forKey: RepositoryStore.lastRepositoryPathKey)
        #expect(RepositoryStore.lastRepositoryToReopen(in: store.defaults) != nil, "only the guard is in the way")

        store.reopenLastRepository()

        #expect(store.root == nil)
        #expect(store.lastError == nil)
    }

    // MARK: - Open Recent

    /// `open(_:)` adds what it opens to Open Recent — a list outside the defaults, which no
    /// scratch suite can stand in for — only in a launch a person made. This process is a test
    /// host, so the scratch folder `openWritesTheLastPathToTheScratchSuite` opens is not added.
    @Test func onlyAnOrdinaryLaunchNotesRecentDocuments() {
        #expect(RepositoryStore.openRecentRefusal(testHost: true, environment: [:]) == .testHost)
        #expect(
            RepositoryStore.openRecentRefusal(
                testHost: TestHost.isRunningTests, environment: ProcessInfo.processInfo.environment) == .testHost)
        #if DEBUG
            #expect(
                RepositoryStore.openRecentRefusal(testHost: false, environment: ["GITTER_DEBUG_THEN": ""])
                    == .scriptedLaunch)
        #endif
        // The control: a launch a person made records what it opens.
        #expect(RepositoryStore.openRecentRefusal(testHost: false, environment: ["HOME": "/Users/someone"]) == nil)
    }
}
