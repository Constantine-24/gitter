import Foundation
import Testing

@testable import Gitter

/// E2 Task 3, RF3: a closed window keeps its view tree (M3.2), so its store is closed explicitly
/// (`close()`): the watcher and the automatic fetch stop, reads are cancelled, the sheet and the
/// notices go, and nothing — a watcher event, a refresh, a tick of the schedule, an open — acts for
/// it again. A write on its lane is not cancelled: the store stays registered, and `QuitGuard`
/// sees it, until the write's own completion frees the lane; then it leaves.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct StoreCloseTests {

    @Test(.timeLimit(.minutes(10))) func closeStopsTheWatcherAndTheScheduleAndDropsTheSheetAndNotices() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let test = TestRegistry()
        defer { test.remove() }
        let store = await test.opened(repo)
        // The schedule's loop, which the test host never starts on its own (`start(for:)`).
        store.autoFetchScheduler.startLoop(for: store)
        #expect(store.isWatching)
        #expect(store.autoFetchScheduler.isRunning)
        store.activeSheet = .rename("main")
        store.showNotice("done")
        store.showStickyNotice(Notice(text: "kept"))

        store.close()

        #expect(store.isClosed)
        #expect(!store.isWatching)
        #expect(!store.autoFetchScheduler.isRunning)
        #expect(store.activeSheet == nil)
        #expect(store.notice == nil)
        #expect(store.stickyNotice == nil)
        // Nothing starts again: not the schedule, not a sheet.
        store.autoFetchScheduler.startLoop(for: store)
        #expect(!store.autoFetchScheduler.isRunning)
        store.activeSheet = .rename("main")
        #expect(store.activeSheet == nil)
    }

    /// After `close()`: a watcher's event (`scheduleRefresh`), a refresh, a tick of the automatic
    /// fetch and an open all do nothing — and the open list does not regain the path.
    @Test(.timeLimit(.minutes(10))) func nothingActsForAClosedStore() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let bare = try repo.makeBareRemote()
        try repo.git("remote", "add", "origin", bare.path)
        let other = try ScratchRepo("other")
        defer { other.remove() }
        try other.commit("a.txt", "one\n", "first")
        let test = TestRegistry()
        defer { test.remove() }
        let store = await test.opened(repo)
        // The control: open, a tick of the schedule fetches.
        store.autoFetchTick(timeout: .seconds(60))
        #expect(store.remoteActivity?.kind == .autoFetch)
        await waitUntilIdle(store)

        test.registry.windowClosed(store)
        #expect(test.registry.openRepositoryPaths == [])
        let loads = store.snapshotLoadCount
        let root = store.root

        store.scheduleRefresh(changed: [repo.url.appending(path: ".git/index").path])
        #expect(store.refreshTask == nil)
        await store.refresh()
        #expect(store.snapshotLoadCount == loads)
        store.autoFetchTick(timeout: .seconds(60))
        #expect(store.remoteActivity == nil)
        store.fetch()
        #expect(store.remoteActivity == nil)
        store.open(other.url)
        #expect(store.root == root)
        #expect(test.registry.openRepositoryPaths == [])
        #expect(test.storedList as? [String] == [])
    }

    /// A read on the lane is cancelled by the close, and the store leaves once it has gone.
    @Test(.timeLimit(.minutes(10))) func aReadOnTheLaneIsStoppedByTheClose() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let held = try HeldTransport.heldFetch(in: repo)
        defer { held.letGo() }
        let test = TestRegistry()
        defer { test.remove() }
        let store = await test.opened(repo)
        store.fetch()
        await held.waitUntilHeld()
        #expect(store.remoteActivity?.kind == .fetch)

        test.registry.windowClosed(store)

        await waitUntilGone(store, from: test.registry)
        #expect(store.remoteActivity == nil)
    }

    /// The write is let finish: the closed store stays in `stores` — and in `quitStores()`'s place,
    /// so `QuitGuard` asks about it — until its own completion frees the lane (no `generation` bump
    /// may stop that), and then it leaves.
    @Test(.timeLimit(.minutes(10))) func aWriteOnTheLaneKeepsTheStoreRegisteredUntilItEnds() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let held = try HeldTransport.heldPush(in: repo)
        defer { held.letGo() }
        let other = try ScratchRepo("other")
        defer { other.remove() }
        try other.commit("a.txt", "one\n", "first")
        let test = TestRegistry()
        defer { test.remove() }
        let store = await test.opened(repo)
        let staying = await test.opened(other)
        store.push()
        await held.waitUntilHeld()

        test.registry.windowClosed(store)

        #expect(store.isClosed)
        #expect(store.remoteActivity?.kind == .push, "the write was cancelled")
        #expect(test.registry.stores.count == 2)
        #expect(test.registry.stores.first === store)
        #expect(QuitGuard.decision(test.registry.stores.map(\.remoteActivity)) == .ask(writeAt: 0))
        #expect(test.registry.openRepositoryPaths == [shownPath(other)])

        held.letGo()
        await waitUntilGone(store, from: test.registry)

        #expect(store.remoteActivity == nil)
        #expect(!store.isMutating)
        #expect(test.registry.stores.count == 1)
        #expect(test.registry.stores.first === staying)
        #expect(QuitGuard.decision(test.registry.stores.map(\.remoteActivity)) == .now)
        let bare = repo.directory.appending(path: "origin.git")
        #expect(try repo.git("-C", bare.path, "rev-parse", "main") == repo.git("rev-parse", "main"))
        #expect(test.registry.openRepositoryPaths == [shownPath(other)])
    }

    /// Returns once `store` has left `registry.stores`; a hang is the test's `.timeLimit`.
    private func waitUntilGone(
        _ store: RepositoryStore, from registry: WindowRegistry, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let call = CallUnderTest { @MainActor () -> Bool in
            while registry.stores.contains(where: { $0 === store }), !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(20))
            }
            return !registry.stores.contains { $0 === store }
        }
        if await call.value("the closed store leaving the registry", sourceLocation: sourceLocation) == nil {
            call.cancel()
        }
    }
}
