import Foundation
import GitCoreTestSupport
import Testing

/// `waitForExit` (GitCoreTestSupport, E3 Task 2): the wait on kqueue's `NOTE_EXIT` that replaced
/// the counted `kill(pid, 0)` polls for a pid's end. Each wait goes through `CallUnderTest`, so a
/// wait that never ends is the time limit's to report; the control shows that it is.
///
/// The children here are started with `posix_spawn`, not `Process`, wherever the test checks the
/// reap: `Process` reaps on a thread of its own, and `NOTE_EXIT` comes at the exit, before the
/// reap (measured: right after the event, an unreaped child still answers `kill(pid, 0)`), so an
/// ESRCH check would race that thread. The test reaps its own child instead.
///
/// "Exited" is read from the kernel's process table (`hasExited`), not from a `WNOHANG` reap: the
/// event can come while the process is still exiting (`P_WEXIT`), before it is a zombie with
/// anything to reap (Task 2 review: `waitpid(WNOHANG)` found nothing ~1 in 4 000 times under load).
@Suite struct ProcessExitTests {

    /// The wait ends once the child has exited, not before: the kernel then has it exiting, a
    /// zombie or gone, where a wait that ended early would find the `sleep` still running (in
    /// `SRUN`/`SSLEEP`, without `P_WEXIT`). The test then reaps it, and the pid is gone.
    @Test(.timeLimit(.minutes(10))) func theWaitEndsOnceTheChildHasExited() async throws {
        let pid = try Self.spawn("exec sleep 0.2")
        var reaped = false
        defer { if !reaped { Self.killAndReap(pid) } }

        let exit = CallUnderTest { await waitForExit(pid) }
        guard await exit.value("the wait for the child's exit") != nil else { return }

        #expect(Self.hasExited(pid), "the wait ended while the child still ran")
        var status: Int32 = 0
        reaped = waitpid(pid, &status, 0) == pid
        #expect(reaped)
        errno = 0
        #expect(kill(pid, 0) == -1 && errno == ESRCH, "the child is still there after its reap")
    }

    /// A pid with nothing left to wait for ends the wait at once: one already reaped, and one
    /// that has exited but is not reaped yet — still found by `kill(pid, 0)`, but `EV_ADD` on it
    /// fails with ESRCH just the same (measured). Either wait, if it waited, would wait for an
    /// exit that has already happened, so the time limit would end it.
    @Test(.timeLimit(.minutes(10))) func theWaitForAProcessAlreadyGoneEndsAtOnce() async throws {
        var status: Int32 = 0
        let reapedPID = try Self.spawn("exit 0")
        try #require(waitpid(reapedPID, &status, 0) == reapedPID)
        errno = 0
        try #require(kill(reapedPID, 0) == -1 && errno == ESRCH, "the reaped child is still there")
        let afterTheReap = CallUnderTest { await waitForExit(reapedPID) }
        #expect(await afterTheReap.value("the wait for a reaped pid") != nil)

        let zombie = try Self.spawn("exit 0")
        defer { _ = waitpid(zombie, nil, 0) }
        // Waits for the exit and leaves the child unreaped (`WNOWAIT`): a zombie.
        var info = siginfo_t()
        try #require(waitid(P_PID, id_t(zombie), &info, WEXITED | WNOWAIT) == 0, "waitid: errno \(errno)")
        try #require(kill(zombie, 0) == 0, "the exited child was reaped already")
        let beforeTheReap = CallUnderTest { await waitForExit(zombie) }
        #expect(await beforeTheReap.value("the wait for an exited, unreaped pid") != nil)
    }

