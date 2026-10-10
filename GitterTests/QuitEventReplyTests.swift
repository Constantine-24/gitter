import AppKit
import Foundation
import Testing

@testable import Gitter

/// E3 Task 1: the quit Apple Event's reply (the Dock's Quit, a logout, a shutdown) is held until
/// the quit's outcome and then answered once — `userCanceledErr` (−128) when the quit is called
/// off, 0 when it goes ahead (measurements A1, A2). The suspend, reply and resume go through
/// `QuitFlow.replies`, which these tests swap for a recording fake; every ending path is driven and
/// each held id must be answered exactly once, with the right number.
///
/// Nested in `QuitFlowTests`, whose `.serialized` covers it: the held list, `QuitFlow.replies` and
/// "under way" are the app's one static state, so none of these may overlap a `QuitFlow` test.
/// Every test puts the live replies back after answering whatever is still held into the fake, so
/// no made-up id ever reaches the real `NSAppleEventManager`.
extension QuitFlowTests {

    /// Hands out ids 1, 2, 3, … from `suspendCurrent` (or nil, as with no event being handled:
    /// ⌘Q, the menu — A4), and records every answer, in order. The ids are made up and never
    /// dereferenced.
    @MainActor final class RecordingReplies: QuitEventReplies {
        struct Answer: Equatable, CustomStringConvertible {
            let id: Int
            let errorNumber: Int32
            init(_ id: Int, _ errorNumber: Int32) {
                self.id = id
                self.errorNumber = errorNumber
            }
            var description: String { "(\(id), \(errorNumber))" }
        }

        var handsOutIDs = true
        private var next = 0
        private(set) var answers: [Answer] = []
        /// The answers and AppKit's replies in the order they happened (`reply(…)` lines are
        /// appended by the tests' reply seam).
        var events: [String] = []

        func suspendCurrent() -> NSAppleEventManager.SuspensionID? {
            guard handsOutIDs else { return nil }
            next += 1
            return OpaquePointer(bitPattern: next)
        }

        func answer(_ id: NSAppleEventManager.SuspensionID, errorNumber: Int32) {
            let answer = Answer(Int(bitPattern: id), errorNumber)
            answers.append(answer)
            events.append("answer\(answer)")
        }
    }

    @MainActor @Suite(.leavesTheRealDefaultsAlone) struct QuitEventReplyTests {
        static let calledOff = Int32(userCanceledErr)

        /// The fake in place of AppKit, and how to put AppKit back.
        private func installRecording() -> (RecordingReplies, restore: @MainActor () -> Void) {
            let fake = RecordingReplies()
            QuitFlow.replies = fake
            return (
                fake,
                {
                    QuitFlow.answerHeldQuitEvents(quitting: false)
                    QuitFlow.replies = AppleEventReplies()
                }
            )
        }

        @Test func aCalledOffQuitAnswersEveryHeldEventOnceWithUserCanceled() {
            #expect(Self.calledOff == -128)
            let (fake, restore) = installRecording()
            defer { restore() }

            QuitFlow.holdCurrentQuitEvent()
            QuitFlow.holdCurrentQuitEvent()
            #expect(QuitFlow.heldQuitEvents.count == 2)
            QuitFlow.answerHeldQuitEvents(quitting: false)

            #expect(fake.answers == [.init(1, -128), .init(2, -128)])
            #expect(QuitFlow.heldQuitEvents.isEmpty)
            // Idempotent: nothing is answered twice.
            QuitFlow.answerHeldQuitEvents(quitting: false)
            QuitFlow.answerHeldQuitEvents(quitting: true)
            #expect(fake.answers == [.init(1, -128), .init(2, -128)])
        }

        @Test func aQuitThatGoesAheadAnswersTheHeldEventWithZero() {
            let (fake, restore) = installRecording()
            defer { restore() }

            QuitFlow.holdCurrentQuitEvent()
            QuitFlow.answerHeldQuitEvents(quitting: true)

            #expect(fake.answers == [.init(1, 0)])
            #expect(QuitFlow.heldQuitEvents.isEmpty)
        }

        /// ⌘Q, the menu's Quit, the harness `quit`: no event is being handled (A4).
        @Test func withNoEventNothingIsHeldAndNothingAnswered() {
            let (fake, restore) = installRecording()
            defer { restore() }
            fake.handsOutIDs = false

            QuitFlow.holdCurrentQuitEvent()
            #expect(QuitFlow.heldQuitEvents.isEmpty)
            QuitFlow.answerHeldQuitEvents(quitting: false)
            QuitFlow.answerHeldQuitEvents(quitting: true)
            #expect(fake.answers.isEmpty)
        }

        /// RF1: an event held after a call-off belongs to the next outcome, and only to it.
        @Test func eachOutcomeAnswersOnlyTheEventsHeldBeforeIt() {
            let (fake, restore) = installRecording()
            defer { restore() }

            QuitFlow.holdCurrentQuitEvent()
            QuitFlow.holdCurrentQuitEvent()
            QuitFlow.answerHeldQuitEvents(quitting: false)
            QuitFlow.holdCurrentQuitEvent()
            QuitFlow.answerHeldQuitEvents(quitting: true)

            #expect(fake.answers == [.init(1, -128), .init(2, -128), .init(3, 0)])
            #expect(QuitFlow.heldQuitEvents.isEmpty)
        }

        // MARK: - The outcomes are wired

