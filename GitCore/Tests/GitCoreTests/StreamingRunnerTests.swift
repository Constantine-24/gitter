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
///
/// Every child here is `/bin/sh`, `/bin/sleep` or `/usr/bin/pgrep` — deliberately never git,
/// which is why the bare `ProcessRunner()`s below need no `isolatedRunner()`: there is no
/// configuration for the developer's machine to leak in through. See `TestGitEnvironment` for
/// the audit that says so.
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

    /// The status the process really ended with, carried on the result.
    ///
    /// It exists because a caller that *allows* a non-zero code has no other way to ask what
    /// happened: `CLIGitBackend.push` allows exit 1 so that a rejection's stdout survives, and
    /// when git prints no porcelain line for the ref it was given, the code is the only thing
    /// left to report. That path used to assume a 1 — true for `src refspec … does not match
    /// any`, and a guess everywhere else.
    @Test func reportsTheProcessesRealExitStatus() async throws {
        let (zero, _) = try await runScript("echo fine")
        #expect(zero.exitCode == 0)

        let (allowed, _) = try await runScript("echo kept; echo noted >&2; exit 7",
                                               allowedExitCodes: [7])
        #expect(allowed.exitCode == 7)
        // Non-vacuous: the run really did produce its output as well as its code, so the 7 is
        // this process's status and not a default on an empty result.
        #expect(String(decoding: allowed.stdout, as: UTF8.self) == "kept\n")
        #expect(allowed.stderr == "noted\n")
    }

    /// A code that is *not* allowed is still a throw, and the error carries the same number:
    /// the new field is a second way of reading one status, never a second status.
    @Test func aThrownFailureStillCarriesItsCode() async throws {
        let (allowed, _) = try await runScript("exit 9", allowedExitCodes: [9])
        #expect(allowed.exitCode == 9)

        await #expect {
            _ = try await ProcessRunner().runStreaming(
                "/bin/sh", ["-c", "echo nope >&2; exit 9"], cwd: Self.root, onStderr: { _ in })
        } throws: { error in
            guard case let GitError.commandFailed(code, _) = error else { return false }
            return code == 9
        }
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

    /// A child that has installed `trap '' TERM` and said so, with the pid the runner launched.
    private struct TrappedChild {
        let task: Task<Error?, Never>
        let pid: Int32
    }

    /// `/bin/sh -c "trap '' TERM; : > <marker>; sleep 30"`, returned once the marker exists.
    ///
    /// The marker is the point. The fixture's premise — that this child ignores SIGTERM — is
    /// only true *after* the trap is installed, and a test that cancels before that cancels an
    /// ordinary shell which dies on the spot. Measured by the reviewer: with the 300 ms sleep
    /// these tests used to settle with, 360 runs produced **0** early deaths (idle, and under a
    /// concurrent full `swift test`); with **no** settle at all, 210 out of 210 died early. So
    /// the race is real and lives entirely before the trap, and a fixed sleep excluded it by
    /// being long enough rather than by asking. The marker asks: the shell writes it on the
    /// line after the trap, so its existence *is* "this child now ignores SIGTERM", at any load
    /// and on any machine.
    private func startChildIgnoringSIGTERM(
        killGracePeriod: Duration = .seconds(2),
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> TrappedChild {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-trap-\(UUID().uuidString)")
        let runner = ProcessRunner()
        let pid = Locked<Int32?>(nil)
        let task = Task { () -> Error? in
            do {
                _ = try await runner.runStreaming(
                    "/bin/sh", ["-c", "trap '' TERM; : > \"\(marker.path)\"; sleep 30"],
                    cwd: Self.root, killGracePeriod: killGracePeriod,
                    onLaunch: { launched in pid.mutate { $0 = launched } },
                    onStderr: { _ in })
                return nil
            } catch {
                return error
            }
        }
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            FileManager.default.fileExists(atPath: marker.path),
            "the child never installed its trap", sourceLocation: sourceLocation)
        try? FileManager.default.removeItem(at: marker)
        return TrappedChild(task: task, pid: try #require(pid.current))
    }

    /// A child that ignores SIGTERM does not get to outlive its cancel. After the grace period
    /// the runner escalates to SIGKILL, aimed at the child's process group so the `sleep` the
    /// shell started goes with it.
    ///
    /// `trap '' TERM` is inherited by the shell's own children, so both processes in the group
    /// ignore the SIGTERM: without the escalation this call waits out the full `sleep 30`.
    @Test func aChildThatIgnoresSIGTERMIsKilled() async throws {
        let clock = ContinuousClock()
        let started = try await startChildIgnoringSIGTERM()
        let task = started.task
        let child = started.pid

        // Measured, and what the escalation's `kill(-pgid, …)` rests on: the child leads a
        // process group of its own, which is never Gitter's.
        let group = getpgid(child)
        #expect(group == child)
        #expect(group != getpgid(getpid()))
        try #require(group > 1)
        // Baselines that can fail: the shell and the `sleep` it started are alive, and in that
        // group, before the cancel — so their absence afterwards is evidence of the kill.
        #expect(kill(child, 0) == 0)
        #expect(kill(-group, 0) == 0)

        let cancelledAt = clock.now
        task.cancel()
        let error = await task.value
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(elapsed < .seconds(5))
        errno = 0
        #expect(kill(child, 0) == -1)
        #expect(errno == ESRCH)
        #expect(await Self.groupIsGone(group))
    }

    /// The grace period is really waited out, proved by a **lower** bound: a six-second grace
    /// against a child that ignores SIGTERM cannot end before five seconds have passed, whatever
    /// the machine is doing, because load can only make a wait longer. If the parameter were
    /// ignored the 2 s default would end it at about two seconds and this would fail.
    ///
    /// That is the whole reason this case exists. An upper bound cannot prove it: a fast
    /// machine returning in 300 ms satisfies "under 1.5 s" whether the 250 ms parameter was
    /// read or the default was, and it was that upper bound — tuned twice, once in Task 4 —
    /// that made this test look like a flaky one. The claim is now the direction that load
    /// cannot move.
    ///
    /// It costs six seconds of a suite that runs its suites in parallel, and it is the only
    /// place the parameter is proved at all.
    @Test func aLongKillGracePeriodIsReallyWaitedOut() async throws {
        let clock = ContinuousClock()
        let started = try await startChildIgnoringSIGTERM(killGracePeriod: .seconds(6))
        #expect(kill(started.pid, 0) == 0)

        let cancelledAt = clock.now
        started.task.cancel()
        let error = await started.task.value
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(elapsed > .seconds(5), "the grace period was not waited out: \(elapsed)")
        // Not the `sleep 30` the child would have run to completion without an escalation.
        #expect(elapsed < .seconds(20), "\(elapsed)")
        errno = 0
        #expect(kill(started.pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    /// The short grace period, kept for what it can honestly say: with 250 ms the call comes
    /// back rather than waiting out the child's `sleep 30`. The bound is deliberately loose —
    /// it is a "did not hang" check, not a measurement, and a tight one here measures the
    /// neighbours' load rather than the runner. `aLongKillGracePeriodIsReallyWaitedOut` is what
    /// proves the parameter is read.
    @Test func theKillGracePeriodIsHonoured() async throws {
        let clock = ContinuousClock()
        let started = try await startChildIgnoringSIGTERM(killGracePeriod: .milliseconds(250))
        #expect(kill(started.pid, 0) == 0)

        let cancelledAt = clock.now
        started.task.cancel()
        let error = await started.task.value
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(elapsed < .seconds(15), "the call did not come back: \(elapsed)")
        errno = 0
        #expect(kill(started.pid, 0) == -1)
        #expect(errno == ESRCH)
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

    /// The same race three hundred times over, with the cancel landing at a different point in
    /// the launch–read–exit sequence every run: before the launch, during it, mid-pipe, after
    /// the exit but before the resume. None of them may hang, resume twice, or leave a process
    /// behind.
    @Test func threeHundredCancelsAtRandomMomentsNeitherHangNorLeak() async throws {
        let token = "gitter-cancel-stress-\(UUID().uuidString)"
        // Non-vacuous: the same probe finds a process that really is running under this token,
        // so finding none after the stress means something. The `true;` matters — `sh` execs a
        // lone command in place, and the token would vanish from the command line with it.
        let marker = Process()
        marker.executableURL = URL(fileURLWithPath: "/bin/sh")
        marker.arguments = ["-c", "true; sleep 30", token]
        marker.standardOutput = FileHandle.nullDevice
        marker.standardError = FileHandle.nullDevice
        try marker.run()
        try await Task.sleep(for: .milliseconds(100))
        #expect(Self.processCount(matching: token) >= 1)
        let markerGroup = getpgid(marker.processIdentifier)
        marker.terminate()
        marker.waitUntilExit()
        // The marker's own `sleep` child carries no token, and `waitUntilExit` returns as soon
        // as the shell is reaped — so wait the whole group out before the stress begins, or it
        // shows up as a process this test left behind.
        #expect(await Self.groupIsGone(markerGroup))

        let clock = ContinuousClock()
        let startedAt = clock.now
        var cancelled = 0
        var completed = 0
        for _ in 0..<300 {
            let runner = ProcessRunner()
            let task = Task { () -> Result<ProcessRunner.StreamedResult, Error> in
                do {
                    return .success(
                        try await runner.runStreaming(
                            "/bin/sh", ["-c", "echo quick; echo noise >&2", token],
                            cwd: Self.root, onStderr: { _ in }))
                } catch {
                    return .failure(error)
                }
            }
            try await Task.sleep(for: .microseconds(Int.random(in: 0...12_000)))
            task.cancel()
            switch await task.value {
            case .success(let result):
                #expect(String(decoding: result.stdout, as: UTF8.self) == "quick\n")
                completed += 1
            case .failure(let error):
                #expect(error is CancellationError)
                cancelled += 1
            }
        }
        // Both outcomes really did occur, so neither branch's assertions were skipped.
        #expect(cancelled > 0)
        #expect(completed > 0)
        // A hang would have been an unbounded wait rather than a failure; this bounds it.
        #expect(clock.now - startedAt < .seconds(120))
        #expect(await Self.waitForNoProcess(matching: token))
    }

    // MARK: - Parity with `run`

    /// `run` and `runStreaming` each build their child by hand, so the non-interactive
    /// environment and the `/dev/null` stdin are written out twice. One script through both,
    /// compared, is what would notice if one of them drifted. Reading stdin rather than testing
    /// `[ -t 0 ]` is deliberate: a closed or inherited descriptor is not a terminal either.
    @Test func bothRunnersGiveTheChildTheSameEnvironmentAndStdin() async throws {
        let script = """
            printf '%s|%s|%s|%s|' \
            "$GIT_TERMINAL_PROMPT" "$LC_ALL" "$GIT_OPTIONAL_LOCKS" "$GIT_EDITOR"
            if read -r line; then printf 'stdin:%s\\n' "$line"; else printf 'stdin:EOF\\n'; fi
            """
        let plain = try await ProcessRunner().run("/bin/sh", ["-c", script], cwd: Self.root)
        let (streamed, _) = try await runScript(script)
        let text = String(decoding: plain, as: UTF8.self)
        #expect(text == "0|C|0|true|stdin:EOF\n")
        #expect(String(decoding: streamed.stdout, as: UTF8.self) == text)
    }

    // MARK: - Helpers

    /// Whether every process in `group` is gone, polled for up to a second: a killed child is
    /// reaped by `Process`, but the shell's own children are reparented and reaped by `init`,
    /// which is prompt rather than instant.
    private static func groupIsGone(_ group: Int32) async -> Bool {
        for _ in 0..<100 {
            errno = 0
            if kill(-group, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    private static func waitForNoProcess(matching token: String) async -> Bool {
        for _ in 0..<100 {
            if processCount(matching: token) == 0 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// How many live processes have `token` on their command line. `pgrep` never matches
    /// itself.
    private static func processCount(matching token: String) -> Int {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        probe.arguments = ["-f", token]
        let out = Pipe()
        probe.standardOutput = out
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return -1 }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        probe.waitUntilExit()
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count
    }
}
