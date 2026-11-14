import Foundation
import Observation

/// What the checker shows and says: the update window and the manual check's alerts (Task 3's
/// panel controller in the app, a recorder in tests).
@MainActor protocol UpdatePresenting: AnyObject {
    /// Whether an automatic result may show now: the app is active, no window has a sheet up,
    /// no modal window is up and no quit is under way. Otherwise the result is held.
    var canShowAutomatic: Bool { get }
    /// Opens the update window, or updates the one already open.
    func show(_ release: LatestRelease, running: ReleaseVersion, manual: Bool)
    /// A manual check's answer when it is not a newer release.
    func tell(_ outcome: UpdateOutcome)
}

/// The one check in flight. Its `manual` is read when it completes.
@MainActor private final class UpdateFlight {
    var manual: Bool
    var task: Task<Void, Never>?
    init(manual: Bool) { self.manual = manual }
}

/// The app's one update checker (`AppModel.updates`): when to check, at most one check in flight,
/// manual against automatic, the held result and the skip. The rules themselves are
/// `UpdateCheck`'s; the request is the fetcher's.
///
/// - **Automatic looks** come `firstLook` after `start()`, then every `lookInterval`. A look checks
///   when the toggle is on, the running version is known, and a day has passed since
///   `updateLastCheck` (`UpdateCheck.isDue`).
/// - **One check in flight.** A manual check pressed during an automatic one joins it: that check
///   then counts as manual, and its one answer is reported as a manual result. Turning the toggle
///   off drops an automatic check in flight, never a manual (or joined) one.
/// - **Every completed check** writes `updateLastCheck` and one event-log line, whatever its
///   outcome, so a failure still waits a day. A dropped check writes neither.
/// - **An automatic newer release** that is not the skipped version shows when the presenter can
///   show it, and is held otherwise until `showHeldIfPossible()` — which a timer calls every
///   `retryInterval` while it is held, and the presenter on its own notifications; showing it
///   clears a skip below it. A later check that says anything about the latest release replaces or drops it.
@Observable @MainActor final class UpdateChecker {
    static let enabledKey = "updateCheckEnabled"
    static let lastCheckKey = "updateLastCheck"
    static let skippedKey = "updateSkippedVersion"

    #if DEBUG
        /// The harness's overrides, compiled out of Release.
        static let feedVariable = "GITTER_DEBUG_UPDATE_FEED"
        static let versionVariable = "GITTER_DEBUG_UPDATE_VERSION"
    #endif

    /// Never under the test host. In DEBUG, a scripted launch checks only when the harness names
    /// its own feed (`GITTER_DEBUG_UPDATE_FEED`, a `file://` or 127.0.0.1 URL): an empty or remote
    /// value checks nothing rather than fall back to GitHub.
    static func runsChecks(environment: [String: String], isRunningTests: Bool) -> Bool {
        guard !isRunningTests else { return false }
        #if DEBUG
            if DebugLaunchGuard.isScripted(environment) { return debugFeed(environment) != nil }
        #endif
        return true
    }

    /// `UpdateCheck.apiURL`. In DEBUG, with `GITTER_DEBUG_UPDATE_FEED` set: that URL when it is a
    /// `file://` or `http://127.0.0.1` one, and otherwise `/dev/null`, which answers nothing —
    /// never GitHub (`runsChecks` is false then anyway).
    static func feedURL(environment: [String: String]) -> URL {
        #if DEBUG
            if environment[feedVariable] != nil {
                return debugFeed(environment) ?? URL(fileURLWithPath: "/dev/null")
            }
        #endif
        return UpdateCheck.apiURL
    }

    #if DEBUG
        /// The harness's feed: a `file://` URL, or an `http://127.0.0.1` one.
        private static func debugFeed(_ environment: [String: String]) -> URL? {
            guard let text = environment[feedVariable], let url = URL(string: text) else { return nil }
            if url.scheme == "file", !url.path.isEmpty { return url }
            if url.scheme == "http", url.host == "127.0.0.1" { return url }
            return nil
        }
    #endif

