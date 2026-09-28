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

    /// **A server line with no end is read once, and delivered in pieces.** The pending,
    /// unterminated segment used to be rescanned from its first byte on every read, so a line
    /// of N bytes cost O(N²): measured before the fix, a 10 MB `remote:` line took over 150 s in
    /// a debug build (5 s in release; `git` itself, 3.4 s). The scan now resumes where the last
    /// one stopped, and a segment that reaches 64 KiB with no separator is delivered as it
    /// stands — an over-long progress line arrives in several pieces, each a whole number of
    /// characters, and the pieces together are the line.
    ///
    /// The time is taken **on the pipe's queue**, between the first piece and the last, and not
    /// around the call: in a full parallel `swift test` the cooperative pool is saturated, and
    /// a wall clock around the `await` measured 12 s of waiting for an executor while the run
    /// itself took well under one.
    @Test func aLongUnterminatedStderrLineIsScannedOnceAndDeliveredInBoundedPieces() async throws {
        let clock = ContinuousClock()
        let arrivals = Locked<[ContinuousClock.Instant]>([])
        let collected = Locked<[String]>([])
        let result = try await ProcessRunner().runStreaming(
            "/bin/sh", ["-c", "head -c 2000000 /dev/zero | tr '\\0' x >&2"], cwd: Self.root,
            onStderr: { segment in
                let now = clock.now
                arrivals.mutate { $0.append(now) }
                collected.mutate { $0.append(segment) }
            })
        let segments = collected.current
        let times = arrivals.current
        let elapsed = (times.last ?? clock.now) - (times.first ?? clock.now)

        #expect(result.stderr.utf8.count == 2_000_000, "the whole stderr is still returned")
        #expect(segments.joined() == result.stderr, "the pieces together are not the line")
        #expect(segments.count > 1, "one 2 MB segment: nothing bounds a pending line")
        #expect(segments.allSatisfy { $0.utf8.count <= 65_536 },
                "\(segments.map(\.utf8.count).max() ?? 0) bytes in one segment")
        #expect(elapsed < .seconds(3), "\(elapsed) between the first piece and the last")
    }

    /// The forced cut lands between characters, never inside one: one `x` and then a 1.4 MB
    /// line of `é` (`\xc3\xa9`, two bytes each) comes back with no U+FFFD in any piece. The
    /// `x` puts every `é` at an odd offset, so a cut at exactly 65 536 bytes would split one —
    /// without it the test would pass for a cut that ignores characters altogether.
    @Test func anOverLongLineIsNeverCutInsideAMultiByteCharacter() async throws {
        let (result, segments) = try await runScript(
            "printf x >&2; yes \"$(printf '\\303\\251')\" | head -n 700000 | tr -d '\\n' >&2")
        #expect(result.stderr.utf8.count == 1_400_001)
        #expect(segments.count > 1)
        #expect(!segments.contains { $0.contains("\u{FFFD}") }, "a character was cut in half")
        #expect(segments.joined() == result.stderr)
    }

    /// A separator after a forced cut still ends the segment it belongs to, and the lines after
    /// it are split as always: the bound changes where an over-long line is cut, nothing else.
    @Test func linesAfterAnOverLongOneAreSplitAsBefore() async throws {
        let (_, segments) = try await runScript(
            "head -c 100000 /dev/zero | tr '\\0' x >&2; printf '\\rnext 1%%\\rnext 2%%\\n' >&2")
        #expect(segments.suffix(2) == ["next 1%", "next 2%"], "\(segments.suffix(3).map { $0.prefix(20) })")
        #expect(segments.dropLast(2).joined() == String(repeating: "x", count: 100_000))
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

    /// **A signalled child's `exitCode` is the signal number, not an exit status** — and for
    /// `SIGHUP` that number is **1**, which is a code `CLIGitBackend.push` allows.
    ///
    /// Measured on macOS 27 / Foundation: `Process.terminationStatus` is the signal for a child
    /// killed by one (`SIGTERM` → 15, `SIGHUP` → 1) and only `terminationReason` tells the two
    /// apart. `runStreaming` records `terminationStatus`, so a git killed by `SIGHUP` comes
    /// back as an ordinary `exitCode == 1` rather than throwing.
    ///
    /// Pinned here rather than fixed, and `StreamedResult.exitCode`'s doc comment now says so
    /// instead of promising "the status the process really ended with". Nothing reads the field
    /// as a cause: `push` reaches it only on the path where git printed **no** porcelain line
    /// for the ref it was given, which is a failure however the child ended, and the number is
    /// reported rather than interpreted. A caller that ever needs to tell a signal from an exit
    /// must carry `terminationReason` too.
    @Test func aSignalledChildsStatusIsTheSignalNumber() async throws {
        let (hangup, _) = try await runScript("kill -HUP $$", allowedExitCodes: [1])
        #expect(hangup.exitCode == 1, "SIGHUP is signal 1, and so indistinguishable from exit 1")

        // Non-vacuous: another signal gives its own number through the same path, so the 1
        // above is this child's status and not a default.
        let (terminated, _) = try await runScript("kill -TERM $$", allowedExitCodes: [15])
        #expect(terminated.exitCode == 15)
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

    // MARK: - Cancellation: a grandchild that survives the SIGTERM

    /// A `sleep` duration unique to one test, between 41 and 49 seconds: long enough that a
    /// call waiting for it fails every bound below by a wide margin. The script receives it as
    /// `$2` and runs `sleep "$2"`, so `pgrep -f "sleep <duration>"` (`sleepToken`) matches the
    /// `sleep` alone — never the shell, whose command line holds `sleep "$2"` and the number
    /// apart.
    private static func uniqueDuration() -> String {
        "4\(Int.random(in: 1...8)).\(Int.random(in: 100_000...999_999))"
    }

    private static func sleepToken(_ duration: String) -> String { "sleep \(duration)" }

    /// Starts `script` under `/bin/sh -c` through `runStreaming`, and returns once the script
    /// has created `marker` (passed to it as `$1`) — the point from which the premise the test
    /// is about holds. `duration` is `$2`.
    ///
    /// `reapedGroupWindow` and `onReapedGroupSignal` are passed through to the runner.
    private func startScript(
        _ script: String, duration: String, killGracePeriod: Duration,
        reapedGroupWindow: Duration = .seconds(5),
        onReapedGroupSignal: (@Sendable (pid_t, Int32) -> Void)? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> TrappedChild {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-orphan-\(UUID().uuidString)")
        let runner = ProcessRunner()
        let pid = Locked<Int32?>(nil)
        let task = Task { () -> Error? in
            do {
                _ = try await runner.runStreaming(
                    "/bin/sh", ["-c", script, "sh", marker.path, duration],
                    cwd: Self.root, killGracePeriod: killGracePeriod,
                    reapedGroupWindow: reapedGroupWindow,
                    onLaunch: { launched in pid.mutate { $0 = launched } },
                    onReapedGroupSignal: onReapedGroupSignal,
                    onStderr: { _ in })
                return nil
            } catch {
                return error
            }
        }
        // Both: the script can write its marker before the launching thread has got as far as
        // `onLaunch` (seen once under a full parallel suite).
        for _ in 0..<1000
        where !FileManager.default.fileExists(atPath: marker.path) || pid.current == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            FileManager.default.fileExists(atPath: marker.path),
            "the script never reached its marker", sourceLocation: sourceLocation)
        try? FileManager.default.removeItem(at: marker)
        guard let launched = pid.current else {
            Issue.record("the runner never reported a launch", sourceLocation: sourceLocation)
            // Never leave the script running behind a failed test.
            task.cancel()
            _ = await task.value
            throw CancellationError()
        }
        return TrappedChild(task: task, pid: launched)
    }

    /// The leader dies on its SIGTERM; a grandchild that ignores SIGTERM does not, and it holds
    /// the inherited stderr. Measured before the fix: the call waited for the grandchild's
    /// whole `sleep`, because the escalation stood down the moment the leader was reaped and
    /// the call then waited for an EOF only the grandchild could give. Now the escalation stays
    /// armed until the call has resumed, and a reaped leader with a pipe still open gets its
    /// remembered process group killed.
    ///
    /// A lower bound too: the grandchild ignores SIGTERM, so nothing but the escalation can end
    /// it, and the call cannot come back before the grace period is up.
    @Test func aGrandchildThatSurvivesTheLeadersSIGTERMIsKilledAfterTheGrace() async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let clock = ContinuousClock()
        let started = try await startScript(
            "( trap '' TERM; : > \"$1\"; exec sleep \"$2\" ) & wait", duration: duration,
            killGracePeriod: .milliseconds(500))
        // Baselines that can fail: the leader and the grandchild are both alive, in one group.
        #expect(kill(started.pid, 0) == 0)
        #expect(getpgid(started.pid) == started.pid)
        #expect(await Self.waitForExactlyOneProcess(matching: sleep))

        let cancelledAt = clock.now
        started.task.cancel()
        let error = await started.task.value
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(elapsed > .milliseconds(450), "returned before the escalation could act: \(elapsed)")
        #expect(elapsed < .seconds(5), "waited for the grandchild: \(elapsed)")
        #expect(await Self.waitForNoProcess(matching: sleep), "the grandchild outlived the call")
        #expect(await Self.groupIsGone(started.pid))
    }

    /// The same, when the leader had already exited *before* the cancel: it ran a grandchild in
    /// the background and ended. The call is waiting for the grandchild's EOF, and a cancel must
    /// still end it — by the remembered group, since the leader's pid is reaped.
    ///
    /// **The window is 30 s here, not the production 5 s.** Everything between the reap and the
    /// SIGKILL counts against `reapedGroupWindow` — `waitForReap`, the polled process listing,
    /// the cancel and the 500 ms grace — and under a heavy concurrent load that alone ate 5 s
    /// (1 of 4 and 2 of 4 full runs failed): the group was never signalled, which past the
    /// window is the runner's rule, not a bug. This test is about the escalation, so it gives
    /// the machine room; that the window itself is honoured is
    /// `aReapedGroupIsNotSignalledPastTheWindow`'s job.
    @Test func aCancelAfterTheLeaderExitedStillEndsAGrandchildHoldingThePipe() async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let clock = ContinuousClock()
        let signals = Locked<[[Int32]]>([])
        let started = try await startScript(
            "( trap '' TERM; exec sleep \"$2\" ) & : > \"$1\"; exit 0", duration: duration,
            killGracePeriod: .milliseconds(500), reapedGroupWindow: .seconds(30),
            onReapedGroupSignal: { group, signal in signals.mutate { $0.append([group, signal]) } })
        // The leader is gone and reaped, and the grandchild is still running: the premise.
        #expect(await Self.waitForReap(started.pid))
        #expect(await Self.waitForExactlyOneProcess(matching: sleep))

        let cancelledAt = clock.now
        started.task.cancel()
        let error = await started.task.value
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(elapsed < .seconds(5), "waited for the grandchild: \(elapsed)")
        #expect(await Self.waitForNoProcess(matching: sleep), "the grandchild outlived the call")
        // What makes the seam's silence in the two tests below mean something: here, with the
        // group still holding the grandchild, it saw the SIGTERM and then the SIGKILL go out.
        #expect(signals.current == [[started.pid, SIGTERM], [started.pid, SIGKILL]])
    }

    /// The reviewer's case, in-suite. The leader backgrounds a job **out of its group**
    /// (`set -m`) and exits: the job holds the pipes, and the leader's group is empty from the
    /// moment of the reap — so its id is free, and a process that later reuses the leader's
    /// pid may create a group with it and leave that group behind (measured by the Task 7
    /// re-reviewer with a pid-cycling C program: the runner SIGTERMed and SIGKILLed that
    /// foreign group's `sleep`). Waiting 59 s for the pids to wrap is not a test; what is
    /// asserted instead is the cause: the runner never asks to signal that number at all.
    ///
    /// The call still returns — by the abandonment, a second grace after the escalation — and
    /// the job, out of every reach, is still running; the test kills it.
    @Test func aGroupAlreadyEmptyAtTheReapIsNeverSignalled() async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let signals = Locked<[[Int32]]>([])
        let clock = ContinuousClock()
        let started = try await startScript(
            "set -m; sleep \"$2\" & : > \"$1\"; exit 0", duration: duration,
            killGracePeriod: .milliseconds(300),
            onReapedGroupSignal: { group, signal in signals.mutate { $0.append([group, signal]) } })
        // The premise, each part able to fail: the leader is reaped, its group is empty, and
        // the out-of-group job is alive (holding the pipes, or the call would have returned).
        #expect(await Self.waitForReap(started.pid))
        #expect(await Self.groupIsGone(started.pid))
        #expect(await Self.waitForExactlyOneProcess(matching: sleep))

        let cancelledAt = clock.now
        started.task.cancel()
        let error = await started.task.value
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(signals.current.isEmpty, "signalled a group that was empty at the reap: \(signals.current)")
        #expect(elapsed > .milliseconds(550), "returned before the abandonment: \(elapsed)")
        #expect(elapsed < .seconds(6), "\(elapsed)")
        #expect(Self.processCount(matching: sleep) == 1)
        Self.killProcesses(matching: sleep)
        #expect(await Self.waitForNoProcess(matching: sleep))
    }

    /// The bound on what is left. A group that still had a member at the reap may empty later
    /// while a holder outside it keeps the call waiting, and then its id is free for a pid
    /// reuse too; the runner cannot see that happen without asking the very number that may no
    /// longer be its own. So it signals a reaped leader's group only within
    /// `reapedGroupWindow` of the reap. Past it, a cancel sends nothing by that number and is
    /// ended by the abandonment — here with the group's own member still alive, which is the
    /// price, and which the test cleans up.
    @Test func aReapedGroupIsNotSignalledPastTheWindow() async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let signals = Locked<[[Int32]]>([])
        let clock = ContinuousClock()
        let started = try await startScript(
            "sleep \"$2\" & : > \"$1\"; exit 0", duration: duration,
            killGracePeriod: .milliseconds(300), reapedGroupWindow: .milliseconds(200),
            onReapedGroupSignal: { group, signal in signals.mutate { $0.append([group, signal]) } })
        #expect(await Self.waitForReap(started.pid))
        // Unlike the test above, the group is NOT empty: the `sleep` is in it.
        #expect(kill(-started.pid, 0) == 0)
        #expect(await Self.waitForExactlyOneProcess(matching: sleep))
        // Well past the window, measured from a reap that has already happened.
        try await Task.sleep(for: .seconds(1))

        let cancelledAt = clock.now
        started.task.cancel()
        let error = await started.task.value
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(signals.current.isEmpty, "signalled a reaped group past the window: \(signals.current)")
        #expect(elapsed > .milliseconds(550), "returned before the abandonment: \(elapsed)")
        #expect(elapsed < .seconds(6), "\(elapsed)")
        #expect(Self.processCount(matching: sleep) == 1)
        Self.killProcesses(matching: sleep)
        #expect(await Self.waitForNoProcess(matching: sleep))
    }

    /// A leader forking helpers as fast as it can. A process that is *being forked* when the
    /// group's SIGTERM is sent misses it (measured on macOS by the reviewer: 28 in 100), so it
    /// outlives a leader that died, holding the pipes. Every cancel must still come back within
    /// about the grace period, and leave nothing behind.
    ///
    /// Non-vacuous: at least one cancel must have needed the escalation — taken longer than the
    /// grace — or the race this test is about never happened. The race is hit in roughly 4–10
    /// of 100 here, and once in 30 suite runs in none of them, so the loop runs a hundred
    /// cancels and then goes on, up to five hundred, until one has.
    @Test func aForkStormLeaderCancelledAHundredTimesNeverWaitsForAnOrphan() async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let grace = Duration.milliseconds(300)
        let clock = ContinuousClock()
        var escalated = 0
        for attempt in 0..<500 where attempt < 100 || escalated == 0 {
            let started = try await startScript(
                ": > \"$1\"; while :; do sleep \"$2\" & kill $! 2>/dev/null; wait $! 2>/dev/null; done",
                duration: duration, killGracePeriod: grace)
            #expect(kill(started.pid, 0) == 0)
            try await Task.sleep(for: .microseconds(Int.random(in: 0...20_000)))

            let cancelledAt = clock.now
            started.task.cancel()
            let error = await started.task.value
            let elapsed = clock.now - cancelledAt

            #expect(error is CancellationError)
            if elapsed >= grace { escalated += 1 }
            guard elapsed < .seconds(5) else {
                Issue.record("attempt \(attempt) waited for an orphan: \(elapsed)")
                break
            }
        }
        #expect(escalated > 0, "no cancel ever raced a fork, so nothing was proved")
        #expect(await Self.waitForNoProcess(matching: sleep), "an orphan outlived its call")
    }

    /// A grandchild that has **left the process group** — here a background job of a shell with
    /// job control on (`set -m`), which gets a group of its own; `setsid` does the same, and
    /// macOS has no `setsid` command — is out of reach of every signal the runner sends. The
    /// call must not wait for it anyway: a second grace after the escalation it stops waiting,
    /// closes its ends of the pipes and throws `CancellationError`.
    ///
    /// The grandchild is then still alive, which is the honest part: the runner cannot reach
    /// it, and this test kills it itself.
    @Test func aGrandchildOutsideTheGroupIsAbandonedAfterASecondGrace() async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let clock = ContinuousClock()
        let started = try await startScript(
            "set -m; sleep \"$2\" & : > \"$1\"; wait", duration: duration,
            killGracePeriod: .milliseconds(500))
        #expect(kill(started.pid, 0) == 0)
        #expect(await Self.waitForExactlyOneProcess(matching: sleep))

        let cancelledAt = clock.now
        started.task.cancel()
        let error = await started.task.value
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(elapsed > .milliseconds(900), "abandoned before two graces: \(elapsed)")
        #expect(elapsed < .seconds(6), "waited for the grandchild: \(elapsed)")
        // Out of the runner's reach, as the doc comment says — and cleaned up here.
        #expect(Self.processCount(matching: sleep) == 1)
        Self.killProcesses(matching: sleep)
        #expect(await Self.waitForNoProcess(matching: sleep))
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
        let markerPID = marker.processIdentifier
        let markerGroup = getpgid(markerPID)
        marker.terminate()
        // Not `marker.waitUntilExit()`, which hung the Xcode scheme's run for good. Foundation
        // notes each task it launches, by raw pointer, in a list kept per launching thread and
        // never pruned, and tells a task without a `terminationHandler` of its exit on the
        // launching thread's run loop; `waitUntilExit` waits for that news whenever the task's
        // address is in the *waiting* thread's list. After the `await` above this test resumes
        // on another cooperative thread, where the address of a task launched earlier and since
        // freed (a probe's, or a runner's) could be the marker's own: it then waited for a run
        // loop that no one runs (measured: that list held 39 addresses, the marker's among
        // them). So the kernel is asked, for a bounded
        // time: the shell is reaped — Foundation reaps it off any run loop — and then its group,
        // since the marker's own `sleep` child carries no token and would otherwise count as a
        // process the stress left behind.
        #expect(await Self.waitForReap(markerPID), "the marker shell outlived its SIGTERM")
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
    ///
    /// **One deliberate difference:** `runStreaming` also sets `SSH_ASKPASS_REQUIRE=force` when
    /// the environment names no askpass of its own (see the tests below and the runner's doc).
    /// Only `runStreaming` ever talks to a remote — every fetch, pull and push goes through it,
    /// and `run` carries the local reads and writes — so only it can start ssh, and `run` is
    /// left as it is.
    @Test func bothRunnersGiveTheChildTheSameEnvironmentAndStdin() async throws {
        let script = """
            printf '%s|%s|%s|%s|' \
            "$GIT_TERMINAL_PROMPT" "$LC_ALL" "$GIT_OPTIONAL_LOCKS" "$GIT_EDITOR"
            if read -r line; then printf 'stdin:%s\\n' "$line"; else printf 'stdin:EOF\\n'; fi
            printf 'askpass:%s\\n' "${SSH_ASKPASS_REQUIRE-unset}"
            """
        let plain = try await ProcessRunner().run("/bin/sh", ["-c", script], cwd: Self.root)
        let (streamed, _) = try await runScript(script)
        let plainLines = String(decoding: plain, as: UTF8.self).split(separator: "\n")
        let streamedLines = String(decoding: streamed.stdout, as: UTF8.self)
            .split(separator: "\n")
        #expect(plainLines.first == "0|C|0|true|stdin:EOF")
        #expect(streamedLines.first == plainLines.first)

        let inherited = ProcessInfo.processInfo.environment
        #expect(plainLines.last == "askpass:\(inherited["SSH_ASKPASS_REQUIRE"] ?? "unset")")
        #expect(
            streamedLines.last
                == "askpass:\(Self.expectedAskpassRequire(inheriting: inherited))")
    }

    // MARK: - ssh never stops on a terminal

    /// What `runStreaming` must hand ssh for `SSH_ASKPASS_REQUIRE`, given what it inherits.
    private static func expectedAskpassRequire(inheriting inherited: [String: String]) -> String {
        if inherited["SSH_ASKPASS"] == nil && inherited["SSH_ASKPASS_REQUIRE"] == nil {
            return "force"
        }
        return inherited["SSH_ASKPASS_REQUIRE"] ?? "unset"
    }

    /// The two askpass variables as the child sees them, `unset` for an absent one, with
    /// `inherited` as the environment the runner builds the child's from.
    private func askpassVariables(inheriting inherited: [String: String]?) async throws -> String {
        let result = try await ProcessRunner().runStreaming(
            "/bin/sh",
            ["-c", "printf '%s|%s' \"${SSH_ASKPASS_REQUIRE-unset}\" \"${SSH_ASKPASS-unset}\""],
            cwd: Self.root, onLaunch: nil, inheritedEnvironment: inherited, onStderr: { _ in })
        return String(decoding: result.stdout, as: UTF8.self)
    }

    /// Measured in Task 11's review with real OpenSSH, isolated (no config, no agent, a scratch
    /// passphrase key, `sshd -i` over a pipe — no socket, no host): started from a terminal,
    /// ssh opens `/dev/tty` to ask for a passphrase or about an unknown host key, and — being
    /// in a background process group, the runner's own — is stopped by SIGTTOU as it turns
    /// echo off, before any prompt is printed. git and ssh then sit stopped (state T) until the
    /// automatic fetch's timeout, or forever for a manual one. With `SSH_ASKPASS_REQUIRE=force`
    /// ssh never touches the terminal: it runs the askpass program, and with none installed
    /// fails in milliseconds with the real cause.
    @Test func forcesTheAskpassWhenTheEnvironmentNamesNone() async throws {
        #expect(try await askpassVariables(inheriting: ["PATH": "/usr/bin:/bin"]) == "force|unset")
    }

    /// A user who configured an askpass — or said how ssh should use one — keeps it exactly:
    /// the variable is only ever added, never overwritten, and `SSH_ASKPASS` is never touched.
    @Test(arguments: [
        ["SSH_ASKPASS": "/opt/scratch/askpass"],
        ["SSH_ASKPASS_REQUIRE": "never"],
        ["SSH_ASKPASS_REQUIRE": "prefer"],
        ["SSH_ASKPASS": "/opt/scratch/askpass", "SSH_ASKPASS_REQUIRE": "prefer"],
    ])
    func leavesAnAskpassTheUserConfiguredAlone(_ askpass: [String: String]) async throws {
        let inherited = askpass.merging(["PATH": "/usr/bin:/bin"]) { mine, _ in mine }
        let expected =
            "\(askpass["SSH_ASKPASS_REQUIRE"] ?? "unset")|\(askpass["SSH_ASKPASS"] ?? "unset")"
        #expect(try await askpassVariables(inheriting: inherited) == expected)
    }

    /// The public overload builds from this process's own environment, by the same rule.
    @Test func thePublicRunnerAppliesTheSameRuleToThisProcesssEnvironment() async throws {
        let inherited = ProcessInfo.processInfo.environment
        let (result, _) = try await runScript("printf '%s' \"${SSH_ASKPASS_REQUIRE-unset}\"")
        #expect(
            String(decoding: result.stdout, as: UTF8.self)
                == Self.expectedAskpassRequire(inheriting: inherited))
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

    /// Whether `pid` is gone — reaped, so `kill(pid, 0)` is ESRCH — polled for up to two
    /// seconds.
    private static func waitForReap(_ pid: Int32) async -> Bool {
        for _ in 0..<200 {
            errno = 0
            if kill(pid, 0) == -1, errno == ESRCH { return true }
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

    /// Polled for up to two seconds: the `sleep` is exec'd a moment after the marker exists.
    private static func waitForExactlyOneProcess(matching token: String) async -> Bool {
        for _ in 0..<200 {
            if processCount(matching: token) == 1 { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// This probe and the one below call `waitUntilExit` on the thread that launched them, with
    /// no `await` in between — the one way it cannot hang (see the stress test's marker). Keep
    /// them synchronous.
    private static func killProcesses(matching token: String) {
        let probe = Process()
        probe.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        probe.arguments = ["-f", token]
        probe.standardOutput = FileHandle.nullDevice
        probe.standardError = FileHandle.nullDevice
        guard (try? probe.run()) != nil else { return }
        probe.waitUntilExit()
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
