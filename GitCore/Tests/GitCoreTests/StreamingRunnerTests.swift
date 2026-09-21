import Foundation
import Testing

@testable import GitCore

/// A lock-protected box, because every collector here is written from a readability handler on
/// an arbitrary background thread and read from the test's own thread after the call returns.
private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    var current: Value {
        lock.lock()
        defer { lock.unlock() }
        return value
    }

    func mutate(_ body: (inout Value) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        body(&value)
    }
}

/// `runStreaming`: the same capture guarantees as `run`, plus stderr as it arrives and a call
/// that ends promptly when its task is cancelled.
@Suite struct StreamingRunnerTests {
    private static let root = URL(fileURLWithPath: "/")

    /// Runs `script` under `/bin/sh -c` and returns the result together with every stderr
    /// segment the runner delivered, in order.
    private func runScript(
        _ script: String, allowedExitCodes: Set<Int32> = []
    ) async throws -> (result: ProcessRunner.StreamedResult, segments: [String]) {
        let segments = Locked<[String]>([])
        let result = try await ProcessRunner().runStreaming(
            "/bin/sh", ["-c", script], cwd: Self.root, allowedExitCodes: allowedExitCodes,
            onStderr: { segment in segments.mutate { $0.append(segment) } }
        )
        return (result, segments.current)
    }

    // MARK: - Capture

    @Test func keepsStderrOnSuccess() async throws {
        let (result, segments) = try await runScript("echo out; echo err >&2")
        #expect(String(decoding: result.stdout, as: UTF8.self) == "out\n")
        #expect(result.stderr.contains("err"))
        #expect(segments == ["err"])
    }

    @Test func runsWithTheSameNonInteractiveEnvironmentAsRun() async throws {
        let (result, _) = try await runScript(
            "echo \"$GIT_TERMINAL_PROMPT|$LC_ALL|$GIT_OPTIONAL_LOCKS|$GIT_EDITOR\"")
        #expect(String(decoding: result.stdout, as: UTF8.self) == "0|C|0|true\n")
    }

    /// stdin is `/dev/null`, so a child that reads it sees EOF at once instead of blocking on a
    /// terminal Gitter has no way of answering.
    @Test func stdinIsTheNullDevice() async throws {
        let (result, _) = try await runScript("cat; echo \"[$?]\"")
        #expect(String(decoding: result.stdout, as: UTF8.self) == "[0]\n")
    }

    // MARK: - Segments

    @Test func deliversSegmentsSplitOnCarriageReturnAndNewline() async throws {
        let (_, segments) = try await runScript("printf 'a 1%%\\ra 2%%\\rdone\\n' >&2")
        #expect(segments == ["a 1%", "a 2%", "done"])
    }

    @Test func aSegmentSplitAcrossTwoReadsIsDeliveredOnce() async throws {
        let (_, segments) = try await runScript("printf 'hal' >&2; sleep 0.2; printf 'f\\n' >&2")
        #expect(segments == ["half"])
    }

    /// The carry-over is bytes, not characters: splitting a segment at an arbitrary read
    /// boundary must not cut a multi-byte character in half. `é` is `\xc3\xa9`, sent one byte
    /// per write with a sleep in between so the two really land in different reads.
    @Test func aMultiByteCharacterSplitAcrossTwoReadsIsNotCorrupted() async throws {
        let (result, segments) = try await runScript(
            "printf '\\303' >&2; sleep 0.2; printf '\\251 done\\n' >&2")
        #expect(segments == ["\u{e9} done"])
        #expect(result.stderr == "\u{e9} done\n")
    }

    @Test func theTrailingPartialSegmentIsFlushedAtEOF() async throws {
        let (result, segments) = try await runScript("printf 'no trailing newline' >&2")
        #expect(segments == ["no trailing newline"])
        #expect(result.stderr == "no trailing newline")
    }

    @Test func emptySegmentsAreDropped() async throws {
        let (_, segments) = try await runScript("printf '\\n\\r\\na\\n\\n\\r' >&2")
        #expect(segments == ["a"])
    }

    // MARK: - Exit codes