        /// `QuitFlow.run` through the hang guard, on `recorder`'s injected AppKit.
        private func run(
            _ recorder: Recorder, bound: Duration, sourceLocation: SourceLocation = #_sourceLocation
        ) async -> QuitFlow.Outcome? {
            let call = CallUnderTest { @MainActor in
                await QuitFlow.run(
                    .appleEvent, environment: recorder.environment(poll: .milliseconds(5), bound: bound))
            }
            return await call.value("the quit flow", sourceLocation: sourceLocation)
        }

        @Test(.timeLimit(.minutes(10))) func sheetsThatNeverDetachAnswerTheHeldEventCalledOff() async {
            defer { QuitFlow.quitEnded() }
            let (fake, restore) = installRecording()
            defer { restore() }
            let recorder = Recorder()
            recorder.attached = true

            QuitFlow.holdCurrentQuitEvent()
            #expect(await run(recorder, bound: .milliseconds(100)) == .sheetsStillAttached)

            #expect(fake.answers == [.init(1, -128)])
            #expect(QuitFlow.heldQuitEvents.isEmpty)
        }

        @Test(.timeLimit(.minutes(10))) func aTerminateAppKitNeverAsksAboutAnswersTheHeldEventCalledOff() async {
            defer { QuitFlow.quitEnded() }
            let (fake, restore) = installRecording()
            defer { restore() }
            let recorder = Recorder()
            recorder.asksOnTerminate = false

            QuitFlow.holdCurrentQuitEvent()
            #expect(await run(recorder, bound: .milliseconds(100)) == .terminateCalled)

            #expect(recorder.terminates == 1)
            #expect(fake.answers == [.init(1, -128)])
            #expect(QuitFlow.heldQuitEvents.isEmpty)
        }

        /// The flow's own success hands the quit to `QuitGuard`, whose outcome answers it.
        @Test(.timeLimit(.minutes(10))) func aQuitAppKitAsksAboutLeavesTheHeldEventForQuitGuard() async {
            defer { QuitFlow.quitEnded() }
            let (fake, restore) = installRecording()
            defer { restore() }
            let recorder = Recorder()

            QuitFlow.holdCurrentQuitEvent()
            #expect(await run(recorder, bound: .seconds(60)) == .terminateCalled)

            #expect(fake.answers.isEmpty)
            #expect(QuitFlow.heldQuitEvents.count == 1)
        }

        /// A2d: a second quit event while a quit is under way is held too, and answered with the
        /// first one's outcome.
        @Test(.timeLimit(.minutes(10))) func anEventDuringAQuitUnderWayIsHeldForItsOutcome() async {
            defer { QuitFlow.quitEnded() }
            let (fake, restore) = installRecording()
            defer { restore() }
            defer { AppModel.windows.endAppTermination() }

            QuitFlow.delegateWasAsked()
            QuitFlow.holdCurrentQuitEvent()
            #expect(await run(Recorder(), bound: .seconds(60)) == .ignoredAlreadyUnderWay)
            #expect(fake.answers.isEmpty)
            #expect(QuitFlow.heldQuitEvents.count == 1)

            QuitGuard.calledOff(reply: { _ in })
            #expect(fake.answers == [.init(1, -128)])
        }

        @Test func quitGuardCallingOffAnswersTheHeldEventsWithUserCanceled() {
            defer { QuitFlow.quitEnded() }
            let (fake, restore) = installRecording()
            defer { restore() }
            defer { AppModel.windows.endAppTermination() }

            QuitFlow.delegateWasAsked()
            QuitFlow.holdCurrentQuitEvent()
            QuitFlow.holdCurrentQuitEvent()
            QuitGuard.calledOff(reply: { fake.events.append("reply(\($0))") })

            #expect(fake.answers == [.init(1, -128), .init(2, -128)])
            #expect(fake.events == ["answer(1, -128)", "answer(2, -128)", "reply(false)"])
            #expect(QuitFlow.heldQuitEvents.isEmpty)
            #expect(!QuitFlow.isUnderWay)
        }

        /// Answered before the reply to AppKit, which may end the process.
        @Test func quitGuardGoingAheadAnswersTheHeldEventWithZeroBeforeTheReply() {
            defer { QuitFlow.quitEnded() }
            let (fake, restore) = installRecording()
            defer { restore() }
            defer { AppModel.windows.endAppTermination() }

            QuitFlow.holdCurrentQuitEvent()
            QuitGuard.wentAhead(reply: { fake.events.append("reply(\($0))") })

            #expect(fake.events == ["answer(1, 0)", "reply(true)"])
            #expect(QuitFlow.heldQuitEvents.isEmpty)
            #expect(AppModel.windows.isTerminating)
        }

        /// `.terminateNow`: with every lane free the quit goes ahead at once.
        @Test func aQuitWithEveryLaneFreeAnswersTheHeldEventWithZero() {
            defer { QuitFlow.quitEnded() }
            let (fake, restore) = installRecording()
            defer { restore() }
            defer { AppModel.windows.endAppTermination() }

            QuitFlow.holdCurrentQuitEvent()
            #expect(QuitGuard.shouldTerminate([]) == .terminateNow)

            #expect(fake.answers == [.init(1, 0)])
            #expect(QuitFlow.heldQuitEvents.isEmpty)
        }

        /// The fake's control: the comparison these tests rest on can fail.
        @Test func control_wrongExpectedAnswersAreCaught() {
            let (fake, restore) = installRecording()
            defer { restore() }

            QuitFlow.holdCurrentQuitEvent()
            QuitFlow.answerHeldQuitEvents(quitting: false)
            withKnownIssue("a called-off quit answers −128, not 0") {
                #expect(fake.answers == [.init(1, 0)])
            }
        }
    }
}
