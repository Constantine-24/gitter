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

/// Holds the runner's record of git's exit — `beforeRecordingTermination`, on Foundation's
/// termination-handler thread, a thread of a global overcommit queue that no other process's
/// handler waits behind (measured) — until `release`. The hold ends on its own after eleven
/// minutes, past every test's time limit, so a test that never released it cannot keep the
/// thread for good.
private final class TerminationHold: @unchecked Sendable {
    private let lock = NSLock()
    private let gate = DispatchSemaphore(value: 0)
    private var isEntered = false
    private var released = false

    /// The runner has reached the record of the exit, and is being held there.
    var entered: Bool {
        lock.lock()
        defer { lock.unlock() }
        return isEntered
    }

    func hold() {
        lock.lock()
        isEntered = true
        lock.unlock()
        _ = gate.wait(timeout: .now() + 660)
    }

    /// Lets the record go ahead; any later call does nothing.
    func release() {
        lock.lock()
        let first = !released
        released = true
        lock.unlock()
        if first { gate.signal() }
    }
}

/// `runStreaming`: the same capture guarantees as `run`, plus stderr as it arrives and a call
/// that ends promptly when its task is cancelled.
///
/// Every child here is `/bin/sh`, `/bin/sleep` or a process listing (`ownProcesses`) — never git,
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
        let (result, segments, span) = try await stderrDeliverySpan(
            "head -c 2000000 /dev/zero | tr '\\0' x >&2")

        #expect(result.stderr.utf8.count == 2_000_000, "the whole stderr is still returned")
        #expect(segments.joined() == result.stderr, "the pieces together are not the line")
        #expect(segments.count > 1, "one 2 MB segment: nothing bounds a pending line")
        #expect(segments.allSatisfy { $0.utf8.count <= 65_536 },
                "\(segments.map(\.utf8.count).max() ?? 0) bytes in one segment")
        #expect(span < .seconds(3), "\(span) between the first piece and the last")
    }

    /// The control for the bound above, which stays an upper bound because it is taken on the
    /// runner's own clock — the pipe's queue — not around the `await`: a line whose pieces
    /// really are delivered more than three seconds apart fails it. So the span spans the
    /// delivery, and a scan slow enough to matter would show in it.
    @Test func aDeliverySpreadOverMoreThanThreeSecondsFailsTheBound() async throws {
        let (_, segments, span) = try await stderrDeliverySpan(
            "head -c 70000 /dev/zero | tr '\\0' x >&2; sleep 3.2; printf 'y\\n' >&2")
        #expect(segments.count > 1)
        withKnownIssue("the pieces are 3.2 s apart by construction") {
            #expect(span < .seconds(3), "\(span) between the first piece and the last")
        }
    }

    /// Runs `script` and returns the time from the first stderr segment to the last, each taken
    /// as it arrives **on the pipe's queue**: the runner's own time, not the test's.
    private func stderrDeliverySpan(
        _ script: String
    ) async throws -> (result: ProcessRunner.StreamedResult, segments: [String], span: Duration) {
        let clock = ContinuousClock()
        let arrivals = Locked<[ContinuousClock.Instant]>([])
        let collected = Locked<[String]>([])
        let result = try await ProcessRunner().runStreaming(
            "/bin/sh", ["-c", script], cwd: Self.root,
            onStderr: { segment in
                let now = clock.now
                arrivals.mutate { $0.append(now) }
                collected.mutate { $0.append(segment) }
            })
        let times = arrivals.current
        let span = (times.last ?? clock.now) - (times.first ?? clock.now)
        return (result, collected.current, span)
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
    /// apart. `runStreaming` records `terminationStatus` as `exitCode`, so a git killed by
    /// `SIGHUP` comes back with `exitCode == 1`; what says it was a signal is the result's
    /// `terminationReason` (E1 S5, the test below).
    @Test func aSignalledChildsStatusIsTheSignalNumber() async throws {
        let (hangup, _) = try await runScript("kill -HUP $$", allowedExitCodes: [1])
        #expect(hangup.exitCode == 1, "SIGHUP is signal 1, and so indistinguishable from exit 1")

        // Non-vacuous: another signal gives its own number through the same path, so the 1
        // above is this child's status and not a default.
        let (terminated, _) = try await runScript("kill -TERM $$", allowedExitCodes: [15])
        #expect(terminated.exitCode == 15)
    }

    /// **E1 S5.** The result says how the child ended: a child killed by `SIGHUP` and one that
    /// ran `exit 1` share `exitCode == 1`, and `terminationReason` tells them apart — so a
    /// caller that allows every code can refuse a signal rather than read it as a status.
    @Test func aSignalIsReportedAsASignalAndAnExitAsAnExit() async throws {
        let (hangup, _) = try await runScript("kill -HUP $$", allowedExitCodes: [1])
        #expect(hangup.exitCode == 1)
        #expect(hangup.terminationReason == .uncaughtSignal)

        let (exited, _) = try await runScript("echo kept; exit 1", allowedExitCodes: [1])
        #expect(exited.exitCode == 1)
        #expect(exited.terminationReason == .exit)
        // `.exit` is also the initialiser's default; the `SIGHUP` case above is what shows the
        // field is the run's own, and this one that an exit is never taken for a signal.
        #expect(String(decoding: exited.stdout, as: UTF8.self) == "kept\n")
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

    /// How a cancellation test here says "the call came back rather than waiting out its
    /// child": the child sleeps **longer than the test's time limit**, so a call that waits it
    /// out is a hang, which `.timeLimit` reports (`CallUnderTest` says why the wait goes
    /// through it). There is no upper bound on the test's clock.
    ///
    /// Such bounds were here, 20 s under `cameBackBound`, and load could exceed them. The time
    /// was taken from the cancel to the moment the *test* ran again, and that includes waits
    /// for a thread of Swift's cooperative pool, which a full parallel `swift test` keeps
    /// saturated: 4.3 s measured in inserted fix 4, a fork-storm cancel at 25.6 s in the E1
    /// survey, and `aLongKillGracePeriodIsReallyWaitedOut` past its 20 s in E1's red run. What
    /// the runner's timing really is gets proved by lower bounds, which load cannot break.
    ///
    /// Eleven minutes: longer than the ten-minute limit every such test carries, which is far
    /// above the seconds they take and above what load was measured to add to them
    /// (`TimeLimitSupport.swift`); and short enough that a child left behind by a failed test
    /// ends on its own soon after.
    private static let outlastsTheTimeLimit = "660"

    /// The child ends on the SIGTERM itself. The grace period, like the child's sleep, outlasts
    /// the time limit, so neither the escalation nor the sleep's end can be what ends the call:
    /// a SIGTERM that never arrived leaves the call waiting, and the limit reports it.
    @Test(.timeLimit(.minutes(10))) func cancellationTerminatesTheProcessPromptly() async throws {
        let runner = ProcessRunner()
        let pid = Locked<Int32?>(nil)
        // A duration of its own, past the limit like `outlastsTheTimeLimit`, so a hung call's
        // child is found by it and killed, and by nothing else.
        let duration = Self.uniqueDuration()

        let call = CallUnderTest { () -> Error? in
            do {
                _ = try await runner.runStreaming(
                    "/bin/sleep", [duration], cwd: Self.root, killGracePeriod: .seconds(660),
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
        call.cancel()
        guard let error = await call.value() else {
            killLeftovers([Self.sleepToken(duration)])
            return
        }

        #expect(error is CancellationError)
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
    ///
    /// `leftovers` are the markers its processes carry on their command lines — the fixture's
    /// unique file name, and its `sleep`'s unique duration where it has one. A test whose call
    /// never came back kills them by group (`killLeftovers`, `RemoteTestSupport.swift`), so a fixture that outlasts the
    /// time limit does not outlive the failed test.
    private struct TrappedChild {
        let call: CallUnderTest<Error?>
        let pid: Int32
        let leftovers: [String]
    }

    /// `/bin/sh -c "trap '' TERM; : > <marker>; sleep 660"`, returned once the marker exists.
    /// The sleep outlasts the time limit (`outlastsTheTimeLimit`).
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
    ///
    /// `reportsItsLaunchLate` is the control for the wait on the pid (E1 S7(3)): the launch is
    /// handed to the fixture only once the marker exists and 200 ms more have passed, so the
    /// marker is there first by construction — the order that was seen once under a full
    /// parallel suite.
    private func startChildIgnoringSIGTERM(
        killGracePeriod: Duration = .seconds(2),
        onSignal: (@Sendable (ProcessRunner.SignalAttempt) -> Void)? = nil,
        reportsItsLaunchLate: Bool = false,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> TrappedChild {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-trap-\(UUID().uuidString)")
        let runner = ProcessRunner()
        let pid = Locked<Int32?>(nil)
        let call = CallUnderTest { () -> Error? in
            do {
                _ = try await runner.runStreaming(
                    "/bin/sh", ["-c", "trap '' TERM; : > \"\(marker.path)\"; sleep \(Self.outlastsTheTimeLimit)"],
                    cwd: Self.root, killGracePeriod: killGracePeriod,
                    onLaunch: { launched in
                        guard reportsItsLaunchLate else {
                            pid.mutate { $0 = launched }
                            return
                        }
                        Self.report(launched, to: pid, once: marker)
                    },
                    onSignal: onSignal,
                    onStderr: { _ in })
                return nil
            } catch {
                return error
            }
        }
        // Both, as `startScript` waits: the shell can write its marker before the launching
        // thread has got as far as `onLaunch` (E1 S7(3)).
        for _ in 0..<1000
        where !FileManager.default.fileExists(atPath: marker.path) || pid.current == nil {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(
            FileManager.default.fileExists(atPath: marker.path),
            "the child never installed its trap", sourceLocation: sourceLocation)
        try? FileManager.default.removeItem(at: marker)
        let leftovers = [marker.lastPathComponent]
        guard let launched = pid.current else {
            Issue.record("the runner never reported a launch", sourceLocation: sourceLocation)
            call.cancel()
            if await call.value("the child that never reported a launch") == nil {
                killLeftovers(leftovers)
            }
            throw CancellationError()
        }
        return TrappedChild(call: call, pid: launched, leftovers: leftovers)
    }

    /// `reportsItsLaunchLate`'s hand-over: on a thread of its own, so the launching thread is
    /// not held, once `marker` exists — polled for up to ten seconds — and 200 ms after that.
    private static func report(_ launched: Int32, to pid: Locked<Int32?>, once marker: URL) {
        DispatchQueue.global().async {
            for _ in 0..<1000 where !FileManager.default.fileExists(atPath: marker.path) {
                usleep(10_000)
            }
            usleep(200_000)
            pid.mutate { $0 = launched }
        }
    }

    /// E1 S7(3): the fixture waits for the runner's report of the launch as well as for the
    /// trap, because the shell can write its marker before the launching thread reaches
    /// `onLaunch`. Here that order is forced (`reportsItsLaunchLate`), and the fixture still
    /// hands back the child it launched — a waiting on the marker alone found no pid and
    /// recorded "the runner never reported a launch".
    @Test(.timeLimit(.minutes(10))) func theTrappedChildIsHandedBackOnlyOnceItsLaunchIsReported() async throws {
        let started = try await startChildIgnoringSIGTERM(
            killGracePeriod: .milliseconds(250), reportsItsLaunchLate: true)
        // The pid handed back is the live child, leading its own group: the runner's report.
        #expect(kill(started.pid, 0) == 0)
        #expect(getpgid(started.pid) == started.pid)

        started.call.cancel()
        guard let error = await started.call.value() else {
            killLeftovers(started.leftovers)
            return
        }
        #expect(error is CancellationError)
        #expect(await Self.groupIsGone(started.pid))
    }

    /// The control for this fixture's failure-path cleanup: a cancelled call whose escalation
    /// never acts (a grace past the limit) is still waiting, and the markers the fixture
    /// carries find its shell — so `killLeftovers` ends the shell's whole group, the `sleep`
    /// with it, and the call comes back.
    @Test(.timeLimit(.minutes(10))) func aTrappedChildIsKilledByItsLeftoversGroup() async throws {
        let started = try await startChildIgnoringSIGTERM(killGracePeriod: .seconds(3600))
        #expect(getpgid(started.pid) == started.pid)
        started.call.cancel()
        try await Task.sleep(for: .milliseconds(300))
        #expect(kill(started.pid, 0) == 0, "the trapped child died on its SIGTERM")

        #expect(killLeftovers(started.leftovers) == [started.pid])
        #expect(await started.call.value("the call, its group killed") is CancellationError)
        #expect(await Self.groupIsGone(started.pid))
    }

    /// A child that ignores SIGTERM does not get to outlive its cancel. After the grace period
    /// the runner escalates to SIGKILL, aimed at the child's process group so the `sleep` the
    /// shell started goes with it.
    ///
    /// `trap '' TERM` is inherited by the shell's own children, so both processes in the group
    /// ignore the SIGTERM: without the escalation this call waits out the full `sleep 660`,
    /// past the time limit.
    @Test(.timeLimit(.minutes(10))) func aChildThatIgnoresSIGTERMIsKilled() async throws {
        let clock = ContinuousClock()
        let started = try await startChildIgnoringSIGTERM()
        let call = started.call
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
        call.cancel()
        guard let error = await call.value() else {
            killLeftovers(started.leftovers)
            return
        }
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        // The escalation, and only it: the child ignores SIGTERM, so nothing ends it before the
        // grace period is up. A lower bound, which load can only make truer. That it came back
        // at all, rather than after the child's sleep: the time limit (`outlastsTheTimeLimit`).
        #expect(elapsed > .milliseconds(1_800), "ended before the grace period: \(elapsed)")
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
    @Test(.timeLimit(.minutes(10))) func aLongKillGracePeriodIsReallyWaitedOut() async throws {
        let clock = ContinuousClock()
        let started = try await startChildIgnoringSIGTERM(killGracePeriod: .seconds(6))
        #expect(kill(started.pid, 0) == 0)

        let cancelledAt = clock.now
        started.call.cancel()
        guard let error = await started.call.value() else {
            killLeftovers(started.leftovers)
            return
        }
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(elapsed > .seconds(5), "the grace period was not waited out: \(elapsed)")
        // Not the `sleep 660` the child would have run to completion without an escalation:
        // that would be past the time limit.
        errno = 0
        #expect(kill(started.pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    /// The short grace period, kept for what it can honestly say: with 250 ms the call comes
    /// back rather than waiting out the child's `sleep 660`. It is a "did not hang" check, not
    /// a measurement, so it is the time limit's: a bound on the test's clock measured the
    /// neighbours' load rather than the runner. `aLongKillGracePeriodIsReallyWaitedOut` is what
    /// proves the parameter is read.
    @Test(.timeLimit(.minutes(10))) func theKillGracePeriodIsHonoured() async throws {
        let started = try await startChildIgnoringSIGTERM(killGracePeriod: .milliseconds(250))
        #expect(kill(started.pid, 0) == 0)

        started.call.cancel()
        guard let error = await started.call.value() else {
            killLeftovers(started.leftovers)
            return
        }

        #expect(error is CancellationError)
        errno = 0
        #expect(kill(started.pid, 0) == -1)
        #expect(errno == ESRCH)
    }

    // MARK: - Cancellation: a grandchild that survives the SIGTERM

    /// A `sleep` duration unique to one test, between 660 and 670 seconds: longer than the time
    /// limit (`outlastsTheTimeLimit`), so a call that waits for it is a hang the limit reports.
    /// The script receives it as
    /// `$2` and runs `sleep "$2"`, so `ownProcesses(matching: "sleep <duration>")` (`sleepToken`)
    /// matches the `sleep` alone — never the shell, whose command line holds `sleep "$2"` and
    /// the number apart.
    private static func uniqueDuration() -> String {
        "66\(Int.random(in: 0...9)).\(Int.random(in: 100_000...999_999))"
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
        onSignal: (@Sendable (ProcessRunner.SignalAttempt) -> Void)? = nil,
        beforeRecordingTermination: (@Sendable () -> Void)? = nil,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws -> TrappedChild {
        let marker = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-orphan-\(UUID().uuidString)")
        let runner = ProcessRunner()
        let pid = Locked<Int32?>(nil)
        let call = CallUnderTest { () -> Error? in
            do {
                _ = try await runner.runStreaming(
                    "/bin/sh", ["-c", script, "sh", marker.path, duration],
                    cwd: Self.root, killGracePeriod: killGracePeriod,
                    reapedGroupWindow: reapedGroupWindow,
                    onLaunch: { launched in pid.mutate { $0 = launched } },
                    onReapedGroupSignal: onReapedGroupSignal,
                    onSignal: onSignal,
                    beforeRecordingTermination: beforeRecordingTermination,
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
        // The shell, and every subshell it forks, carries the marker's name as `$1`; the
        // `sleep` carries its duration.
        let leftovers = [marker.lastPathComponent, Self.sleepToken(duration)]
        guard let launched = pid.current else {
            Issue.record("the runner never reported a launch", sourceLocation: sourceLocation)
            // Never leave the script running behind a failed test.
            call.cancel()
            if await call.value("the script that never reported a launch") == nil {
                killLeftovers(leftovers)
            }
            throw CancellationError()
        }
        return TrappedChild(call: call, pid: launched, leftovers: leftovers)
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
    ///
    /// **The window is 30 s, not the production 5 s**, for the reason
    /// `aCancelAfterTheLeaderExitedStillEndsAGrandchildHoldingThePipe` gives. The leader is
    /// reaped at once, so the SIGKILL goes by the remembered group, and only within the window
    /// of that reap. The escalation is a timer on a global queue, and load can delay it past
    /// 5 s. Measured (inserted fix 4): with that queue's threads kept busy after the cancel,
    /// the escalation came 24 s late. With a 5 s window nothing was sent and the grandchild
    /// survived; with 30 s it was killed.
    @Test(.timeLimit(.minutes(10))) func aGrandchildThatSurvivesTheLeadersSIGTERMIsKilledAfterTheGrace() async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let clock = ContinuousClock()
        let started = try await startScript(
            "( trap '' TERM; : > \"$1\"; exec sleep \"$2\" ) & wait", duration: duration,
            killGracePeriod: .milliseconds(500), reapedGroupWindow: .seconds(30))
        // Baselines that can fail: the leader and the grandchild are both alive, in one group.
        #expect(kill(started.pid, 0) == 0)
        #expect(getpgid(started.pid) == started.pid)
        #expect(await Self.waitForExactlyOneProcess(matching: sleep))

        let cancelledAt = clock.now
        started.call.cancel()
        guard let error = await started.call.value() else {
            killLeftovers(started.leftovers)
            return
        }
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(elapsed > .milliseconds(450), "returned before the escalation could act: \(elapsed)")
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
    @Test(.timeLimit(.minutes(10))) func aCancelAfterTheLeaderExitedStillEndsAGrandchildHoldingThePipe() async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let signals = Locked<[[Int32]]>([])
        let started = try await startScript(
            "( trap '' TERM; exec sleep \"$2\" ) & : > \"$1\"; exit 0", duration: duration,
            killGracePeriod: .milliseconds(500), reapedGroupWindow: .seconds(30),
            onReapedGroupSignal: { group, signal in signals.mutate { $0.append([group, signal]) } })
        // The leader is gone and reaped, and the grandchild is still running: the premise.
        #expect(await Self.waitForReap(started.pid))
        #expect(await Self.waitForExactlyOneProcess(matching: sleep))

        started.call.cancel()
        guard let error = await started.call.value() else {
            killLeftovers(started.leftovers)
            return
        }

        #expect(error is CancellationError)
        #expect(await Self.waitForNoProcess(matching: sleep), "the grandchild outlived the call")
        // What makes the seam's silence in the two tests below mean something: here, with the
        // group still holding the grandchild, it saw the SIGTERM and then the SIGKILL go out.
        #expect(signals.current == [[started.pid, SIGTERM], [started.pid, SIGKILL]])
    }

    // MARK: - Cancellation: the reap the runner has not recorded yet (E1 S1)

    /// git's stand-in for E1 S1: a helper it started — a hook, an ssh, a credential helper —
    /// that ignores SIGTERM and holds the pipes, and git itself exiting while it runs. The
    /// leader waits for the helper's trap (its `$1.trap`), so the helper ignores SIGTERM from
    /// before the leader ends.
    private static let helperOutlivingTheLeader =
        "( trap '' TERM; : > \"$1.trap\"; exec sleep \"$2\" ) & "
        + "while [ ! -e \"$1.trap\" ]; do sleep 0.01; done; rm -f \"$1.trap\"; : > \"$1\"; exit 0"

    /// **E1 S1.** The cancel and the escalation both land after Foundation has reaped git but
    /// before the runner has recorded it: `isRunning` is false and the pid is free, so the
    /// SIGKILL through the leader reaches nothing. It used to count as sent all the same; the
    /// helper, ignoring SIGTERM, ran on, and the call came back only by the abandonment. Now a
    /// SIGKILL that reached nothing is kept pending, and the record of the reap sends it to the
    /// remembered group (`onReapedGroupSignal` sees it, as the fork storm's proof requires).
    ///
    /// The gap is held open by `beforeRecordingTermination` until the escalation has made its
    /// attempt — A1 needed ~200 random iterations to land in it (3 in 200). The helper is gone
    /// a grace after the cancel, on the runner's clock (`expectEscalation`).
    @Test(.timeLimit(.minutes(10))) func anEscalationThatFindsGitReapedButNotYetRecordedStillKillsItsHelper() async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let attempts = Locked<[ProcessRunner.SignalAttempt]>([])
        let reapedGroupSignals = Locked<[[Int32]]>([])
        let hold = TerminationHold()
        defer { hold.release() }
        let started = try await startScript(
            Self.helperOutlivingTheLeader, duration: duration, killGracePeriod: .seconds(2),
            onReapedGroupSignal: { group, signal in reapedGroupSignals.mutate { $0.append([group, signal]) } },
            onSignal: { attempt in
                attempts.mutate { $0.append(attempt) }
                // The escalation has made its attempt: the runner may record the reap now.
                if attempt.signal == SIGKILL { hold.release() }
            },
            beforeRecordingTermination: { hold.hold() })
        // The premise, each part able to fail: Foundation has reaped git (the termination
        // handler is being held, and the pid is free), its group still holds the helper, and
        // the runner has recorded nothing.
        while !hold.entered { try await Task.sleep(for: .milliseconds(10)) }
        errno = 0
        #expect(kill(started.pid, 0) == -1 && errno == ESRCH, "git is not reaped")
        #expect(kill(-started.pid, 0) == 0, "git's group holds nothing")
        #expect(await Self.waitForExactlyOneProcess(matching: sleep))

        started.call.cancel()
        guard let error = await started.call.value() else {
            hold.release()
            killLeftovers(started.leftovers)
            return
        }

        #expect(error is CancellationError)
        let helperIsGone = await Self.waitForNoProcess(matching: sleep)
        #expect(helperIsGone, "the TERM-ignoring helper outlived the call")
        if !helperIsGone { killLeftovers([sleep]) }
        // Through the remembered group, at the record of the reap — the fork storm's seam.
        #expect(reapedGroupSignals.current == [[started.pid, SIGKILL]])
        // Neither the SIGTERM nor the escalation's own SIGKILL reached anything; the one that
        // did came at the record, a grace after the cancel on the runner's clock.
        #expect(attempts.current.map(\.signal) == [SIGTERM, SIGKILL, SIGKILL])
        #expect(attempts.current.map(\.delivered) == [false, false, true])
        Self.expectEscalation(attempts.current, after: .seconds(2))
    }

    /// The control for the test above, and what the runner did before the fix: with the
    /// record of the reap held until the call has come back — by the abandonment, a grace after
    /// the SIGKILL that reached nothing — no kill is ever sent, and the leak check fails on the
    /// helper that is still running. The test then kills it by its group, which is git's.
    @Test(.timeLimit(.minutes(10))) func aReapRecordedOnlyAfterTheCallCameBackLeavesTheHelperRunning() async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let reapedGroupSignals = Locked<[[Int32]]>([])
        let hold = TerminationHold()
        defer { hold.release() }
        let started = try await startScript(
            Self.helperOutlivingTheLeader, duration: duration, killGracePeriod: .milliseconds(500),
            onReapedGroupSignal: { group, signal in reapedGroupSignals.mutate { $0.append([group, signal]) } },
            beforeRecordingTermination: { hold.hold() })
        while !hold.entered { try await Task.sleep(for: .milliseconds(10)) }
        #expect(await Self.waitForExactlyOneProcess(matching: sleep))

        started.call.cancel()
        guard let error = await started.call.value() else {
            hold.release()
            killLeftovers(started.leftovers)
            return
        }
        #expect(error is CancellationError)

        await withKnownIssue("the reap is recorded only after the call came back, so nothing kills the helper") {
            #expect(await Self.waitForNoProcess(matching: sleep), "the TERM-ignoring helper outlived the call")
        }
        hold.release()
        #expect(reapedGroupSignals.current.isEmpty)
        #expect(killLeftovers([sleep]) == [started.pid])
        #expect(await Self.waitForNoProcess(matching: sleep))
    }

    // MARK: - The escalation's latency, on the runner's clock

    /// How late the escalation's SIGKILL may come after the grace, on the runner's own clock.
    /// See `expectEscalation`.
    static let escalationMargin: Duration = .milliseconds(500)

    /// The escalation's latency **as the runner measured it**: from the cancel's SIGTERM attempt
    /// to the first SIGKILL that reached a process, both read by the runner as it made them
    /// (`onSignal`). At least the grace, and at most the grace plus `escalationMargin`.
    ///
    /// The upper bound is on the runner's interval, not the test's: no wait of the test for a
    /// thread is in it, only the escalation's own timer and the `kill` behind it.
    private static func expectEscalation(
        _ attempts: [ProcessRunner.SignalAttempt], after grace: Duration,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard let sigterm = attempts.first(where: { $0.signal == SIGTERM }),
            let sigkill = attempts.first(where: { $0.signal == SIGKILL && $0.delivered })
        else {
            Issue.record("escalation: no SIGTERM, or no SIGKILL that reached anything: \(attempts)", sourceLocation: sourceLocation)
            return
        }
        let latency = sigkill.at - sigterm.at
        #expect(latency >= grace, "escalation: the SIGKILL came before the grace was up, \(latency)", sourceLocation: sourceLocation)
        #expect(
            latency <= grace + escalationMargin,
            "escalation: the SIGKILL came \(latency) after the SIGTERM, against a grace of \(grace)",
            sourceLocation: sourceLocation)
    }

    /// The escalation comes a grace after the SIGTERM, measured inside the runner — the latency
    /// claim the test's own clock could not make once load was let into it (E1 Task 1).
    @Test(.timeLimit(.minutes(10))) func theEscalationComesOneGraceAfterTheSIGTERMOnTheRunnersClock() async throws {
        let attempts = Locked<[ProcessRunner.SignalAttempt]>([])
        let started = try await startChildIgnoringSIGTERM(
            onSignal: { attempt in attempts.mutate { $0.append(attempt) } })

        started.call.cancel()
        guard let error = await started.call.value() else {
            killLeftovers(started.leftovers)
            return
        }

        #expect(error is CancellationError)
        // The ordinary path: the SIGTERM reached the live child, the SIGKILL its group.
        #expect(attempts.current.map(\.signal) == [SIGTERM, SIGKILL])
        #expect(attempts.current.map(\.delivered) == [true, true])
        Self.expectEscalation(attempts.current, after: .seconds(2))
    }

    /// The control for `expectEscalation`: an escalation that really comes early (a 1 s grace)
    /// or late (past the margin) against the 2 s it is checked for fails it.
    @Test(.timeLimit(.minutes(10)), arguments: [
        Duration.seconds(1), Duration.seconds(2) + StreamingRunnerTests.escalationMargin + .seconds(1),
    ])
    func anEscalationOutsideTheGraceFailsTheLatencyCheck(realGrace: Duration) async throws {
        let attempts = Locked<[ProcessRunner.SignalAttempt]>([])
        let started = try await startChildIgnoringSIGTERM(
            killGracePeriod: realGrace, onSignal: { attempt in attempts.mutate { $0.append(attempt) } })

        started.call.cancel()
        guard let error = await started.call.value() else {
            killLeftovers(started.leftovers)
            return
        }

        #expect(error is CancellationError)
        withKnownIssue("the escalation came \(realGrace) after the SIGTERM, checked against 2 s") {
            Self.expectEscalation(attempts.current, after: .seconds(2))
        } matching: { issue in issue.comments.contains { $0.rawValue.hasPrefix("escalation: the SIGKILL came") } }
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
    @Test(.timeLimit(.minutes(10))) func aGroupAlreadyEmptyAtTheReapIsNeverSignalled() async throws {
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
        started.call.cancel()
        guard let error = await started.call.value() else {
            killLeftovers(started.leftovers)
            return
        }
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(signals.current.isEmpty, "signalled a group that was empty at the reap: \(signals.current)")
        #expect(elapsed > .milliseconds(550), "returned before the abandonment: \(elapsed)")
        #expect(Self.processCount(matching: sleep) == 1)
        // The job's own group, which `set -m` made for it and the runner never reaches.
        #expect(killLeftovers([sleep]).count == 1)
        #expect(await Self.waitForNoProcess(matching: sleep))
    }

    /// The bound on what is left. A group that still had a member at the reap may empty later
    /// while a holder outside it keeps the call waiting, and then its id is free for a pid
    /// reuse too; the runner cannot see that happen without asking the very number that may no
    /// longer be its own. So it signals a reaped leader's group only within
    /// `reapedGroupWindow` of the reap. Past it, a cancel sends nothing by that number and is
    /// ended by the abandonment — here with the group's own member still alive, which is the
    /// price, and which the test cleans up.
    @Test(.timeLimit(.minutes(10))) func aReapedGroupIsNotSignalledPastTheWindow() async throws {
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
        started.call.cancel()
        guard let error = await started.call.value() else {
            killLeftovers(started.leftovers)
            return
        }
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(signals.current.isEmpty, "signalled a reaped group past the window: \(signals.current)")
        #expect(elapsed > .milliseconds(550), "returned before the abandonment: \(elapsed)")
        #expect(Self.processCount(matching: sleep) == 1)
        // The reaped leader's group, read from its live `sleep`: the number still names it.
        #expect(killLeftovers([sleep]) == [started.pid])
        #expect(await Self.waitForNoProcess(matching: sleep))
    }

    /// A leader forking helpers as fast as it can. A process that is *being forked* when the
    /// group's SIGTERM is sent misses it (measured on macOS by the reviewer: 28 in 100), so it
    /// outlives a leader that died, holding the pipes. Every cancel must still come back, and
    /// leave nothing behind.
    ///
    /// Non-vacuous: at least one cancel must have needed the escalation to a reaped leader's
    /// group, or the race this test is about never happened. That is **counted**, as the SIGKILLs
    /// the runner reports through `onReapedGroupSignal` immediately before it sends them, not
    /// inferred from a cancel taking longer than the grace: on the test's clock, a cancel waiting
    /// for a thread of the saturated cooperative pool took longer with no orphan at all (E1
    /// survey S9). The race is hit in a few of 100 here, so the loop runs a hundred cancels and
    /// then goes on, up to five hundred, until one has.
    ///
    /// The orphan outlives a reaped leader, so it too is killed by the remembered group, and the
    /// window is 30 s for the reason the grandchild test above gives. An orphan nobody killed is
    /// the `waitForNoProcess` below; a call that waited for one sleeps past the time limit.
    @Test(.timeLimit(.minutes(10))) func aForkStormLeaderCancelledAHundredTimesNeverWaitsForAnOrphan() async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let reapedGroupKills = Locked(0)
        for attempt in 0..<500 where attempt < 100 || reapedGroupKills.current == 0 {
            let started = try await startScript(
                ": > \"$1\"; while :; do sleep \"$2\" & kill $! 2>/dev/null; wait $! 2>/dev/null; done",
                duration: duration, killGracePeriod: .milliseconds(300), reapedGroupWindow: .seconds(30),
                onReapedGroupSignal: { _, signal in
                    if signal == SIGKILL { reapedGroupKills.mutate { $0 += 1 } }
                })
            #expect(kill(started.pid, 0) == 0)
            try await Task.sleep(for: .microseconds(Int.random(in: 0...20_000)))

            started.call.cancel()
            guard let error = await started.call.value("attempt \(attempt)") else {
                killLeftovers(started.leftovers)
                return
            }
            #expect(error is CancellationError)
        }
        Self.expectARaceWasProved(reapedGroupKills.current)
        #expect(await Self.waitForNoProcess(matching: sleep), "an orphan outlived its call")
    }

    /// The fork storm's proof that its race happened: a SIGKILL went to a reaped leader's group.
    private static func expectARaceWasProved(
        _ reapedGroupKills: Int, sourceLocation: SourceLocation = #_sourceLocation
    ) {
        #expect(
            reapedGroupKills > 0, "no cancel ever raced a fork, so nothing was proved",
            sourceLocation: sourceLocation)
    }

    /// The control for the fork storm's counted proof: a leader that forks nothing dies on its
    /// SIGTERM and leaves no orphan, so no SIGKILL goes to a reaped group and the proof fails,
    /// as it must when the race never happened. The proof it replaced — a cancel taking longer
    /// than the grace on the test's clock — could be met here by load alone.
    @Test(.timeLimit(.minutes(10))) func withoutAForkTheStormsProofFails() async throws {
        let reapedGroupKills = Locked(0)
        for attempt in 0..<20 {
            let started = try await startScript(
                ": > \"$1\"; exec sleep \"$2\"", duration: Self.uniqueDuration(),
                killGracePeriod: .milliseconds(300), reapedGroupWindow: .seconds(30),
                onReapedGroupSignal: { _, signal in
                    if signal == SIGKILL { reapedGroupKills.mutate { $0 += 1 } }
                })
            started.call.cancel()
            guard let error = await started.call.value("attempt \(attempt)") else {
                killLeftovers(started.leftovers)
                return
            }
            #expect(error is CancellationError)
        }
        withKnownIssue("no fork, so no orphan and no SIGKILL to a reaped group") {
            Self.expectARaceWasProved(reapedGroupKills.current)
        }
    }

    /// The control for the hang guards above, which replaced `elapsed < cameBackBound`: what
    /// that bound caught — a call that waited out its child's sleep — is now a call that is
    /// still waiting when the time limit cancels the test, and the test reports it.
    ///
    /// Each fixture is one the tests above use, with the escalation made to never act (a grace
    /// that outlasts the limit): the TERM-ignoring child itself, and a TERM-ignoring
    /// grandchild in the group after the leader died. A real limit cannot be let expire here
    /// (`TimeLimitSupport.swift`), so the test's task is stood in for by a waiting task that
    /// this test cancels. The call's own process group — made by this call, still holding the
    /// sleeping child — is then SIGKILLed so that nothing outlives the control.
    @Test(.timeLimit(.minutes(10)), arguments: [
        "trap '' TERM; : > \"$1\"; exec sleep \"$2\"",
        "( trap '' TERM; : > \"$1\"; exec sleep \"$2\" ) & wait",
    ])
    func aCallThatWaitsOutItsChildIsReportedOnceTheTestIsCancelled(script: String) async throws {
        let started = try await startScript(
            script, duration: Self.uniqueDuration(), killGracePeriod: .seconds(3600))
        let group = started.pid
        started.call.cancel()

        await withKnownIssue("the escalation never acts, so the call waits out the child's sleep") {
            let waiter = Task { await started.call.value() }
            try? await Task.sleep(for: .milliseconds(500))
            waiter.cancel()
            let error = await waiter.value
            #expect(error == nil, "the call came back: \(String(describing: error))")
        } matching: { $0.isNeverCameBack }

        // The group is this call's own: still alive, since its `sleep` ignores the SIGTERM.
        try #require(kill(-group, 0) == 0)
        #expect(killLeftovers(started.leftovers) == [group])
        #expect(await started.call.value("the call, its group killed") is CancellationError)
        #expect(await Self.groupIsGone(group))
    }

    /// The control for the three hang guards whose fixture the escalation does not end —
    /// `aGroupAlreadyEmptyAtTheReapIsNeverSignalled`, `aReapedGroupIsNotSignalledPastTheWindow`
    /// and `aGrandchildOutsideTheGroupIsAbandonedAfterASecondGrace` — where the abandonment, a
    /// second grace after it, is what brings the call back. Each fixture is theirs, with that
    /// grace made to outlast the limit: the call is still waiting when the test is cancelled,
    /// and the test reports it.
    ///
    /// The `sleep` holding the pipes is then killed by its own group — `set -m` made one for
    /// it, or the reaped leader's still holds it — read from the process `ownProcesses` finds
    /// under the test's own duration. (Task 1 left these without a control of their own: the
    /// only cleanup there was then a kill by command line over the whole process table.)
    @Test(.timeLimit(.minutes(10)), arguments: [
        ("set -m; sleep \"$2\" & : > \"$1\"; exit 0", Duration.seconds(5)),
        ("sleep \"$2\" & : > \"$1\"; exit 0", Duration.milliseconds(200)),
        ("set -m; sleep \"$2\" & : > \"$1\"; wait", Duration.seconds(5)),
    ])
    func aCallTheAbandonmentNeverEndsIsReportedOnceTheTestIsCancelled(
        script: String, reapedGroupWindow: Duration
    ) async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let started = try await startScript(
            script, duration: duration, killGracePeriod: .seconds(3600),
            reapedGroupWindow: reapedGroupWindow)
        #expect(await Self.waitForExactlyOneProcess(matching: sleep))
        if script.hasSuffix("exit 0") {
            // As in the tests above: the leader is reaped, and — for the in-group `sleep` —
            // the cancel comes well past the window, so nothing signals the group.
            #expect(await Self.waitForReap(started.pid))
            try await Task.sleep(for: .seconds(1))
        }
        started.call.cancel()

        await withKnownIssue("the abandonment never comes, so the call waits out the sleep") {
            let waiter = Task { await started.call.value() }
            try? await Task.sleep(for: .milliseconds(500))
            waiter.cancel()
            let error = await waiter.value
            #expect(error == nil, "the call came back: \(String(describing: error))")
        } matching: { $0.isNeverCameBack }

        #expect(killLeftovers([sleep]).count == 1)
        #expect(await started.call.value("the call, its sleep killed") is CancellationError)
        #expect(await Self.waitForNoProcess(matching: sleep))
        // The leader of the `wait` fixture died on its SIGTERM; nothing of the call is left.
        #expect(await Self.waitForNoProcess(matching: started.leftovers[0]))
    }

    /// A grandchild that has **left the process group** — here a background job of a shell with
    /// job control on (`set -m`), which gets a group of its own; `setsid` does the same, and
    /// macOS has no `setsid` command — is out of reach of every signal the runner sends. The
    /// call must not wait for it anyway: a second grace after the escalation it stops waiting,
    /// closes its ends of the pipes and throws `CancellationError`.
    ///
    /// The grandchild is then still alive, which is the honest part: the runner cannot reach
    /// it, and this test kills it itself.
    @Test(.timeLimit(.minutes(10))) func aGrandchildOutsideTheGroupIsAbandonedAfterASecondGrace() async throws {
        let duration = Self.uniqueDuration()
        let sleep = Self.sleepToken(duration)
        let clock = ContinuousClock()
        let started = try await startScript(
            "set -m; sleep \"$2\" & : > \"$1\"; wait", duration: duration,
            killGracePeriod: .milliseconds(500))
        #expect(kill(started.pid, 0) == 0)
        #expect(await Self.waitForExactlyOneProcess(matching: sleep))

        let cancelledAt = clock.now
        started.call.cancel()
        guard let error = await started.call.value() else {
            killLeftovers(started.leftovers)
            return
        }
        let elapsed = clock.now - cancelledAt

        #expect(error is CancellationError)
        #expect(elapsed > .milliseconds(900), "abandoned before two graces: \(elapsed)")
        // Out of the runner's reach, as the doc comment says — and cleaned up here, by the
        // group `set -m` made for it.
        #expect(Self.processCount(matching: sleep) == 1)
        #expect(killLeftovers([sleep]).count == 1)
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
    ///
    /// A hang is the time limit's to catch. The `< 120 s` this used to assert after the loop
    /// could not: a call that hung never let the test get that far, so it failed only runs that
    /// did not hang but waited for the cooperative pool — 132.9 s in a full unbounded
    /// `swift test`, against 2.3 s alone (E1 survey S15).
    /// `aStressCallThatNeverReturnsIsReportedOnceTheTestIsCancelled` is the control.
    @Test(.timeLimit(.minutes(10))) func threeHundredCancelsAtRandomMomentsNeitherHangNorLeak() async throws {
        let token = "gitter-cancel-stress-\(UUID().uuidString)"
        // Non-vacuous: the same probe finds a process that really is running under this token,
        // so finding none after the stress means something. The `true;` matters — `sh` execs a
        // lone command in place, and the token would vanish from the command line with it.
        //
        // 300 s, not 30: the marker must still be running when it is looked for, and that is
        // after an `await`. In one full `swift test` (inserted fix 4) the whole process made
        // almost no progress for about 30 s, while the system log reported heavy thermal
        // pressure; the marker's `sleep 30` had ended by then, the probe found nothing, and
        // the premise failed. It is ended below in every case, so the length costs nothing.
        let marker = try Self.startStressMarker("true; sleep 300", token: token)
        try await Task.sleep(for: .milliseconds(100))
        #expect(Self.processCount(matching: token) >= 1)
        await Self.endStressMarker(marker)

        guard let (completed, cancelled) = try await Self.cancelAtRandomMoments(300, {
            try await ProcessRunner().runStreaming(
                "/bin/sh", ["-c", "echo quick; echo noise >&2", token], cwd: Self.root, onStderr: { _ in })
        }) else {
            killLeftovers([token])
            return
        }
        // Both outcomes really did occur, so neither branch's assertions were skipped.
        #expect(cancelled > 0)
        #expect(completed > 0)
        #expect(await Self.waitForNoProcess(matching: token))
    }

    /// The stress test's marker: `/bin/sh -c <script> <token>`, started directly, so it leads a
    /// process group of its own (Foundation makes one for every task it launches).
    private static func startStressMarker(_ script: String, token: String) throws -> Process {
        let marker = Process()
        marker.executableURL = URL(fileURLWithPath: "/bin/sh")
        marker.arguments = ["-c", script, token]
        marker.standardOutput = FileHandle.nullDevice
        marker.standardError = FileHandle.nullDevice
        try marker.run()
        return marker
    }

    /// SIGTERMs the stress marker and waits for its shell to be reaped and its group to empty.
    /// If either fails, the failure is named and the group is SIGKILLed — the marker's
    /// `sleep 300` must not run on into the next test (E1 survey S3).
    ///
    /// Not `marker.waitUntilExit()`, which hung the Xcode scheme's run for good. Foundation
    /// notes each task it launches, by raw pointer, in a list kept per launching thread and
    /// never pruned, and tells a task without a `terminationHandler` of its exit on the
    /// launching thread's run loop; `waitUntilExit` waits for that news whenever the task's
    /// address is in the *waiting* thread's list. After an `await` the test resumes on
    /// another cooperative thread, where the address of a task launched earlier and since
    /// freed (a probe's, or a runner's) could be the marker's own: it then waited for a run
    /// loop that no one runs (measured: that list held 39 addresses, the marker's among
    /// them). So the kernel is asked, for a bounded time: the shell is reaped — Foundation
    /// reaps it off any run loop — and then its group, since the marker's own `sleep` child
    /// carries no token and would otherwise count as a process the stress left behind.
    private static func endStressMarker(
        _ marker: Process, sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        let markerPID = marker.processIdentifier
        // Read while the shell is surely unreaped, so the number is its group's.
        let markerGroup = getpgid(markerPID)
        marker.terminate()
        let reaped = await waitForReap(markerPID)
        let groupGone = reaped ? await groupIsGone(markerGroup) : false
        guard !(reaped && groupGone) else { return }
        Issue.record(
            reaped ? "the marker's group outlived its SIGTERM" : "the marker shell outlived its SIGTERM",
            sourceLocation: sourceLocation)
        // Read before the reap, from a shell that was alive: a group of the test's own.
        killOwnGroup(markerGroup)
    }

    /// The control for the stress marker's failure path: a marker that ignores its SIGTERM is
    /// not reaped, the failure is named, and the marker — shell and `sleep` — is SIGKILLed by
    /// its group rather than left running into the next test.
    @Test(.timeLimit(.minutes(10))) func aStressMarkerThatOutlivesItsSIGTERMIsKilledByItsGroup() async throws {
        let token = "gitter-stress-marker-\(UUID().uuidString)"
        let trapped = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-trap-\(UUID().uuidString)")
        let marker = try Self.startStressMarker(
            "trap '' TERM; : > \"\(trapped.path)\"; sleep \(Self.outlastsTheTimeLimit)", token: token)
        let group = getpgid(marker.processIdentifier)
        // The premise: the trap is set (the file is written on the line after it).
        for _ in 0..<1000 where !FileManager.default.fileExists(atPath: trapped.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(FileManager.default.fileExists(atPath: trapped.path), "the marker never set its trap")
        try? FileManager.default.removeItem(at: trapped)
        #expect(Self.processCount(matching: token) == 1)

        await withKnownIssue("the marker ignores its SIGTERM, so its reap fails") {
            await Self.endStressMarker(marker)
        } matching: { $0.comments.contains { $0.rawValue.contains("outlived its SIGTERM") } }

        #expect(await Self.groupIsGone(group), "the marker outlived the failed reap")
        #expect(await Self.waitForNoProcess(matching: token))
    }

    /// The stress loop: `times` calls, each cancelled at a random moment up to 12 ms after it
    /// starts and waited for through `CallUnderTest.value`. A call that completed must have
    /// printed `quick`; one that did not must throw `CancellationError`. Nil once a call never
    /// came back, which `CallUnderTest.value` has recorded.
    private static func cancelAtRandomMoments(
        _ times: Int, _ call: @escaping @Sendable () async throws -> ProcessRunner.StreamedResult
    ) async throws -> (completed: Int, cancelled: Int)? {
        var cancelled = 0
        var completed = 0
        for iteration in 0..<times {
            let stressed = CallUnderTest { () -> Result<ProcessRunner.StreamedResult, Error> in
                do {
                    return .success(try await call())
                } catch {
                    return .failure(error)
                }
            }
            // `try?`: a cancel landing here — the test's limit — still ends in the wait below,
            // which reports it, rather than in a thrown `CancellationError` that names nothing.
            try? await Task.sleep(for: .microseconds(Int.random(in: 0...12_000)))
            stressed.cancel()
            switch await stressed.value("iteration \(iteration)") {
            case nil:
                return nil
            case .success(let result):
                #expect(String(decoding: result.stdout, as: UTF8.self) == "quick\n")
                completed += 1
            case .failure(let error):
                #expect(error is CancellationError)
                cancelled += 1
            }
        }
        return (completed, cancelled)
    }

    /// The control for the stress test's hang guard: the same loop, with a call that never
    /// returns and ignores its cancel — a runner that lost its resume. The test's time limit
    /// cancels the test's task, which `CallUnderTest.value` turns into a recorded "iteration 0
    /// never came back" and an end to the loop. A real limit cannot be let expire in a control
    /// (its issue is not a known issue, and the shortest is a minute; `TimeLimitSupport.swift`),
    /// so the loop runs in a task that this test cancels in its place.
    @Test(.timeLimit(.minutes(10))) func aStressCallThatNeverReturnsIsReportedOnceTheTestIsCancelled() async throws {
        let stuck = StuckCall()
        try await withKnownIssue("the call never returns, so the cancelled loop reports it") {
            let loop = Task { try await Self.cancelAtRandomMoments(300) {
                await stuck.wait()
                throw CancellationError()
            } }
            while !stuck.waiting { try await Task.sleep(for: .milliseconds(5)) }
            try await Task.sleep(for: .milliseconds(50))
            loop.cancel()
            let outcome = try await loop.value
            #expect(outcome == nil, "the loop went on past a call that never came back")
        } matching: { $0.isNeverCameBack }
        stuck.release()
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

    /// How many of the test's own live processes have `token` on their command line
    /// (`ownProcesses`), or -1 when the listing failed.
    private static func processCount(matching token: String) -> Int {
        (try? ownProcesses(matching: token))?.count ?? -1
    }
}
