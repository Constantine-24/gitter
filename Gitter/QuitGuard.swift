import AppKit

/// What quitting does while a network lane is busy — over every store a quit takes with it
/// (`AppModel.quitStores()`, every registered store; E2 Tasks 2 and 3): the lanes decide together (`decision`), and the reply
/// waits until every lane is free. The sheets are already closed: `QuitFlow`, the one way in,
/// closes them before it terminates, since AppKit never asks the delegate while one is attached.
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
/// | push, publish, force push, delete on a remote | asks: **Wait** (default) lets it finish — stopping every read on any lane — then quits, unless a lane that had a write has ended since the quit was asked with a banner, a sheet or a notice with a warning in it, which is then left on screen and the quit called off; and unless it is still running after `waitBound`, when the quit is called off with a banner saying so; **Stop and Quit** stops it and quits when the lane frees; **Don't Quit** calls the quit off |
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
/// A second quit (⌘Q again) while one is held does nothing: `QuitFlow` ignores a request while a
/// quit is under way, and AppKit does not ask `applicationShouldTerminate` again until the first
/// is answered. Every answer of false ends the quit for `QuitFlow` (`quitEnded`).
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

    /// What quitting does about every store's lane, from the lanes alone (`[]` and all-free
    /// alike quit now). A write anywhere is asked about — the first one, by its index into the
    /// stores — whatever reads run beside it; otherwise any read is stopped.
    enum Decision: Equatable {
        case now
        case stopReads
        case ask(writeAt: Int)
    }

    static func decision(_ lanes: [RemoteActivity?]) -> Decision {
        if let write = lanes.firstIndex(where: { $0?.isWrite == true }) { return .ask(writeAt: write) }
        return lanes.contains { $0 != nil } ? .stopReads : .now
    }

    /// The answer to `applicationShouldTerminate`, over every store a quit takes with it
    /// (`AppModel.quitStores()`). Every path that answers false tells `QuitFlow` the quit has
    /// ended (`quitEnded`) and ends the terminating of every store it began.
    static func shouldTerminate(_ stores: [RepositoryStore]) -> NSApplication.TerminateReply {
        let lanes = stores.map(\.remoteActivity)
        switch decision(lanes) {
        case .now:
            log("quit: the lane is free, quitting now")
            AppModel.windows.beginAppTermination()
            return .terminateNow
        case .stopReads:
            let kinds = lanes.compactMap { $0.map { "\($0.kind)" } }
            log("quit: stopping \(kinds.joined(separator: ", ")) and quitting when the lane frees")
            for store in stores {
                store.beginTerminating()
                store.cancelRemoteActivity()
            }
            replyWhenLanesFree(
                stores, bound: readStopBound, atTheBound: .quitAnyway, callOffIfToldSince: nil)
            return .terminateLater
        case .ask(let index):
            guard let activity = lanes[index] else { preconditionFailure("asked about a free lane") }
            log("quit: \(activity.kind) is a write, asking")
            // Before the alert: whatever any lane ends with from here on is unread.
            ask(
                about: activity, of: stores[index], stores: stores,
                writesAsked: lanes.map { $0?.isWrite == true }, messagesBefore: stores.map(\.laneMessagesToRead))
            return .terminateLater
        }
    }

    private static func ask(
        about activity: RemoteActivity, of writing: RepositoryStore, stores: [RepositoryStore],
        writesAsked: [Bool], messagesBefore: [Int]
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
                let compared = beginWaiting(stores, writesAsked: writesAsked, messagesBefore: messagesBefore)
                replyWhenLanesFree(
                    stores, bound: waitBound, atTheBound: .callOff, callOffIfToldSince: compared)
            case .alertSecondButtonReturn:
                log("quit: Stop and Quit")
                for store in stores {
                    store.beginTerminating()
                    store.cancelRemoteActivity()
                }
                replyWhenLanesFree(
                    stores, bound: readStopBound, atTheBound: .quitAnyway,
                    callOffIfToldSince: nil)
            default:
                log("quit: Don't Quit")
                callOff()
            }
        }
        // As a sheet on the window showing the store with the write (or on the sheet it already
        // has), like every other question Gitter asks; app-modal when that window is closed — a
        // closed window's write still runs (`WindowRegistry.windowClosed`) — or not on screen.
        if let window = AppModel.windows.window(of: writing), window.isVisible {
            alert.beginSheetModal(for: window.attachedSheet ?? window, completionHandler: answer)
        } else {
            DispatchQueue.main.async { answer(alert.runModal()) }
        }
    }

    /// Replies to the pending terminate once every lane is free — or, once `bound` has passed with
    /// a lane still busy, as `atTheBound` says.
    ///
    /// `callOffIfToldSince` is each store's `laneMessagesToRead` as it was when the quit was asked:
    /// if a store's lane has ended since with something to read (the push failed, the server
    /// refused it, it pushed but could not set the upstream), the quit is called off so that the
    /// user reads it — checked per store, as soon as that store's lane is free. A write that failed
    /// while nobody was looking is exactly the silent loss this type exists to prevent.
    private static func replyWhenLanesFree(
        _ stores: [RepositoryStore], bound: Duration, atTheBound: AtTheBound,
        callOffIfToldSince before: [Int?]?
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
                if let before, let store = storeCallingOff(stores, before: before) {
                    log(
                        "quit: called off, the lane ended with something to read: "
                            + (store.lastLaneMessageToRead ?? "?"))
                    for store in stores { store.endTerminating() }
                    callOff()
                    return true
                }
                let busy = stores.compactMap { store in store.remoteActivity.map { (store, $0) } }
                if !busy.isEmpty {
                    guard waited > bound else { return false }
                    switch atTheBound {
                    case .quitAnyway:
                        log("quit: the lane did not free within \(bound); quitting anyway")
                        quit()
                    case .callOff:
                        log("quit: the lane did not free within \(bound); calling the quit off")
                        for store in stores { store.endTerminating() }
                        for (store, activity) in busy {
                            store.showStickyError(RemoteWording.quitWaitGaveUp(activity, after: bound))
                        }
                        callOff()
                    }
                    return true
                }
                log("quit: the lane is free after \(waited), quitting")
                quit()
                return true
            }
            if replied { timer.invalidate() }
        }
        RunLoop.main.add(timer, forMode: .common)
    }

    /// **Wait** was chosen (Ruling 8): every store begins terminating, and every read running on
    /// any lane is stopped — the spec's "every running read is cancelled"; only the write the user
    /// chose to wait for is let run. Returns what the call-off compares, per store: the count of
    /// lane messages as it was when the quit was asked for a store that had a write then (or has one
    /// now), and nil for every other — a read's failure in another window calls off no quit.
    static func beginWaiting(
        _ stores: [RepositoryStore], writesAsked: [Bool], messagesBefore: [Int]
    ) -> [Int?] {
        zip(stores, zip(writesAsked, messagesBefore)).map { store, asked in
            let (hadWrite, count) = asked
            store.beginTerminating()
            let writing = store.remoteActivity?.isWrite == true
            if store.remoteActivity != nil, !writing { store.cancelRemoteActivity() }
            return hadWrite || writing ? count : nil
        }
    }

    /// The store whose lane has ended, since the quit was asked, with something the user has to
    /// read (`laneMessagesToRead` moved past its count in `before`), and is free: its message is
    /// left on screen and the quit called off. Only the stores with a count are looked at.
    static func storeCallingOff(_ stores: [RepositoryStore], before: [Int?]) -> RepositoryStore? {
        zip(stores, before).first { store, count in
            guard let count else { return false }
            return store.remoteActivity == nil && store.laneMessagesToRead != count
        }?.0
    }

    /// The quit goes ahead: from here on a window's close is part of it, and leaves the
    /// open-repositories list alone (`WindowRegistry.beginAppTermination`).
    private static func quit() {
        AppModel.windows.beginAppTermination()
        NSApp.reply(toApplicationShouldTerminate: true)
    }

    /// The quit is called off: AppKit is told, and so is `QuitFlow`, so that the next ⌘Q starts
    /// afresh, and the window registry, whose closes count again.
    private static func callOff() {
        AppModel.windows.endAppTermination()
        NSApp.reply(toApplicationShouldTerminate: false)
        QuitFlow.quitEnded()
    }

    /// A `QUIT <time> …` line on stderr, DEBUG only. Internal: `QuitFlow` writes its lines here too.
    static func log(_ message: String) {
        #if DEBUG
            let time = Date.now.formatted(
                .dateTime.hour(.twoDigits(amPM: .omitted)).minute().second()
                    .secondFraction(.fractional(3)))
            FileHandle.standardError.write(Data("QUIT \(time) \(message)\n".utf8))
        #endif
    }
}

