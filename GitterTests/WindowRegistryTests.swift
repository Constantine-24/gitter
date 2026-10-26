import AppKit
import Foundation
import Testing

@testable import Gitter

/// E2 Task 3: one store per window. Each window's store is made and registered by a
/// `WindowRegistry`, in order; the stores are independent of each other; a window is found by the
/// repository it shows, compared by resolved path; a window's close reaches the registry once; the
/// DEBUG check counts registered stores; and `QuitGuard` over several stores (Ruling 8).
///
/// Every registry here is a scratch one (`TestRegistry`), on real repositories (`ScratchRepo`).
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct WindowRegistryTests {

    @Test(.timeLimit(.minutes(10))) func twoStoresHoldTheirOwnSheetRootAndLane() async throws {
        let first = try ScratchRepo("first")
        defer { first.remove() }
        let second = try ScratchRepo("second")
        defer { second.remove() }
        let held = try HeldTransport.heldPush(in: first)
        defer { held.letGo() }
        try second.commit("a.txt", "one\n", "first")
        let test = TestRegistry()
        defer { test.remove() }
        let one = await test.opened(first)
        let two = await test.opened(second)

        #expect(test.registry.stores.count == 2)
        #expect(test.registry.stores[0] === one)
        #expect(test.registry.stores[1] === two)
        #expect(one.root.map(RepositoryWindow.init(url:))?.path == shownPath(first))
        #expect(two.root.map(RepositoryWindow.init(url:))?.path == shownPath(second))

        one.activeSheet = .rename("main")
        #expect(two.activeSheet == nil)

        #expect(one.pushBlockedReason == nil)
        one.push()
        await held.waitUntilHeld()
        #expect(one.remoteActivity?.kind == .push)
        #expect(two.remoteActivity == nil)
        #expect(two.laneClaimRefusal(.fetch, holdingMutation: true) == nil, "the other window's lane is its own")

        held.letGo()
        await waitUntilIdle(one)
        #expect(one.remoteActivity == nil)
    }

    /// RF2's half that is here: a repository is found by its resolved path, whichever spelling.
    @Test(.timeLimit(.minutes(10))) func aStoreIsFoundByTheRepositoryItShowsUnderAnySpelling() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let other = try ScratchRepo("other")
        defer { other.remove() }
        try other.commit("a.txt", "one\n", "first")
        let link = repo.directory.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo.url)
        let test = TestRegistry()
        defer { test.remove() }
        let store = await test.opened(repo)
        let empty = test.registry.makeStore()

        #expect(test.registry.store(showing: repo.url) === store)
        #expect(test.registry.store(showing: link) === store)
        #expect(test.registry.store(showing: URL(fileURLWithPath: repo.url.path + "/")) === store)
        #expect(test.registry.store(showing: repo.url.appending(path: "sub/..")) === store)
        #expect(test.registry.store(showing: other.url) == nil)
        #expect(test.registry.stores.last === empty)
        #expect(RepositoryWindow(url: link) == RepositoryWindow(url: repo.url))
    }

    /// A window's `willCloseNotification` closes its store once, and the store has no window from
    /// then on; the `onDisappear` fallback calling `windowClosed` again changes nothing.
    @Test(.timeLimit(.minutes(10))) func aWindowsCloseReachesTheRegistryOnce() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let other = try ScratchRepo("other")
        defer { other.remove() }
        try other.commit("a.txt", "one\n", "first")
        let test = TestRegistry()
        defer { test.remove() }
        let store = await test.opened(repo)
        let staying = await test.opened(other)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        test.registry.attach(window, to: store)
        test.registry.attach(window, to: store)
        #expect(test.registry.window(of: store) === window)
        #expect(test.registry.window(of: staying) == nil)
        #expect(test.registry.openRepositoryPaths == [shownPath(repo), shownPath(other)])

        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)

        #expect(store.isClosed)
        #expect(!staying.isClosed)
        #expect(test.registry.window(of: store) == nil)
        #expect(test.registry.stores.count == 1)
        #expect(test.registry.stores.first === staying)
        #expect(test.registry.openRepositoryPaths == [shownPath(other)])

        // The fallback signal, and the notification again: nothing more happens.
        test.registry.windowClosed(store)
        NotificationCenter.default.post(name: NSWindow.willCloseNotification, object: window)
        #expect(test.registry.stores.count == 1)
        #expect(test.registry.openRepositoryPaths == [shownPath(other)])
    }

    #if DEBUG
        /// The DEBUG check ("every store the app builds is a registered one") holds with two
        /// registered stores, and reports a store built outside a registry. Read without an `await`
        /// in between, so no other test's store can land between the two counts.
        @Test func theDebugCheckHoldsWithTwoRegisteredStores() {
            let test = TestRegistry()
            defer { test.remove() }
            let builtBefore = RepositoryStore.storesBuilt
            let registeredBefore = RepositoryStore.storesRegistered

            _ = test.registry.makeStore()
            _ = test.registry.makeStore()
            let built = RepositoryStore.storesBuilt - builtBefore
            let registered = RepositoryStore.storesRegistered - registeredBefore

            #expect(built == 2)
            #expect(registered == 2)
            #expect(RepositoryStore.storeCheck(built: built, registered: registered) == nil)

            // The control: a store made outside any registry is one the check reports.
            let scratch = ScratchDefaults()
            defer { scratch.remove() }
            _ = RepositoryStore(defaults: scratch.defaults)
            let builtAfter = RepositoryStore.storesBuilt - builtBefore
            let registeredAfter = RepositoryStore.storesRegistered - registeredBefore
            #expect(builtAfter == 3)
            #expect(registeredAfter == 2)
            #expect(RepositoryStore.storeCheck(built: builtAfter, registered: registeredAfter) != nil)
        }
    #endif

    /// The test host is a Gitter launch with one window: its registry is the app's own, on the
    /// user's domain, and must never write the open list there (Ruling 4); its store opens nothing.
    @Test func theTestHostsRegistryKeepsNoOpenList() {
        #expect(!AppModel.windows.recordsOpenList)
        #expect(AppModel.windows.defaults === UserDefaults.standard)
        // The host's one window has a registered store (not an empty list that `allSatisfy` passes).
        #expect(!AppModel.windows.stores.isEmpty)
        #expect(AppModel.windows.stores.allSatisfy { $0.root == nil })
    }

    /// B4 Task 5: a launch asks for a window only when no window has taken the launch and none is
    /// on screen — the launch macOS restores with no window ("Close windows when quitting" off).
    /// A window that took the launch, or one SwiftUI has shown and not yet appeared, asks for none.
    @Test func aLaunchAsksForAWindowOnlyWithNoneTakenAndNoneShown() {
        #expect(WindowRegistry.launchNeedsWindow(launchHandled: false, visibleMainWindows: 0))
        #expect(!WindowRegistry.launchNeedsWindow(launchHandled: false, visibleMainWindows: 1))
        #expect(!WindowRegistry.launchNeedsWindow(launchHandled: true, visibleMainWindows: 0))
        #expect(!WindowRegistry.launchNeedsWindow(launchHandled: true, visibleMainWindows: 1))
    }

    // MARK: - QuitGuard over several stores (Ruling 8)

    /// Under Wait every store's running read is stopped, and only a store that had a write can call
    /// the quit off: a write on one window, a read on another — the read is cancelled, and a failure
    /// banner from the other window does not call off a quit whose write succeeded.
    @Test(.timeLimit(.minutes(10))) func underWaitEveryReadIsStoppedAndOnlyAWritesStoreCallsTheQuitOff() async throws {
        let writing = try ScratchRepo("writing")
        defer { writing.remove() }
        let reading = try ScratchRepo("reading")
        defer { reading.remove() }
        let push = try HeldTransport.heldPush(in: writing)
        defer { push.letGo() }
        let fetch = try HeldTransport.heldFetch(in: reading)
        defer { fetch.letGo() }
        try reading.git("remote", "add", "broken", reading.directory.appending(path: "nowhere.git").path)
        let test = TestRegistry()
        defer { test.remove() }
        let a = await test.opened(writing)
        let b = await test.opened(reading)
        let stores = test.registry.stores
        defer { for store in stores { store.endTerminating() } }

        a.push()
        await push.waitUntilHeld()
        // What `shouldTerminate` takes as it asks.
        let lanes = stores.map(\.remoteActivity)
        #expect(QuitGuard.decision(lanes) == .ask(writeAt: 0))
        let messagesBefore = stores.map(\.laneMessagesToRead)

        // The other window's read fails while the question is up: a banner to read, counted.
        b.fetch(remote: "broken")
        await waitUntilIdle(b)
        #expect(b.lastError != nil)
        #expect(b.laneMessagesToRead == messagesBefore[1] + 1)
        // And another read is running there when Wait is chosen.
        b.fetch()
        await fetch.waitUntilHeld()
        #expect(b.remoteActivity?.kind == .fetch)

        let compared = QuitGuard.beginWaiting(
            stores, writesAsked: lanes.map { $0?.isWrite == true }, messagesBefore: messagesBefore)

        #expect(compared == [messagesBefore[0], nil])
        #expect(stores.allSatisfy { $0.isTerminating })
        await waitUntilLaneFree(b)
        #expect(b.remoteActivity == nil, "the read was not stopped")
        #expect(a.remoteActivity?.kind == .push, "the write was stopped")
        #expect(QuitGuard.storeCallingOff(stores, before: compared) == nil)
        // The control: compared on every store, as before Ruling 8, the read's banner calls it off.
        let everyStore: [Int?] = messagesBefore.map { $0 }
        #expect(QuitGuard.storeCallingOff(stores, before: everyStore) === b)

        push.letGo()
        await waitUntilLaneFree(a)
        #expect(a.laneMessagesToRead == messagesBefore[0], "the push ended with something to read")
        #expect(QuitGuard.storeCallingOff(stores, before: compared) == nil)
    }

    /// Ruling 10: a held quit that a store's lane calls off is never called off silently. With its
    /// window open the message is on screen there; with the window closed — a closed window's
    /// write still runs — the call-off says it in an app-modal alert instead.
    @Test(.timeLimit(.minutes(10))) func aCallOffFromAWindowlessStoreSaysWhyInAnAlert() async throws {
        let quiet = try ScratchRepo("quiet")
        defer { quiet.remove() }
        try quiet.commit("a.txt", "one\n", "first")
        let failing = try ScratchRepo("failing")
        defer { failing.remove() }
        try failing.commit("a.txt", "one\n", "first")
        try failing.git("remote", "add", "broken", failing.directory.appending(path: "nowhere.git").path)
        let test = TestRegistry()
        defer { test.remove() }
        let a = await test.opened(quiet)
        let b = await test.opened(failing)
        let stores = test.registry.stores
        let before: [Int?] = stores.map(\.laneMessagesToRead)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        test.registry.attach(window, to: b)

        #expect(QuitGuard.callingOff(stores, before: before, hasWindow: { _ in true }) == nil, "nothing ended yet")
        b.fetch(remote: "broken")
        await waitUntilIdle(b)
        let told = try #require(b.lastLaneMessageToRead)

        // With its window: the store that ended is the one, and its banner is the message.
        let shown = try #require(QuitGuard.callingOff(stores, before: before) { test.registry.window(of: $0) != nil })
        #expect(shown.store === b)
        #expect(shown.windowlessAlert == nil)

        // Its window closed: the same call-off, said in an alert naming the repository.
        test.registry.windowClosed(b)
        let alerted = try #require(QuitGuard.callingOff(stores, before: before) { test.registry.window(of: $0) != nil })
        #expect(alerted.store === b)
        #expect(alerted.windowlessAlert == RemoteWording.quitCalledOffInClosedWindow(repository: "failing", told: told))
        #expect(a.laneMessagesToRead == before[0])
    }
}
