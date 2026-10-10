import AppKit

/// An app-modal alert raised from the run loop.
///
/// `runModal` called inside a main-actor job or a `DispatchQueue.main.async` block holds up every
/// other main-actor job until the alert is dismissed — another window's git ending, a refresh —
/// because the main queue is serial and the modal loop runs inside the current block (measured,
/// C3). Raised from a run-loop timer, the main queue keeps draining while the alert is up.
enum ModalAlert {
    /// Builds nothing itself: runs `alert.runModal()` from a one-shot `Timer` on `RunLoop.main`
    /// and hands the response to `then` — never from `DispatchQueue.main.async` or a Task, which
    /// hold up every other main-actor job while the alert is up (C3).
    ///
    /// **Modes: exactly `.default` and `.modalPanel`.** `.default` for an alert raised while the
    /// app is idle (C3's measurement); `.modalPanel` because `QuitGuard` raises its question while
    /// AppKit holds the quit (`.terminateLater`) in that mode, where a `.default`-only timer never
    /// fires. Not `.common`, which adds `.eventTracking`: an alert should not start inside a menu's
    /// tracking or a live resize, but wait for it to end. In both modes the main queue keeps
    /// draining while the alert is up (`ModalAlertTests`).
    @MainActor static func raise(_ alert: NSAlert, then: @escaping @MainActor (NSApplication.ModalResponse) -> Void) {
        raise(alert, runModal: { $0.runModal() }, then: then)
    }

    /// `raise`, with `runModal` as a seam (internal for tests).
    @MainActor static func raise(
        _ alert: NSAlert, runModal: @escaping @MainActor (NSAlert) -> NSApplication.ModalResponse,
        then: @escaping @MainActor (NSApplication.ModalResponse) -> Void
    ) {
        let timer = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated { then(runModal(alert)) }
        }
        // `.modalPanel` as well as `.default`: `QuitGuard` raises its question from inside
        // `applicationShouldTerminate`, and once that answers `.terminateLater` AppKit spins the
        // main run loop in `NSModalPanelRunLoopMode` until the reply — a `.default`-only timer
        // would not fire before the reply, which waits for the question's answer, and the quit
        // would hang with nothing on screen (`ModalAlertTests`, the modal-panel test and its
        // `.default` control). Not `.eventTracking` (see the doc above).
        RunLoop.main.add(timer, forMode: .default)
        RunLoop.main.add(timer, forMode: .modalPanel)
    }
}
