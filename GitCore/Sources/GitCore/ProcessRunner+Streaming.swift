import Foundation

extension ProcessRunner {
    /// What a finished `runStreaming` hands back: stdout as bytes, and the whole of stderr —
    /// on success too, because git writes the interesting part of a network operation there
    /// (`remote:` lines, the hosting service's pull-request URL) while exiting 0.
    public struct StreamedResult: Sendable {
        public let stdout: Data
        public let stderr: String
        /// `Process.terminationStatus`: `0`, or one of `allowedExitCodes` — any other value is
        /// a `GitError.commandFailed` and never reaches here.
        ///
        /// It is on the result because a caller that allows a non-zero code has no other way
        /// to ask what happened. `CLIGitBackend.push` allows exit 1 so that a rejection's
        /// stdout survives (every rejection exits 1, and the outcome lives on stdout); when
        /// git then prints no porcelain line for the ref it was given, the code is all that is
        /// left to report, and reporting an assumed one would be inventing evidence.
        ///
        /// **It is not always an exit status.** For a child killed by a signal,
        /// `terminationStatus` is the **signal number** and only `terminationReason` says so —
        /// measured on macOS 27 / Foundation: `SIGTERM` gives 15, `SIGHUP` gives **1**, and
        /// `exit 3` gives 3, all through this same field. So a git killed by `SIGHUP` arrives
        /// here as `exitCode == 1`, indistinguishable from the ordinary rejection code, and a
        /// signal whose number is not allowed is a `commandFailed` carrying that number as if
        /// it were a status.
        ///
        /// That is left as it is, deliberately, because nothing reads this field as a *cause*:
        /// it is reported alongside git's stderr on a path that is already a failure whatever
        /// ended the child (`CLIGitBackend+Push.swift`'s "no porcelain line for the ref we
        /// asked about"). A caller that ever needs to tell a signal from an exit must have
        /// `terminationReason` carried here too — it is not derivable from this number.
        /// `aSignalledChildsStatusIsTheSignalNumber` pins the measurement.
        public let exitCode: Int32

        public init(stdout: Data, stderr: String, exitCode: Int32) {
            self.stdout = stdout
            self.stderr = stderr
            self.exitCode = exitCode
        }
    }

