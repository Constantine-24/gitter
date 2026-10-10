import Foundation
import Testing

@testable import Gitter

/// E2 Task 2: `QuitFlow`, the one way the app quits, on test stores with every AppKit call
/// injected — which sheets are attached, the terminate, the beep. AppKit refuses every quit while
/// a sheet is attached (M1.4), so the flow closes the sheets, waits until none is attached, and
/// only then terminates; and a flow that AppKit never answers must not stay under way (RF1).
///
/// Serialized: the flow's "under way" is the app's one static state, so two of these tests must
/// never overlap. Each test ends the quit it started (`quitEnded`) whatever happened. Outcomes and
/// counts are asserted, never durations; a hang ends through `CallUnderTest` at the time limit.
@MainActor @Suite(.serialized, .leavesTheRealDefaultsAlone) struct QuitFlowTests {

    /// What the injected environment saw and did.
    @MainActor final class Recorder {
        var stores: [RepositoryStore] = []
        /// Whether a sheet is attached; `detachAfterPolls` turns it false after that many looks.
        var attached = false
        var detachAfterPolls: Int?
        /// Whether the injected terminate is answered by AppKit asking the delegate.
        var asksOnTerminate = true
        var polls = 0
        var terminates = 0
        var beeps = 0
        var attachedAtTerminate: [Bool] = []
        var sheetsAtFirstPoll: [BranchSheet?]?

        func environment(poll: Duration, bound: Duration) -> QuitFlow.Environment {
            QuitFlow.Environment(
                stores: { self.stores },
                sheetsAttached: {
                    if self.sheetsAtFirstPoll == nil { self.sheetsAtFirstPoll = self.stores.map(\.activeSheet) }
                    self.polls += 1
                    if let after = self.detachAfterPolls, self.polls >= after { self.attached = false }
                    return self.attached
                },
                terminate: {
                    self.terminates += 1
                    self.attachedAtTerminate.append(self.attached)
                    if self.asksOnTerminate { QuitFlow.delegateWasAsked() }
                },
                beep: { self.beeps += 1 },
                poll: poll, bound: bound)
        }
    }

