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
    /// sleep 30"` kept a cancelled call waiting 29.7 s — so the cancel escalates. If the call
    /// has still not *resumed* `killGracePeriod` after the SIGTERM, SIGKILL goes to the child's
    /// process group: through the child while it is unreaped, and through the group id
    /// remembered at launch once it is reaped but a pipe is still open.
    ///
    /// (Within `reapedGroupWindow` of the reap, and only if the group still had a member then;
    /// `signalReapedLeadersGroup` says why and what is left.)
    ///
    /// That second half matters because the SIGTERM does not reach every descendant, and the
    /// call waits for the pipes' EOF, which any descendant holding them can withhold. Measured
    /// on macOS in Task 7's review: a process that is *being forked* at the instant the group
    /// is signalled misses the signal (28 in 100 in a fork-storm probe) and outlives a leader
    /// that died; and a grandchild that ignores SIGTERM does the same by design. Before Task
    /// 7's fix round the escalation stood down once git was reaped, and such a call waited for
    /// the grandchild's whole life (22 in 100 fork-storm cancels waited 10 s; a TERM-ignoring
    /// grandchild, 5.8 s). Now it returns in about `killGracePeriod` (measured 0.50–0.53 s with
    /// a 500 ms grace; the fork storm's worst of 100, 0.32 s with 300 ms).
    ///
    /// A descendant that has **left the group** (`setsid`, or a job-control shell's background
    /// job) is out of every signal's reach, and so is a member of the group once the window
    /// has passed. For those, a second `killGracePeriod` after the SIGKILL the call stops
    /// waiting: it closes its ends of the pipes and throws `CancellationError` (measured
    /// 1.01–1.05 s with a 500 ms grace). That descendant is left running — the runner cannot
    /// reach it — and a write of its to the closed pipe gets what a pipe with no reader gives:
    /// SIGPIPE, which kills it by default, or EPIPE if it ignores SIGPIPE. So **a cancelled call
    /// returns within about two grace periods**, whatever its descendants do (unless `onStderr`
    /// itself blocks).
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
    ///   SIGTERM before its process group is sent SIGKILL — and, again, how long after that the
    ///   call waits for its pipes before abandoning them. Two seconds in production; a test
    ///   that only needs to prove the wait is real passes a short one rather than sleeping it.
    /// - Parameter onLaunch: called with the child's pid once `run()` has succeeded, from
    ///   whatever thread started it. It exists so a cancellation test can ask the kernel
    ///   whether the process is really gone; production callers use the public overload.
    /// - Parameter reapedGroupWindow: how long after the leader's reap its remembered process
    ///   group may still be signalled; see `signalReapedLeadersGroup`. Five seconds in
    ///   production: longer than the two-second grace, so the usual case — git dies on its
    ///   SIGTERM and a grandchild that survived it is SIGKILLed a grace later — is inside it
    ///   with three seconds to spare, and far shorter than the 59 s a deliberate pid reuse
    ///   was measured to take. Tests pass a short one to reach the case past it.
    /// - Parameter onReapedGroupSignal: called with the group id and the signal immediately
    ///   before a reaped leader's group is signalled — the one `kill(-pgid, …)` the runner
    ///   makes by a remembered number rather than through a live child. A test records it to
    ///   prove when that call is *not* made.
    func runStreaming(
        _ executable: String, _ arguments: [String], cwd: URL,
        allowedExitCodes: Set<Int32> = [],
        killGracePeriod: Duration = .seconds(2),
        reapedGroupWindow: Duration = .seconds(5),
        onLaunch: (@Sendable (Int32) -> Void)?,
        onReapedGroupSignal: (@Sendable (pid_t, Int32) -> Void)? = nil,
        onStderr: @escaping @Sendable (String) -> Void
    ) async throws -> StreamedResult {
        // Built before the cancellation handler is installed, because `onCancel` can run at
        // any moment from any thread — including before the operation closure is entered, if
        // the task is cancelled already — and it has nowhere to record that but here.
        let state = StreamingProcessState(
            killGracePeriod: killGracePeriod, reapedGroupWindow: reapedGroupWindow,
            onReapedGroupSignal: onReapedGroupSignal)

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

                // Every handler asks `beginRead` before it touches its handle, and says
                // `endRead` when it is done — delivering segments included. That is what lets an
                // abandoned run (see `StreamingProcessState.abandon`) close the read ends
                // without a handler reading a closed descriptor, and what keeps the resume from
                // overtaking a segment that is still being delivered. Each calls `finish` last,
                // because a claim that another thread found blocked by this read in flight is
                // this handler's to make.
                stdout.fileHandleForReading.readabilityHandler = { handle in
                    guard state.beginRead() else { return }
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        state.markStdoutFinished()
                    } else {
                        state.appendStdout(chunk)
                    }
                    state.endRead()
                    finish()
                }
                stderr.fileHandleForReading.readabilityHandler = { handle in
                    guard state.beginRead() else { return }
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        handle.readabilityHandler = nil
                        // The unterminated tail is a segment too, and this is its only
                        // chance: delivered before `endRead`, so every segment has reached the
                        // caller by the time the call returns.
                        for segment in state.markStderrFinished() { onStderr(segment) }
                    } else {
                        for segment in state.appendStderr(chunk) { onStderr(segment) }
                    }
                    state.endRead()
                    finish()
                }

                process.terminationHandler = { proc in
                    state.recordTermination(proc.terminationStatus, pid: proc.processIdentifier)
                    finish()
                }

                state.installAbandonment(
                    stdout: stdout.fileHandleForReading, stderr: stderr.fileHandleForReading,
                    finish: finish)

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
/// cancellation handler, the two timed work items and the launching thread of a single
/// `runStreaming` call.
///
/// `@unchecked Sendable` on the same terms as `run`'s `ProcessState`: every stored property is
/// touched only under `lock`. Signalling the child — `terminate()`, and the SIGKILL that may
/// follow it — closing the read ends and calling `finish` are deliberately done *outside* the
/// lock, after the decision to do them has been recorded inside. That is sound because the
/// decision, not the act, is the shared state: `terminateSent`, `killSent`, `abandoned` and
/// `readEndsClosed` are set under the lock by whichever thread wins, so each act happens at
/// most once no matter how many threads raced for it, and the act itself touches nothing this
/// class owns. Doing it the other way round would be worse than merely unnecessary:
/// `Process.terminate()` and `kill` are kernel calls made while the termination handler, on
/// another thread, may already be waiting on this very lock to record the exit — holding the
/// lock across them would serialise the two for no gain — and `finish` takes the lock itself.
///
/// **Resumed exactly once.** Only two functions ever answer "resume now": `claimResumeIfComplete`
/// (called through `finish`) and `claimResumeWithoutLaunching`. Both test and set `resumed` in
/// one critical section, so at most one caller is ever told to resume. The first is reached by
/// the three signals (stdout EOF, stderr EOF, termination — `run`'s rule), or, once a cancelled
/// run has been abandoned, by `abandoned` alone; in both cases only when no handler is in the
/// middle of a read, so no segment is delivered after the call has returned.
///
/// **Resumed at least once, for a cancelled run.** A cancel of a launched run always arms the
/// escalation (`armEscalation`); the escalation always arms the abandonment; the abandonment
/// always sets `abandoned` and then calls `finish`, or — if a read is in flight — leaves that to
/// the handler, whose `endRead` and `finish` follow. So a cancelled call returns within about
/// two grace periods whatever its descendants do, unless `onStderr` itself blocks.
private final class StreamingProcessState: @unchecked Sendable {
    /// What the first caller to observe completion is told to resume with.
    enum Resumption {
        case cancelled
        case finished(status: Int32, stdout: Data, stderr: Data)
    }

