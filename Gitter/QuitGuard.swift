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
/// | push, publish, force push, delete on a remote | asks: **Wait** (default) lets it finish, then quits — unless it ended with a banner, which is then left on screen and the quit is called off; **Stop and Quit** stops it and quits when the lane frees; **Don't Quit** calls the quit off |
///
/// Once the user has decided to quit (every row but "Don't Quit"), `beginTerminating()` stops
/// anything new from starting on the lane — the automatic fetch, a pull's merge, a cancelled
/// write's follow-up fetch — so the lane can only free.
///
/// **Not covered:** a SIGTERM (`kill`, a logout that force-quits) never reaches
/// `applicationShouldTerminate`, and git is left running as before; and a mutation that is not
/// on the lane (a merge, a commit) is not waited for. Both are in `docs/BACKLOG.md`.
@MainActor
enum QuitGuard {
    /// How long a stopped fetch may take to go before the app quits anyway. The runner ends a
    /// cancelled git within about two grace periods (2 s each); this is generous on top.
    static let readStopBound: Duration = .seconds(10)

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
            replyWhenLaneFrees(store, bound: readStopBound, stayForBanner: nil)
            return .terminateLater
        }
        log("quit: \(activity.kind) is a write, asking")
        ask(about: activity, store: store)
        return .terminateLater
    }

    private static func ask(about activity: RemoteActivity, store: RepositoryStore) {
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
                // A banner the write ends with is new if it differs from what was up before.
                replyWhenLaneFrees(store, bound: nil, stayForBanner: store.lastError)
            case .alertSecondButtonReturn:
                log("quit: Stop and Quit")
                store.beginTerminating()
                store.cancelRemoteActivity()
                replyWhenLaneFrees(store, bound: readStopBound, stayForBanner: nil)
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

    /// Replies to the pending terminate once the lane is free — or after `bound`, if given.
    ///
    /// `stayForBanner` is the banner that was up when the user chose Wait: if the lane ends with
    /// a different one (the push failed, or the server refused it), the quit is called off so
    /// that the user reads it. A write that failed while nobody was looking is exactly the
    /// silent loss this type exists to prevent.
    private static func replyWhenLaneFrees(
        _ store: RepositoryStore, bound: Duration?, stayForBanner before: String??
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
                if store.remoteActivity != nil {
                    guard let bound, waited > bound else { return false }
                    log("quit: the lane did not free within \(bound); quitting anyway")
                }
                if let before, let banner = store.lastError, banner != before {
                    log("quit: called off, the write ended with a banner: \(banner)")
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
