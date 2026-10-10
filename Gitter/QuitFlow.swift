import AppKit

/// The one way the app quits (E2 Task 2): Quit Gitter (⌘Q), a quit Apple Event (the Dock, a
/// logout, a shutdown) and the harness's `quit` step all come here.
///
/// **Why it exists.** While any window has a sheet attached, AppKit refuses every quit before it
/// asks the delegate (measured, M1.4): the private `-[NSApplication _shouldTerminate]` returns
/// false without calling `applicationShouldTerminate`, for SwiftUI sheets and plain `beginSheet`
/// sheets alike. ⌘Q, the menu item, `NSApp.terminate` (direct or from the run loop) and the quit
/// Apple Event were all dropped, silently and for good — nothing queues the quit for later.
///
/// **What it does** (`run`): it closes every store's sheet (`activeSheet = nil`), waits until no
/// visible window has an `attachedSheet` — AppKit takes 0.27–0.29 s to detach a dismissed sheet
/// (M1.5), and every variant that terminated without waiting was a race — and then terminates
/// from the run loop, where `QuitGuard` answers `applicationShouldTerminate` as before. A sheet's
/// typed text is lost (the user's decision, 2026-10-10).
///
/// **Under way.** From the request until `QuitGuard` ends the quit, a quit is under way, and a
/// second request is ignored and logged: a second ⌘Q never stacks a second flow, and never closes
/// `QuitGuard`'s own question. `applicationShouldTerminate` reached by any path (`delegateWasAsked`)
/// counts as under way too. Two bounds make sure it never stays under way for good:
/// - sheets still attached after `bound`: logged, a beep, the app keeps running;
/// - AppKit dropping the terminate anyway, without asking the delegate within `bound` (a sheet
///   that came back between the last look and the terminate; RF1): logged, and the flow ends.
///
/// **The quit event's reply** (E3, `QuitEventReplies.swift`): a quit Apple Event is held from its
/// handler on (`holdCurrentQuitEvent`) and answered once, with the quit's outcome
/// (`answerHeldQuitEvents`): −128 when either bound gives up or `QuitGuard` calls the quit off, 0
/// when it goes ahead. A request ignored as under way leaves its event held for that outcome.
///
/// The stores come from `AppModel.quitStores()`, the one provider `QuitGuard` uses too.
@MainActor
enum QuitFlow {
    enum Reason: String, Sendable {
        case menu, appleEvent, harness, launchRefusal
    }

    enum Outcome: Equatable, Sendable {
        /// `terminate()` was called; whatever AppKit and `QuitGuard` made of it is theirs.
        case terminateCalled
        /// A quit was already under way; nothing was done.
        case ignoredAlreadyUnderWay
        /// A sheet was still attached at the bound; the app keeps running.
        case sheetsStillAttached
    }

    /// From a request (or `applicationShouldTerminate`) until the quit ends: the app goes, or
    /// `QuitGuard` calls it off (`quitEnded`), or one of the flow's bounds passes.
    private(set) static var isUnderWay = false

    /// How many times `applicationShouldTerminate` has been reached: the flow compares it across
    /// its terminate to tell whether AppKit asked.
    private static var delegateAsks = 0

    /// What the flow touches outside itself: the seams its tests inject.
    struct Environment {
        var stores: @MainActor () -> [RepositoryStore]
        /// Whether any visible window still has a sheet attached — what AppKit refuses a quit over.
        var sheetsAttached: @MainActor () -> Bool
        var terminate: @MainActor () -> Void
        var beep: @MainActor () -> Void
        var poll: Duration = .milliseconds(20)
        /// How long the sheets may take to go (M1.5 measured 0.27–0.29 s); and how long AppKit
        /// may take to ask the delegate after the terminate before the flow gives up on it.
        var bound: Duration = .seconds(2)

        static var live: Environment {
            Environment(
                stores: { AppModel.quitStores() },
                sheetsAttached: { NSApp.windows.contains { $0.isVisible && $0.attachedSheet != nil } },
                // From the run loop, as a key event or the Dock's quit event arrives — not called
                // in this job: `terminate` does not return while `QuitGuard` holds the quit, and
                // the run loop it spins then cannot drain the main queue from *inside* a
                // main-queue block (a MainActor job is one), so nothing on the main actor — the
                // lane's own task included — would run again (measured in Task 11).
                terminate: { NSApp.perform(#selector(NSApplication.terminate(_:)), with: nil, afterDelay: 0) },
                beep: { NSSound.beep() })
        }
    }

    /// Quits, as `reason` asks: the entry points call this.
    static func request(_ reason: Reason) {
        Task { await run(reason, environment: .live) }
    }

    /// Closes the sheets, waits until none is attached, terminates, and then waits — at most
    /// `bound` — for AppKit to ask the delegate, ending the quit if it does not. Returns once all
    /// of that is over (or at once, if a quit was already under way).
    static func run(_ reason: Reason, environment: Environment) async -> Outcome {
        guard !isUnderWay else {
            QuitGuard.log("quit: asked (\(reason.rawValue)) while a quit is under way; ignored")
            return .ignoredAlreadyUnderWay
        }
        isUnderWay = true
        let stores = environment.stores()
        let open = stores.filter { $0.activeSheet != nil }.count
        QuitGuard.log("quit: asked (\(reason.rawValue)); closing \(open) sheet(s)")
        for store in stores { store.activeSheet = nil }

        let clock = ContinuousClock()
        let closing = clock.now
        while environment.sheetsAttached() {
            guard clock.now - closing < environment.bound else {
                QuitGuard.log("quit: a sheet did not close")
                environment.beep()
                isUnderWay = false
                answerHeldQuitEvents(quitting: false)
                return .sheetsStillAttached
            }
            try? await Task.sleep(for: environment.poll)
        }

        QuitGuard.log("quit: no sheet attached after \(clock.now - closing); terminating")
        let asksBefore = delegateAsks
        environment.terminate()
        let terminated = clock.now
        while delegateAsks == asksBefore {
            guard clock.now - terminated < environment.bound else {
                QuitGuard.log("quit: AppKit did not ask")
                isUnderWay = false
                answerHeldQuitEvents(quitting: false)
                return .terminateCalled
            }
            try? await Task.sleep(for: environment.poll)
        }
        return .terminateCalled
    }

    /// `applicationShouldTerminate` was reached: called first thing there, by whatever path the
    /// quit came. From here the quit is `QuitGuard`'s, and under way until it ends.
    static func delegateWasAsked() {
        delegateAsks &+= 1
        isUnderWay = true
    }

    /// `QuitGuard` called the quit off (every `reply(false)` and `.terminateCancel` path): the next
    /// request starts afresh.
    static func quitEnded() {
        isUnderWay = false
    }
}