    /// What a cancel is to signal, decided under the lock and carried out outside it.
    private enum TerminationTarget {
        /// Not reaped yet: `Process.terminate()` signals its group, as it always has.
        case leader(Process)
        /// The leader is reaped but a pipe is still open, so a member of its group may still be
        /// running — reachable only through the process group id remembered at launch.
        case reapedLeadersGroup(pid_t)
        /// Nothing left to signal; the resume is imminent.
        case none
    }

    private let killGracePeriod: Duration
    private let lock = NSLock()
    private var outBuffer = Data()
    private var errBuffer = Data()
    /// stderr bytes since the last `\r` or `\n`: a segment that is not complete yet. Bytes,
    /// not characters, because a read can end in the middle of a multi-byte one and decoding
    /// the fragment would replace it with U+FFFD.
    private var pendingSegment: [UInt8] = []
    /// How much of `pendingSegment` has already been searched for a separator — all of it, after
    /// every `appendStderr`. The next read's search starts here, so each byte is looked at once.
    private var pendingScanned = 0
    private var stdoutFinished = false
    private var stderrFinished = false
    private var status: Int32?
    private var resumed = false
    private var cancelled = false
    private var process: Process?
    /// The child's process group id — its pid, checked at launch — or 0 when the check failed.
    /// Remembered because once the child is reaped its pid can no longer be asked about, and
    /// its group may still hold the grandchild that is keeping a pipe open.
    private var groupID: pid_t = 0
    /// The group had no member left when the leader was reaped; see `recordTermination`.
    private var groupEmptyAtReap = false
    /// When the reap was recorded — the start of `reapedGroupWindow`.
    private var reapedAt: ContinuousClock.Instant?
    private var terminateSent = false
    private var killSent = false
    private var killWork: DispatchWorkItem?
    private var abandonWork: DispatchWorkItem?
    /// Readability handlers currently between `beginRead` and `endRead`.
    private var readsInFlight = 0
    /// The cancelled call has stopped waiting for its pipes; see `abandon`.
    private var abandoned = false
    private var readEndsClosed = false
    private var readEnds: (stdout: FileHandle, stderr: FileHandle)?
    /// `runStreaming`'s `finish`, for `abandon` to call. It captures this object, so it is
    /// dropped at the resume to break the cycle.
    private var finishForAbandonment: (@Sendable () -> Void)?