    /// Runs an executable like `run`, reporting stderr as it arrives and ending when the
    /// calling task is cancelled.
    ///
    /// `onStderr` receives each stderr segment as it is completed, split on `\r` and `\n` with
    /// empty segments dropped — so git's `Counting objects:  50% (2/4)\r…` counters arrive one
    /// per update and a caller can replace the previous line rather than accumulate it. The
    /// split is done on bytes and the unterminated tail is carried over, so a segment spread
    /// across two reads is delivered once and a multi-byte character cut at a read boundary is
    /// not corrupted; whatever is still pending when stderr reaches EOF is delivered then.
    ///
    /// **`onStderr` is called from a background queue** — the file handle's readability queue,
    /// never the caller's executor — and it is called before this function returns. It must be
    /// safe to run off the main actor, and it must not block: the pipe is not drained while it
    /// runs. Every call for one process is serialized and in order.
    ///
    /// Segments arrive with git's own trailing padding spaces: it pads each progress line out
    /// to erase the longer one before it (`remote: Counting objects: 100% (12/12)        \r`,
    /// measured against `git clone --progress`). A caller that displays a segment trims it.
    ///
    /// Cancelling the task terminates the process and the call then throws `CancellationError`,
    /// never a `GitError.commandFailed` invented from the signal exit. A cancel that arrives
    /// before the process is launched prevents the launch.
    ///
    /// Measured on this OS: `Foundation.Process` starts the child in a process group of its own
    /// whose id is the child's pid, and `terminate()` signals that whole group — so a
    /// grandchild (git's transport under an `--upload-pack` wrapper script, say) dies with the
    /// child instead of outliving it and holding the inherited pipe ends open. A bare
    /// `kill <pid>` from a shell would not reach that grandchild; `terminate()` does.
    ///
    /// What SIGTERM cannot do is end a child that ignores it — `/bin/sh -c "trap '' TERM;
    /// sleep 30"` kept a cancelled call waiting 29.7 s — so the cancel escalates. If the
    /// process has still not been *observed to terminate* `killGracePeriod` after the SIGTERM,
    /// its process group is sent SIGKILL, which nothing can ignore.
    ///
    /// A cancelled call throws, which discards the stdout captured so far. A caller that
    /// cancelled a WRITE therefore knows nothing about how much of it happened: it must re-read
    /// the repository's state, and must never report the cancel as "nothing changed".
    ///
    /// The environment, the `/dev/null` stdin and the pipe-draining rule are `run`'s; see
    /// `ProcessRunner.run` for why nothing but a readability handler ever reads a pipe.
    /// `StreamingRunnerTests.bothRunnersGiveTheChildTheSameEnvironmentAndStdin` pins the two
    /// hand-written copies together.
    ///
    /// - Throws: `GitError.launchFailed` if the executable cannot be started,
    ///   `GitError.commandFailed` on an exit code that is neither 0 nor in `allowedExitCodes`,
    ///   `CancellationError` if the task was cancelled.
    public func runStreaming(
        _ executable: String, _ arguments: [String], cwd: URL,
        allowedExitCodes: Set<Int32> = [],
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> StreamedResult {
        try await runStreaming(
            executable, arguments, cwd: cwd, allowedExitCodes: allowedExitCodes,
            onLaunch: nil, onStderr: onStderr)
    }

    /// The implementation, with the two seams the tests need.
    ///
    /// - Parameter killGracePeriod: how long a cancelled process is given to act on its
    ///   SIGTERM before its process group is sent SIGKILL. Two seconds in production; a test
    ///   that only needs to prove the wait is real passes a short one rather than sleeping it.
    /// - Parameter onLaunch: called with the child's pid once `run()` has succeeded, from
    ///   whatever thread started it. It exists so a cancellation test can ask the kernel
    ///   whether the process is really gone; production callers use the public overload.
    func runStreaming(
        _ executable: String, _ arguments: [String], cwd: URL,
        allowedExitCodes: Set<Int32> = [],
        killGracePeriod: Duration = .seconds(2),
        onLaunch: (@Sendable (Int32) -> Void)?,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> StreamedResult {
        // Built before the cancellation handler is installed, because `onCancel` can run at
        // any moment from any thread — including before the operation closure is entered, if
        // the task is cancelled already — and it has nowhere to record that but here.
        let state = StreamingProcessState(killGracePeriod: killGracePeriod)

        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation {
                (continuation: CheckedContinuation<StreamedResult, Error>) in
                let process = Process()
                process.executableURL = URL(fileURLWithPath: executable)
                process.arguments = arguments
                process.currentDirectoryURL = cwd

                var env = ProcessInfo.processInfo.environment
                env["GIT_TERMINAL_PROMPT"] = "0"
                env["LC_ALL"] = "C"
                env["GIT_OPTIONAL_LOCKS"] = "0"
                env["GIT_EDITOR"] = "true"
                process.environment = env

                let stdout = Pipe()
                let stderr = Pipe()
                process.standardOutput = stdout
                process.standardError = stderr
                process.standardInput = FileHandle.nullDevice

                // Same shape, and the same reasons, as `ProcessRunner.run`: each pipe is
                // drained only by its own readability handler, so a chatty stderr cannot
                // deadlock an idle stdout and no second reader can race a chunk out of order.
                // `finish` captures both pipes to keep them alive until their EOF callbacks
                // have arrived; the handlers hold `finish`, and nil'ing them at EOF breaks
                // that cycle.
                let finish: @Sendable () -> Void = { [state, stdout, stderr] in
                    _ = stdout
                    _ = stderr
                    switch state.claimResumeIfComplete() {
                    case nil:
                        return
                    case .cancelled:
                        continuation.resume(throwing: CancellationError())
                    case .finished(let status, let out, let err):
                        let text = String(decoding: err, as: UTF8.self)
                        if status == 0 || allowedExitCodes.contains(status) {
                            continuation.resume(
                                returning: StreamedResult(
                                    stdout: out, stderr: text, exitCode: status))
                        } else {
                            continuation.resume(
                                throwing: GitError.commandFailed(
                                    exitCode: status,
                                    stderr: text.trimmingCharacters(in: .whitespacesAndNewlines)))
                        }
                    }
                }

                stdout.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        state.markStdoutFinished()
                        finish()
                    } else {
                        state.appendStdout(chunk)
                    }
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        // The unterminated tail is a segment too, and this is its only
                        // chance: delivered before `finish`, so every segment has reached the
                        // caller by the time the call returns.
                        for segment in state.markStderrFinished() { onStderr(segment) }
                        finish()
                    } else {
                        for segment in state.appendStderr(chunk) { onStderr(segment) }
                    }
                }

                process.terminationHandler = { proc in
                    state.recordTermination(proc.terminationStatus)
                    finish()
                }

                // Cancelled before the process exists: nothing is launched, and no handler can
                // ever run, so claiming the resume here is safe and final. A cancel arriving
                // just after this check instead lands on `registerLaunched` below.
                guard !Task.isCancelled else {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    if state.claimResumeWithoutLaunching() {
                        continuation.resume(throwing: CancellationError())
                    }
                    return
                }

                do {
                    try process.run()
                } catch {
                    stdout.fileHandleForReading.readabilityHandler = nil
                    stderr.fileHandleForReading.readabilityHandler = nil
                    if state.claimResumeWithoutLaunching() {
                        continuation.resume(
                            throwing: GitError.launchFailed(error.localizedDescription))
                    }
                    return
                }

                // Hands the process to the cancellation handler, and terminates it right away
                // if the cancel got here first — the window between the check above and this
                // line is exactly the race `registerLaunched` closes.
                state.registerLaunched(process)
                onLaunch?(process.processIdentifier)
            }
        } onCancel: {
            state.requestCancellation()
        }
    }
}

