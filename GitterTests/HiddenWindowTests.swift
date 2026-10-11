import AppKit
import Foundation
import GitCoreTestSupport
import Testing

@testable import GitCore
@testable import Gitter

/// The window side of hiding, recorded instead of done (`HiddenWindowEnvironment`, Ruling 3): what
/// was ordered out, brought to the front and closed for real, and every alert with its answer,
/// which the test gives.
@MainActor final class HiddenWindowRecorder {
    private(set) var orderedOut: [NSWindow] = []
    private(set) var fronted: [NSWindow] = []
    private(set) var closed: [NSWindow] = []
    private(set) var alerts: [String] = []
    /// The last alert's answer: what its Show or Close does.
    private(set) var answer: (@MainActor (HiddenWindowEnvironment.Choice) -> Void)?

    var environment: HiddenWindowEnvironment {
        HiddenWindowEnvironment(
            orderOut: { self.orderedOut.append($0) },
            front: { self.fronted.append($0) },
            realClose: { self.closed.append($0) },
            alert: { text, answer in
                self.alerts.append(text)
                self.answer = answer
            })
    }
}

/// E3 Task 5 (spec Design §3): a window whose store is still working — a write on its lane, or a
/// local change running — hides instead of closing; opening its repository again brings that same
/// window back; when the work ends while it is hidden, the window closes for real, or an alert
/// says what it ended with. The window side goes through `HiddenWindowEnvironment`, recorded here;
/// the work is real git, held through `TestBackend`.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct HiddenWindowTests {

    // MARK: - The close decision

    @Test func onlyAWriteOnTheLaneOrAChangeRunningHidesTheWindow() {
        let fetch = RemoteActivity(kind: .fetch, remote: "origin")
        let autoFetch = RemoteActivity(kind: .autoFetch, remote: nil)
        let push = RemoteActivity(kind: .push, remote: "origin")
        #expect(WindowRegistry.closeDecision(remoteActivity: nil, isMutating: false) == .close)
        #expect(WindowRegistry.closeDecision(remoteActivity: fetch, isMutating: false) == .close)
        #expect(WindowRegistry.closeDecision(remoteActivity: autoFetch, isMutating: false) == .close)
        #expect(WindowRegistry.closeDecision(remoteActivity: push, isMutating: false) == .hide)
        #expect(WindowRegistry.closeDecision(remoteActivity: nil, isMutating: true) == .hide)
        #expect(WindowRegistry.closeDecision(remoteActivity: push, isMutating: true) == .hide)
    }

    // MARK: - How the work ended

    @Test func nothingNewToReadClosesTheWindow() {
        #expect(
            HiddenEnding.decide(
                repository: "repo", errorAtHide: nil, errorNow: nil, messagesAtHide: 2, messagesNow: 2,
                lastMessage: "an older one") == .close)
    }

    @Test func aNewBannerIsTheAlert() {
        #expect(
            HiddenEnding.decide(
                repository: "repo", errorAtHide: nil, errorNow: "Commit failed.", messagesAtHide: 0,
                messagesNow: 0, lastMessage: nil) == .alert("repo: Commit failed."))
        #expect(
            HiddenEnding.decide(
                repository: "repo", errorAtHide: "An older banner.", errorNow: "Commit failed.",
                messagesAtHide: 0, messagesNow: 0, lastMessage: nil) == .alert("repo: Commit failed."))
    }

    @Test func aLaneMessageToReadIsTheAlertInItsOwnWords() {
        #expect(
            HiddenEnding.decide(
                repository: "repo", errorAtHide: nil, errorNow: "The banner.", messagesAtHide: 1,
                messagesNow: 2, lastMessage: "The push was rejected.") == .alert("repo: The push was rejected."))
    }

    @Test func aBannerAlreadyUpBeforeTheHideIsNotToldAgain() {
        #expect(
            HiddenEnding.decide(
                repository: "repo", errorAtHide: "Seen already.", errorNow: "Seen already.", messagesAtHide: 1,
                messagesNow: 1, lastMessage: "Seen already.") == .close)
    }

    @Test func withNoRepositoryTheAlertIsTheMessageAlone() {
        #expect(
            HiddenEnding.decide(
                repository: nil, errorAtHide: nil, errorNow: "Failed.", messagesAtHide: 0, messagesNow: 0,
                lastMessage: nil) == .alert("Failed."))
    }

    // MARK: - The proxy

    /// The proxy answers `windowShouldClose` from the original delegate when it does not hide, and
    /// passes every other delegate call to it (C1: SwiftUI's own delegate implements
    /// `windowShouldClose` and more); the original is held weakly.
    @Test func theProxyForwardsEverythingElseToTheOriginalDelegate() {
        let window = Self.window()
        let original = RecordingDelegate()
        let state = ProxyState()
        let proxy = WindowCloseProxy(original: original, shouldHide: { state.busy }, hide: { state.hides += 1 })

        original.answer = false
        #expect(proxy.windowShouldClose(window) == false, "the original's answer")
        original.answer = true
        #expect(proxy.windowShouldClose(window) == true)
        #expect(original.askedToClose == 2)

        state.busy = true
        #expect(proxy.windowShouldClose(window) == false)
        #expect(state.hides == 1)
        #expect(original.askedToClose == 2, "a hide does not ask the original")

        #expect(proxy.responds(to: #selector(NSWindowDelegate.windowDidResize(_:))))
        #expect(!proxy.responds(to: #selector(NSWindowDelegate.windowDidMiniaturize(_:))))
        let delegate: any NSWindowDelegate = proxy
        delegate.windowDidResize?(Notification(name: NSWindow.didResizeNotification, object: window))
        #expect(original.resized == 1)
    }

    @Test func theProxyKeepsTheOriginalWeaklyAndClosesWithoutOne() {
        let window = Self.window()
        var original: RecordingDelegate? = RecordingDelegate()
        original?.answer = false
        let proxy = WindowCloseProxy(original: original, shouldHide: { false }, hide: {})
        #expect(proxy.windowShouldClose(window) == false)
        original = nil
        #expect(proxy.windowShouldClose(window) == true)
    }

    /// `attach` puts the proxy in as the window's delegate, once, keeping the delegate it found as
    /// the original; a window attached again keeps the same proxy.
    @Test(.timeLimit(.minutes(10))) func attachInstallsTheProxyOnceKeepingTheOriginal() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let test = TestRegistry()
        defer { test.remove() }
        let store = await test.opened(repo)
        let window = Self.window()
        let original = RecordingDelegate()
        original.answer = false
        window.delegate = original

        test.registry.attach(window, to: store)
        let proxy = try #require(window.delegate as? WindowCloseProxy)
        test.registry.attach(window, to: store)
        #expect(window.delegate === proxy)

        #expect(window.delegate?.windowShouldClose?(window) == false, "the original's answer, the store idle")
        #expect(original.askedToClose == 1)
    }

    // MARK: - Close All with a mix (RF3)

    /// RF3: a busy window and an idle one closed together — Close All asks each window in turn —
    /// the busy one hides, the idle one closes; a quit after that brings the hidden one to the
    /// front before asking, so the question has a window.
    @Test(.timeLimit(.minutes(10))) func closeAllHidesTheBusyWindowAndClosesTheIdleOneAndAQuitFrontsTheHidden() async throws {
        let busyRepo = try ScratchRepo("busy")
        defer { busyRepo.remove() }
        _ = try TestBackendTests.remoteOneCommitBehind(busyRepo)
        let idleRepo = try ScratchRepo("idle")
        defer { idleRepo.remove() }
        try idleRepo.commit("a.txt", "one\n", "first")
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let backend = TestBackend()
        let busy = test.registry.makeStore(backend: backend)
        await open(busy, busyRepo.url)
        let idle = await test.opened(idleRepo)
        defer { backend.releaseAll() }
        let busyWindow = Self.window()
        let idleWindow = Self.window()
        test.registry.attach(busyWindow, to: busy)
        test.registry.attach(idleWindow, to: idle)
        let gate = backend.hold(.push)
        busy.push()
        #expect(await waitUntil("the push parked") { gate.waiting })

        // AppKit's own user close, as Close All sends it to each window in turn (C1).
        busyWindow.performClose(nil)
        idleWindow.performClose(nil)

        #expect(recorder.orderedOut == [busyWindow])
        #expect(busy.isHidden)
        #expect(!busy.isClosed)
        #expect(!idle.isHidden)
        #expect(idle.isClosed, "the idle window closed, as before E3")
        #expect(test.registry.openRepositoryPaths == [], "both left the list: the closed one and the hidden one")

        // The quit: its question goes on the hidden window, brought to the front first.
        #expect(QuitGuard.decision(test.registry.stores.map(\.remoteActivity)) == .ask(writeAt: 0))
        #expect(QuitGuard.questionWindow(for: busy, in: test.registry) === busyWindow)
        #expect(recorder.fronted == [busyWindow])
        #expect(!busy.isHidden)
        #expect(test.registry.openRepositoryPaths == [shownPath(busyRepo)])

        gate.release()
        await waitUntilIdle(busy)
        #expect(recorder.closed.isEmpty, "a window back on screen is not closed when its work ends")
        #expect(recorder.alerts.isEmpty)
    }

    /// The control: a window that is not hidden and not on screen (minimized) is asked about
    /// app-modally, as before, and nothing is brought to the front.
    @Test(.timeLimit(.minutes(10))) func aQuitAboutAWindowNotHiddenAndNotOnScreenFrontsNothing() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let store = await test.opened(repo)
        let window = Self.window()
        test.registry.attach(window, to: store)

        #expect(QuitGuard.questionWindow(for: store, in: test.registry) == nil)
        #expect(recorder.fronted.isEmpty)
        let windowless = test.registry.makeStore()
        #expect(QuitGuard.questionWindow(for: windowless, in: test.registry) == nil)
    }

    // MARK: - Opening it again

    /// A hidden store is live: every open of its repository, by any spelling (E2 RF2), fronts it.
    @Test(.timeLimit(.minutes(10))) func everyOpenOfAHiddenWindowsRepositoryFrontsIt() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        _ = try TestBackendTests.remoteOneCommitBehind(repo)
        let link = repo.directory.appending(path: "link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: repo.url)
        let other = try ScratchRepo("other")
        defer { other.remove() }
        try other.commit("a.txt", "one\n", "first")
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let backend = TestBackend()
        let hidden = test.registry.makeStore(backend: backend)
        await open(hidden, repo.url)
        let front = await test.opened(other)
        defer { backend.releaseAll() }
        let window = Self.window()
        test.registry.attach(window, to: hidden)
        let gate = backend.hold(.push)
        hidden.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(hidden.isHidden)

        for spelling in [repo.url, link] {
            for kind in [OpenKind.recentOrFinder, .openPanel, .worktreeNewWindow, .worktreeHere] {
                #expect(test.registry.route(spelling, kind: kind, front: front) == .front(hidden), "\(spelling.path)")
            }
        }
        #expect(recorder.fronted.isEmpty, "route only decides")

        #expect(test.registry.open(link, kind: .recentOrFinder, front: front) == .front(hidden))
        #expect(recorder.fronted == [window])
        #expect(!hidden.isHidden)
        #expect(test.registry.openRepositoryPaths == [shownPath(other), shownPath(repo)])

        gate.release()
        await waitUntilIdle(hidden)
        #expect(recorder.closed.isEmpty)
        #expect(test.registry.stores.contains { $0 === hidden })
    }

    // MARK: - The work ends while hidden

    /// A push that succeeds while its window is hidden: the window closes for real, with no alert,
    /// and the store leaves the registry.
    @Test(.timeLimit(.minutes(10))) func aPushThatSucceedsWhileHiddenClosesTheWindowForReal() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let bare = try TestBackendTests.remoteOneCommitBehind(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { backend.releaseAll() }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })

        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(store.isHidden)
        #expect(test.registry.window(of: store) === window, "a hidden store keeps its window")
        #expect(test.registry.openRepositoryPaths == [])
        #expect(recorder.closed.isEmpty, "nothing is closed while the push runs")

        gate.release()
        await waitUntil("the real close") { !recorder.closed.isEmpty }
        await waitUntilGone(store, from: test.registry)

        #expect(recorder.closed == [window])
        #expect(recorder.alerts.isEmpty)
        #expect(store.isClosed)
        #expect(!store.isHidden)
        #expect(store.lastError == nil)
        #expect(try repo.git("-C", bare.path, "rev-parse", "main") == repo.git("rev-parse", "main"))
        #expect(test.registry.openRepositoryPaths == [])
    }

    /// A push the server refuses while its window is hidden: the alert says so, and nothing is
    /// closed until its Close.
    @Test(.timeLimit(.minutes(10))) func aPushThatFailsWhileHiddenRaisesTheAlertAndClosesOnlyOnItsClose() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.refusingRemote(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { backend.releaseAll() }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)

        gate.release()
        await waitUntil("the alert") { !recorder.alerts.isEmpty }

        let told = try #require(store.lastLaneMessageToRead)
        #expect(recorder.alerts == ["repo: \(told)"])
        #expect(store.lastError != nil)
        #expect(recorder.closed.isEmpty, "not closed before the alert's answer")
        #expect(store.isHidden)
        #expect(test.registry.stores.contains { $0 === store })

        let answer = try #require(recorder.answer)
        answer(.close)
        #expect(recorder.closed == [window])
        await waitUntilGone(store, from: test.registry)
        #expect(recorder.alerts.count == 1)
    }

    /// The alert's Show brings the window back, its banner there; nothing is closed.
    @Test(.timeLimit(.minutes(10))) func theAlertsShowBringsTheWindowBackWithItsBanner() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.refusingRemote(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { backend.releaseAll() }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)
        gate.release()
        await waitUntil("the alert") { !recorder.alerts.isEmpty }

        let answer = try #require(recorder.answer)
        answer(.show)

        #expect(recorder.fronted == [window])
        #expect(!store.isHidden)
        #expect(store.lastError != nil, "the banner is there")
        #expect(test.registry.openRepositoryPaths == [shownPath(repo)])
        #expect(recorder.closed.isEmpty)
        #expect(!store.isClosed)
    }

    /// A local change (a commit) running as the window closes hides it; when the commit ends the
    /// window closes for real and the store is left with nothing running (the B3.1 gap: closed at
    /// once, the commit's ending was dropped and the store stayed mutating).
    @Test(.timeLimit(.minutes(10))) func aCommitThatEndsWhileHiddenClosesTheWindowWithNothingStuck() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.write("a.txt", "two\n")
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { backend.releaseAll() }
        let gate = backend.hold(.commit)
        store.draft.subject = "second"
        store.commit()
        #expect(await waitUntil("the commit parked") { gate.waiting })
        #expect(store.isMutating)
        #expect(store.remoteActivity == nil)

        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(store.isHidden)

        gate.release()
        await waitUntil("the real close") { !recorder.closed.isEmpty }
        await waitUntilGone(store, from: test.registry)

        #expect(!store.isMutating)
        #expect(store.lastError == nil)
        #expect(recorder.alerts.isEmpty)
        #expect(try repo.git("log", "-1", "--format=%s").trimmingCharacters(in: .newlines) == "second")
    }

    /// The control, and what is left of B3.1: a store closed through E2's path (`windowClosed`,
    /// which only the `onDisappear` fallback of a never-attached window still takes for a busy
    /// store) while its commit runs is still left mutating, its ending dropped.
    @Test(.timeLimit(.minutes(10))) func aStoreClosedMidCommitThroughE2sPathIsStillLeftMutating() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.write("a.txt", "two\n")
        let test = TestRegistry()
        defer { test.remove() }
        let backend = TestBackend()
        let store = test.registry.makeStore(backend: backend)
        await open(store, repo.url)
        defer { backend.releaseAll() }
        let gate = backend.hold(.commit)
        store.draft.subject = "second"
        store.commit()
        #expect(await waitUntil("the commit parked") { gate.waiting })

        test.registry.windowClosed(store)
        gate.release()
        await waitUntil("the commit landing") {
            (try? repo.git("log", "-1", "--format=%s").trimmingCharacters(in: .newlines)) == "second"
        }
        // The ending's own turn: anything it would clear is cleared by the next one.
        try await Task.sleep(for: .milliseconds(200))

        withKnownIssue("B3.1: closed at once, a store's local change ends at finishMutation's stale-generation guard") {
            #expect(!store.isMutating)
        }
    }

    // MARK: - RF2: the work ends just as the window comes back

    /// RF2: the hidden window shown again (its `didBecomeKeyNotification`, as SwiftUI's
    /// `openWindow(value:)` shows it, C2), then the push ends: no alert, no real close, the store
    /// no longer hidden and its repository back on the list.
    @Test(.timeLimit(.minutes(10))) func shownAgainBeforeItsPushEndsTheWindowStays() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.refusingRemote(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { backend.releaseAll() }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)
        #expect(store.isHidden)

        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        gate.release()
        await waitUntilIdle(store)

        #expect(!store.isHidden)
        #expect(store.lastError != nil, "the failure is on its banner")
        #expect(recorder.alerts.isEmpty)
        #expect(recorder.closed.isEmpty)
        #expect(test.registry.openRepositoryPaths == [shownPath(repo)])
        #expect(test.registry.stores.contains { $0 === store })
    }

    /// RF2 reversed: the push ends first and the window is closed for real; the open after that
    /// makes a new window.
    @Test(.timeLimit(.minutes(10))) func endedBeforeItIsShownAgainTheOpenMakesANewWindow() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        _ = try TestBackendTests.remoteOneCommitBehind(repo)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await Self.attachedStore(repo, in: test)
        defer { backend.releaseAll() }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)

        gate.release()
        await waitUntilGone(store, from: test.registry)
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)

        #expect(recorder.closed == [window])
        #expect(test.registry.route(repo.url, kind: .recentOrFinder, front: nil) == .newWindow(RepositoryWindow(url: repo.url)))
        #expect(test.registry.openRepositoryPaths == [], "a late signal from the closed window puts nothing back")
    }

    // MARK: - A held quit with two hidden busy stores

    /// Two hidden windows pushing, and a quit: its question fronts the first; under Wait the
    /// second's push is refused by the server while it is still hidden. The failure is told once —
    /// by the hidden ending's alert — and the quit is called off by it without its own windowless
    /// alert: a hidden store counts as having a window in `callingOff(hasWindow:)`.
    @Test(.timeLimit(.minutes(10))) func underAHeldQuitAHiddenWindowsFailureIsToldOnce() async throws {
        let (test, recorder, stores, gates, backends, repos) = try await Self.twoHiddenPushes()
        defer { for repo in repos { repo.remove() } }
        defer { test.remove() }
        defer { for backend in backends { backend.releaseAll() } }
        defer { for store in stores { store.endTerminating() } }
        let lanes = stores.map(\.remoteActivity)
        #expect(QuitGuard.decision(lanes) == .ask(writeAt: 0))
        let messagesBefore = stores.map(\.laneMessagesToRead)
        #expect(QuitGuard.questionWindow(for: stores[0], in: test.registry) != nil)
        #expect(!stores[0].isHidden)
        #expect(stores[1].isHidden)
        let compared = QuitGuard.beginWaiting(
            stores, writesAsked: lanes.map { $0?.isWrite == true }, messagesBefore: messagesBefore)

        gates[1].release()
        await waitUntil("the hidden ending's alert") { !recorder.alerts.isEmpty }

        let calling = try #require(
            QuitGuard.callingOff(stores, before: compared) { test.registry.window(of: $0) != nil })
        #expect(calling.store === stores[1])
        #expect(calling.windowlessAlert == nil, "not told a second time")
        #expect(recorder.alerts == ["refusing: \(try #require(stores[1].lastLaneMessageToRead))"])
    }

    /// The control: the same failure in a store whose window really closed (E2's windowless
    /// store) is told by the quit's own call-off alert, and no hidden ending alerts.
    @Test(.timeLimit(.minutes(10))) func underAHeldQuitAClosedWindowsFailureIsToldByTheCallOff() async throws {
        let (test, recorder, stores, gates, backends, repos) = try await Self.twoHiddenPushes(closeSecond: true)
        defer { for repo in repos { repo.remove() } }
        defer { test.remove() }
        defer { for backend in backends { backend.releaseAll() } }
        defer { for store in stores { store.endTerminating() } }
        let lanes = stores.map(\.remoteActivity)
        let messagesBefore = stores.map(\.laneMessagesToRead)
        let compared = QuitGuard.beginWaiting(
            stores, writesAsked: lanes.map { $0?.isWrite == true }, messagesBefore: messagesBefore)

        gates[1].release()
        await waitUntilLaneFree(stores[1])
        await waitUntil("the closed store's message") { stores[1].laneMessagesToRead != messagesBefore[1] }

        let calling = try #require(
            QuitGuard.callingOff(stores, before: compared) { test.registry.window(of: $0) != nil })
        #expect(calling.store === stores[1])
        #expect(calling.windowlessAlert != nil)
        #expect(recorder.alerts.isEmpty)
    }

    // MARK: - The recorder's control

    /// The recorder's checks can fail: before any ending, nothing is recorded as closed or alerted.
    @Test func theRecorderRecordsOnlyWhatItWasAsked() {
        let recorder = HiddenWindowRecorder()
        let window = Self.window()
        recorder.environment.orderOut(window)
        #expect(recorder.orderedOut == [window])
        withKnownIssue("nothing was closed or alerted") {
            #expect(recorder.closed == [window])
            #expect(!recorder.alerts.isEmpty)
        }
    }

    // MARK: - Fixtures

    static func window() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled, .closable],
            backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        return window
    }

    /// A store on `repo` made by `test`'s registry through a fresh `TestBackend`, opened, idle and
    /// attached to a window of its own.
    static func attachedStore(
        _ repo: ScratchRepo, in test: TestRegistry, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> (RepositoryStore, TestBackend, NSWindow) {
        let backend = TestBackend()
        let store = test.registry.makeStore(backend: backend)
        await open(store, repo.url, sourceLocation: sourceLocation)
        let window = window()
        test.registry.attach(window, to: store)
        return (store, backend, window)
    }

    /// `remoteOneCommitBehind`'s repository, its bare remote refusing every push (`pre-receive`).
    static func refusingRemote(_ repo: ScratchRepo) throws {
        let bare = try TestBackendTests.remoteOneCommitBehind(repo)
        let hook = bare.appending(path: "hooks/pre-receive")
        try "#!/bin/sh\necho 'refused by the test' >&2\nexit 1\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
    }

    /// Two stores, "accepting" and "refusing", each pushing on a hold and its window hidden by a
    /// close — or, with `closeSecond`, the second's window closed through E2's path instead.
    static func twoHiddenPushes(closeSecond: Bool = false) async throws -> (
        TestRegistry, HiddenWindowRecorder, [RepositoryStore], [StuckCall], [TestBackend], [ScratchRepo]
    ) {
        let accepting = try ScratchRepo("accepting")
        _ = try TestBackendTests.remoteOneCommitBehind(accepting)
        let refusing = try ScratchRepo("refusing")
        try refusingRemote(refusing)
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        var stores: [RepositoryStore] = []
        var gates: [StuckCall] = []
        var backends: [TestBackend] = []
        for repo in [accepting, refusing] {
            let (store, backend, window) = await attachedStore(repo, in: test)
            let gate = backend.hold(.push)
            store.push()
            #expect(await waitUntil("the push parked") { gate.waiting })
            if closeSecond, repo.url == refusing.url {
                test.registry.windowClosed(store)
            } else {
                #expect(window.delegate?.windowShouldClose?(window) == false)
                #expect(store.isHidden)
            }
            stores.append(store)
            gates.append(gate)
            backends.append(backend)
        }
        return (test, recorder, stores, gates, backends, [accepting, refusing])
    }
}

/// What a test's proxy is told to answer, and how often it hid.
@MainActor final class ProxyState {
    var busy = false
    var hides = 0
}

/// A window delegate that answers `windowShouldClose` as told and counts what reaches it.
@MainActor final class RecordingDelegate: NSObject, NSWindowDelegate {
    var answer = true
    private(set) var askedToClose = 0
    private(set) var resized = 0

    func windowShouldClose(_ sender: NSWindow) -> Bool {
        askedToClose += 1
        return answer
    }

    func windowDidResize(_ notification: Notification) {
        resized += 1
    }
}
