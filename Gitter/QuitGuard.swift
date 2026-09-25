import AppKit

/// What quitting does while the network lane is busy.
///
/// Without this, ⌘Q left git running: it runs in a process group of its own, nothing cancelled
/// `remoteTask`, and git — re-parented to pid 1 — finished on its own, so a push whose pack was
/// already out could land on the server after Gitter was gone, with no message anywhere
/// (measured in Tasks 8 and 9). So `applicationShouldTerminate` answers `.terminateLater`
/// whenever the lane is busy, and replies once it has freed:
///
/// | on the lane | what quitting does |
/// |---|---|
/// | nothing | quits at once |
/// | fetch, automatic fetch, pull (its fetch) | stops it and quits when the lane frees — at most `readStopBound` (the runner's escalation ends git within about two grace periods) |
/// | push, publish, force push, delete on a remote | asks: **Wait** (default) lets it finish, then quits — unless something ended on the lane since the quit was asked with a banner, a sheet or a notice with a warning in it, which is then left on screen and the quit called off; and unless it is still running after `waitBound`, when the quit is called off with a banner saying so; **Stop and Quit** stops it and quits when the lane frees; **Don't Quit** calls the quit off |
///
/// "Since the quit was asked", not "since Wait was clicked": the write can end — rejected, say —
/// while the alert is still up, and its banner is then just as unread (Task 11's review: a
/// rejected push under the alert, then Wait, quit with the banner unread). What is compared is
/// `RepositoryStore.laneMessagesToRead`, a count of lane endings the user has to read, taken
/// before the alert goes up — not the banner's text, which can repeat word for word.
///
/// Once the user has decided to quit (every row but "Don't Quit"), `beginTerminating()` stops
/// anything new from starting on the lane — the automatic fetch, a pull's merge, a cancelled
/// write's follow-up fetch — so the lane can only free; a Fetch, Pull or Push the user asks for
/// meanwhile is refused with a sentence saying so. Stop (⌘.) still works while the quit is held.
///
/// A second quit (⌘Q again) while one is held does nothing: AppKit does not ask
/// `applicationShouldTerminate` again until the first is answered.
///
/// **Not covered:** a SIGTERM (`kill`, a logout that force-quits) never reaches
/// `applicationShouldTerminate`, and git is left running as before; and a mutation that is not
/// on the lane (a merge, a commit) is not waited for. Both are in `docs/BACKLOG.md`.
@MainActor
enum QuitGuard {
    /// How long a stopped fetch may take to go before the app quits anyway. The runner ends a
    /// cancelled git within about two grace periods (2 s each); this is generous on top.
    static let readStopBound: Duration = .seconds(10)

    /// How long **Wait** waits for a write before it gives up on quitting (final review's fix
    /// wave). It used to wait without end: a push stuck on a server that never answers held the
    /// quit — and the app, with every new lane claim refused — for as long as git ran, with
    /// nothing on screen to say why nothing happened. Ten minutes is far past any push the lane
    /// makes while leaving a stuck one visibly stuck; at the bound the quit is **called off**,
    /// never turned into a quit: the write is still running, and quitting now is the silent
    /// loss this type exists to prevent. The banner says so and the user chooses again.
    ///
    /// DEBUG builds read `GITTER_DEBUG_QUIT_WAIT=<seconds>` so the harness can reach the bound.
    static var waitBound: Duration {
        #if DEBUG
            if let seconds = ProcessInfo.processInfo.environment["GITTER_DEBUG_QUIT_WAIT"]
                .flatMap(Double.init), seconds > 0
            {
                return .milliseconds(Int(seconds * 1000))
            }
        #endif
        return .seconds(600)
    }

    /// What happens when a bound passes with the lane still busy.
    private enum AtTheBound {
        /// A stopped read: git has been told to go and the runner's escalation ends it; quit.
        case quitAnyway
        /// A write the user chose to wait for: still running, so the quit is called off.
        case callOff
    }

    /// The answer to `applicationShouldTerminate`.
    static func shouldTerminate(_ store: RepositoryStore?) -> NSApplication.TerminateReply {
        guard let store, let activity = store.remoteActivity else {
            log("quit: the lane is free, quitting now")
            return .terminateNow
        }
        guard activity.isWrite else {
            log("quit: stopping \(activity.kind) and quitting when the lane frees")
            store.beginTerminating()
            store.cancelRemoteActivity()
            replyWhenLaneFrees(
                store, bound: readStopBound, atTheBound: .quitAnyway, callOffIfToldSince: nil)
            return .terminateLater
        }
        log("quit: \(activity.kind) is a write, asking")
        // Before the alert: whatever the write ends with from here on is unread.
        ask(about: activity, store: store, messagesBefore: store.laneMessagesToRead)
        return .terminateLater
    }