/// Mutable state shared by the two readability handlers, the termination handler, the
/// cancellation handler and the launching thread of a single `runStreaming` call.
///
/// `@unchecked Sendable` on the same terms as `run`'s `ProcessState`: every stored property is
/// touched only under `lock`. Signalling the child — `terminate()`, and the SIGKILL that may
/// follow it — is deliberately done *outside* the lock, after the decision to do it has been
/// recorded inside. That is sound because the decision, not the signal, is the shared state:
/// the `terminateSent` / `killSent` flags are set under the lock by whichever thread wins, so
/// each signal is sent at most once no matter how many threads raced for it, and the signal
/// itself touches nothing this class owns. Doing it the other way round would be worse than
/// merely unnecessary: `Process.terminate()` and `kill` are kernel calls made while the
/// termination handler, on another thread, may already be waiting on this very lock to record
/// the exit — holding the lock across them would serialise the two for no gain.
///
/// It keeps `run`'s three-signal rule — stdout EOF, stderr EOF and termination must all have
/// arrived before the continuation is resumed — and adds four things: the byte-level carry-
/// over for a stderr segment that spans two reads, the `cancelled` flag that turns a completed
/// run into a `CancellationError`, the process itself, so the cancellation handler has
/// something to terminate, and the pending escalation that turns an ignored SIGTERM into a
/// SIGKILL.
private final class StreamingProcessState: @unchecked Sendable {
    /// What the first caller to observe all three signals is told to resume with.
    enum Resumption {
        case cancelled
        case finished(status: Int32, stdout: Data, stderr: Data)
    }

    private let killGracePeriod: Duration
    private let lock = NSLock()
    private var outBuffer = Data()
    private var errBuffer = Data()
    /// stderr bytes since the last `\r` or `\n`: a segment that is not complete yet. Bytes,
    /// not characters, because a read can end in the middle of a multi-byte one and decoding
    /// the fragment would replace it with U+FFFD.
    private var pendingSegment: [UInt8] = []
    private var stdoutFinished = false
    private var stderrFinished = false
    private var status: Int32?
    private var resumed = false
    private var cancelled = false
    private var process: Process?
    private var terminateSent = false
    private var killSent = false
    private var killWork: DispatchWorkItem?

    init(killGracePeriod: Duration) {
        self.killGracePeriod = killGracePeriod
    }

    func appendStdout(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        outBuffer.append(chunk)
    }

    /// Adds `chunk` to the captured stderr and returns the segments it completed, in order.
    func appendStderr(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        errBuffer.append(chunk)
        pendingSegment.append(contentsOf: chunk)

        var segments: [String] = []
        var start = 0
        for index in pendingSegment.indices
        where pendingSegment[index] == UInt8(ascii: "\n") || pendingSegment[index] == UInt8(ascii: "\r") {
            // Empty segments are dropped: a `\r\n`, or a blank line, is a separator and not an
            // update worth showing.
            if index > start {
                segments.append(String(decoding: pendingSegment[start..<index], as: UTF8.self))
            }
            start = index + 1
        }
        if start > 0 { pendingSegment.removeFirst(start) }
        return segments
    }

    func markStdoutFinished() {
        lock.lock()
        defer { lock.unlock() }
        stdoutFinished = true
    }

    /// Records stderr's EOF and returns the trailing partial segment, if the child ended
    /// without a final separator.
    func markStderrFinished() -> [String] {
        lock.lock()
        defer { lock.unlock() }
        stderrFinished = true
        guard !pendingSegment.isEmpty else { return [] }
        let tail = String(decoding: pendingSegment, as: UTF8.self)
        pendingSegment.removeAll()
        return [tail]
    }

    func recordTermination(_ terminationStatus: Int32) {
        lock.lock()
        defer { lock.unlock() }
        status = terminationStatus
    }

