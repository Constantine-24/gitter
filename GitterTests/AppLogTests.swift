import AppKit
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
        #expect(Self.windowLines(recorder) == ["open \(path)"])
        test.registry.windowClosed(store)
        #expect(Self.windowLines(recorder) == ["open \(path)", "close \(path)"])
        test.registry.windowClosed(store)
        #expect(Self.windowLines(recorder).count == 2, "a second close does nothing")
    }

    /// M6: a window switched to another repository closes the one it showed, before it opens the next.
    @Test(.timeLimit(.minutes(10))) func aSwitchToAnotherRepositoryClosesTheOldOneFirst() async throws {
        let first = try ScratchRepo("first")
        defer { first.remove() }
        let second = try ScratchRepo("second")
        defer { second.remove() }
        try first.commit("a.txt", "one\n", "first")
        try second.commit("b.txt", "one\n", "first")
        let recorder = RecordingEventLog()
        let test = TestRegistry(eventLog: recorder.eventLog)
        defer { test.remove() }

        let store = await test.opened(first)
        let firstPath = try #require(store.root?.path)
        await open(store, second.url)
        let secondPath = try #require(store.root?.path)
        #expect(firstPath != secondPath)
        #expect(Self.windowLines(recorder) == ["open \(firstPath)", "close \(firstPath)", "open \(secondPath)"])

        // The same repository again is a reopen: an open, and no close.
        await open(store, second.url)
        #expect(Self.windowLines(recorder).suffix(2) == ["open \(secondPath)", "open \(secondPath)"])
    }

    /// I2: at a quit that goes ahead, every open window's close is given to the log then — before
    /// the terminate path's flush — and not again when its window closes during the teardown.
    @Test(.timeLimit(.minutes(10))) func aQuitTellsEveryOpenWindowsCloseOnce() async throws {
        let first = try ScratchRepo("first")
        defer { first.remove() }
        let second = try ScratchRepo("second")
        defer { second.remove() }
        try first.commit("a.txt", "one\n", "first")
        try second.commit("b.txt", "one\n", "first")
        let recorder = RecordingEventLog()
        let test = TestRegistry(eventLog: recorder.eventLog)
        defer { test.remove() }
        let one = await test.opened(first)
        let two = await test.opened(second)
        let empty = test.registry.makeStore()
        let paths = [try #require(one.root?.path), try #require(two.root?.path)]

        test.registry.beginAppTermination()
        #expect(Self.windowLines(recorder).filter { $0.hasPrefix("close ") } == paths.map { "close \($0)" })
        test.registry.beginAppTermination()
        test.registry.windowClosed(one)
        test.registry.windowClosed(two)
        test.registry.windowClosed(empty)
        #expect(Self.windowLines(recorder).filter { $0.hasPrefix("close ") } == paths.map { "close \($0)" })
        test.registry.endAppTermination()
    }

    /// The control for the quit's check: without the quit, nothing is closed and no close is told.
    @Test(.timeLimit(.minutes(10))) func theQuitsCloseCheckCanFail() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let recorder = RecordingEventLog()
        let test = TestRegistry(eventLog: recorder.eventLog)
        defer { test.remove() }
        let store = await test.opened(repo)
        let path = try #require(store.root?.path)
        withKnownIssue("no quit began, so no close was told") {
            #expect(Self.windowLines(recorder).contains("close \(path)"))
        }
    }

    /// The registry's lines about windows: its opens and closes, whatever else a refresh tells.
    static func windowLines(_ recorder: RecordingEventLog) -> [String] {
        recorder.lines.filter { $0.hasPrefix("open ") || $0.hasPrefix("close ") }
    }

    // MARK: - The quit question (M2, M3)

    @Test func eachQuitAnswerIsOneLineWithItsButton() {
        let cases: [(NSApplication.ModalResponse, QuitGuard.Answer, String)] = [
            (.alertFirstButtonReturn, .wait, RemoteWording.quitWait),
            (.alertSecondButtonReturn, .stopAndQuit, RemoteWording.quitStop),
            (.alertThirdButtonReturn, .dontQuit, RemoteWording.quitCancel),
            (.abort, .dontQuit, RemoteWording.quitCancel),
        ]
        for (response, answer, title) in cases {
            let recorder = RecordingEventLog()
            #expect(QuitGuard.answer(response, toldTo: recorder.eventLog) == answer)
            #expect(recorder.lines == ["quit question: \(title)"])
        }
    }

    // MARK: - Where the writer writes (M5)

    @Test func aTestHostOrAScriptedLaunchWithoutItsOwnFolderHasNoWriter() throws {
        #expect(AppLog.writerFolder(environment: [:], isRunningTests: true) == nil)
        #expect(AppLog.writerFolder(environment: ["GITTER_LOG_DIR": "/tmp/x"], isRunningTests: true) == nil)
        let plain = try #require(AppLog.writerFolder(environment: [:], isRunningTests: false))
        #expect(plain.path.hasSuffix("Library/Logs/Gitter"))
        #if DEBUG
            #expect(AppLog.writerFolder(environment: ["GITTER_DEBUG_OPEN": "/tmp/fixture"], isRunningTests: false) == nil)
            #expect(AppLog.writerFolder(environment: ["GITTER_DEBUG_THEN": ""], isRunningTests: false) == nil)
            #expect(
                AppLog.writerFolder(
                    environment: ["GITTER_DEBUG_OPEN": "/tmp/fixture", "GITTER_LOG_DIR": ""], isRunningTests: false) == nil)
            #expect(
                AppLog.writerFolder(
                    environment: ["GITTER_DEBUG_OPEN": "/tmp/fixture", "GITTER_LOG_DIR": "/tmp/x"], isRunningTests: false)?
                    .path == "/tmp/x")
        #endif
    }

    // MARK: - Show Logs (M4), through its seam: never the real folder

    @Test func showLogsMakesTheFolderAndOpensItSayingNothing() throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        var opened: [URL] = []
        var told: [String] = []
        AppLog.showLogs(folder: folder.url, open: { opened.append($0); return true }, tell: { told.append($0) })
        #expect(FileManager.default.fileExists(atPath: folder.url.path))
        #expect(opened == [folder.url])
        #expect(told.isEmpty)
    }

    @Test func showLogsSaysSoWhenTheFolderCannotBeMade() throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        try FileManager.default.createDirectory(at: folder.parent, withIntermediateDirectories: true)
        let plain = folder.parent.appending(path: "plain")
        try Data("x".utf8).write(to: plain)
        var opened: [URL] = []
        var told: [String] = []
        AppLog.showLogs(folder: plain.appending(path: "logs"), open: { opened.append($0); return true }, tell: { told.append($0) })
        #expect(opened.isEmpty)
        #expect(told.count == 1)
        #expect(told.first?.contains(plain.appending(path: "logs").path) == true, "\(told)")
    }

    @Test func showLogsSaysSoWhenFinderCannotOpenIt() throws {
        let folder = LogTestFolder()
        defer { folder.remove() }
        var told: [String] = []
        AppLog.showLogs(folder: folder.url, open: { _ in false }, tell: { told.append($0) })
        #expect(told.count == 1)
        #expect(told.first?.contains(folder.url.path) == true, "\(told)")
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
