import Foundation
import Testing

// The hang guard GitCoreTests and GitterTests share (E3 Task 2; before it, GitterTests kept a
// copy). `value`'s `what` is `@Sendable` because GitterTests waits from the main actor, and
// Swift 6 rejects sending a non-Sendable autoclosure out of it. Its own controls are
// `TimeLimitSupportTests` in GitCoreTests.
//
// A test's hang guard is Swift Testing's `.timeLimit`, not an upper bound on the test's own
// clock: that clock includes every wait for a thread of the cooperative pool, which a full
// parallel `swift test` keeps saturated (E1 survey S15–S17), so a bound on it fails slow runs
// that did not hang and, evaluated after the wait, never catches one that did.
//
// **What `.timeLimit` does, measured** (Swift 6.4, Testing 2084, a scratch package, E1 Task 1):
// - At the limit it records "Time limit was exceeded" and cancels the test's task. A body
//   waiting on something that observes cancellation (`Task.sleep`) then ends, and the run goes
//   on. A body stuck in `await task.value` on an **unstructured** task does not: that await does
//   not observe the cancel, so the issue is recorded but the test, and the whole run with it,
//   waits on for good (killed by hand after 90 s, 100 s and 240 s in three probes). Every
//   cancellation test here runs its call in an unstructured task, so it waits through
//   `CallUnderTest.value`, which ends the wait on the cancel. Probed end to end with a call that
//   never returns under `.timeLimit(.minutes(1))`: the issue at 60 s, the test over at 64 s,
//   and the next test run.
// - **Its clock counts the waits for the pool too.** A test whose body only slept ten times
//   100 ms, queued behind 900 tests blocking the pool, failed a one-minute limit ("failed after
//   96 s"). So the limit is a wall-clock bound like the ones it replaces, and it is set far
//   above what load adds: in E1's red run (full `swift test`, unbounded width, 28 `yes` loops,
//   load1 up to 121) the cancellation tests reported 103–299 s. Hence ten minutes in every
//   hang guard, not the five the spec first named.
// - A time-limit issue is **not** absorbed by `withKnownIssue` around the body (it is recorded
//   against the test's `@Test` line, outside the known-issue scope), and the shortest limit is
//   a minute. So no control here can let a real limit expire. Each control cancels the waiting
//   task itself, which is exactly what the limit does, and checks what the test then reports.
// - The limit cancels only the test's own task. A call the test started in a task of its own
//   is left running; a test that gives up on it may clean up after it.

/// What `CallUnderTest.value` records when the task that waits is cancelled first. A control
/// that expects the hang guard to fire matches this issue alone (`isNeverCameBack`), so it fails
/// if anything else — a thrown cancel, a call that came back — is what got recorded.
public let neverCameBack = "never came back: the test was cancelled (by its time limit) while it waited"

extension Issue {
    /// The issue `CallUnderTest.value` records for a wait that the test's cancel ended.
    public var isNeverCameBack: Bool { comments.contains { $0.rawValue.contains(neverCameBack) } }
}

/// A call under test, run in a task of its own so the test can cancel it and then wait for it —
/// and stop waiting when the test itself is cancelled, which is what `.timeLimit` does once a
/// test runs past its limit.
///
/// The call's own task hands its value to the waiters, so a wait costs no more hops of the
/// cooperative pool than `await task.value` does: the stress test makes 300 such waits, and
/// under load each hop is a wait for a thread.
///
/// Every wait goes through `value`, cleanup included: a bare `await task.value` is the one wait
/// a time limit cannot end, so the task is not exposed.
public final class CallUnderTest<Value: Sendable>: Sendable {
    private let task: Task<Value, Never>
    private let answers: Answers<Value>

    public init(_ operation: @escaping @Sendable () async -> Value) {
        let answers = Answers<Value>()
        self.answers = answers
        task = Task {
            let value = await operation()
            answers.finish(value)
            return value
        }
    }

    public func cancel() { task.cancel() }

    /// The call's value, whenever it comes first. If the task that waits is cancelled first,
    /// it records that the call never came back (`neverCameBack`) and returns nil. Each wait is
    /// its own: one ended by a cancel leaves the call to be waited for again.
    public func value(
        _ what: @autoclosure @Sendable () -> String = "the call", sourceLocation: SourceLocation = #_sourceLocation
    ) async -> Value? {
        let waiter = answers.newWaiter()
        let value = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Value?, Never>) in
                answers.install(waiter, continuation)
            }
        } onCancel: {
            answers.cancel(waiter)
        }
        if value == nil {
            Issue.record("\(what()) \(neverCameBack)", sourceLocation: sourceLocation)
        }
        return value
    }
}

/// The call's value once it has one, and the waits for it: each resumed exactly once, with the
/// value when it comes or nil when its own wait is cancelled first — which may happen before
/// the wait's continuation is installed (a test cancelled already).
private final class Answers<Value: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var finished = false
    private var result: Value?
    private var nextWaiter = 0
    private var waiting: [Int: CheckedContinuation<Value?, Never>] = [:]
    private var cancelledBeforeInstall: Set<Int> = []

    func newWaiter() -> Int {
        lock.lock()
        defer { lock.unlock() }
        nextWaiter += 1
        return nextWaiter
    }

    func install(_ waiter: Int, _ continuation: CheckedContinuation<Value?, Never>) {
        lock.lock()
        if finished {
            let result = self.result
            lock.unlock()
            continuation.resume(returning: result)
        } else if cancelledBeforeInstall.remove(waiter) != nil {
            lock.unlock()
            continuation.resume(returning: nil)
        } else {
            waiting[waiter] = continuation
            lock.unlock()
        }
    }

    func cancel(_ waiter: Int) {
        lock.lock()
        if let continuation = waiting.removeValue(forKey: waiter) {
            lock.unlock()
            continuation.resume(returning: nil)
            return
        }
        if !finished { cancelledBeforeInstall.insert(waiter) }
        lock.unlock()
    }

    func finish(_ value: Value) {
        lock.lock()
        finished = true
        result = value
        let all = waiting.values
        waiting = [:]
        lock.unlock()
        for continuation in all { continuation.resume(returning: value) }
    }
}

/// A call that never returns: its continuation is kept and never resumed, as by a runner that
/// lost its resume, and it ignores cancellation. The controls of the hang guards wait on one;
/// `release()` ends it, so a control leaves nothing suspended.
public final class StuckCall: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [CheckedContinuation<Void, Never>] = []

    public init() {}

    public func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            kept.append(continuation)
            lock.unlock()
        }
    }

    public func release() {
        lock.lock()
        let all = kept
        kept = []
        lock.unlock()
        for continuation in all { continuation.resume() }
    }

    public var waiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !kept.isEmpty
    }
}