    @Test func aFailingCommandThrowsCommandFailedWithItsStderr() async {
        let segments = Locked<[String]>([])
        await #expect {
            _ = try await ProcessRunner().runStreaming(
                "/bin/sh", ["-c", "echo nope >&2; exit 3"], cwd: Self.root,
                onStderr: { segment in segments.mutate { $0.append(segment) } })
        } throws: { error in
            guard case let GitError.commandFailed(code, stderr) = error else { return false }
            return code == 3 && stderr == "nope"
        }
        #expect(segments.current == ["nope"])
    }

    @Test func allowedExitCodesAreNotErrors() async throws {
        let (result, segments) = try await runScript(
            "echo kept; echo noted >&2; exit 1", allowedExitCodes: [1])
        #expect(String(decoding: result.stdout, as: UTF8.self) == "kept\n")
        #expect(result.stderr == "noted\n")
        #expect(segments == ["noted"])
    }

    @Test func throwsLaunchFailedWhenTheExecutableIsMissing() async {
        await #expect(throws: GitError.self) {
            _ = try await ProcessRunner().runStreaming(
                "/nonexistent/git", [], cwd: Self.root, onStderr: { _ in })
        }
    }

    // MARK: - No deadlock between the two pipes

    /// A child that floods stderr while writing almost nothing to stdout fills the stderr pipe
    /// buffer (64 KiB) several times over. It only makes progress because stderr is drained by
    /// its own readability handler rather than after stdout is finished.
    @Test func aFloodOfStderrDoesNotDeadlockAnIdleStdout() async throws {
        let (result, segments) = try await runScript(
            "yes 0123456789 | head -c 250000 >&2; echo done")
        #expect(String(decoding: result.stdout, as: UTF8.self) == "done\n")
        #expect(result.stderr.utf8.count == 250_000)
        #expect(segments.count == 250_000 / 11 + 1)
        #expect(segments.allSatisfy { "0123456789".hasPrefix($0) })
    }

    @Test func aFloodOfStdoutDoesNotDeadlockAnIdleStderr() async throws {
        let (result, segments) = try await runScript(
            "yes 0123456789 | head -c 250000; echo done >&2")
        #expect(result.stdout.count == 250_000)
        #expect(result.stderr == "done\n")
        #expect(segments == ["done"])
    }

    // MARK: - Cancellation

    @Test func cancellationTerminatesTheProcessPromptly() async throws {
        let runner = ProcessRunner()
        let pid = Locked<Int32?>(nil)
        let clock = ContinuousClock()

        let task = Task { () -> Error? in
            do {
                _ = try await runner.runStreaming(
                    "/bin/sleep", ["30"], cwd: Self.root,
                    onLaunch: { launched in pid.mutate { $0 = launched } },
                    onStderr: { _ in })
                return nil
            } catch {
                return error
            }
        }

        while pid.current == nil { try await Task.sleep(for: .milliseconds(20)) }
        let child = try #require(pid.current)
        // A baseline that can fail: the child really is alive before the cancel, so the
        // `kill` below is evidence of a termination rather than of a pid that never existed.
        #expect(kill(child, 0) == 0)

        try await Task.sleep(for: .milliseconds(300))
        let cancelledAt = clock.now
        task.cancel()
        let error = await task.value
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(elapsed < .seconds(3))
        errno = 0
        #expect(kill(child, 0) == -1)
        #expect(errno == ESRCH)
    }

    /// Cancelled before the runner ever reaches `process.run()`: the call still throws
    /// `CancellationError`, and nothing is launched.
    @Test func cancellationBeforeLaunchThrowsCancellationError() async {
        let runner = ProcessRunner()
        let pid = Locked<Int32?>(nil)
        let task = Task { () -> Error? in
            do {
                _ = try await runner.runStreaming(
                    "/bin/sleep", ["30"], cwd: Self.root,
                    onLaunch: { launched in pid.mutate { $0 = launched } },
                    onStderr: { _ in })
                return nil
            } catch {
                return error
            }
        }
        task.cancel()
        let error = await task.value
        #expect(error is CancellationError)
        if let launched = pid.current {
            // The cancel landed after the launch, which is a legitimate race; the child must
            // still be gone.
            errno = 0
            #expect(kill(launched, 0) == -1)
            #expect(errno == ESRCH)
        }
    }

    /// A process that has already exited when the cancel arrives: whichever side wins, the call
    /// returns exactly once — either the result or `CancellationError`, never a hang and never
    /// a `commandFailed` invented from a signal.
    @Test func cancellingAfterTheProcessExitedStillReturnsOnce() async throws {
        for _ in 0..<20 {
            let runner = ProcessRunner()
            let task = Task { () -> Result<ProcessRunner.StreamedResult, Error> in
                do {
                    return .success(
                        try await runner.runStreaming(
                            "/bin/sh", ["-c", "echo quick"], cwd: Self.root, onStderr: { _ in }))
                } catch {
                    return .failure(error)
                }
            }
            try await Task.sleep(for: .milliseconds(5))
            task.cancel()
            switch await task.value {
            case .success(let result):
                #expect(String(decoding: result.stdout, as: UTF8.self) == "quick\n")
            case .failure(let error):
                #expect(error is CancellationError)
            }
        }
    }
}
