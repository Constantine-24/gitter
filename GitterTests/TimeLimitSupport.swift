import Foundation
import Testing

// A verbatim copy of `CallUnderTest`, `Answers`, `neverCameBack`, `Issue.isNeverCameBack` and
// `StuckCall` from GitCore/Tests/GitCoreTests/TimeLimitSupport.swift (E1 Task 1). GitCore's test
// helpers are internal to that test target and not visible here; the copy is what makes a hang in
// a GitterTest fail the test through `.timeLimit(.minutes(10))` instead of freezing the run. The
// reasoning (what `.timeLimit` does and does not end, why ten minutes) is in that file's header.
// Change the two together. The one difference: `value`'s `what` is `@Sendable`, because the
// waits here are made from the main actor and Swift 6 rejects sending a non-Sendable autoclosure
// out of it.

/// What `CallUnderTest.value` records when the task that waits is cancelled first. A control
/// that expects the hang guard to fire matches this issue alone (`isNeverCameBack`), so it fails
/// if anything else — a thrown cancel, a call that came back — is what got recorded.
let neverCameBack = "never came back: the test was cancelled (by its time limit) while it waited"

extension Issue {
    /// The issue `CallUnderTest.value` records for a wait that the test's cancel ended.
    var isNeverCameBack: Bool { comments.contains { $0.rawValue.contains(neverCameBack) } }
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
final class CallUnderTest<Value: Sendable>: Sendable {
    private let task: Task<Value, Never>
    private let answers: Answers<Value>

    init(_ operation: @escaping @Sendable () async -> Value) {
        let answers = Answers<Value>()
        self.answers = answers
        task = Task {
            let value = await operation()
            answers.finish(value)
            return value
        }
    }

    func cancel() { task.cancel() }

    /// The call's value, whenever it comes first. If the task that waits is cancelled first,
    /// it records that the call never came back (`neverCameBack`) and returns nil. Each wait is
    /// its own: one ended by a cancel leaves the call to be waited for again.
    func value(
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
final class StuckCall: @unchecked Sendable {
    private let lock = NSLock()
    private var kept: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        await withCheckedContinuation { continuation in
            lock.lock()
            kept.append(continuation)
            lock.unlock()
        }
    }

    func release() {
        lock.lock()
        let all = kept
        kept = []
        lock.unlock()
        for continuation in all { continuation.resume() }
    }

    var waiting: Bool {
        lock.lock()
        defer { lock.unlock() }
        return !kept.isEmpty
    }
}

