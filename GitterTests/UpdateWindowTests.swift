import AppKit
import Testing

@testable import Gitter

/// The URLs an opener was handed, in order.
@MainActor final class RecordingOpener {
    private(set) var opened: [URL] = []
    var opener: UpdateOpener { UpdateOpener { [self] url in opened.append(url) } }
}

/// Update notices Task 3: the update window's buttons and how it is ordered on screen, with a
/// recording opener and a checker on scratch defaults (never the app's own, which is nil under the
/// test host). No request is ever sent, and the real `NSWorkspace.open` never runs.
@MainActor @Suite(.leavesTheRealDefaultsAlone, .serialized) struct UpdateWindowTests {

    static let running = ReleaseVersion("0.2.0")!

    static func release(_ tag: String) -> LatestRelease {
        LatestRelease(
            tag: tag, version: ReleaseVersion(tag)!,
            downloadURL: URL(string: "https://github.com/Constantine-24/gitter/releases/download/\(tag)/Gitter.dmg")!,
            pageURL: URL(string: "https://github.com/Constantine-24/gitter/releases/tag/\(tag)")!,
            notes: "Notes for \(tag).")
    }

    /// The checker is reached through the controller's closure, as `AppModel.updates` is.
    @MainActor final class CheckerBox {
        var checker: UpdateChecker?
    }

    /// One controller and one checker on a scratch suite. Call `tearDown()` at the end.
    @MainActor struct Rig {
        let scratch = ScratchDefaults()
        let recorder = RecordingOpener()
        let log = RecordingEventLog()
        let box = CheckerBox()
        let fetcher: FakeFetcher
        let controller: UpdatePanelController
        let checker: UpdateChecker

        init(fetcher: FakeFetcher = FakeFetcher([])) {
            self.fetcher = fetcher
            let box = box
            controller = UpdatePanelController(checker: { box.checker }, opener: recorder.opener, log: log.eventLog)
            checker = UpdateChecker(
                defaults: scratch.defaults, running: UpdateWindowTests.running, fetcher: fetcher,
                presenter: controller, log: log.eventLog)
            box.checker = checker
        }

        var defaults: UserDefaults { scratch.defaults }
        var domain: [String: Any]? { defaults.persistentDomain(forName: scratch.suiteName) }

        func tearDown() {
            controller.panel?.close()
            scratch.remove()
        }
    }

    @Test func downloadOpensTheDownloadURLAndCloses() {
        let rig = Rig()
        defer { rig.tearDown() }
        let release = Self.release("v0.3.0")
        rig.controller.show(release, running: Self.running, manual: false)
        #expect(rig.controller.isShowing)
        #expect(rig.controller.shownVersion == release.version)

        rig.controller.press(.download)
        #expect(rig.recorder.opened == [release.downloadURL])
        #expect(!rig.controller.isShowing)
        #expect(rig.controller.panel?.isVisible == false)
        #expect(rig.controller.shownVersion == nil)
        #expect(rig.log.lines == ["update window: Download — v0.3.0"])
    }

    @Test func releasePageOpensThePageAndStays() {
        let rig = Rig()
        defer { rig.tearDown() }
        let release = Self.release("v0.3.0")
        rig.controller.show(release, running: Self.running, manual: false)

        rig.controller.press(.releasePage)
        #expect(rig.recorder.opened == [release.pageURL])
        #expect(rig.controller.isShowing)
        #expect(rig.controller.panel?.isVisible == true)
        #expect(rig.controller.shownVersion == release.version)
    }

    @Test func laterAndCloseStoreNothing() {
        let rig = Rig()
        defer { rig.tearDown() }
        // A key already there, so "unchanged" compares a domain that holds something.
        rig.defaults.set(Date(timeIntervalSince1970: 1_000), forKey: UpdateChecker.lastCheckKey)
        let before = rig.domain.map { NSDictionary(dictionary: $0) }
        #expect(before?.count == 1)
        let release = Self.release("v0.3.0")

        rig.controller.show(release, running: Self.running, manual: false)
        rig.controller.press(.later)
        #expect(!rig.controller.isShowing)
        #expect(rig.domain.map { NSDictionary(dictionary: $0) } == before)

        rig.controller.show(release, running: Self.running, manual: false)
        #expect(rig.controller.isShowing)
        rig.controller.press(.close)
        #expect(!rig.controller.isShowing)
        #expect(rig.domain.map { NSDictionary(dictionary: $0) } == before)
        #expect(rig.defaults.string(forKey: UpdateChecker.skippedKey) == nil)
        #expect(rig.recorder.opened.isEmpty)
        #expect(rig.log.lines == ["update window: Later — v0.3.0", "update window: closed — v0.3.0"])
    }

    @Test func skipStoresTheVersion() {
        let rig = Rig()
        defer { rig.tearDown() }
        #expect(rig.defaults.string(forKey: UpdateChecker.skippedKey) == nil)
        rig.controller.show(Self.release("v0.3.0"), running: Self.running, manual: false)

        rig.controller.press(.skip)
        #expect(rig.defaults.string(forKey: UpdateChecker.skippedKey) == "0.3.0")
        #expect(!rig.controller.isShowing)
        #expect(rig.recorder.opened.isEmpty)
    }

