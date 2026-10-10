import Dispatch
import Foundation

/// Waits for `pid` to exit, through kqueue's `EVFILT_PROC`/`NOTE_EXIT`; returns at once if it is
/// already gone (`EV_ADD` fails with ESRCH). No sleep loop, and no bound: a pid that never exits
/// holds the wait, so a test waits through `CallUnderTest` — the time limit then ends the wait
/// (E3 Task 2, replacing E1's polls of `kill(pid, 0)` counted in 10 ms sleeps).
///
/// Measured (E3 Task 2, and measurement B4.5's `probe-kit/kq.swift`):
/// - The event fires for a child and for a reparented grandchild alike.
/// - It fires at the **exit, before the reap**: right after it, an unreaped child still answers
///   `kill(pid, 0)`. A caller that needs the pid reaped (ESRCH) still has a step with no event.
/// - `EV_ADD` fails with ESRCH on a pid that has exited but is not reaped yet, as on one that is
///   gone, so either ends the wait at once.
///
/// The kqueue's own descriptor is read through a dispatch source, so the wait holds no thread of
/// the cooperative pool (or any other) while the process runs.
public func waitForExit(_ pid: pid_t) async {
    precondition(pid > 0, "waitForExit: no process has pid \(pid)")
    let queue = kqueue()
    precondition(queue >= 0, "kqueue: errno \(errno)")
    var change = kevent(
        ident: UInt(pid), filter: Int16(EVFILT_PROC), flags: UInt16(EV_ADD | EV_ONESHOT),
        fflags: NOTE_EXIT, data: 0, udata: nil)
    if kevent(queue, &change, 1, nil, 0, nil) == -1 {
        let failure = errno
        close(queue)
        precondition(failure == ESRCH, "kevent EV_ADD for pid \(pid): errno \(failure)")
        return
    }
    await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
        // Readable once the registered event is pending. The source is cancelled on its first
        // event, and the cancel handler, which runs once, closes the queue and resumes.
        let source = DispatchSource.makeReadSource(fileDescriptor: queue, queue: .global())
        source.setEventHandler { source.cancel() }
        source.setCancelHandler {
            close(queue)
            continuation.resume()
        }
        source.activate()
    }
}
