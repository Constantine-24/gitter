import Foundation
import Synchronization

/// Owns one log file on one serial queue: appends, rotates, recreates a deleted folder, and stops
/// for good at the first failure it cannot recover from. Never throws to a caller.
///
/// A serial `DispatchQueue`, not an actor (the plan's correction 1): `CommandLog.record` is
/// synchronous and called from any thread, and `queue.async` keeps the order lines were given in,
/// which unstructured tasks into an actor would not. Every write happens on the queue; the state
/// is in a `Mutex` that a write holds for its whole length, so `hasStopped`, the one read from off
/// the queue, waits behind a write that hangs.
final class LogFileWriter: Sendable {
    /// folder/gitter.log; rotated files are gitter.1.log … gitter.<keep-1>.log.
    let fileURL: URL
    /// The folder it writes in, as it was given (Show Logs opens it).
    let folder: URL

    private let limit: Int
    private let keep: Int
    private let queue = DispatchQueue(label: "dev.penzin.Gitter.log")
    private let state = Mutex(State())
    /// Used on the queue only. `FileManager` is not `Sendable`; its methods are safe to call from
    /// any thread (its documentation), and here they are called from one at a time.
    private nonisolated(unsafe) let fileManager: FileManager

    private struct State {
        var handle: FileHandle?
        /// The open file's size in bytes.
        var size = 0
        var stopped = false
    }

    init(folder: URL, limit: Int = 2_000_000, keep: Int = 5, fileManager: FileManager = .default) {
        self.folder = folder
        self.limit = limit
        self.keep = max(keep, 1)
        fileURL = folder.appending(path: "gitter.log")
        self.fileManager = fileManager
    }

    /// Appends `line` and a newline, rotating first if the file would pass `limit`.
    func append(_ line: String) {
        let data = Data((line + "\n").utf8)
        queue.async { [self] in
            state.withLock { write(data, into: &$0) }
        }
    }

    /// Waits for every append so far, but no longer than `timeout` (the terminate path, the final
    /// review's m11): true when they were all written in time; false when the queue is still busy —
    /// a write stuck on a volume that does not answer, a network home folder — and the caller goes
    /// on without them.
    func flush(within timeout: DispatchTimeInterval) -> Bool {
        let drained = DispatchSemaphore(value: 0)
        queue.async { drained.signal() }
        return drained.wait(timeout: .now() + timeout) == .success
    }

    /// Returns once every append so far has been written, without blocking a thread (tests, which
    /// wait for it through `CallUnderTest`, so a time limit can end the wait).
    func flushed() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async { continuation.resume() }
        }
    }

    /// Whether the writer has stopped, as of the appends written so far: read it after `flushed()`.
    var hasStopped: Bool {
        state.withLock { $0.stopped }
    }

    // MARK: - On the queue

    private func write(_ data: Data, into state: inout State) {
        guard !state.stopped else { return }
        do {
            // Deleted since it was opened (the user tidying up, RF2): a new folder and file.
            if state.handle != nil, !fileManager.fileExists(atPath: fileURL.path) {
                try? state.handle?.close()
                state.handle = nil
            }
            if state.handle == nil { try open(&state) }
            if state.size > 0, state.size + data.count > limit {
                try state.handle?.close()
                state.handle = nil
                try rotate()
                try open(&state)
            }
            guard let handle = state.handle else { throw CocoaError(.fileNoSuchFile) }
            try handle.write(contentsOf: data)
            state.size += data.count
        } catch {
            try? state.handle?.close()
            state.handle = nil
            state.stopped = true
        }
    }

    /// Makes the folder and the file when they are not there, and opens the file to append
    /// (`O_APPEND`): every write lands at the file's end as it is then, so a second process writing
    /// the same file (a Debug build beside the installed one) adds its lines after these rather than
    /// over them. Two processes *rotating* the same folder can still race (docs/BACKLOG.md).
    private func open(_ state: inout State) throws {
        try fileManager.createDirectory(at: folder, withIntermediateDirectories: true)
        let descriptor = fileURL.path.withCString { Darwin.open($0, O_WRONLY | O_APPEND | O_CREAT | O_CLOEXEC, 0o644) }
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        state.size = Int(try handle.seekToEnd())
        state.handle = handle
    }

    /// gitter.<keep-1>.log removed, each gitter.<n>.log up to gitter.<n+1>.log from the oldest
    /// down, then gitter.log to gitter.1.log.
    private func rotate() throws {
        func rotated(_ index: Int) -> URL { folder.appending(path: "gitter.\(index).log") }
        guard keep > 1 else {
            try fileManager.removeItem(at: fileURL)
            return
        }
        if fileManager.fileExists(atPath: rotated(keep - 1).path) {
            try fileManager.removeItem(at: rotated(keep - 1))
        }
        for index in stride(from: keep - 2, through: 1, by: -1)
        where fileManager.fileExists(atPath: rotated(index).path) {
            try fileManager.moveItem(at: rotated(index), to: rotated(index + 1))
        }
        try fileManager.moveItem(at: fileURL, to: rotated(1))
    }
}
