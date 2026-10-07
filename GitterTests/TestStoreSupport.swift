import Foundation
import GitCore
import Testing

@testable import Gitter

/// A defaults suite of the test's own: `dev.penzin.Gitter.tests.<uuid>`, removed by `remove()`.
///
/// The test host is the app itself (`GitterTests` is hosted by Gitter), so `.standard` in a test
/// is the user's real `dev.penzin.Gitter` domain: their last repository, their merge mode. A
/// store built on one of these reads and writes only the scratch suite (E1 Task 4, S2).
struct ScratchDefaults {
    static let prefix = "dev.penzin.Gitter.tests."

    let suiteName: String
    let defaults: UserDefaults

    init() {
        suiteName = Self.prefix + UUID().uuidString
        guard let defaults = UserDefaults(suiteName: suiteName) else {
            preconditionFailure("no defaults suite \(suiteName)")
        }
        self.defaults = defaults
    }

    /// Empties the suite. cfprefsd still leaves its file in `~/Library/Preferences`, an empty
    /// dictionary, for every suite a test wrote to — written when this process exits, so deleting
    /// it here does not keep it away (measured).
    func remove() {
        defaults.removePersistentDomain(forName: suiteName)
    }
}

/// A store for a test: its defaults are a fresh `ScratchDefaults` suite, never `.standard`, and
/// `cleanup` removes that suite. Every store GitterTests build comes from here.
@MainActor
func makeTestStore(
    backend: RepositoryStore.Backend = CLIGitBackend()
) -> (RepositoryStore, UserDefaults, cleanup: () -> Void) {
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

/// Fails the current test (or suite) when `after` differs from `before` in any key.
func expectUnchanged(
    _ before: DefaultsDomainSnapshot, _ after: DefaultsDomainSnapshot,
    sourceLocation: SourceLocation = #_sourceLocation
) {
    let changed = after.changedKeys(since: before)
    #expect(changed.isEmpty, "the \(after.domain) domain changed: \(changed)", sourceLocation: sourceLocation)
}

/// Runs `function` and fails the current test or suite when `domain` is not the same afterwards.
/// Reads the domain twice and writes nothing.
func checkingDomainUnchanged(
    _ domain: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ function: @Sendable () async throws -> Void
) async throws {
    let before = DefaultsDomainSnapshot.read(domain)
    try await function()
    expectUnchanged(before, DefaultsDomainSnapshot.read(domain), sourceLocation: sourceLocation)
}

/// RF5: a defaults domain read before and after a whole suite and required unchanged — for
/// `.leavesTheRealDefaultsAlone`, the user's real `dev.penzin.Gitter` domain. Read only: nothing
/// here writes the domain it watches. Its control (`DefaultsIsolationTests`) runs the same scope
/// over a scratch suite named like the real one, never the real one.
///
/// A failure here is the suite's issue: Swift Testing reports it and fails its run, but
/// `xcodebuild test` 27 still says TEST SUCCEEDED (measured), so `LeavesTheDomainUnchangedInEachTest`
/// checks every test as well, where a failure fails the scheme.
struct LeavesTheDomainUnchanged: SuiteTrait, TestScoping {
    static let realDomain = "dev.penzin.Gitter"

    let domain: String

    var isRecursive: Bool { false }

    func scopeProvider(for test: Test, testCase: Test.Case?) -> Self? {
        test.isSuite ? self : nil
    }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await checkingDomainUnchanged(domain, function)
    }
}

/// `LeavesTheDomainUnchanged` around each test case of a suite instead of the suite as a whole.
struct LeavesTheDomainUnchangedInEachTest: SuiteTrait, TestTrait, TestScoping {
    let domain: String

    var isRecursive: Bool { true }

    func provideScope(
        for test: Test, testCase: Test.Case?, performing function: @Sendable () async throws -> Void
    ) async throws {
        try await checkingDomainUnchanged(domain, function)
    }
}

extension Trait where Self == LeavesTheDomainUnchanged {
    /// The real domain, before and after the whole suite.
    static var leavesTheRealDefaultsAlone: Self { Self(domain: LeavesTheDomainUnchanged.realDomain) }
}

extension Trait where Self == LeavesTheDomainUnchangedInEachTest {
    /// The real domain, before and after each of the suite's tests.
    static var leavesTheRealDefaultsAloneInEachTest: Self { Self(domain: LeavesTheDomainUnchanged.realDomain) }
}
