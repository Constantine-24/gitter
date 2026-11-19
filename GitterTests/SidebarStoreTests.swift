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
        #expect(store.recentBranches.map(\.name) == ["main", "b", "a"])
        // Away and back, as a terminal would: a stale read still says main, b, a.
        try repo.git("switch", "a")
        try repo.git("switch", "main")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.recentBranches.map(\.name) == ["main", "a", "b"])
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
        // A write while B is open is B's alone.
        store.setSection(.stashes, folded: true)
        #expect(store.sidebarFolding.foldedSections == [.stashes])
        await open(store, a.url)
        #expect(store.sidebarFolding.foldedSections == [.tags])
        #expect(SidebarFolding.load(from: defaults, root: a.url).foldedSections == [.tags])
        #expect(SidebarFolding.load(from: defaults, root: b.url).foldedSections == [.stashes])
    }

    /// The saved entry for `root`, as stored: what a write would change.
    private static func savedEntry(_ defaults: UserDefaults, _ root: URL) -> Data? {
        defaults.dictionary(forKey: SidebarFolding.defaultsKey)?[SidebarFolding.key(for: root)] as? Data
    }

    /// A click that changes nothing writes nothing — also when the saved folding names a folder
    /// and a remote that are gone: they are dropped with the next real write, never by a no-op.
    @Test(.timeLimit(.minutes(10))) func aClickThatChangesNothingWritesNothingDespiteGoneNames() async throws {
        let repo = try Self.repo(switching: [])
        defer { repo.remove() }
        let (store, defaults, cleanup) = makeTestStore()
        defer { cleanup() }
        let seeded = SidebarFolding(expandedFolders: ["gone"], expandedRemotes: ["ghost"])
        SidebarFolding.save(seeded, to: defaults, root: repo.url)
        let before = Self.savedEntry(defaults, repo.url)
        #expect(before != nil)
        await open(store, repo.url)
        #expect(store.sidebarFolding == seeded)

        // Tags is open already: the same disclosure value set again, as a binding may.
        store.setSection(.tags, folded: false)
        #expect(Self.savedEntry(defaults, repo.url) == before)
        #expect(store.sidebarFolding == seeded)

        // Control: the comparison fails once a real click writes.
        withKnownIssue("the saved entry must differ once a fold is written") {
            store.setSection(.tags, folded: true)
            #expect(Self.savedEntry(defaults, repo.url) == before)
        }
    }

    /// One entry of another type in the saved dictionary never hides or wipes the others: this
    /// repository's entry still loads, and a fold here keeps another repository's entry.
    @Test(.timeLimit(.minutes(10))) func anEntryOfAnotherTypeLeavesTheOthersAlone() async throws {
        let repo = try Self.repo(switching: [])
        defer { repo.remove() }
        let (store, defaults, cleanup) = makeTestStore()
        defer { cleanup() }
        let other = URL(fileURLWithPath: "/gitter-tests/no-such-repository")
        let otherData = try JSONEncoder().encode(SidebarFolding(foldedSections: [.remotes]))
        let mine = try JSONEncoder().encode(SidebarFolding(foldedSections: [.tags]))
        defaults.set(
            [
                "/gitter-tests/not-data": "a string, not Data",
                SidebarFolding.key(for: other): otherData,
                SidebarFolding.key(for: repo.url): mine,
            ], forKey: SidebarFolding.defaultsKey)

        await open(store, repo.url)
        #expect(store.sidebarFolding.foldedSections == [.tags])

        store.setSection(.stashes, folded: true)
        #expect(Self.savedEntry(defaults, other) == otherData)
        #expect(SidebarFolding.load(from: defaults, root: other).foldedSections == [.remotes])
        #expect(SidebarFolding.load(from: defaults, root: repo.url).foldedSections == [.tags, .stashes])
    }

    /// An entry written by another version — a key missing, a section this one does not know —
    /// keeps everything it can read rather than starting over.
    @Test func aSavedEntryKeepsWhatItCanRead() throws {
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let root = URL(fileURLWithPath: "/gitter-tests/some-repository")
        func load(_ json: String) -> SidebarFolding {
            scratch.defaults.set(
                [SidebarFolding.key(for: root): Data(json.utf8)], forKey: SidebarFolding.defaultsKey)
            return SidebarFolding.load(from: scratch.defaults, root: root)
        }
        let missing = load(#"{"foldedSections":["tags"],"expandedFolders":["feature"]}"#)
        #expect(missing == SidebarFolding(foldedSections: [.tags], expandedFolders: ["feature"]))
        let unknown = load(
            #"{"foldedSections":["tags","someday"],"expandedFolders":[],"expandedRemotes":["origin"],"otherExpanded":true}"#)
        #expect(
            unknown == SidebarFolding(foldedSections: [.tags], expandedRemotes: ["origin"], otherExpanded: true))
        // What this version writes reads back whole.
        let full = SidebarFolding(
            foldedSections: [.recent, .worktrees], expandedFolders: ["fix"], expandedRemotes: ["up"], otherExpanded: true)
        #expect(load(String(decoding: try JSONEncoder().encode(full), as: UTF8.self)) == full)
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
        let scratch = ScratchDefaults()
        defer { scratch.remove() }
        let store = makeTestStore(on: scratch)
        let defaults = scratch.defaults
        // Opening records the last repository (not the sidebar's); everything else must stay put.
        // The suite's own domain, without the global and registration ones.
        func contents() -> [String: Any] {
            var all = DefaultsDomainSnapshot.read(scratch.suiteName).contents
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

    /// A click while the filter narrows the sidebar changes nothing, in the store or saved: the
    /// user's folding from before the filter comes back whole once it is cleared.
    @Test(.timeLimit(.minutes(10))) func foldingDuringAFilterIsIgnored() async throws {
        let repo = try Self.repo(switching: [])
        defer { repo.remove() }
        try repo.git("branch", "feature/one")
        try repo.git("branch", "feature/two")
        let bare = try repo.makeBareRemote(named: "origin")
        try repo.git("remote", "add", "origin", bare.path)
        let (store, defaults, cleanup) = makeTestStore()
        defer { cleanup() }
        await open(store, repo.url)
        store.setSection(.tags, folded: true)
        store.setFolder("feature", expanded: true)
        let seeded = SidebarFolding(foldedSections: [.tags], expandedFolders: ["feature"])
        #expect(store.sidebarFolding == seeded)
        let saved = Self.savedEntry(defaults, repo.url)

        store.sidebarFilter = "ma"
        store.setSection(.tags, folded: false)
        store.setSection(.branches, folded: true)
        store.setFolder("feature", expanded: false)
        store.setRemote("origin", expanded: true)
        store.setOtherExpanded(true)
        #expect(store.sidebarFolding == seeded)
        #expect(Self.savedEntry(defaults, repo.url) == saved)

        // Positive control: the same call lands once the filter is empty.
        store.sidebarFilter = ""
        #expect(store.sidebarFolding == seeded)
        store.setSection(.tags, folded: false)
        #expect(store.sidebarFolding.foldedSections.isEmpty)
        #expect(SidebarFolding.load(from: defaults, root: repo.url).expandedFolders == ["feature"])
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

    #if DEBUG
        // MARK: - The harness's clicks

        /// The harness's fold and folder steps refuse, with a line of their own, what a click
        /// could not do: a folder that is not one now, and any fold while the filter narrows the
        /// sidebar (the store would ignore it). A step that can run gets no refusal.
        @Test(.timeLimit(.minutes(10))) func harnessFoldStepsRefuseWhatAClickCouldNotDo() async throws {
            let repo = try Self.repo(switching: [])
            defer { repo.remove() }
            try repo.git("branch", "feature/one")
            try repo.git("branch", "feature/two")
            try repo.git("branch", "solo/one")
            let (store, cleanup) = await openedTestStore(repo)
            defer { cleanup() }
            func refusal(_ command: String, _ rest: String) -> String? {
                DebugLaunchHooks.sidebarClickRefusal(command, rest, store: store)
            }
            #expect(refusal("sidebarfolder", "feature") == nil)
            #expect(refusal("sidebarfolder", "solo") == "sidebarfolder: no folder solo")
            #expect(refusal("sidebarfolder", "nope") == "sidebarfolder: no folder nope")
            #expect(refusal("sidebarfold", "tags") == nil)
            #expect(refusal("sidebarunfold", "tags") == nil)

            store.sidebarFilter = "fe"
            #expect(refusal("sidebarfolder", "feature") == "sidebarfolder: ignored, filtering")
            #expect(refusal("sidebarfold", "tags") == "sidebarfold: ignored, filtering")
            #expect(refusal("sidebarunfold", "tags") == "sidebarunfold: ignored, filtering")
        }
    #endif
}
