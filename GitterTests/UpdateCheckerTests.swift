import Foundation
import Synchronization
import Testing

@testable import Gitter

/// A fetcher that answers from a script, counts its calls, and can hold an answer at a gate until
/// the test opens it. `entered(_:)` waits until the n-th call has arrived (bounded), so a test can
/// act while a check is surely in flight.
final class FakeFetcher: UpdateFetching, Sendable {
    private struct State {
        var answers: [UpdateAnswer]
        var calls = 0
        var gated: Bool
        var waiting: [CheckedContinuation<Void, Never>] = []
    }
    private let state: Mutex<State>

    init(_ answers: [UpdateAnswer], gated: Bool = false) {
        state = Mutex(State(answers: answers, gated: gated))
    }

    var calls: Int { state.withLock { $0.calls } }

    func fetch() async -> UpdateAnswer {
        let answer = state.withLock { s in
            s.calls += 1
            return s.answers.isEmpty ? UpdateAnswer.failure("no scripted answer") : s.answers.removeFirst()
        }
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let hold = state.withLock { s in
                if s.gated { s.waiting.append(c) }
                return s.gated
            }
            if !hold { c.resume() }
        }
        return answer
    }

    /// Lets every held answer go, and every later one through at once.
    func open() {
        let waiting = state.withLock { s in
            s.gated = false
            defer { s.waiting = [] }
            return s.waiting
        }
        for c in waiting { c.resume() }
    }

    /// Whether `n` calls arrived within about two seconds.
    func entered(_ n: Int) async -> Bool {
        for _ in 0..<2_000 {
            if calls >= n { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return calls >= n
    }
}

/// What the checker asked the window and the alerts to do.
@MainActor final class RecordingPresenter: UpdatePresenting {
    struct Shown: Equatable {
        let version: ReleaseVersion
        let running: ReleaseVersion
        let manual: Bool
    }
    var canShowAutomatic = true
    private(set) var shown: [Shown] = []
    private(set) var told: [UpdateOutcome] = []

    func show(_ release: LatestRelease, running: ReleaseVersion, manual: Bool) {
        shown.append(Shown(version: release.version, running: running, manual: manual))
    }

    func tell(_ outcome: UpdateOutcome) { told.append(outcome) }
}

/// Update notices Task 2: the app-wide checker against a fake fetcher — when it checks, one check
/// in flight, manual against automatic, the held result, the skip, the toggle, and the gate that
/// keeps the test host from checking. Scratch defaults only; no request is ever sent.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct UpdateCheckerTests {

    static let now = Date(timeIntervalSince1970: 2_000_000_000)
    static let v020 = ReleaseVersion("0.2.0")!

    static func release(_ tag: String) -> UpdateAnswer {
        .response(
            status: 200,
            body: Data(
                #"{"tag_name":"\#(tag)","html_url":"https://github.com/Constantine-24/gitter/releases/tag/\#(tag)","body":"Notes."}"#
                    .utf8))
    }

    static func v(_ text: String) -> ReleaseVersion { ReleaseVersion(text)! }

    /// Whether a check started without the test's own await (the toggle's look, the loop's) has
    /// completed within about two seconds, so nothing writes to the suite after it is removed.
    static func settled(_ checker: UpdateChecker) async -> Bool {
        for _ in 0..<2_000 {
            if !checker.isChecking { return true }
            try? await Task.sleep(for: .milliseconds(1))
        }
        return !checker.isChecking
    }

    /// One checker on its own scratch suite. Remove `scratch` at the end.
    @MainActor struct Rig {
        let scratch = ScratchDefaults()
        let fetcher: FakeFetcher
        let presenter = RecordingPresenter()
        let log = RecordingEventLog()
        let checker: UpdateChecker

        init(
            _ answers: [UpdateAnswer], gated: Bool = false, running: ReleaseVersion? = UpdateCheckerTests.v020,
            firstLook: Duration = .seconds(10), lookInterval: Duration = .seconds(3600),
            setUp: (UserDefaults) -> Void = { _ in }
        ) {
            fetcher = FakeFetcher(answers, gated: gated)
            setUp(scratch.defaults)
            checker = UpdateChecker(
                defaults: scratch.defaults, running: running, fetcher: fetcher, presenter: presenter,
                log: log.eventLog, now: { UpdateCheckerTests.now }, firstLook: firstLook, lookInterval: lookInterval)
        }

        var defaults: UserDefaults { scratch.defaults }
        var lastCheck: Date? { defaults.object(forKey: UpdateChecker.lastCheckKey) as? Date }
        var skipped: String? { defaults.string(forKey: UpdateChecker.skippedKey) }
    }

    @Test func theFirstLookChecksAndStoresTheDate() async {
        let rig = Rig([Self.release("v0.3.0")])
        defer { rig.scratch.remove() }
        #expect(await rig.checker.look())
        #expect(rig.fetcher.calls == 1)
        #expect(rig.presenter.shown == [.init(version: Self.v("0.3.0"), running: Self.v020, manual: false)])
        #expect(rig.presenter.told.isEmpty)
        #expect(rig.lastCheck == Self.now)
        #expect(rig.log.lines == ["update check (automatic): newer — latest v0.3.0, running 0.2.0"])
        #expect(!rig.checker.isChecking)
    }

    @Test func aLookWithinADayDoesNotFetch() async {
        let rig = Rig([Self.release("v0.3.0")]) {
            $0.set(UpdateCheckerTests.now.addingTimeInterval(-3600), forKey: UpdateChecker.lastCheckKey)
        }
        defer { rig.scratch.remove() }
        #expect(await rig.checker.look() == false)
        #expect(rig.fetcher.calls == 0)
        #expect(rig.presenter.shown.isEmpty)
        #expect(rig.log.lines.isEmpty)
        // Forced, due-ness is skipped.
        #expect(await rig.checker.look(force: true))
        #expect(rig.fetcher.calls == 1)
        #expect(rig.presenter.shown.count == 1)
    }

    @Test func aFailureStillWaitsADay() async {
        let rig = Rig([.failure("The Internet connection appears to be offline."), Self.release("v0.3.0")])
        defer { rig.scratch.remove() }
        #expect(await rig.checker.look())
        #expect(rig.lastCheck == Self.now)
        #expect(rig.presenter.shown.isEmpty)
        #expect(rig.presenter.told.isEmpty)
        #expect(rig.log.lines == ["update check (automatic): unreachable — latest ?, running 0.2.0"])
        #expect(await rig.checker.look() == false)
        #expect(rig.fetcher.calls == 1)
    }

    @Test func aSkippedVersionStaysQuietAutomaticallyButShowsManually() async {
        let rig = Rig([Self.release("v0.3.0"), Self.release("v0.3.0")]) {
            $0.set("0.3.0", forKey: UpdateChecker.skippedKey)
        }
        defer { rig.scratch.remove() }
        #expect(await rig.checker.look())
        #expect(rig.fetcher.calls == 1)
        #expect(rig.presenter.shown.isEmpty)
        #expect(rig.presenter.told.isEmpty)
        #expect(rig.lastCheck == Self.now)
        await rig.checker.checkNowAndWait()
        #expect(rig.fetcher.calls == 2)
        #expect(rig.presenter.shown == [.init(version: Self.v("0.3.0"), running: Self.v020, manual: true)])
        #expect(rig.presenter.told.isEmpty)
        // A manual show of the skipped version itself leaves the skip.
        #expect(rig.skipped == "0.3.0")
    }

    @Test func aNewerVersionClearsTheSkipWhenShown() async {
        let rig = Rig([Self.release("v0.4.0")]) { $0.set("0.3.0", forKey: UpdateChecker.skippedKey) }
        defer { rig.scratch.remove() }
        rig.presenter.canShowAutomatic = false
        #expect(await rig.checker.look())
        #expect(rig.presenter.shown.isEmpty)
        // Held, not shown: the skip stays until it is.
        #expect(rig.skipped == "0.3.0")
        rig.presenter.canShowAutomatic = true
        rig.checker.showHeldIfPossible()
        #expect(rig.presenter.shown == [.init(version: Self.v("0.4.0"), running: Self.v020, manual: false)])
        #expect(rig.skipped == nil)
    }

    /// From Task 1's review: a skip below the running version, and a release equal to the running one.
    @Test func aSkipBelowTheRunningVersionShowsNothing() async {
        let rig = Rig([Self.release("v0.4.0"), Self.release("v0.4.0")], running: Self.v("0.4.0")) {
            $0.set("0.3.0", forKey: UpdateChecker.skippedKey)
        }
        defer { rig.scratch.remove() }
        #expect(await rig.checker.look())
        #expect(rig.presenter.shown.isEmpty)
        #expect(rig.presenter.told.isEmpty)
        await rig.checker.checkNowAndWait()
        #expect(rig.presenter.shown.isEmpty)
        #expect(rig.presenter.told == [.upToDate(Self.v("0.4.0"))])
        #expect(rig.skipped == "0.3.0")
    }

    @Test func aHeldResultShowsWhenThePresenterCanAgain() async {
        let rig = Rig([Self.release("v0.3.0")])
        defer { rig.scratch.remove() }
        rig.presenter.canShowAutomatic = false
        #expect(await rig.checker.look())
        #expect(rig.presenter.shown.isEmpty)
        rig.checker.showHeldIfPossible()
        #expect(rig.presenter.shown.isEmpty)
        rig.presenter.canShowAutomatic = true
        rig.checker.showHeldIfPossible()
        rig.checker.showHeldIfPossible()
        #expect(rig.presenter.shown == [.init(version: Self.v("0.3.0"), running: Self.v020, manual: false)])
    }

    @Test func aLaterHeldResultReplacesAnEarlierOne() async {
        let rig = Rig([Self.release("v0.3.0"), Self.release("v0.4.0")])
        defer { rig.scratch.remove() }
        rig.presenter.canShowAutomatic = false
        #expect(await rig.checker.look(force: true))
        #expect(await rig.checker.look(force: true))
        rig.presenter.canShowAutomatic = true
        rig.checker.showHeldIfPossible()
        #expect(rig.presenter.shown == [.init(version: Self.v("0.4.0"), running: Self.v020, manual: false)])
    }

    @Test func aHeldResultIsDroppedByALaterUpToDateCheckOrASkip() async {
        let rig = Rig([Self.release("v0.3.0"), Self.release("v0.2.0"), Self.release("v0.3.0")])
        defer { rig.scratch.remove() }
        rig.presenter.canShowAutomatic = false
        #expect(await rig.checker.look(force: true))
        #expect(await rig.checker.look(force: true))
        rig.presenter.canShowAutomatic = true
        rig.checker.showHeldIfPossible()
        #expect(rig.presenter.shown.isEmpty)

        rig.presenter.canShowAutomatic = false
        #expect(await rig.checker.look(force: true))
        rig.checker.skip(Self.v("0.3.0"))
        #expect(rig.skipped == "0.3.0")
        rig.presenter.canShowAutomatic = true
        rig.checker.showHeldIfPossible()
        #expect(rig.presenter.shown.isEmpty)
    }

    @Test func aManualCheckDuringAnAutomaticOneAnswersOnce() async {
        let rig = Rig([Self.release("v0.3.0"), Self.release("v0.3.0")], gated: true)
        defer { rig.scratch.remove() }
        let automatic = Task { await rig.checker.look() }
        #expect(await rig.fetcher.entered(1))
        #expect(rig.checker.isChecking)
        rig.checker.checkNow()
        #expect(rig.checker.isChecking)
        rig.fetcher.open()
        #expect(await automatic.value)
        #expect(rig.fetcher.calls == 1)
        #expect(rig.presenter.shown == [.init(version: Self.v("0.3.0"), running: Self.v020, manual: true)])
        #expect(rig.presenter.told.isEmpty)
        #expect(rig.log.lines == ["update check (manual): newer — latest v0.3.0, running 0.2.0"])
        #expect(!rig.checker.isChecking)
    }

    @Test func turningOffCancelsOnlyAnAutomaticCheck() async {
        // Automatic: dropped.
        let automatic = Rig([Self.release("v0.3.0")], gated: true)
        defer { automatic.scratch.remove() }
        let look = Task { await automatic.checker.look() }
        #expect(await automatic.fetcher.entered(1))
        automatic.checker.setEnabled(false)
        #expect(!automatic.checker.isChecking)
        #expect(automatic.defaults.object(forKey: UpdateChecker.enabledKey) as? Bool == false)
        automatic.fetcher.open()
        _ = await look.value
        #expect(automatic.presenter.shown.isEmpty)
        #expect(automatic.presenter.told.isEmpty)
        #expect(automatic.lastCheck == nil)
        #expect(automatic.log.lines.isEmpty)

        // Manual: answers.
        let manual = Rig([Self.release("v0.2.0")], gated: true)
        defer { manual.scratch.remove() }
        let check = Task { await manual.checker.checkNowAndWait() }
        #expect(await manual.fetcher.entered(1))
        manual.checker.setEnabled(false)
        #expect(manual.checker.isChecking)
        manual.fetcher.open()
        await check.value
        #expect(manual.presenter.told == [.upToDate(Self.v020)])
        #expect(manual.lastCheck == Self.now)
    }

    /// Ruling 2: once a manual check has joined the automatic one, the toggle no longer cancels it.
    @Test func turningOffDoesNotCancelAnAutomaticCheckAManualOneJoined() async {
        let rig = Rig([Self.release("v0.3.0")], gated: true)
        defer { rig.scratch.remove() }
        let look = Task { await rig.checker.look() }
        #expect(await rig.fetcher.entered(1))
        rig.checker.checkNow()
        rig.checker.setEnabled(false)
        #expect(rig.checker.isChecking)
        rig.fetcher.open()
        _ = await look.value
        #expect(rig.fetcher.calls == 1)
        #expect(rig.presenter.shown == [.init(version: Self.v("0.3.0"), running: Self.v020, manual: true)])
        #expect(rig.lastCheck == Self.now)
    }

    /// A manual check pressed right after the toggle dropped an automatic one gets a check of its own.
    @Test func aManualCheckAfterTurningOffStartsItsOwn() async {
        let rig = Rig([Self.release("v0.3.0"), Self.release("v0.2.0")], gated: true)
        defer { rig.scratch.remove() }
        let look = Task { await rig.checker.look() }
        #expect(await rig.fetcher.entered(1))
        rig.checker.setEnabled(false)
        let check = Task { await rig.checker.checkNowAndWait() }
        #expect(await rig.fetcher.entered(2))
        rig.fetcher.open()
        _ = await look.value
        await check.value
        #expect(rig.presenter.shown.isEmpty)
        #expect(rig.presenter.told == [.upToDate(Self.v020)])
        #expect(rig.log.lines == ["update check (manual): up to date — latest 0.2.0, running 0.2.0"])
        #expect(!rig.checker.isChecking)
    }

    @Test func turningOnLooksRightAway() async {
        let rig = Rig([Self.release("v0.3.0")]) { $0.set(false, forKey: UpdateChecker.enabledKey) }
        defer { rig.scratch.remove() }
        #expect(!rig.checker.isEnabled)
        #expect(await rig.checker.look(force: true) == false)
        #expect(rig.fetcher.calls == 0)
        rig.checker.setEnabled(true)
        #expect(rig.checker.isEnabled)
        #expect(await rig.fetcher.entered(1))
        #expect(await Self.settled(rig.checker))
        #expect(rig.presenter.shown == [.init(version: Self.v("0.3.0"), running: Self.v020, manual: false)])
    }

    @Test func manualUpToDateAndFailuresAreTold() async {
        let answers: [UpdateAnswer] = [
            Self.release("v0.2.0"), .response(status: 404, body: Data()), .response(status: 403, body: Data()),
            .response(status: 500, body: Data()), .failure("offline"), .response(status: 200, body: Data("{}".utf8)),
        ]
        let rig = Rig(answers)
        defer { rig.scratch.remove() }
        for _ in answers { await rig.checker.checkNowAndWait() }
        #expect(
            rig.presenter.told == [
                .upToDate(Self.v020), .noRelease, .rateLimited, .httpError(500), .unreachable("offline"),
                .unreadable("json"),
            ])
        #expect(rig.presenter.shown.isEmpty)
        #expect(rig.log.lines.count == answers.count)
        #expect(rig.log.lines.allSatisfy { $0.hasPrefix("update check (manual): ") })
    }

    @Test func noRunningVersionMeansNoAutomaticCheck() async {
        let rig = Rig([Self.release("v0.3.0")], running: nil)
        defer { rig.scratch.remove() }
        #expect(await rig.checker.look(force: true) == false)
        #expect(rig.fetcher.calls == 0)
        #expect(rig.lastCheck == nil)
        #expect(rig.log.lines.isEmpty)
        await rig.checker.checkNowAndWait()
        #expect(rig.fetcher.calls == 0)
        #expect(rig.presenter.told == [.unreadable("version")])
        #expect(rig.log.lines == ["update check (manual): unreadable (version) — latest ?, running ?"])
    }

    @Test func theLoopLooksAfterTheFirstDelayAndStopEndsIt() async {
        let rig = Rig([Self.release("v0.3.0")], firstLook: .milliseconds(1), lookInterval: .milliseconds(1))
        defer { rig.scratch.remove() }
        rig.checker.start()
        #expect(await rig.fetcher.entered(1))
        #expect(await Self.settled(rig.checker))
        rig.checker.stop()
        // Within a day of that check every later look fetches nothing.
        #expect(rig.fetcher.calls == 1)
        #expect(rig.presenter.shown.count == 1)
    }

    @Test func theTestHostRunsNoChecks() {
        #expect(UpdateChecker.runsChecks(environment: [:], isRunningTests: true) == false)
        #expect(AppModel.updates == nil)
        #if DEBUG
            #expect(UpdateChecker.runsChecks(environment: ["GITTER_DEBUG_OPEN": "/x"], isRunningTests: false) == false)
            #expect(
                UpdateChecker.runsChecks(
                    environment: ["GITTER_DEBUG_OPEN": "/x", "GITTER_DEBUG_UPDATE_FEED": "file:///x"],
                    isRunningTests: false))
            #expect(
                UpdateChecker.runsChecks(
                    environment: ["GITTER_DEBUG_UPDATE_FEED": "http://127.0.0.1:8123/feed.json"], isRunningTests: false))
            // An empty or remote override never checks: it would fall back to GitHub.
            for feed in ["", "https://api.github.com/repos/Constantine-24/gitter/releases/latest", "http://localhost:1/"] {
                #expect(
                    UpdateChecker.runsChecks(environment: ["GITTER_DEBUG_UPDATE_FEED": feed], isRunningTests: false)
                        == false, "\(feed)")
            }
            #expect(
                UpdateChecker.runsChecks(
                    environment: ["GITTER_DEBUG_UPDATE_FEED": "file:///x"], isRunningTests: true) == false)
        #endif
        #expect(UpdateChecker.runsChecks(environment: [:], isRunningTests: false))
    }

    @Test func theFeedAndTheVersionComeFromTheBundleUnlessTheHarnessSaysOtherwise() {
        #expect(UpdateChecker.feedURL(environment: [:]) == UpdateCheck.apiURL)
        let info: [String: Any] = ["CFBundleShortVersionString": "0.2.0"]
        #expect(UpdateChecker.runningVersion(info: info, environment: [:]) == Self.v020)
        #expect(UpdateChecker.runningVersion(info: ["CFBundleShortVersionString": "0.2.0-beta"], environment: [:]) == nil)
        #expect(UpdateChecker.runningVersion(info: [:], environment: [:]) == nil)
        #if DEBUG
            #expect(
                UpdateChecker.feedURL(environment: ["GITTER_DEBUG_UPDATE_FEED": "file:///tmp/feed.json"])
                    == URL(string: "file:///tmp/feed.json"))
            #expect(
                UpdateChecker.feedURL(environment: ["GITTER_DEBUG_UPDATE_FEED": "http://127.0.0.1:8123/f"])
                    == URL(string: "http://127.0.0.1:8123/f"))
            #expect(UpdateChecker.feedURL(environment: ["GITTER_DEBUG_UPDATE_FEED": "https://example.com/"]) != UpdateCheck.apiURL)
            #expect(UpdateChecker.feedURL(environment: ["GITTER_DEBUG_UPDATE_FEED": ""]) != UpdateCheck.apiURL)
            #expect(
                UpdateChecker.runningVersion(info: info, environment: ["GITTER_DEBUG_UPDATE_VERSION": "0.1.0"])
                    == Self.v("0.1.0"))
            #expect(UpdateChecker.runningVersion(info: info, environment: ["GITTER_DEBUG_UPDATE_VERSION": "nope"]) == nil)
        #endif
    }
}
