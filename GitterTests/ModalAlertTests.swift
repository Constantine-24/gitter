import AppKit
import Foundation
import Testing

@testable import Gitter

/// E3 Task 1: `ModalAlert.raise` runs an app-modal alert from a one-shot run-loop timer, never
/// within the job that raises it. Measured (C3): `runModal` called inside a main-actor job or a
/// `DispatchQueue.main.async` block holds up every other main-actor job — another window's git
/// ending, a refresh — until the alert is dismissed, because the main queue is serial and the
/// modal loop runs inside the current block; from a run-loop source the main queue keeps draining.
///
/// `runModal` is the seam: no alert is ever put on screen here.
@MainActor @Suite struct ModalAlertTests {

    @MainActor final class Probe {
        var inCall = false
        var runs = 0
        var ranInsideCall: Bool?
        var response: NSApplication.ModalResponse?
    }

    private func raise(_ probe: Probe) {
        probe.inCall = true
        ModalAlert.raise(
            NSAlert(),
            runModal: { _ in
                probe.runs += 1
                probe.ranInsideCall = probe.inCall
                return .alertThirdButtonReturn
            },
            then: { probe.response = $0 })
        probe.inCall = false
    }

    @Test(.timeLimit(.minutes(10))) func theAlertRunsAfterTheCallReturnsAndItsAnswerIsHandedOn() async {
        let probe = Probe()
        raise(probe)
        #expect(probe.runs == 0)

        let answered = CallUnderTest { @MainActor () -> NSApplication.ModalResponse? in
            while probe.response == nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return probe.response
        }
        #expect(await answered.value("the alert's answer") == .alertThirdButtonReturn)
        #expect(probe.runs == 1)
        #expect(probe.ranInsideCall == false)
    }

    /// From the run loop, not the main queue — and in AppKit's modal-panel mode too: while
    /// `QuitGuard` holds a quit (`.terminateLater`) AppKit spins the main run loop in
    /// `NSModalPanelRunLoopMode` until the reply, so the quit's own question must be able to come
    /// up there. Spun here from inside this main-actor job, where no main-queue block can run (the
    /// controls below show that neither a main-queue block nor a `.default`-mode timer would).
    @Test(.timeLimit(.minutes(10))) func theAlertIsRunFromTheRunLoopEvenInItsModalPanelMode() {
        let probe = Probe()
        raise(probe)

        while probe.response == nil, !Task.isCancelled {
            _ = RunLoop.main.run(mode: .modalPanel, before: Date(timeIntervalSinceNow: 0.05))
        }

        #expect(probe.response == .alertThirdButtonReturn)
        #expect(probe.ranInsideCall == false)
    }

    /// Not `.common`: an alert does not start inside a menu's tracking or a live resize
    /// (`.eventTracking`), but waits for it to end — and then runs.
    @Test(.timeLimit(.minutes(10))) func theAlertWaitsOutEventTracking() {
        let probe = Probe()
        raise(probe)

        for _ in 0..<20 { _ = RunLoop.main.run(mode: .eventTracking, before: Date(timeIntervalSinceNow: 0.01)) }
        #expect(probe.runs == 0)

        // The same spin in a mode it is added to does run it.
        while probe.response == nil, !Task.isCancelled {
            _ = RunLoop.main.run(mode: .modalPanel, before: Date(timeIntervalSinceNow: 0.05))
        }
        #expect(probe.runs == 1)
    }

    // MARK: - Other main-actor work goes on under the alert (C3)

    /// What a draining `runModal` saw.
    @MainActor final class Drain {
        var queueBlockRan = false
        var actorJobRan = false
        /// Whether both jobs posted as the alert came up ran before it went: set as it goes.
        var bothRanUnderTheAlert: Bool?
        var firedInMode: RunLoop.Mode?
        var response: NSApplication.ModalResponse?
    }

    /// A stand-in for `runModal`: as it comes up it posts a main-queue block and a main-actor job —
    /// a lane's ending, a refresh — and then spins the run loop in its modal-panel mode, as
    /// `runModal` does, until both have run or 500 passes are over. The jobs are posted from
    /// inside, not before the raise, so that one that ran before the alert came up cannot count.
    private static func drainingRunModal(_ drain: Drain) -> @MainActor (NSAlert) -> NSApplication.ModalResponse {
        { _ in
            drain.firedInMode = RunLoop.current.currentMode
            DispatchQueue.main.async { MainActor.assumeIsolated { drain.queueBlockRan = true } }
            Task { @MainActor in drain.actorJobRan = true }
            var passes = 0
            while !(drain.queueBlockRan && drain.actorJobRan), passes < 500 {
                _ = RunLoop.main.run(mode: .modalPanel, before: Date(timeIntervalSinceNow: 0.01))
                passes += 1
            }
            drain.bothRanUnderTheAlert = drain.queueBlockRan && drain.actorJobRan
            return .alertFirstButtonReturn
        }
    }

