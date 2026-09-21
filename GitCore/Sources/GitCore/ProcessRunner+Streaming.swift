import Foundation

extension ProcessRunner {
    /// What a finished `runStreaming` hands back: stdout as bytes, and the whole of stderr —
    /// on success too, because git writes the interesting part of a network operation there
    /// (`remote:` lines, the hosting service's pull-request URL) while exiting 0.
    public struct StreamedResult: Sendable {
        public let stdout: Data
        public let stderr: String

        public init(stdout: Data, stderr: String) {
            self.stdout = stdout
            self.stderr = stderr
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
    /// Cancelling the task terminates the process (SIGTERM) and the call then throws
    /// `CancellationError`, never a `GitError.commandFailed` invented from the signal exit.
    /// A cancel that arrives before the process is launched prevents the launch.
    ///
    /// Caveat, measured and deliberately not solved here: SIGTERM reaches the child only. A
    /// grandchild — git's transport running under a wrapper script, say — can outlive it, and
    /// while it holds the inherited pipe ends open this call waits for the EOFs that its
    /// exactly-once resume is built on. Fetch over an ordinary transport has no such
    /// grandchild. Killing the whole process group is a separate change.
    ///
    /// The environment, the `/dev/null` stdin and the pipe-draining rule are `run`'s; see
    /// `ProcessRunner.run` for why nothing but a readability handler ever reads a pipe.
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

    /// The implementation, with a seam the tests need.
    ///
    /// - Parameter onLaunch: called with the child's pid once `run()` has succeeded, from
    ///   whatever thread started it. It exists so a cancellation test can ask the kernel
    ///   whether the process is really gone; production callers use the public overload.
    func runStreaming(
        _ executable: String, _ arguments: [String], cwd: URL,
        allowedExitCodes: Set<Int32> = [],
        onLaunch: (@Sendable (Int32) -> Void)?,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> StreamedResult {
        // Built before the cancellation handler is installed, because `onCancel` can run at
        // any moment from any thread — including before the operation closure is entered, if
        // the task is cancelled already — and it has nowhere to record that but here.
        let state = StreamingProcessState()

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
                                returning: StreamedResult(stdout: out, stderr: text))
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
/// touched only under `lock`, and `terminate()` is the one call deliberately made outside it,
/// after the decision to make it has been recorded.
///
/// It keeps `run`'s three-signal rule — stdout EOF, stderr EOF and termination must all have
/// arrived before the continuation is resumed — and adds three things: the byte-level carry-
/// over for a stderr segment that spans two reads, the `cancelled` flag that turns a completed
/// run into a `CancellationError`, and the process itself, so the cancellation handler has
/// something to terminate.
private final class StreamingProcessState: @unchecked Sendable {
    /// What the first caller to observe all three signals is told to resume with.
    enum Resumption {
        case cancelled
        case finished(status: Int32, stdout: Data, stderr: Data)
    }

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
        if let target, target.isRunning { target.terminate() }
    }

    /// Publishes the launched process to the cancellation handler, terminating it at once if
    /// the cancel arrived while it was starting.
    func registerLaunched(_ launched: Process) {
        lock.lock()
        process = launched
        let shouldTerminate = cancelled && !terminateSent && status == nil
        if shouldTerminate { terminateSent = true }
        lock.unlock()
        if shouldTerminate, launched.isRunning { launched.terminate() }
    }

    /// Returns what to resume with exactly once, to the first caller that observes all three
    /// signals (stdout EOF, stderr EOF, termination). Every other call returns `nil`.
    func claimResumeIfComplete() -> Resumption? {
        lock.lock()
        defer { lock.unlock() }
        guard stdoutFinished, stderrFinished, let status, !resumed else { return nil }
        resumed = true
        if cancelled { return .cancelled }
        return .finished(status: status, stdout: outBuffer, stderr: errBuffer)
    }

    /// Claims the resume for a process that never launched — cancelled beforehand, or a launch
    /// that threw. No handler can ever run, so this is the only completion the caller gets.
    func claimResumeWithoutLaunching() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}
