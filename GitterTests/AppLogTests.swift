import Foundation
import GitCore
import GitCoreTestSupport
import Synchronization
import Testing

@testable import Gitter

/// An `EventLog` that keeps every line it is given, for a store or a registry to write to.
final class RecordingEventLog: Sendable {
    private let kept = Mutex<[String]>([])

    var eventLog: EventLog { EventLog { [self] line in kept.withLock { $0.append(line) } } }
    var lines: [String] { kept.withLock { $0 } }
}

/// P1 Task 2: the app's log as the app wires it — no file under the test host, the folder and its
/// DEBUG override, the launch header with a git that is not there (RF5), and the store's and the
/// registry's events: a banner, a notice, an open, a close and a hidden window's alert, each one
/// line, said once.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct AppLogTests {

    @Test func underTheTestHostThereIsNoFileAndNoSink() {
        #expect(TestHost.isRunningTests)
        #expect(AppLog.writer == nil)
        #expect(AppLog.commandLog is NoCommandLog)
    }

    @Test func theFolderIsTheUsersLogsFolderOrTheDebugOverride() {
        #expect(AppLog.folder(environment: [:]).path.hasSuffix("Library/Logs/Gitter"))
        #expect(AppLog.folder(environment: ["GITTER_LOG_DIR": ""]).path.hasSuffix("Library/Logs/Gitter"))
        #if DEBUG
            #expect(AppLog.folder(environment: ["GITTER_LOG_DIR": "/tmp/x"]).path == "/tmp/x")
        #endif
    }

    /// RF5: a git that fails or is not there gives the header its words, and the header returns.
    @Test(.timeLimit(.minutes(10))) func theHeaderSaysWhenGitIsNotAvailable() async {
        let info: [String: Any] = [
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "412", "GitterCommit": "d410591",
        ]
        let failing = await AppLog.header(info: info, gitPath: "/usr/bin/false")
        #expect(failing.contains("git: not available"), "\(failing)")
        #expect(failing.contains("Gitter 0.1.0 (412, d410591)"), "\(failing)")
        #expect(failing.contains("macOS "), "\(failing)")
        let missing = await AppLog.header(info: info, gitPath: "/nonexistent-\(UUID().uuidString)/git")
        #expect(missing.contains("git: not available"), "\(missing)")
    }

    @Test(.timeLimit(.minutes(10))) func theHeaderHasGitsVersion() async {
        precondition(TestGitEnvironment.isolated)
        let header = await AppLog.header(info: [:], gitPath: "/usr/bin/git")
        #expect(header.contains("git version"), "\(header)")
        #expect(!header.contains("git: not available"))
        #expect(!header.contains("\n"))
    }

    // MARK: - The store's events

    @Test(.timeLimit(.minutes(10))) func aBannerIsOneLineAndItsDismissalNone() {
        let recorder = RecordingEventLog()
        let (store, _, cleanup) = makeTestStore(eventLog: recorder.eventLog)
        defer { cleanup() }

        store.showStickyError("x")
        #expect(recorder.lines.count == 1)
        #expect(recorder.lines.first.map { $0.hasPrefix("banner") && $0.hasSuffix(": x") } == true, "\(recorder.lines)")
        store.showStickyError("x")
        #expect(recorder.lines.count == 1, "the same banner set again is not a new one")
        store.dismissError()
        #expect(recorder.lines.count == 1)
        store.showStickyError("y")
        #expect(recorder.lines.count == 2)
        #expect(recorder.lines.last?.hasSuffix(": y") == true)
    }

    @Test(.timeLimit(.minutes(10))) func aNoticeIsOneLineAndItsDismissalNone() {
        let recorder = RecordingEventLog()
        let (store, _, cleanup) = makeTestStore(eventLog: recorder.eventLog)
        defer { cleanup() }

        store.showNotice("Fetched")
        #expect(recorder.lines.count == 1)
        #expect(recorder.lines.first.map { $0.hasPrefix("notice") && $0.hasSuffix(": Fetched") } == true, "\(recorder.lines)")
        store.dismissNotice()
        #expect(recorder.lines.count == 1)

        store.showStickyNotice(Notice(text: "Pushed"))
        #expect(recorder.lines.count == 2)
        #expect(recorder.lines.last.map { $0.hasPrefix("sticky") && $0.hasSuffix(": Pushed") } == true, "\(recorder.lines)")
        store.dismissStickyNotice()
        #expect(recorder.lines.count == 2)
    }

    /// The control for the store's checks: a store made with `.none` writes to no log, so a
    /// recorder beside it — not given to it — never holds the banner.
    @Test(.timeLimit(.minutes(10))) func theBannerCheckCanFail() {
        let recorder = RecordingEventLog()
        let (store, _, cleanup) = makeTestStore(eventLog: .none)
        defer { cleanup() }
        store.showStickyError("x")
        withKnownIssue("the store was not given the recorder") {
            #expect(recorder.lines.contains { $0.hasSuffix(": x") })
        }
    }

    // MARK: - The registry's events

    @Test(.timeLimit(.minutes(10))) func anOpenAndACloseAreEachOneLineWithThePath() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let recorder = RecordingEventLog()
        let test = TestRegistry(eventLog: recorder.eventLog)
        defer { test.remove() }

        let store = await test.opened(repo)
        let path = try #require(store.root?.path)
        #expect(recorder.lines == ["open \(path)"])
        test.registry.windowClosed(store)
        #expect(recorder.lines == ["open \(path)", "close \(path)"])
        test.registry.windowClosed(store)
        #expect(recorder.lines.count == 2, "a second close does nothing")
    }

    /// The hidden ending's alert, with the button that answered it, after the banner it tells.
    @Test(.timeLimit(.minutes(10))) func aHiddenWindowsAlertIsOneLineWithItsAnswer() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try HiddenWindowTests.refusingRemote(repo)
        let recorder = HiddenWindowRecorder()
        let events = RecordingEventLog()
        let test = TestRegistry(hiddenWindows: recorder.environment, eventLog: events.eventLog)
        defer { test.remove() }
        let (store, backend, window) = await HiddenWindowTests.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        let gate = backend.hold(.push)
        store.push()
        #expect(await waitUntil("the push parked") { gate.waiting })
        #expect(window.delegate?.windowShouldClose?(window) == false)
        gate.release()
        await waitUntil("the alert") { !recorder.alerts.isEmpty }

        let path = try #require(store.root?.path)
        let text = try #require(recorder.alerts.first)
        let answer = try #require(recorder.answer)
        answer(.close)

        let alert = "alert \"\(RemoteWording.closedWindowFailedTitle)\": \(text) → \(RemoteWording.closedWindowClose)"
        #expect(events.lines.filter { $0 == alert }.count == 1, "\(events.lines)")
        let banner = try #require(events.lines.firstIndex { $0.hasPrefix("banner ") })
        let told = try #require(events.lines.firstIndex(of: alert))
        #expect(banner < told)
        #expect(events.lines.first == "open \(path)")
        #expect(events.lines.last == "close \(path)")
    }
}