    /// Terminates the process if it is running, and makes every later completion a
    /// `CancellationError`.
    ///
    /// It never resumes the continuation itself. That is what keeps the exactly-once argument
    /// small: whatever happens, the continuation is resumed by the first claimer of the three
    /// signals, by the pre-launch bail-out, or by the launch failure — and those three are
    /// mutually exclusive.
    func requestCancellation() {
        lock.lock()
        cancelled = true
        // Not after termination has been recorded: the pid is reaped by then and SIGTERM
        // would be aimed at whatever the system gave that number next.
        let target = (process != nil && !terminateSent && status == nil) ? process : nil
        if target != nil { terminateSent = true }
        lock.unlock()
        if let target, target.isRunning { terminate(target) }
    }

    /// Publishes the launched process to the cancellation handler, terminating it at once if
    /// the cancel arrived while it was starting.
    func registerLaunched(_ launched: Process) {
        lock.lock()
        process = launched
        let shouldTerminate = cancelled && !terminateSent && status == nil
        if shouldTerminate { terminateSent = true }
        lock.unlock()
        if shouldTerminate, launched.isRunning { terminate(launched) }
    }

    /// Sends the SIGTERM and arms the escalation behind it. Called outside the lock, at most
    /// once per run — `terminateSent` is what guarantees that.
    ///
    /// The escalation is a `DispatchWorkItem` rather than a timer source on purpose: a source
    /// must be resumed before it may be released, and the branch below that decides *not* to
    /// arm one would have had to release a suspended source, which traps inside libdispatch
    /// (`_dispatch_lane_suspend` from `_xref_dispose`). A work item has no such rule, and
    /// `cancel()` on one that has not started yet means it simply never runs.
    private func terminate(_ target: Process) {
        target.terminate()

        // Weak, so a pending escalation keeps nothing alive; and every path that ends the run
        // cancels it, so it cannot act after the continuation has resumed.
        let escalation = DispatchWorkItem { [weak self] in self?.escalateToKill() }
        let grace = killGracePeriod.components
        let seconds = Double(grace.seconds) + Double(grace.attoseconds) / 1e18

        lock.lock()
        let stillWorthArming = !resumed && !killSent && status == nil
        if stillWorthArming { killWork = escalation }
        lock.unlock()
        guard stillWorthArming else { return }
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + seconds, execute: escalation)
    }

    /// The grace period is up. If the process has still not been *observed* to terminate, kill
    /// its process group.
    private func escalateToKill() {
        lock.lock()
        // `status == nil` is the same rule as the SIGTERM's, and it matters more here: once
        // termination has been recorded the pid is reaped, and a signal aimed at it would land
        // on whatever the system handed that number to next.
        let target = (!killSent && !resumed && status == nil) ? process : nil
        if target != nil { killSent = true }
        killWork = nil
        lock.unlock()

        guard let target, target.isRunning else { return }
        let pid = target.processIdentifier
        // Nothing below may ever be reached with a pid of 0 (`kill` would signal *our* whole
        // process group) or -1 (every process we may signal). `Process` only reports a pid
        // above 1 for a running child, but the consequence of a bug here is severe enough to
        // be worth the two comparisons.
        guard pid > 1 else { return }
        // Measured on macOS: a `Foundation.Process` child is the leader of a process group of
        // its own, so its pgid is its pid and `kill(-pgid, …)` reaches it and everything it
        // started. The equality is checked rather than assumed: if it does not hold, the group
        // is somebody else's — possibly ours — and only the child itself is signalled.
        // `getpgid` returning -1 means the pid is already gone; nothing is signalled then.
        let group = getpgid(pid)
        if group == pid {
            kill(-group, SIGKILL)
        } else if group > 0 {
            kill(pid, SIGKILL)
        }
    }

    /// Returns what to resume with exactly once, to the first caller that observes all three
    /// signals (stdout EOF, stderr EOF, termination). Every other call returns `nil`.
    func claimResumeIfComplete() -> Resumption? {
        lock.lock()
        guard stdoutFinished, stderrFinished, let status, !resumed else {
            lock.unlock()
            return nil
        }
        resumed = true
        let escalation = killWork
        killWork = nil
        let resumption: Resumption =
            cancelled
            ? .cancelled : .finished(status: status, stdout: outBuffer, stderr: errBuffer)
        lock.unlock()
        // Outside the lock, like the signals, and for the same reason. `cancel()` does not
        // wait for an escalation that is already running, so it cannot deadlock against one
        // blocked on the lock this just released; that one then finds `resumed` set and
        // signals nothing.
        escalation?.cancel()
        return resumption
    }

    /// Claims the resume for a process that never launched — cancelled beforehand, or a launch
    /// that threw. No handler can ever run, so this is the only completion the caller gets.
    func claimResumeWithoutLaunching() -> Bool {
        lock.lock()
        guard !resumed else {
            lock.unlock()
            return false
        }
        resumed = true
        let escalation = killWork
        killWork = nil
        lock.unlock()
        escalation?.cancel()
        return true
    }
}