    private let reapedGroupWindow: Duration
    private let onReapedGroupSignal: (@Sendable (pid_t, Int32) -> Void)?

    init(
        killGracePeriod: Duration, reapedGroupWindow: Duration,
        onReapedGroupSignal: (@Sendable (pid_t, Int32) -> Void)?
    ) {
        self.killGracePeriod = killGracePeriod
        self.reapedGroupWindow = reapedGroupWindow
        self.onReapedGroupSignal = onReapedGroupSignal
    }

    private var graceSeconds: Double {
        let grace = killGracePeriod.components
        return Double(grace.seconds) + Double(grace.attoseconds) / 1e18
    }

    /// Hands over what `abandon` needs: the two read ends and the claiming closure.
    func installAbandonment(
        stdout: FileHandle, stderr: FileHandle, finish: @escaping @Sendable () -> Void
    ) {
        lock.lock()
        defer { lock.unlock() }
        readEnds = (stdout, stderr)
        finishForAbandonment = finish
    }

    // MARK: Reads

    /// Called by a readability handler before it touches its handle. `false` once the run has
    /// been abandoned: the handle may be closed by then, and must not be read.
    func beginRead() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard !abandoned else { return false }
        readsInFlight += 1
        return true
    }

    /// The handler is done with its handle and has delivered its segments. The last read to
    /// end after an abandonment is the one that closes the read ends.
    func endRead() {
        lock.lock()
        readsInFlight -= 1
        let toClose = (abandoned && readsInFlight == 0) ? takeReadEndsLocked() : nil
        lock.unlock()
        if let toClose { Self.close(toClose) }
    }

    func appendStdout(_ chunk: Data) {
        lock.lock()
        defer { lock.unlock() }
        outBuffer.append(chunk)
    }

    /// Adds `chunk` to the captured stderr and returns the segments it completed, in order.
    ///
    /// **Linear in the bytes read, however long a line is.** The search for a separator resumes
    /// at `pendingScanned` rather than at the start of the pending segment: it used to rescan
    /// the whole unterminated segment on every read, so one long server line cost O(N²) —
    /// measured, a 10 MB line took 268 s in a debug build. And the pending segment is bounded:
    /// once it holds `maxPendingStderrSegment` bytes with no separator, that much is delivered
    /// as a segment of its own, cut on a character boundary — so an over-long progress line
    /// arrives **in pieces**, which together are the line. Buffer handling only: the captured
    /// `errBuffer`, what is returned at the end and the exactly-once resume are untouched.
    func appendStderr(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        errBuffer.append(chunk)
        pendingSegment.append(contentsOf: chunk)

        var segments: [String] = []
        var start = 0
        var index = pendingScanned
        while index < pendingSegment.count {
            let byte = pendingSegment[index]
            if byte == UInt8(ascii: "\n") || byte == UInt8(ascii: "\r") {
                // Empty segments are dropped: a `\r\n`, or a blank line, is a separator and not
                // an update worth showing.
                if index > start {
                    segments.append(String(decoding: pendingSegment[start..<index], as: UTF8.self))
                }
                start = index + 1
            } else if index + 1 - start >= Self.maxPendingStderrSegment {
                // No separator in a whole bound's worth: deliver what there is, ending before
                // any character the bound would cut in half (see `characterBoundary`).
                let cut = Self.characterBoundary(in: pendingSegment, before: index + 1, after: start)
                segments.append(String(decoding: pendingSegment[start..<cut], as: UTF8.self))
                start = cut
                index = cut
                continue
            }
            index += 1
        }
        if start > 0 { pendingSegment.removeFirst(start) }
        pendingScanned = pendingSegment.count
        return segments
    }

    /// Where to end a forced piece that would end at `end`: `end` itself if the character
    /// before it is complete, otherwise that character's lead byte, which then starts the next
    /// piece. Decided from the bytes **before** `end` — the byte after it may not have been
    /// read yet. A lead byte announces its character's length (`110xxxxx` two, `1110xxxx`
    /// three, `11110xxx` four); bytes that are not UTF-8 are cut where they are, since there is
    /// no character to keep whole.
    private static func characterBoundary(in bytes: [UInt8], before end: Int, after start: Int)
        -> Int
    {
        var lead = end - 1
        // At most three continuation bytes follow a lead byte.
        while lead > start, end - lead < 4, bytes[lead] & 0xC0 == 0x80 { lead -= 1 }
        let length: Int
        switch bytes[lead] {
        case 0xC0...0xDF: length = 2
        case 0xE0...0xEF: length = 3
        case 0xF0...0xF7: length = 4
        default: return end
        }
        return lead + length > end && lead > start ? lead : end
    }

    /// The longest stderr segment held back waiting for its separator: 64 KiB. git's own
    /// progress lines are well under 100 bytes; this is for a server that prints one enormous
    /// line, which is then delivered in pieces of at most this many bytes.
    static let maxPendingStderrSegment = 65_536

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
        pendingScanned = 0
        return [tail]
    }

    /// Records the reaped child's status, and whether the group it led was **already empty**
    /// at that moment.
    ///
    /// An empty group means whatever still holds a pipe is outside it — a descendant that left
    /// the group — and an empty group can never gain a member of ours again: its id is free,
    /// and the next process to take the leader's pid may make a group of it (measured by the
    /// Task 7 re-reviewer, whose pid-cycling program's `sleep` the runner then killed). So the
    /// group is never signalled by number after that; the abandonment ends the call.
    ///
    /// Asked with the reaped pid rather than `groupID`, because this can run before
    /// `registerLaunched` has stored the group — a child that exits at once. The probe is a
    /// kernel call and is made outside the lock. Anything but ESRCH (members, or members we may
    /// not signal) counts as not empty: the conservative answer is to keep the id, and the
    /// window below bounds it.
    func recordTermination(_ terminationStatus: Int32, pid: pid_t) {
        var emptyAtReap = true
        if pid > 1 {
            errno = 0
            emptyAtReap = kill(-pid, 0) == -1 && errno == ESRCH
        }
        lock.lock()
        defer { lock.unlock() }
        status = terminationStatus
        groupEmptyAtReap = emptyAtReap
        reapedAt = .now
    }

    // MARK: Cancellation

    /// Terminates the process if it is running, makes every later completion a
    /// `CancellationError`, and arms the escalation behind it.
    ///
    /// It never resumes the continuation itself; see the class comment.
    func requestCancellation() {
        lock.lock()
        cancelled = true
        let target = startTerminationLocked()
        lock.unlock()
        carryOut(target)
    }

    /// Publishes the launched process to the cancellation handler, terminating it at once if
    /// the cancel arrived while it was starting.
    func registerLaunched(_ launched: Process) {
        // Measured on macOS: a `Foundation.Process` child leads a process group of its own, so
        // its pgid is its pid. Checked rather than assumed — if it does not hold, the group is
        // somebody else's, possibly ours, and it is never signalled once the child is reaped.
        // Asked outside the lock: it is a kernel call and touches nothing here.
        let pid = launched.processIdentifier
        let group: pid_t = (pid > 1 && getpgid(pid) == pid) ? pid : 0

        lock.lock()
        process = launched
        groupID = group
        let target = cancelled ? startTerminationLocked() : nil
        lock.unlock()
        carryOut(target)
    }

    /// Decides, once per run, what the cancel signals. `nil` when there is nothing to do:
    /// not launched yet (`registerLaunched` will ask again), already decided, or resumed.
    private func startTerminationLocked() -> TerminationTarget? {
        guard let process, !terminateSent, !resumed else { return nil }
        terminateSent = true
        // Not `Process.terminate()` after termination has been recorded: the pid is reaped by
        // then and SIGTERM would be aimed at whatever the system gave that number next.
        if status == nil { return .leader(process) }
        let group = reapedGroupLocked()
        if group > 1 { return .reapedLeadersGroup(group) }
        return TerminationTarget.none
    }

    /// The group id a reaped leader's group may still be signalled by, or 0 when it may not:
    /// not reaped, no pipe left open (the resume is imminent), no group remembered, the group
    /// already empty at the reap, or the reap more than `reapedGroupWindow` ago. See
    /// `signalReapedLeadersGroup` for why each is there.
    private func reapedGroupLocked() -> pid_t {
        guard status != nil, !stdoutFinished || !stderrFinished,
            groupID > 1, !groupEmptyAtReap,
            let reapedAt, ContinuousClock.now - reapedAt < reapedGroupWindow
        else { return 0 }
        return groupID
    }

    /// Sends the SIGTERM and arms the escalation behind it — whether or not there was anything
    /// to send it to, because a pipe held open by a grandchild keeps the call waiting after
    /// its leader has gone. Called outside the lock.
    private func carryOut(_ target: TerminationTarget?) {
        guard let target else { return }
        switch target {
        case .leader(let leader):
            if leader.isRunning { leader.terminate() }
        case .reapedLeadersGroup(let group):
            signalReapedLeadersGroup(group, SIGTERM)
        case .none:
            break
        }
        armEscalation()
    }

    /// The escalation is a `DispatchWorkItem` rather than a timer source on purpose: a source
    /// must be resumed before it may be released, and the branch below that decides *not* to
    /// arm one would have had to release a suspended source, which traps inside libdispatch
    /// (`_dispatch_lane_suspend` from `_xref_dispose`). A work item has no such rule, and
    /// `cancel()` on one that has not started yet means it simply never runs.
    private func armEscalation() {
        // Weak, so a pending escalation keeps nothing alive; and the resume cancels it, so it
        // cannot act after the continuation has resumed.
        let escalation = DispatchWorkItem { [weak self] in self?.escalateToKill() }
        lock.lock()
        let worthArming = !resumed && !killSent && killWork == nil
        if worthArming { killWork = escalation }
        lock.unlock()
        guard worthArming else { return }
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + graceSeconds, execute: escalation)
    }

    /// The grace period is up and the call has not resumed. SIGKILL whatever can still be
    /// reached, and arm the abandonment a second grace period later.
    ///
    /// It stays armed until the resume, not until the leader's termination — the change that
    /// closed the wait measured in Task 7's review. A grandchild that survived the SIGTERM
    /// (one that ignores it, or one that was being forked at the instant the group was
    /// signalled and so was not yet in it) keeps a pipe open after git itself has been reaped;
    /// the escalation used to stand down at the reap, and the call then waited for the
    /// grandchild to exit.
    private func escalateToKill() {
        lock.lock()
        killWork = nil
        guard !resumed, !killSent else {
            lock.unlock()
            return
        }
        killSent = true
        let leader: Process? = status == nil ? process : nil
        let reapedGroup = reapedGroupLocked()
        let abandonment = DispatchWorkItem { [weak self] in self?.abandon() }
        abandonWork = abandonment
        lock.unlock()

        if let leader {
            Self.killLeadersGroup(leader)
        } else if reapedGroup > 1 {
            signalReapedLeadersGroup(reapedGroup, SIGKILL)
        }
        // Scheduled even if the resume cancelled it in the meantime: a cancelled work item
        // never runs.
        DispatchQueue.global(qos: .userInitiated)
            .asyncAfter(deadline: .now() + graceSeconds, execute: abandonment)
    }

    /// SIGKILL for a leader not yet observed to terminate — its group, when it leads one.
    private static func killLeadersGroup(_ leader: Process) {
        guard leader.isRunning else { return }
        let pid = leader.processIdentifier
        // Nothing below may ever be reached with a pid of 0 (`kill` would signal *our* whole
        // process group) or -1 (every process we may signal). `Process` only reports a pid
        // above 1 for a running child, but the consequence of a bug here is severe enough to
        // be worth the two comparisons.
        guard pid > 1 else { return }
        // The pgid/pid equality is re-checked here rather than assumed: if it does not hold,
        // the group is somebody else's — possibly ours — and only the child itself is
        // signalled. `getpgid` returning -1 means the pid is already gone; nothing is
        // signalled then.
        let group = getpgid(pid)
        if group == pid {
            kill(-group, SIGKILL)
        } else if group > 0 {
            kill(pid, SIGKILL)
        }
    }

    /// Signals the group a reaped leader led, by the id remembered at launch — the one signal
    /// the runner sends by a number rather than through a child it knows is alive, and so the
    /// one that could reach a process that is not ours.
    ///
    /// What makes the number usable: POSIX does not reuse a pid while a process group with that
    /// id has a member, so while the child's group keeps one, nobody else can own the id.
    /// Nothing the runner observes proves that it still does. An open pipe does not — a
    /// descendant that left the group (`setsid`, a job-control background job) holds it just
    /// as well — and once the group is empty the id is free: a process that later takes the
    /// leader's pid can create a group with it and exit, leaving that group alive with nobody
    /// holding the pid (the Task 7 re-reviewer did exactly this, and the earlier "the pid is
    /// free, so the group is ours" rule then signalled the foreign group). So the number is
    /// used only while each of these holds, all decided in `reapedGroupLocked`:
    ///
    /// - it was checked at launch to be the child's own group (`getpgid(pid) == pid`), and is
    ///   above 1 — never 0 (our own group) or -1 (every process we may signal);
    /// - the group still had a member **at the reap** (`recordTermination`). One that was empty
    ///   then is never signalled: whatever holds the pipe is outside it, and the abandonment
    ///   ends the call;
    /// - the reap was less than `reapedGroupWindow` ago (5 s in production);
    /// - and, asked here, no live process holds the pid itself — one that does is a new process
    ///   (the leader is reaped), and a group of that id may be its. Any answer but ESRCH,
    ///   EPERM included, means nothing is sent.
    ///
    /// **The residual risk**, stated whole: the group had a member at the reap; that member
    /// then exited while a holder *outside* the group kept a pipe open and the call waiting;
    /// the system then handed the leader's pid to a new process; and that process created a
    /// group with the id and left it behind, orphaned, before this signal. The window bounds
    /// it: all of that has to happen within 5 s of the reap, and a reuse of one particular pid
    /// needs the system to cycle through the others first — macOS hands pids out in order up
    /// to 99 999, and the re-reviewer's program, forking as fast as it could, needed 59 s
    /// to get the pid it wanted. A cancel past the window sends nothing by number: a member
    /// of the child's group that is still alive then is left running, like a descendant
    /// outside it.
    private func signalReapedLeadersGroup(_ group: pid_t, _ signal: Int32) {
        guard group > 1 else { return }
        errno = 0
        guard kill(group, 0) == -1, errno == ESRCH else { return }
        onReapedGroupSignal?(group, signal)
        kill(-group, signal)
    }

    /// The second grace period is up and the call has *still* not resumed: something that is
    /// out of every signal's reach — a descendant that left the process group — holds a pipe
    /// open. Stop waiting for it: close the read ends and let `finish` resume with
    /// `CancellationError`.
    ///
    /// The read ends are closed only when no handler is between `beginRead` and `endRead`;
    /// otherwise the last such handler closes them in `endRead`. A closed handle is never read,
    /// because every later `beginRead` answers `false`. The descendant is left running — the
    /// runner has no way to reach it — and a write of its to the closed pipe raises SIGPIPE,
    /// which kills it by default (EPIPE instead, if it ignores SIGPIPE).
    private func abandon() {
        lock.lock()
        abandonWork = nil
        guard !resumed, cancelled, !abandoned else {
            lock.unlock()
            return
        }
        abandoned = true
        let toClose = readsInFlight == 0 ? takeReadEndsLocked() : nil
        let finish = finishForAbandonment
        lock.unlock()
        if let toClose { Self.close(toClose) }
        finish?()
    }

    private func takeReadEndsLocked() -> (stdout: FileHandle, stderr: FileHandle)? {
        guard !readEndsClosed, let readEnds else { return nil }
        readEndsClosed = true
        return readEnds
    }

    private static func close(_ ends: (stdout: FileHandle, stderr: FileHandle)) {
        for end in [ends.stdout, ends.stderr] {
            end.readabilityHandler = nil
            try? end.close()
        }
    }

    // MARK: Resuming

    /// Returns what to resume with exactly once, to the first caller that observes completion:
    /// the three signals (stdout EOF, stderr EOF, termination), or an abandoned cancel — and in
    /// both cases no read in flight. Every other call returns `nil`.
    func claimResumeIfComplete() -> Resumption? {
        lock.lock()
        let complete = abandoned || (stdoutFinished && stderrFinished && status != nil)
        guard complete, readsInFlight == 0, !resumed else {
            lock.unlock()
            return nil
        }
        resumed = true
        let pending = [killWork, abandonWork]
        killWork = nil
        abandonWork = nil
        finishForAbandonment = nil
        // `abandoned` implies `cancelled`, and without it `complete` required the status.
        let resumption: Resumption =
            if !cancelled, let status {
                .finished(status: status, stdout: outBuffer, stderr: errBuffer)
            } else {
                .cancelled
            }
        lock.unlock()
        // Outside the lock, like the signals, and for the same reason. `cancel()` does not
        // wait for a work item that is already running, so it cannot deadlock against one
        // blocked on the lock this just released; that one then finds `resumed` set and does
        // nothing.
        for work in pending { work?.cancel() }
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
        let pending = [killWork, abandonWork]
        killWork = nil
        abandonWork = nil
        finishForAbandonment = nil
        lock.unlock()
        for work in pending { work?.cancel() }
        return true
    }
}
