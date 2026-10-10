import AppKit

/// What holding and answering a quit event needs from AppKit.
///
/// The quit Apple Event (the Dock's Quit, a logout, a shutdown) reaches `AppDelegate.handleQuit`,
/// which only starts the quit (`QuitFlow`); its outcome comes later. Left alone, AppKit answers the
/// sender as soon as the handler returns — success, 0.001 s after the send and about a second
/// before a "Don't Quit" called the quit off (measured, A2) — so a logout never learned that Gitter
/// refused it. The handler holds the event instead (`suspendCurrent`), and the quit's outcome
/// answers it (`answer`): `userCanceledErr` (−128) when the quit is called off and 0 when it goes
/// ahead, which is exactly what AppKit's own handler sends for `reply(false)` and `reply(true)` (A1).
@MainActor protocol QuitEventReplies {
    /// `NSAppleEventManager.shared().suspendCurrentAppleEvent()`; nil when no event is being handled.
    func suspendCurrent() -> NSAppleEventManager.SuspensionID?
    /// Sets `keyErrorNumber` on `replyAppleEvent(forSuspensionID:)` (harmless on a null reply) and resumes.
    func answer(_ id: NSAppleEventManager.SuspensionID, errorNumber: Int32)
}

/// The live one: AppKit's Apple Event manager.
@MainActor struct AppleEventReplies: QuitEventReplies {
    func suspendCurrent() -> NSAppleEventManager.SuspensionID? {
        NSAppleEventManager.shared().suspendCurrentAppleEvent()
    }

    /// The reply goes out at the resume (A2a). A sender that asked for no reply (`kAENoReply`)
    /// has a null reply event; setting the number on it and resuming is harmless (A2d), and so is
    /// a resume after the sender timed out (A2c). The id is not touched again after its resume.
    func answer(_ id: NSAppleEventManager.SuspensionID, errorNumber: Int32) {
        let manager = NSAppleEventManager.shared()
        manager.replyAppleEvent(forSuspensionID: id)
            .setParam(NSAppleEventDescriptor(int32: errorNumber), forKeyword: AEKeyword(keyErrorNumber))
        manager.resume(withSuspensionID: id)
    }
}

extension QuitFlow {
    /// `AppleEventReplies()` in the app; the tests swap it for a recording fake.
    static var replies: any QuitEventReplies = AppleEventReplies()

    /// The held ids, oldest first (internal for tests). A list, not one slot: a second quit event
    /// arrives while the first is held — during `.terminateLater` — and each has its own id (A2d).
    private(set) static var heldQuitEvents: [NSAppleEventManager.SuspensionID] = []

    /// Called by `handleQuit` before `request(.appleEvent)`: holds the current event, if any. Only
    /// the handler can: by the time `applicationShouldTerminate` is asked there is no current
    /// event (A2). A quit already under way still holds the new one, for its outcome to answer.
    static func holdCurrentQuitEvent() {
        guard let id = replies.suspendCurrent() else { return }
        heldQuitEvents.append(id)
        QuitGuard.log("quit: holding the quit event's reply (\(heldQuitEvents.count) held)")
    }

    /// Answers every held id once — `userCanceledErr` (−128) when `quitting` is false, 0 when
    /// true — and empties the list. Idempotent on an empty list (⌘Q, the menu and the harness
    /// `quit` carry no event, A4).
    ///
    /// Called at every ending: `QuitGuard.wentAhead` (`.terminateNow`, every `reply(true)`) and
    /// `QuitGuard.calledOff` (every `reply(false)`), `run`'s two give-ups, and
    /// `applicationWillTerminate` as a net.
    static func answerHeldQuitEvents(quitting: Bool) {
        guard !heldQuitEvents.isEmpty else { return }
        // Emptied first: an id must not be used after its resume.
        let held = heldQuitEvents
        heldQuitEvents = []
        let errorNumber = quitting ? 0 : Int32(userCanceledErr)
        QuitGuard.log("quit: answering \(held.count) held quit event(s) with \(errorNumber)")
        for id in held { replies.answer(id, errorNumber: errorNumber) }
    }
}