    /// `QuitFlow.run`, waited for through the hang guard.
    private func run(
        _ reason: QuitFlow.Reason, _ recorder: Recorder, poll: Duration = .milliseconds(5),
        bound: Duration, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> QuitFlow.Outcome? {
        let call = CallUnderTest { @MainActor in
            await QuitFlow.run(reason, environment: recorder.environment(poll: poll, bound: bound))
        }
        return await call.value("the quit flow", sourceLocation: sourceLocation)
    }

    private static let newBranch = BranchSheet.newBranch(startPoint: nil, startLabel: "main")

    @Test(.timeLimit(.minutes(10))) func everySheetIsClosedAndTheQuitWaitsUntilNoneIsAttached() async {
        defer { QuitFlow.quitEnded() }
        let (first, _, cleanFirst) = makeTestStore()
        defer { cleanFirst() }
        let (second, _, cleanSecond) = makeTestStore()
        defer { cleanSecond() }
        first.activeSheet = Self.newBranch
        second.activeSheet = .rename("main")
        let recorder = Recorder()
        recorder.stores = [first, second]
        recorder.attached = true
        recorder.detachAfterPolls = 3

        let outcome = await run(.menu, recorder, bound: .seconds(60))

        #expect(outcome == .terminateCalled)
        #expect(first.activeSheet == nil)
        #expect(second.activeSheet == nil)
        // Closed before the first look, not after it.
        #expect(recorder.sheetsAtFirstPoll?.count == 2)
        #expect(recorder.sheetsAtFirstPoll?.allSatisfy { $0 == nil } == true)
        #expect(recorder.polls >= 3)
        #expect(recorder.terminates == 1)
        #expect(recorder.attachedAtTerminate == [false])
        #expect(recorder.beeps == 0)
    }

    @Test(.timeLimit(.minutes(10))) func aSecondRequestWhileTheFirstWaitsIsIgnored() async {
        defer { QuitFlow.quitEnded() }
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        store.activeSheet = Self.newBranch
        let recorder = Recorder()
        recorder.stores = [store]
        recorder.attached = true
        let first = CallUnderTest { @MainActor in
            await QuitFlow.run(.menu, environment: recorder.environment(poll: .milliseconds(5), bound: .seconds(60)))
        }
        // The first flow is polling: under way, the sheet still attached.
        let polling = CallUnderTest { @MainActor () -> Bool in
            while recorder.polls == 0, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
            return recorder.polls > 0
        }
        #expect(await polling.value("the first flow polling") == true)
        #expect(QuitFlow.isUnderWay)

        let second = Recorder()
        second.stores = [store]
        let ignored = await run(.menu, second, bound: .seconds(60))
        #expect(ignored == .ignoredAlreadyUnderWay)
        #expect(second.polls == 0)
        #expect(second.terminates == 0)

        recorder.attached = false
        #expect(await first.value("the first quit flow") == .terminateCalled)
        #expect(recorder.terminates == 1)
    }

    @Test(.timeLimit(.minutes(10))) func aSheetThatNeverClosesLeavesTheAppRunning() async {
        defer { QuitFlow.quitEnded() }
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        store.activeSheet = Self.newBranch
        let recorder = Recorder()
        recorder.stores = [store]
        recorder.attached = true

        let outcome = await run(.appleEvent, recorder, bound: .milliseconds(100))

        #expect(outcome == .sheetsStillAttached)
        #expect(recorder.beeps == 1)
        #expect(recorder.terminates == 0)
        #expect(!QuitFlow.isUnderWay)
        // The next request starts afresh.
        recorder.attached = false
        #expect(await run(.menu, recorder, bound: .seconds(60)) == .terminateCalled)
        #expect(recorder.terminates == 1)
    }

    @Test(.timeLimit(.minutes(10))) func withNoSheetTheQuitGoesStraightThrough() async {
        defer { QuitFlow.quitEnded() }
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        let recorder = Recorder()
        recorder.stores = [store]

        let outcome = await run(.harness, recorder, bound: .seconds(60))

        #expect(outcome == .terminateCalled)
        #expect(recorder.terminates == 1)
        #expect(recorder.attachedAtTerminate == [false])
        #expect(recorder.beeps == 0)
        // AppKit asked (the injected terminate says so): the quit is QuitGuard's now, still
        // under way until it ends.
        #expect(QuitFlow.isUnderWay)
    }

    /// RF1: a terminate that AppKit drops without asking the delegate (a sheet that came back
    /// between the last look and the terminate) must not leave the flow under way, or every
    /// later ⌘Q would be ignored.
    @Test(.timeLimit(.minutes(10))) func aTerminateAppKitNeverAsksAboutEndsTheQuit() async {
        defer { QuitFlow.quitEnded() }
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        let recorder = Recorder()
        recorder.stores = [store]
        recorder.asksOnTerminate = false

        #expect(await run(.menu, recorder, bound: .milliseconds(100)) == .terminateCalled)
        #expect(!QuitFlow.isUnderWay)
        #expect(await run(.menu, recorder, bound: .milliseconds(100)) == .terminateCalled)
        #expect(recorder.terminates == 2)
    }

    /// A quit AppKit asks about by any path is under way until `QuitGuard` ends it: a request in
    /// the meantime never stacks a second flow (nor closes `QuitGuard`'s own question).
    @Test(.timeLimit(.minutes(10))) func aQuitTheDelegateIsAskedAboutIsUnderWayUntilItEnds() async {
        defer { QuitFlow.quitEnded() }
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        let recorder = Recorder()
        recorder.stores = [store]

        QuitFlow.delegateWasAsked()
        #expect(QuitFlow.isUnderWay)
        #expect(await run(.menu, recorder, bound: .seconds(60)) == .ignoredAlreadyUnderWay)
        #expect(recorder.terminates == 0)

        // Don't Quit, say.
        QuitFlow.quitEnded()
        #expect(!QuitFlow.isUnderWay)
        #expect(await run(.menu, recorder, bound: .seconds(60)) == .terminateCalled)
        #expect(recorder.terminates == 1)
    }
}
