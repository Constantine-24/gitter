import Foundation
import Testing

@testable import Gitter

/// E2 Task 3: Gitter's own list of the repositories its windows show (`openRepositoryPaths`), which
/// launch reopens instead of macOS restoration. What changes it — an open adds, a replace swaps in
/// place, a window's close removes, nothing is removed while the app terminates — and what launch
/// makes of it (RF5): a vanished folder, a folder with no `.git`, duplicates and a value that is no
/// list are skipped, the list is rewritten clean, and with nothing left `lastRepositoryPath` is
/// reopened, as before E2.
///
/// Every registry here is a scratch one (`TestRegistry`); none writes the user's domain.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct OpenRepositoriesListTests {

    /// Three repositories with a commit each.
    private static func repos() throws -> (ScratchRepo, ScratchRepo, ScratchRepo) {
        let a = try ScratchRepo("a")
        let b = try ScratchRepo("b")
        let c = try ScratchRepo("c")
        for repo in [a, b, c] { try repo.commit("f.txt", "one\n", "first") }
        return (a, b, c)
    }

    // MARK: - What changes it

    @Test(.timeLimit(.minutes(10))) func anOpenAddsAndAReplaceSwapsInPlace() async throws {
        let (a, b, c) = try Self.repos()
        defer { [a, b, c].forEach { $0.remove() } }
        let test = TestRegistry()
        defer { test.remove() }

        let one = await test.opened(a)
        #expect(test.registry.openRepositoryPaths == [shownPath(a)])
        let two = await test.opened(b)
        #expect(test.registry.openRepositoryPaths == [shownPath(a), shownPath(b)])

        await open(one, c.url)
        #expect(test.registry.openRepositoryPaths == [shownPath(c), shownPath(b)])
        // Reopening what a window already shows changes nothing.
        await open(two, b.url)
        #expect(test.registry.openRepositoryPaths == [shownPath(c), shownPath(b)])
        #expect(test.storedList as? [String] == [shownPath(c), shownPath(b)])
    }

    @Test(.timeLimit(.minutes(10))) func theListHoldsNoDuplicates() async throws {
        let (a, b, c) = try Self.repos()
        defer { [a, b, c].forEach { $0.remove() } }
        let test = TestRegistry()
        defer { test.remove() }
        let one = await test.opened(a)
        let two = await test.opened(b)

        // The second window switches to what the first shows: one entry for it, and `b` is gone.
        await open(two, a.url)
        #expect(test.registry.openRepositoryPaths == [shownPath(a)])
        // The first leaves `a`, which the second still shows: `a` stays, `c` is added once.
        await open(one, c.url)
        #expect(test.registry.openRepositoryPaths == [shownPath(a), shownPath(c)])
        // A third window on `c` through a link adds nothing.
        let link = c.directory.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: c.url)
        let three = test.registry.makeStore()
        await open(three, link)
        #expect(test.registry.openRepositoryPaths == [shownPath(a), shownPath(c)])
    }

    @Test(.timeLimit(.minutes(10))) func aClosedWindowLeavesTheListUnlessAnotherShowsIt() async throws {
        let (a, b, c) = try Self.repos()
        defer { [a, b, c].forEach { $0.remove() } }
        let test = TestRegistry()
        defer { test.remove() }
        let one = await test.opened(a)
        let two = await test.opened(b)
        let three = await test.opened(c)
        let alsoB = test.registry.makeStore()
        await open(alsoB, b.url)
        #expect(test.registry.openRepositoryPaths == [shownPath(a), shownPath(b), shownPath(c)])

        test.registry.windowClosed(two)
        #expect(test.registry.openRepositoryPaths == [shownPath(a), shownPath(b), shownPath(c)], "b is still shown")
        test.registry.windowClosed(one)
        #expect(test.registry.openRepositoryPaths == [shownPath(b), shownPath(c)])
        test.registry.windowClosed(alsoB)
        test.registry.windowClosed(three)
        #expect(test.registry.openRepositoryPaths == [])
        #expect(test.storedList as? [String] == [])
    }

    @Test(.timeLimit(.minutes(10))) func whileTheAppTerminatesNothingIsRemoved() async throws {
        let (a, b, c) = try Self.repos()
        defer { [a, b, c].forEach { $0.remove() } }
        let test = TestRegistry()
        defer { test.remove() }
        let one = await test.opened(a)
        let two = await test.opened(b)

        test.registry.beginAppTermination()
        #expect(test.registry.isTerminating)
        test.registry.windowClosed(one)
        test.registry.windowClosed(two)
        #expect(one.isClosed && two.isClosed)
        #expect(test.registry.openRepositoryPaths == [shownPath(a), shownPath(b)])

        // Called off: closing removes again.
        test.registry.endAppTermination()
        #expect(!test.registry.isTerminating)
        let three = await test.opened(c)
        test.registry.windowClosed(three)
        #expect(test.registry.openRepositoryPaths == [shownPath(a), shownPath(b)])
    }

    /// A scripted launch and the test host keep no list (Ruling 4): nothing is written under the
    /// key through an open, a replace, a close, or launch's clean-up.
    @Test(.timeLimit(.minutes(10))) func aRegistryThatKeepsNoListNeverWritesIt() async throws {
        let (a, b, c) = try Self.repos()
        defer { [a, b, c].forEach { $0.remove() } }
        let test = TestRegistry(recordsOpenList: false)
        defer { test.remove() }

        let one = await test.opened(a)
        await open(one, b.url)
        let two = await test.opened(c)
        test.registry.windowClosed(one)
        test.registry.windowClosed(two)
        #expect(test.storedList == nil)
        #expect(test.registry.openRepositoryPaths == [])

        // A list written by someone else is read, and left as it was.
        test.defaults.set([shownPath(a), "/nowhere", shownPath(a)], forKey: WindowRegistry.openRepositoriesKey)
        #expect(test.registry.launchPaths().map(\.path) == [shownPath(a)])
        #expect(test.storedList as? [String] == [shownPath(a), "/nowhere", shownPath(a)])
    }

    // MARK: - Launch (RF5)

    @Test func launchSkipsEveryBadEntryAndRewritesTheListClean() throws {
        let (a, b, c) = try Self.repos()
        defer { [a, b, c].forEach { $0.remove() } }
        let test = TestRegistry()
        defer { test.remove() }
        let vanished = c.url.path
        c.remove()
        let plain = a.directory.appending(path: "plain")
        try FileManager.default.createDirectory(at: plain, withIntermediateDirectories: true)
        let link = b.directory.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: b.url)
        test.defaults.set(
            [
                a.url.path, vanished, plain.path, a.url.path + "/", b.url.path, link.path,
                a.url.appending(path: "x/..").path,
            ],
            forKey: WindowRegistry.openRepositoriesKey)

        let paths = test.registry.launchPaths()

        #expect(paths.map(\.path) == [shownPath(a), shownPath(b)])
        #expect(test.storedList as? [String] == [shownPath(a), shownPath(b)])
    }

    @Test func launchKeepsTheListsOrder() throws {
        let (a, b, c) = try Self.repos()
        defer { [a, b, c].forEach { $0.remove() } }
        let test = TestRegistry()
        defer { test.remove() }
        test.defaults.set([c.url.path, a.url.path, b.url.path], forKey: WindowRegistry.openRepositoriesKey)

        #expect(test.registry.launchPaths().map(\.path) == [shownPath(c), shownPath(a), shownPath(b)])
    }

    @Test func aValueThatIsNoListFallsBackToTheLastRepository() throws {
        let (a, b, c) = try Self.repos()
        defer { [a, b, c].forEach { $0.remove() } }
        let test = TestRegistry()
        defer { test.remove() }
        test.defaults.set(b.url.path, forKey: RepositoryStore.lastRepositoryPathKey)
        test.defaults.set("not a list", forKey: WindowRegistry.openRepositoriesKey)

        #expect(test.registry.launchPaths().map(\.path) == [b.url.path])
        #expect(test.storedList as? [String] == [])
    }

    @Test func anEmptyListFallsBackToTheLastRepository() throws {
        let (a, b, c) = try Self.repos()
        defer { [a, b, c].forEach { $0.remove() } }
        let test = TestRegistry()
        defer { test.remove() }
        test.defaults.set([String](), forKey: WindowRegistry.openRepositoriesKey)
        #expect(test.registry.launchPaths().isEmpty, "nothing to reopen at all")

        test.defaults.set(a.url.path, forKey: RepositoryStore.lastRepositoryPathKey)
        #expect(test.registry.launchPaths().map(\.path) == [a.url.path])
        // A list whose every entry is bad is as good as empty.
        test.defaults.set(["/nowhere", b.directory.path], forKey: WindowRegistry.openRepositoriesKey)
        #expect(test.registry.launchPaths().map(\.path) == [a.url.path])
        #expect(test.storedList as? [String] == [])
        // No list at all: the last repository, and nothing is written.
        test.defaults.removeObject(forKey: WindowRegistry.openRepositoriesKey)
        #expect(test.registry.launchPaths().map(\.path) == [a.url.path])
        #expect(test.storedList == nil)
    }

    /// The reopen keeps its refusal: under the test host (and a scripted launch) the launch paths
    /// are never even read, so the list is not rewritten either; and nothing is opened.
    @Test func theReopenAsksForNoLaunchPathsWhenItIsRefused() throws {
        let (a, b, c) = try Self.repos()
        defer { [a, b, c].forEach { $0.remove() } }
        let test = TestRegistry()
        defer { test.remove() }
        let store = test.registry.makeStore()
        var asked = 0

        let rest = store.reopenLastRepository {
            asked += 1
            return [a.url, b.url]
        }

        #expect(asked == 0)
        #expect(rest.isEmpty)
        #expect(store.root == nil)
    }
}