    /// `CFBundleShortVersionString`, parsed like a tag; nil when it does not parse. In DEBUG,
    /// `GITTER_DEBUG_UPDATE_VERSION` pretends to be another version (one that does not parse is nil).
    static func runningVersion(info: [String: Any], environment: [String: String]) -> ReleaseVersion? {
        #if DEBUG
            if let pretend = environment[versionVariable] { return ReleaseVersion(pretend) }
        #endif
        return (info["CFBundleShortVersionString"] as? String).flatMap(ReleaseVersion.init)
    }

    private let defaults: UserDefaults
    private let running: ReleaseVersion?
    private let fetcher: any UpdateFetching
    private let presenter: any UpdatePresenting
    private let log: EventLog
    private let now: @MainActor () -> Date
    private let firstLook: Duration
    private let lookInterval: Duration
    private let retryInterval: Duration

    /// Whether a check is in flight: Check for Updates… is off meanwhile.
    private(set) var isChecking = false

    @ObservationIgnored private var flight: UpdateFlight?
    /// The automatic result waiting for the presenter. While there is one, `retry` tries it again
    /// every `retryInterval` (Ruling 4).
    @ObservationIgnored private var held: LatestRelease? {
        didSet { held == nil ? stopRetry() : startRetry() }
    }
    @ObservationIgnored private var retry: Timer?
    @ObservationIgnored private var loop: Task<Void, Never>?

    /// Whether a held result is being tried again on the timer (internal for tests).
    var isRetryingHeld: Bool { retry != nil }

    #if DEBUG
        /// The held automatic result's version, for the harness's `update:state`.
        var debugHeldVersion: ReleaseVersion? { held?.version }
    #endif

    init(
        defaults: UserDefaults, running: ReleaseVersion?, fetcher: any UpdateFetching,
        presenter: any UpdatePresenting, log: EventLog, now: @escaping @MainActor () -> Date = { Date() },
        firstLook: Duration = .seconds(10), lookInterval: Duration = .seconds(3600),
        retryInterval: Duration = .seconds(2)
    ) {
        self.defaults = defaults
        self.running = running
        self.fetcher = fetcher
        self.presenter = presenter
        self.log = log
        self.now = now
        self.firstLook = firstLook
        self.lookInterval = lookInterval
        self.retryInterval = retryInterval
    }

    /// "Check for Updates Automatically". Absent means on.
    var isEnabled: Bool { defaults.object(forKey: Self.enabledKey) as? Bool ?? true }

    private var skipped: ReleaseVersion? {
        defaults.string(forKey: Self.skippedKey).flatMap(ReleaseVersion.init)
    }

    /// The looks: the first after `firstLook`, then one every `lookInterval`, each followed by a
    /// try at the held result. Once; a second call changes nothing.
    func start() {
        guard loop == nil else { return }
        let firstLook = firstLook
        let lookInterval = lookInterval
        loop = Task { [weak self] in
            var delay = firstLook
            while true {
                do { try await Task.sleep(for: delay) } catch { return }
                guard let self else { return }
                await self.look()
                self.showHeldIfPossible()
                delay = lookInterval
            }
        }
    }

    /// Ends the looks and the held result's retry. A check in flight still completes.
    func stop() {
        loop?.cancel()
        loop = nil
        stopRetry()
    }

