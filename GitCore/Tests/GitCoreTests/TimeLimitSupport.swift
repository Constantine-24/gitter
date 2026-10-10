import Foundation
import GitCoreTestSupport
import Testing

// The hang guard itself (`CallUnderTest`, `StuckCall`, `neverCameBack`, and what `.timeLimit`
// does, measured) is in GitCoreTestSupport's TimeLimitSupport.swift, shared with GitterTests.

/// The controls for `CallUnderTest`, and through it for every hang guard that replaced a bound
/// on the test's clock: a call that really never returns is reported once the waiting task is
/// cancelled, and a call that returns is not. Each known issue is matched to the very issue the
/// hang guard records (`isNeverCameBack`), so a control fails when anything else is recorded.
@Suite struct TimeLimitSupportTests {
    /// Control: the stand-in for the limit (cancelling the waiting task) ends a wait that would
    /// otherwise never end, and the test then reports the call by name.
    @Test(.timeLimit(.minutes(10))) func aCallThatNeverReturnsIsReportedOnceTheWaitingTaskIsCancelled() async throws {
        let stuck = StuckCall()
        let call = CallUnderTest { () -> Int in
            await stuck.wait()
            return 1
        }
        while !stuck.waiting { try await Task.sleep(for: .milliseconds(5)) }

        await withKnownIssue("the call never returns, so the cancelled wait reports it") {
            let waiter = Task { await call.value("the stuck call") }
            try? await Task.sleep(for: .milliseconds(100))
            waiter.cancel()
            #expect(await waiter.value == nil, "the stuck call came back")
        } matching: { $0.isNeverCameBack }
        stuck.release()
        #expect(await call.value() == 1)
    }

    /// Non-vacuous the other way: a call that comes back is its value, with nothing recorded —
    /// whether it finishes while the test waits or before.
    @Test func aCallThatReturnsIsItsValue() async throws {
        let slow = CallUnderTest { () -> Int in
            try? await Task.sleep(for: .milliseconds(50))
            return 7
        }
        #expect(await slow.value() == 7)

        let quick = CallUnderTest { 8 }
        #expect(await quick.value() == 8)
        // Finished by now: the wait is answered from what the call left.
        #expect(await quick.value() == 8)
    }

    /// The cancel can come first: a wait that starts already cancelled ends at once.
    @Test(.timeLimit(.minutes(10))) func aWaitStartedAfterTheCancelEndsAtOnce() async throws {
        let stuck = StuckCall()
        let call = CallUnderTest { () -> Int in
            await stuck.wait()
            return 1
        }
        await withKnownIssue("the waiter was cancelled before it began to wait") {
            let waiter = Task { () -> Int? in
                withUnsafeCurrentTask { $0?.cancel() }
                return await call.value("the stuck call")
            }
            #expect(await waiter.value == nil, "the stuck call came back")
        } matching: { $0.isNeverCameBack }
        while !stuck.waiting { try await Task.sleep(for: .milliseconds(5)) }
        stuck.release()
        #expect(await call.value() == 1)
    }

    /// A wait the cancel ended spends nothing: the call can be waited for again, and that wait
    /// gets its value once it comes. (Each wait used to share one answer, so a second wait after
    /// a cancelled one installed a continuation nobody would ever resume.)
    @Test(.timeLimit(.minutes(10))) func aCallCanBeWaitedForAgainAfterACancelledWait() async throws {
        let stuck = StuckCall()
        let call = CallUnderTest { () -> Int in
            await stuck.wait()
            return 3
        }
        while !stuck.waiting { try await Task.sleep(for: .milliseconds(5)) }
        await withKnownIssue("the first wait is cancelled while the call is stuck") {
            let first = Task { await call.value("the stuck call") }
            try? await Task.sleep(for: .milliseconds(50))
            first.cancel()
            #expect(await first.value == nil, "the stuck call came back")
        } matching: { $0.isNeverCameBack }

        let second = Task { await call.value("the released call") }
        try await Task.sleep(for: .milliseconds(50))
        stuck.release()
        #expect(await second.value == 3)
    }

    /// The polling waits that had a deadline of their own (`WorktreeAddTests`,
    /// `WorktreeRemovalTests`) now poll until their limit: `Task.sleep` throws on the cancel,
    /// so a condition that never comes true ends the test rather than hanging it.
    @Test(.timeLimit(.minutes(10))) func aPollForAConditionThatNeverComesTrueEndsOnTheCancel() async throws {
        let poll = Task { () -> Error? in
            do {
                while true { try await Task.sleep(for: .milliseconds(20)) }
            } catch {
                return error
            }
        }
        try await Task.sleep(for: .milliseconds(100))
        poll.cancel()
        #expect(await poll.value is CancellationError)
    }
}