    /// A grandchild is waited for too: the shell exits first, so its background `sleep` is
    /// reparented and no longer ours to reap, and kqueue still tells of its exit (the probe of
    /// measurement B4.5, `probe-kit/kq.swift`). Once the wait ends it has exited — a zombie or
    /// gone, read from the kernel's process table — where a wait that ended early would find it
    /// still sleeping out its 0.4 s.
    @Test(.timeLimit(.minutes(10))) func aReparentedGrandchildIsWaitedForToo() async throws {
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", "sleep 0.4 & echo $!; exec sleep 0.2"]
        let output = Pipe()
        shell.standardOutput = output
        shell.standardError = FileHandle.nullDevice
        shell.standardInput = FileHandle.nullDevice
        try shell.run()
        let line = String(decoding: output.fileHandleForReading.availableData, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shellPID = shell.processIdentifier
        let grandchild = try #require(pid_t(line), "the shell printed no pid: \(line)")

        let shellExit = CallUnderTest { await waitForExit(shellPID) }
        let grandchildExit = CallUnderTest { await waitForExit(grandchild) }
        // A wait that never came back kills only its own process: one that has not exited, so its
        // pid is still its own. One whose wait came back may be reaped, and its pid reused.
        guard await shellExit.value("the wait for the shell's exit") != nil else {
            kill(shellPID, SIGKILL)
            return
        }
        guard await grandchildExit.value("the wait for the grandchild's exit") != nil else {
            kill(grandchild, SIGKILL)
            return
        }
        #expect(Self.hasExited(grandchild), "the wait ended while the grandchild still ran")
    }

    /// Control: a process that never exits holds the wait until the test is cancelled — what
    /// `.timeLimit` does, stood in for here by cancelling the waiting task (a real limit cannot
    /// be let expire, `TimeLimitSupport.swift`) — and the wait is then reported as never having
    /// come back. Killing the process ends the wait, so nothing is left waiting.
    @Test(.timeLimit(.minutes(10))) func aWaitForAProcessThatNeverExitsIsReportedOnceTheTestIsCancelled() async throws {
        let pid = try Self.spawn("exec sleep 1000")
        var reaped = false
        defer { if !reaped { Self.killAndReap(pid) } }
        let exit = CallUnderTest { await waitForExit(pid) }

        await withKnownIssue("the process never exits, so the cancelled wait reports it") {
            let waiter = Task { await exit.value("the wait for sleep 1000") }
            try? await Task.sleep(for: .milliseconds(100))
            waiter.cancel()
            #expect(await waiter.value == nil, "the wait ended with the process running")
        } matching: { $0.isNeverCameBack }

        var status: Int32 = 0
        #expect(waitpid(pid, &status, WNOHANG) == 0, "sleep 1000 exited on its own")
        kill(pid, SIGKILL)
        #expect(await exit.value("the wait, its process killed") != nil)
        reaped = waitpid(pid, &status, 0) == pid
        #expect(reaped)
    }

    // MARK: - Helpers

    /// Starts `/bin/sh -c <script>` with `posix_spawn`, so the test reaps it itself. As `Process`
    /// does, every descriptor but 0–2 is closed in the child, which matters in a parallel run: a
    /// child holding another test's pipe open would keep that test's call waiting for its EOF.
    /// 0–2 are `/dev/null`.
    private static func spawn(_ script: String) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_CLOEXEC_DEFAULT))
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        for descriptor: Int32 in 0...2 {
            posix_spawn_file_actions_addopen(
                &actions, descriptor, "/dev/null", descriptor == 0 ? O_RDONLY : O_WRONLY, 0)
        }
        let arguments = ["/bin/sh", "-c", script].map { strdup($0) }
        let environment = ProcessInfo.processInfo.environment.map { strdup("\($0.key)=\($0.value)") }
        defer { (arguments + environment).forEach { free($0) } }
        var pid: pid_t = 0
        let status = posix_spawn(&pid, "/bin/sh", &actions, &attributes, arguments + [nil], environment + [nil])
        try #require(status == 0, "posix_spawn: \(status)")
        return pid
    }

    /// For a test that gives up on its own unreaped child.
    private static func killAndReap(_ pid: pid_t) {
        kill(pid, SIGKILL)
        _ = waitpid(pid, nil, 0)
    }

    /// Whether `pid` has exited — still exiting (`P_WEXIT`: `NOTE_EXIT` can come before the
    /// process is a zombie, Task 2 review), a zombie, or no longer in the kernel's process table
    /// at all (`sysctl` then succeeds with size 0, measured) — read with `sysctl`, independently
    /// of kqueue.
    private static func hasExited(_ pid: pid_t) -> Bool {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var name: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&name, u_int(name.count), &info, &size, nil, 0) == 0 else { return false }
        return size == 0 || Int32(info.kp_proc.p_stat) == SZOMB || (info.kp_proc.p_flag & P_WEXIT) != 0
    }
}