    private static func ask(
        about activity: RemoteActivity, store: RepositoryStore, messagesBefore: Int
    ) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = RemoteWording.quitDuringWriteTitle(activity)
        alert.informativeText = RemoteWording.quitDuringWriteMessage
        // First button: the default, Return. The safe answer.
        alert.addButton(withTitle: RemoteWording.quitWait)
        let stop = alert.addButton(withTitle: RemoteWording.quitStop)
        stop.hasDestructiveAction = true
        let cancel = alert.addButton(withTitle: RemoteWording.quitCancel)
        cancel.keyEquivalent = "\u{1b}"

        let answer: (NSApplication.ModalResponse) -> Void = { response in
            switch response {
            case .alertFirstButtonReturn:
                log("quit: Wait")
                store.beginTerminating()
                replyWhenLaneFrees(
                    store, bound: waitBound, atTheBound: .callOff,
                    callOffIfToldSince: messagesBefore)
            case .alertSecondButtonReturn:
                log("quit: Stop and Quit")
                store.beginTerminating()
                store.cancelRemoteActivity()
                replyWhenLaneFrees(
                    store, bound: readStopBound, atTheBound: .quitAnyway,
                    callOffIfToldSince: nil)
            default:
                log("quit: Don't Quit")
                NSApp.reply(toApplicationShouldTerminate: false)
            }
        }
        // As a sheet on the window (or on the sheet it already has), like every other question
        // Gitter asks; app-modal only when no window is open.
        if let window = NSApp.windows.first(where: { $0.isVisible && $0.sheetParent == nil }) {
            alert.beginSheetModal(for: window.attachedSheet ?? window, completionHandler: answer)
        } else {
            DispatchQueue.main.async { answer(alert.runModal()) }
        }
    }

    /// Replies to the pending terminate once the lane is free — or, once `bound` has passed with
    /// the lane still busy, as `atTheBound` says.
    ///
    /// `callOffIfToldSince` is `laneMessagesToRead` as it was when the quit was asked: if a lane
    /// has ended since with something to read (the push failed, the server refused it, it
    /// pushed but could not set the upstream), the quit is called off so that the user reads it.
    /// A write that failed while nobody was looking is exactly the silent loss this type exists
    /// to prevent.
    private static func replyWhenLaneFrees(
        _ store: RepositoryStore, bound: Duration, atTheBound: AtTheBound,
        callOffIfToldSince before: Int?
    ) {
        // Polled from a run-loop timer in the common modes, not from a Task: while the quit is
        // held AppKit spins the run loop in its modal-panel mode, and a timer there fires even if
        // the terminate came from inside a main-queue block — where no MainActor job can run, so
        // a Task would never get to look (and neither would the lane's own task, so the bound is
        // then what quits).
        let started = ContinuousClock.now
        let timer = Timer(timeInterval: 0.05, repeats: true) { timer in
            let replied = MainActor.assumeIsolated { () -> Bool in
                let waited = ContinuousClock.now - started
                if let activity = store.remoteActivity {
                    guard waited > bound else { return false }
                    switch atTheBound {
                    case .quitAnyway:
                        log("quit: the lane did not free within \(bound); quitting anyway")
                        NSApp.reply(toApplicationShouldTerminate: true)
                    case .callOff:
                        log("quit: the lane did not free within \(bound); calling the quit off")
                        store.endTerminating()
                        store.showStickyError(RemoteWording.quitWaitGaveUp(activity, after: bound))
                        NSApp.reply(toApplicationShouldTerminate: false)
                    }
                    return true
                }
                if let before, store.laneMessagesToRead != before {
                    log(
                        "quit: called off, the lane ended with something to read: "
                            + (store.lastLaneMessageToRead ?? "?"))
                    store.endTerminating()
                    NSApp.reply(toApplicationShouldTerminate: false)
                    return true
                }
                log("quit: the lane is free after \(waited), quitting")
                NSApp.reply(toApplicationShouldTerminate: true)
                return true
            }
            if replied { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    private static func log(_ message: String) {
        #if DEBUG
            let time = Date.now.formatted(
                .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()
                    .secondFraction(.fractional(3)))
            FileHandle.standardError.write(Data("QUIT \(time) \(message)\n".utf8))
        #endif
    }
}
