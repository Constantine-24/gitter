import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// The store's half of the sidebar (N1 Task 3): the branch activity read beside each snapshot, and
/// the folding kept per repository in the store's defaults. Real git in scratch repositories; the
/// defaults are a scratch suite, never the user's.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct SidebarStoreTests {

    /// `main` with one commit, then `git switch` through `names` in order.
    private static func repo(switching names: [String]) throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.commit("a.txt", "one\n", "first")
        for name in names where name != "main" { try repo.git("branch", name) }
        for name in names { try repo.git("switch", name) }
        return repo
    }

    // MARK: - Activity

    @Test(.timeLimit(.minutes(10))) func recentFollowsSwitchesAfterRefresh() async throws {
        let repo = try Self.repo(switching: ["a", "b", "main"])
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        #expect(store.recentBranches.map(\.name) == ["main", "b", "a"])
    }

    @Test(.timeLimit(.minutes(10))) func aSwitchInATerminalShowsAfterReload() async throws {
        let repo = try Self.repo(switching: ["a", "b", "main"])
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        try repo.git("switch", "a")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.recentBranches.first?.name == "a")
    }

    @Test(.timeLimit(.minutes(10))) func aFailingActivityReadFallsBackAndKeepsTheRefresh() async throws {
        let repo = try Self.repo(switching: ["a", "b", "main"])
        defer { repo.remove() }
        let backend = TestBackend()
        backend.fail(.branchActivity, with: GitError.commandFailed(exitCode: 128, stderr: "injected by the test"))
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        #expect(store.snapshot != nil)
        #expect(store.lastError == nil)
        #expect(store.branchActivity == .none)
        // With no reflog and no tip dates the rest is by name; the current branch stays first.
        #expect(store.recentBranches.map(\.name) == ["main", "a", "b"])
    }

    // MARK: - Folding

    @Test(.timeLimit(.minutes(10))) func foldingIsPerRepository() async throws {
        let a = try Self.repo(switching: [])
        defer { a.remove() }
        let b = try Self.repo(switching: [])
        defer { b.remove() }
        let (store, defaults, cleanup) = makeTestStore()
        defer { cleanup() }
        await open(store, a.url)
        store.setSection(.tags, folded: true)
        #expect(store.sidebarFolding.foldedSections == [.tags])
        await open(store, b.url)
        #expect(store.sidebarFolding.foldedSections.isEmpty)
        await open(store, a.url)
        #expect(store.sidebarFolding.foldedSections == [.tags])
        #expect(SidebarFolding.load(from: defaults, root: a.url).foldedSections == [.tags])
    }

    @Test func oneRepositoryOpenedThroughTwoPathsSharesAnEntry() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let folder = FileManager.default.temporaryDirectory.appending(path: "gitter-fold-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let link = FileManager.default.temporaryDirectory.appending(path: "gitter-link-\(UUID().uuidString)")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: folder)
        defer { try? FileManager.default.removeItem(at: link) }
        SidebarFolding.save(
            SidebarFolding(foldedSections: [.stashes]), to: scratch.defaults, root: link)
        #expect(SidebarFolding.load(from: scratch.defaults, root: folder).foldedSections == [.stashes])
    }

    @Test(.timeLimit(.minutes(10))) func openingWritesNothing() async throws {
        let repo = try Self.repo(switching: ["a", "main"])
        defer { repo.remove() }
        let (store, defaults, cleanup) = makeTestStore()
        defer { cleanup() }
        // Opening records the last repository (not the sidebar's); everything else must stay put.
        func contents() -> [String: Any] {
            var all = defaults.dictionaryRepresentation()
            all[RepositoryStore.lastRepositoryPathKey] = nil
            return all
        }
        let before = contents()
        await open(store, repo.url)
        #expect(NSDictionary(dictionary: contents()).isEqual(to: before))
        #expect(defaults.object(forKey: SidebarFolding.defaultsKey) == nil)

        // Control: the comparison fails when the key IS written.
        withKnownIssue("the comparison must fail when the sidebar key is written") {
            SidebarFolding.save(SidebarFolding(otherExpanded: true), to: defaults, root: repo.url)
            #expect(NSDictionary(dictionary: contents()).isEqual(to: before))
        }
    }

    @Test(.timeLimit(.minutes(10))) func foldingDuringAFilterIsIgnored() async throws {
        let repo = try Self.repo(switching: [])
        defer { repo.remove() }
        let (store, defaults, cleanup) = makeTestStore()
        defer { cleanup() }
        await open(store, repo.url)
        store.sidebarFilter = "ma"
        store.setSection(.tags, folded: true)
        store.setOtherExpanded(true)
        #expect(store.sidebarFolding == SidebarFolding())
        #expect(defaults.object(forKey: SidebarFolding.defaultsKey) == nil)
        // Positive control: the same call lands once the filter is empty.
        store.sidebarFilter = ""
        store.setSection(.tags, folded: true)
        #expect(store.sidebarFolding.foldedSections == [.tags])
    }

    @Test(.timeLimit(.minutes(10))) func vanishedNamesAreDroppedOnTheNextWrite() async throws {
        let repo = try Self.repo(switching: [])
        defer { repo.remove() }
        try repo.git("branch", "feature/one")
        try repo.git("branch", "feature/two")
        let bare = try repo.makeBareRemote(named: "origin")
        try repo.git("remote", "add", "origin", bare.path)
        let (store, defaults, cleanup) = makeTestStore()
        defer { cleanup() }
        await open(store, repo.url)
        store.setFolder("feature", expanded: true)
        #expect(store.sidebarFolding.expandedFolders == ["feature"])

        try repo.git("branch", "-D", "feature/one", "feature/two")
        await store.refresh()
        await waitUntilIdle(store)
        // Nothing is written by the reload itself.
        #expect(SidebarFolding.load(from: defaults, root: repo.url).expandedFolders == ["feature"])
        store.setRemote("origin", expanded: true)
        #expect(store.sidebarFolding.expandedFolders.isEmpty)
        #expect(store.sidebarFolding.expandedRemotes == ["origin"])
        let saved = SidebarFolding.load(from: defaults, root: repo.url)
        #expect(saved.expandedFolders.isEmpty)
        #expect(saved.expandedRemotes == ["origin"])
    }

    @Test(.timeLimit(.minutes(10))) func showAllStashesResetsOnOpen() async throws {
        let a = try Self.repo(switching: [])
        defer { a.remove() }
        let (store, cleanup) = await openedTestStore(a)
        defer { cleanup() }
        #expect(!store.showsAllStashes)
        store.showsAllStashes = true
        store.open(a.url)
        #expect(!store.showsAllStashes)
        await waitUntilIdle(store)
    }
}
