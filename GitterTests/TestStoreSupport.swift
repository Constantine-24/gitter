import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// A defaults suite of the test's own, removed by `remove()`.
///
/// The test host is the app itself (`GitterTests` is hosted by Gitter), so `.standard` in a test
/// is the user's real `dev.penzin.Gitter` domain: their last repository, their merge mode. A
/// store built on one of these reads and writes only the scratch suite (E1 Task 4, S2).
///
/// The suite is named by an absolute path, `<tmp>/gitter-defaults-<uuid>/dev.penzin.Gitter.tests.<uuid>`,
/// and its file is that path plus `.plist`, inside the folder. A suite named only
/// `dev.penzin.Gitter.tests.<uuid>` left an empty plist in `~/Library/Preferences` for every suite
/// a test wrote to, rewritten by cfprefsd when the process exits (measured). Named by a path, it
/// writes nothing there (measured on macOS 27, and checked by
/// `DefaultsIsolationTests.theScratchSuiteIsKeptInItsOwnTemporaryFolder`), and `remove()` takes
/// the folder away with it.
struct ScratchDefaults {
    static let prefix = "dev.penzin.Gitter.tests."

    let folder: URL
    let suiteName: String
    let defaults: UserDefaults

    init() {
        folder = FileManager.default.temporaryDirectory.appending(path: "gitter-defaults-\(UUID().uuidString)")
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        } catch {
            preconditionFailure("no folder for a defaults suite: \(error)")
        }
        suiteName = folder.appending(path: Self.prefix + UUID().uuidString).path
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("no defaults suite \(suiteName)")
        }
        self.defaults = defaults
    }

    /// Where the suite is kept: in its folder.
    var file: URL { URL(fileURLWithPath: suiteName + ".plist") }

    /// Where a suite of the same last name would be kept if it were not named by a path. Only ever
    /// checked for existence.
    var preferencesFile: URL {
        URL.libraryDirectory.appending(path: "Preferences/\(URL(fileURLWithPath: suiteName).lastPathComponent).plist")
    }

    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
        try? FileManager.default.removeItem(at: folder)
    }
}

/// A store for a test: its defaults are a fresh `ScratchDefaults` suite, never `.standard`, and
/// `cleanup` removes that suite. Every store GitterTests build comes from here, and with it the
/// git environment of `TestGitEnvironment.isolated` (E2 Task 1).
@MainActor
func makeTestStore(
    backend: RepositoryStore.Backend = CLIGitBackend()
) -> (RepositoryStore, UserDefaults, cleanup: () -> Void) {
    precondition(TestGitEnvironment.isolated)
    let scratch = ScratchDefaults()
    let store = RepositoryStore(backend: backend, defaults: scratch.defaults)
    return (store, scratch.defaults, { scratch.remove() })
}

/// What one defaults domain holds, read and never written: `persistentDomain(forName:)`, which
/// leaves out the global and registration domains that `dictionaryRepresentation()` would mix in
/// (another app can change those).
///
/// Read through a plain `UserDefaults()`, not `UserDefaults(suiteName:)`: in the test host the
/// real domain is the app's own bundle identifier, and a suite of that name logs "does not make
/// sense and will not work" (measured). `persistentDomain(forName:)` takes the domain by name
/// whichever instance it is asked on.
struct DefaultsDomainSnapshot {
    let domain: String
    let contents: [String: Any]

    static func read(_ domain: String) -> DefaultsDomainSnapshot {
        DefaultsDomainSnapshot(domain: domain, contents: UserDefaults().persistentDomain(forName: domain) ?? [:])
    }

    /// The keys added, removed or given another value since `before`, sorted. Names only: the
    /// values are the user's (a path, window frames) and are never printed.
    func changedKeys(since before: DefaultsDomainSnapshot) -> [String] {
        let keys = Set(contents.keys).union(before.contents.keys)
        return keys.filter { key in
            switch (before.contents[key], contents[key]) {
            case (nil, nil): false
            case let (old?, new?): !(old as AnyObject).isEqual(new)
            default: true
            }
        }.sorted()
    }
}

/// Fails the current test when `after` differs from `before` in any key.
func expectUnchanged(
    _ before: DefaultsDomainSnapshot, _ after: DefaultsDomainSnapshot,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let changed = after.changedKeys(since: before)
    #expect(changed.isEmpty, "the \(after.domain) domain changed: \(changed)", sourceLocation: sourceLocation)
}

/// Runs `function` and fails the current test when `domain` is not the same afterwards — also
/// when `function` throws, whose error is then rethrown. Reads the domain twice and writes nothing.
func checkingDomainUnchanged(
    _ domain: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ function: @Sendable () async throws -> Void
) async throws {
    let before = DefaultsDomainSnapshot.read(domain)
    do {
        try await function()
    } catch {
        expectUnchanged(before, DefaultsDomainSnapshot.read(domain), sourceLocation: sourceLocation)
        throw error
    }
    expectUnchanged(before, DefaultsDomainSnapshot.read(domain), sourceLocation: sourceLocation)
}

/// RF5: a defaults domain read before and after each test of a suite, and required unchanged —
/// for `.leavesTheRealDefaultsAlone`, the user's real `dev.penzin.Gitter` domain. Read only:
/// nothing here writes the domain it watches. Its controls (`DefaultsIsolationTests`) run the same
/// scope over a scratch suite, a path whose last component is `dev.penzin.Gitter.tests.<uuid>`,
/// never the real domain.
///
/// Per test, not around the suite: on Xcode 27 an issue recorded in a suite's own scope crashes
/// the test host ("Recording issues for suites is not supported", found in review). The scheme
/// run's `defaults export` and `cmp` cover the time between tests.
///
/// A real running Gitter that writes its domain during a test (a window of about 20 ms) can make
/// this check fail when the test wrote nothing: a false positive.
struct LeavesTheDomainUnchanged: SuiteTrait, TestTrait, TestScoping {
    static let realDomain = "dev.penzin.Gitter"

    let domain: String

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await checkingDomainUnchanged(domain, function)
    }
}

extension Trait where Self == LeavesTheDomainUnchanged {
    /// The real domain, before and after each of the suite's tests.
    static var leavesTheRealDefaultsAlone: Self { Self(domain: LeavesTheDomainUnchanged.realDomain) }
}

/// A `WindowRegistry` for a test (E2 Task 3): on a fresh `ScratchDefaults` suite, never `.standard`,
/// under `TestGitEnvironment.isolated`. `remove()` closes every store it made — stopping their
/// watchers — and removes the suite.
@MainActor
struct TestRegistry {
    let scratch = ScratchDefaults()
    let registry: WindowRegistry

    init(recordsOpenList: Bool = true) {
        precondition(TestGitEnvironment.isolated)
        registry = WindowRegistry(defaults: scratch.defaults, recordsOpenList: recordsOpenList)
    }

    var defaults: UserDefaults { scratch.defaults }

    /// What the suite holds under the open list's key, as written: nil when nothing was ever written.
    var storedList: Any? { defaults.object(forKey: WindowRegistry.openRepositoriesKey) }

    /// A new registered store with `repo` open and idle (`open(_:_:sourceLocation:)`).
    func opened(_ repo: ScratchRepo, sourceLocation: SourceLocation = #_sourceLocation) async -> RepositoryStore {
        let store = registry.makeStore()
        await open(store, repo.url, sourceLocation: sourceLocation)
        return store
    }

    func remove() {
        for store in registry.stores { store.close() }
        scratch.remove()
    }
}

/// The path a window shows for `repo`: what the open list holds.
func shownPath(_ repo: ScratchRepo) -> String { RepositoryWindow(url: repo.url).path }