    private func answer(of drain: Drain) async -> NSApplication.ModalResponse? {
        let answered = CallUnderTest { @MainActor () -> NSApplication.ModalResponse? in
            while drain.response == nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return drain.response
        }
        return await answered.value("the alert's answer") ?? nil
    }

    /// Raised while the app is idle: the timer fires in `.default` (C3f).
    @Test(.timeLimit(.minutes(10))) func otherMainActorWorkRunsUnderAnAlertRaisedWhileIdle() async {
        let drain = Drain()
        ModalAlert.raise(NSAlert(), runModal: Self.drainingRunModal(drain), then: { drain.response = $0 })

        #expect(await answer(of: drain) == .alertFirstButtonReturn)
        #expect(drain.firedInMode == .default)
        #expect(drain.bothRanUnderTheAlert == true)
    }

    /// Raised while AppKit holds a quit: `.terminateLater` is a loop in the modal-panel mode until
    /// the reply, entered from a run-loop source (`QuitFlow` performs the terminate from the run
    /// loop), and `QuitGuard.shouldTerminate` raises the question inside it. The outer loop is
    /// bounded by 500 passes, so a timer that cannot fire there fails the mode check instead of hanging.
    @Test(.timeLimit(.minutes(10))) func otherMainActorWorkRunsUnderAnAlertRaisedWhileAppKitHoldsAQuit() async {
        let drain = Drain()
        let held = Timer(timeInterval: 0, repeats: false) { _ in
            MainActor.assumeIsolated {
                ModalAlert.raise(NSAlert(), runModal: Self.drainingRunModal(drain), then: { drain.response = $0 })
                var passes = 0
                while drain.response == nil, passes < 500 {
                    _ = RunLoop.main.run(mode: .modalPanel, before: Date(timeIntervalSinceNow: 0.01))
                    passes += 1
                }
            }
        }
        RunLoop.main.add(held, forMode: .default)

        #expect(await answer(of: drain) == .alertFirstButtonReturn)
        #expect(drain.firedInMode == .modalPanel)
        #expect(drain.bothRanUnderTheAlert == true)
    }

    // MARK: - Controls

    /// The drain's control: an alert run from a main-queue block, `QuitGuard`'s old form (C3g),
    /// holds up both jobs until it is gone.
    @Test(.timeLimit(.minutes(10))) func control_underAnAlertRunFromAMainQueueBlockNothingElseRuns() async {
        let drain = Drain()
        DispatchQueue.main.async {
            MainActor.assumeIsolated { drain.response = Self.drainingRunModal(drain)(NSAlert()) }
        }

        #expect(await answer(of: drain) == .alertFirstButtonReturn)
        withKnownIssue("a main-queue block's modal loop cannot run another main-queue job") {
            #expect(drain.bothRanUnderTheAlert == true)
        }
    }

    @Test func control_anAlertRunInsideTheCallIsCaught() {
        let probe = Probe()
        raise(probe)
        withKnownIssue("raised from a timer: it has not run when the call returns") {
            #expect(probe.runs == 1)
        }
    }

    /// The modal-panel test's spin cannot run a main-queue block — `QuitGuard`'s old
    /// `DispatchQueue.main.async { runModal }` (C3g).
    @Test func control_aMainQueueBlockDoesNotRunInsideTheSpin() {
        let probe = Probe()
        DispatchQueue.main.async { MainActor.assumeIsolated { probe.runs += 1 } }
        for _ in 0..<20 { _ = RunLoop.main.run(mode: .modalPanel, before: Date(timeIntervalSinceNow: 0.01)) }
        withKnownIssue("the main queue is serial and this job is on it") {
            #expect(probe.runs == 1)
        }
    }

    /// The modal-panel test's spin cannot fire a timer added in `.default` mode alone.
    @Test func control_aDefaultModeTimerDoesNotFireInTheModalPanelMode() {
        let probe = Probe()
        let timer = Timer(timeInterval: 0, repeats: false) { _ in MainActor.assumeIsolated { probe.runs += 1 } }
        RunLoop.main.add(timer, forMode: .default)
        defer { timer.invalidate() }
        for _ in 0..<20 { _ = RunLoop.main.run(mode: .modalPanel, before: Date(timeIntervalSinceNow: 0.01)) }
        withKnownIssue("a .default-mode timer does not fire in the modal-panel mode") {
            #expect(probe.runs == 1)
        }
    }
}
