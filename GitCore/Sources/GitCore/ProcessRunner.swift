import Foundation

/// Runs an executable asynchronously, capturing stdout and stderr.
///
/// Every invocation is fully non-interactive: `GIT_TERMINAL_PROMPT=0` guarantees git
/// never blocks waiting for credentials, and `LC_ALL=C` keeps output parseable.
public struct ProcessRunner: Sendable {
    public init() {}

    public func run(
        _ executable: String, _ arguments: [String], cwd: URL, allowedExitCodes: Set<Int32> = []
    ) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: executable)
            process.arguments = arguments
            process.currentDirectoryURL = cwd

            var env = ProcessInfo.processInfo.environment
            env["GIT_TERMINAL_PROMPT"] = "0"
            env["LC_ALL"] = "C"
            env["GIT_OPTIONAL_LOCKS"] = "0"
            process.environment = env

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            process.standardInput = FileHandle.nullDevice

            let state = ProcessState()

            // Each pipe is drained *only* through its own readability handler, which the
            // system serializes per file handle. Mixing in `readDataToEndOfFile()` from the
            // termination handler (as an earlier version did) could race a still-running
            // handler invocation and append the tail before an earlier chunk, corrupting
            // outputs larger than the 64 KiB pipe buffer. Draining both pipes on background
            // threads also keeps a chatty stderr from deadlocking stdout.
            // `finish` deliberately captures both pipes: nothing else keeps them alive once
            // `process` is released after termination, and a deallocated `Pipe` closes its
            // descriptors and cancels the dispatch source, so the pending EOF callback this
            // design waits for would simply never arrive and the run would hang. The handlers
            // hold `finish` (and so the pipes); nil'ing them at EOF breaks that cycle.
            let finish: @Sendable () -> Void = { [state, stdout, stderr] in
                _ = stdout
                _ = stderr
                guard let (status, out, err) = state.claimResumeIfComplete() else { return }
                if status == 0 || allowedExitCodes.contains(status) {
                    continuation.resume(returning: out)
                } else {
                    let message = String(decoding: err, as: UTF8.self)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    continuation.resume(
                        throwing: GitError.commandFailed(exitCode: status, stderr: message)
                    )
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
                    state.markStderrFinished()
                    finish()
                } else {
                    state.appendStderr(chunk)
                }
            }

            process.terminationHandler = { proc in
                state.recordTermination(proc.terminationStatus)
                finish()
            }

            do {
                try process.run()
            } catch {
                // Nothing has been signalled yet and no handler can have run for a process
                // that never launched, so claiming the resume here is safe and final.
                stdout.fileHandleForReading.readabilityHandler = nil
                stderr.fileHandleForReading.readabilityHandler = nil
                if state.claimResumeForLaunchFailure() {
                    continuation.resume(throwing: GitError.launchFailed(error.localizedDescription))
                }
            }
        }
    }
}

/// Mutable state shared by the two readability handlers and the termination handler of a
/// single `run` call.
///
/// `@unchecked Sendable`: every stored property is read and written only while `lock` is
/// held, which is exactly the guarantee the compiler cannot verify for a class with mutable
/// state. The three callbacks fire on arbitrary, potentially concurrent threads, so the lock
/// is what makes the buffers, the completion flags and the one-shot `resumed` flag safe.
///
/// The three completion signals are tracked as separate flags rather than a counter because
/// a readability handler can legitimately observe EOF more than once before it is unhooked;
/// with a counter, two EOFs from the same pipe would reach the "all done" threshold while
/// the process had not terminated yet, and the run would hang with the continuation never
/// resumed.
private final class ProcessState: @unchecked Sendable {
    private let lock = NSLock()
    private var outBuffer = Data()
    private var errBuffer = Data()
    private var stdoutFinished = false
    private var stderrFinished = false
    private var status: Int32?
    private var resumed = false

    func appendStdout(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        outBuffer.append(chunk)
    }

    func appendStderr(_ chunk: Data) {
        lock.lock(); defer { lock.unlock() }
        errBuffer.append(chunk)
    }

    func markStdoutFinished() {
        lock.lock(); defer { lock.unlock() }
        stdoutFinished = true
    }

    func markStderrFinished() {
        lock.lock(); defer { lock.unlock() }
        stderrFinished = true
    }

    func recordTermination(_ terminationStatus: Int32) {
        lock.lock(); defer { lock.unlock() }
        status = terminationStatus
    }

    /// Returns the captured result exactly once, to the first caller that observes all three
    /// signals (stdout EOF, stderr EOF, termination); that caller owns resuming the
    /// continuation. Every other call returns `nil`.
    func claimResumeIfComplete() -> (status: Int32, stdout: Data, stderr: Data)? {
        lock.lock(); defer { lock.unlock() }
        guard stdoutFinished, stderrFinished, let status, !resumed else { return nil }
        resumed = true
        return (status, outBuffer, errBuffer)
    }

    /// Claims the resume for a process that never launched: no handler can ever run, so this
    /// is the only completion the caller will get.
    func claimResumeForLaunchFailure() -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !resumed else { return false }
        resumed = true
        return true
    }
}
