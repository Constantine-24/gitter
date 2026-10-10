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

    // MARK: - Controls

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