    /// The held result's retry: `showHeldIfPossible()` every `retryInterval`, from a repeating
    /// timer on the main run loop in `.default` **and `.modalPanel`** — the mode AppKit runs while
    /// an app-modal alert (QuitGuard's question, a manual check's answer) or an Open panel is up.
    /// The notifications the presenter watches (the app became active, a sheet ended) are not
    /// posted when such a modal ends with the app still active; the timer fires during it (and
    /// finds the presenter unable) and right after it. Not `.eventTracking`: a menu being tracked
    /// holds it until the menu closes. Here, not in the presenter, because the held state lives here
    /// and every path that holds or drops a result sets `held`.
    private func startRetry() {
        guard retry == nil else { return }
        let (seconds, attoseconds) = retryInterval.components
        let interval = max(Double(seconds) + Double(attoseconds) / 1e18, 0.001)
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] timer in
            // A checker that is gone takes its timer with it.
            guard let self else { return timer.invalidate() }
            MainActor.assumeIsolated { self.showHeldIfPossible() }
        }
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .modalPanel)
        retry = timer
    }

    private func stopRetry() {
        retry?.invalidate()
        retry = nil
    }

    /// The manual check: starts one, or joins the one in flight, which then answers as manual.
    func checkNow() {
        _ = beginManual()
    }

    /// `checkNow()`, waiting for its answer.
    func checkNowAndWait() async {
        await beginManual()?.task?.value
    }

    /// Writes the toggle. On looks right away; off drops an automatic check in flight and any
    /// held result.
    func setEnabled(_ on: Bool) {
        defaults.set(on, forKey: Self.enabledKey)
        if on {
            Task { await self.look() }
        } else {
            held = nil
            if let flight, !flight.manual {
                flight.task?.cancel()
                self.flight = nil
                isChecking = false
            }
        }
    }

    /// Skip This Version: automatic checks stay quiet until a strictly newer version.
    func skip(_ version: ReleaseVersion) {
        defaults.set(version.description, forKey: Self.skippedKey)
        if let held, held.version <= version { self.held = nil }
    }

    /// Shows the held automatic result, if there is one and the presenter can show it now; the
    /// skip is read again first.
    func showHeldIfPossible() {
        guard let held, let running, presenter.canShowAutomatic else { return }
        self.held = nil
        showAutomatic(held, running: running)
    }

    /// One automatic look: false when it found nothing to do (no running version, the toggle off,
    /// or — unless `force` — not due), true when it ran a check or joined the one in flight.
    @discardableResult func look(force: Bool = false) async -> Bool {
        guard let running, isEnabled else { return false }
        if let flight {
            await flight.task?.value
            return true
        }
        guard force || UpdateCheck.isDue(lastCheck: lastCheck, now: now(), enabled: true) else { return false }
        await begin(manual: false, running: running).task?.value
        return true
    }

    private var lastCheck: Date? { defaults.object(forKey: Self.lastCheckKey) as? Date }

    /// The manual check's start; nil when the running version is unknown, which it says at once.
    private func beginManual() -> UpdateFlight? {
        guard let running else {
            log.write(UpdateWording.logLine(.unreadable("version"), running: nil, manual: true))
            presenter.tell(.unreadable("version"))
            return nil
        }
        return begin(manual: true, running: running)
    }

    /// The check in flight, now manual if `manual` — or a new one.
    private func begin(manual: Bool, running: ReleaseVersion) -> UpdateFlight {
        if let flight {
            if manual { flight.manual = true }
            return flight
        }
        let flight = UpdateFlight(manual: manual)
        self.flight = flight
        isChecking = true
        let fetcher = fetcher
        flight.task = Task { [weak self] in
            let answer = await fetcher.fetch()
            // Dropped by the toggle (or replaced): no date, no line, no answer.
            guard let self, self.flight === flight else { return }
            self.complete(flight, answer: answer, running: running)
        }
        return flight
    }

    /// The one place a check's answer goes: the date, the log line, then the presenter.
    private func complete(_ flight: UpdateFlight, answer: UpdateAnswer, running: ReleaseVersion) {
        self.flight = nil
        isChecking = false
        let outcome = UpdateCheck.outcome(of: answer, running: running)
        defaults.set(now(), forKey: Self.lastCheckKey)
        log.write(UpdateWording.logLine(outcome, running: running, manual: flight.manual))
        switch outcome {
        case .newer, .upToDate, .noRelease: held = nil  // a later word on the latest release
        default: break  // a failure says nothing about it
        }
        if flight.manual {
            if case .newer(let release) = outcome {
                presenter.show(release, running: running, manual: true)
            } else {
                presenter.tell(outcome)
            }
        } else if case .newer(let release) = outcome {
            if presenter.canShowAutomatic {
                showAutomatic(release, running: running)
            } else if UpdateCheck.showsAutomatically(release, skipped: skipped) {
                held = release
            }
        }
    }

    /// An automatic result, unless it is the skipped version (or older); a skip below it is cleared.
    private func showAutomatic(_ release: LatestRelease, running: ReleaseVersion) {
        let skipped = skipped
        guard UpdateCheck.showsAutomatically(release, skipped: skipped) else { return }
        if skipped != nil { defaults.removeObject(forKey: Self.skippedKey) }
        presenter.show(release, running: running, manual: false)
    }
}