    @Test func aSecondResultUpdatesTheOpenPanel() {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.controller.show(Self.release("v0.3.0"), running: Self.running, manual: false)
        let first = rig.controller.panel
        #expect(first != nil)

        rig.controller.show(Self.release("v0.4.0"), running: Self.running, manual: false)
        #expect(rig.controller.panel === first)
        #expect(rig.controller.shownVersion == ReleaseVersion("0.4.0"))
        let shown = NSApp.windows.filter { $0.isVisible && $0.title == UpdateWording.windowTitle }
        #expect(shown.count == 1)

        // The buttons act on the newer one.
        rig.controller.press(.download)
        #expect(rig.recorder.opened == [Self.release("v0.4.0").downloadURL])
    }

    @Test func thePanelIsNotAMainWindow() throws {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.controller.show(Self.release("v0.3.0"), running: Self.running, manual: false)
        let panel = try #require(rig.controller.panel)
        #expect(panel.canBecomeMain == false)
        #expect(panel.isRestorable == false)
        #expect(panel.isReleasedWhenClosed == false)
        #expect(panel.hidesOnDeactivate == false)
        // Ruling 5: a click into the panel makes it key, so Return reaches Download and ⌘W closes it.
        #expect(panel.becomesKeyOnlyIfNeeded == false)
        #expect(panel.styleMask.contains(.titled) && panel.styleMask.contains(.closable))
        #expect(panel.title == UpdateWording.windowTitle)
        // What `visibleMainWindows()` and the windowless-launch check count.
        #expect(!NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.contains(panel))
        #expect(panel.isVisible)
    }

    /// The ordering call is recorded by the panel itself (`UpdatePanel`), so the test fails if the
    /// automatic branch makes the panel key, whether or not the test host is active.
    @Test func anAutomaticResultDoesNotTakeKey() throws {
        let rig = Rig()
        defer { rig.tearDown() }
        rig.controller.show(Self.release("v0.3.0"), running: Self.running, manual: false)
        let panel = try #require(rig.controller.panel)
        #expect(panel.orderingCalls == [.orderFront])
        // Ruling 9: nor can AppKit make it key by itself (when the key window closes).
        #expect(panel.canBecomeKey == false)
        // A second automatic result (the open window updated) still only orders it to the front.
        rig.controller.show(Self.release("v0.4.0"), running: Self.running, manual: false)
        #expect(panel.orderingCalls == [.orderFront, .orderFront])
        #expect(panel.canBecomeKey == false)
        // Secondary only: an inactive test host has no key window either way.
        #expect(panel.isVisible)
        #expect(panel.isKeyWindow == false)

        // A click into the panel lets it become key; a later automatic result takes that back.
        Self.click(panel)
        #expect(panel.canBecomeKey)
        rig.controller.show(Self.release("v0.4.0"), running: Self.running, manual: false)
        #expect(panel.canBecomeKey == false)

        // The control: a manual result makes the panel key, and the panel records that call.
        rig.controller.show(Self.release("v0.4.0"), running: Self.running, manual: true)
        #expect(panel.orderingCalls == [.orderFront, .orderFront, .orderFront, .makeKeyAndOrderFront])
        #expect(panel.canBecomeKey)
    }

    /// A left mouse-down sent through the panel's `sendEvent`, in the content's padding (on no
    /// control), with its mouse-up queued first so no tracking loop waits for one.
    static func click(_ panel: NSWindow) {
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(
                with: type, location: NSPoint(x: 4, y: 4), modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: panel.windowNumber, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1)
        }
        guard let down = event(.leftMouseDown), let up = event(.leftMouseUp) else {
            Issue.record("could not make the mouse events")
            return
        }
        NSApp.postEvent(up, atStart: false)
        panel.sendEvent(down)
    }

    @Test func theScriptedOpenerOnlyLogs() {
        #if DEBUG
            let url = Self.release("v0.3.0").downloadURL
            let workspace = RecordingOpener()
            let log = RecordingEventLog()
            let scripted = UpdateOpener.live(
                environment: ["GITTER_DEBUG_OPEN": "/x"], log: log.eventLog, workspace: workspace.opener.open)
            scripted.open(url)
            #expect(log.lines == ["UPDATE would open \(url.absoluteString)"])
            #expect(workspace.opened.isEmpty)

            // The control: unscripted, the same opener reaches the workspace seam and logs nothing.
            let quiet = RecordingEventLog()
            let real = UpdateOpener.live(environment: [:], log: quiet.eventLog, workspace: workspace.opener.open)
            real.open(url)
            #expect(workspace.opened == [url])
            #expect(quiet.lines.isEmpty)
        #endif
    }

    @Test func checkForUpdatesIsOffWithNoCheckerOrACheckInFlight() async {
        #expect(UpdateCommands.checkIsOff(nil))
        let rig = Rig(fetcher: FakeFetcher([UpdateCheckerTests.release("v0.2.0")], gated: true))
        defer { rig.tearDown() }
        #expect(!UpdateCommands.checkIsOff(rig.checker))
        let look = Task { await rig.checker.look(force: true) }
        #expect(await rig.fetcher.entered(1))
        #expect(rig.checker.isChecking)
        #expect(UpdateCommands.checkIsOff(rig.checker))
        rig.fetcher.open()
        _ = await look.value
        #expect(!UpdateCommands.checkIsOff(rig.checker))
    }
}
