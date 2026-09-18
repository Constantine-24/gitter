import CoreServices
import Foundation

/// Watches a repository root (including `.git/`) for filesystem changes and calls `onChange`
/// on the main actor, after filtering out noise (lockfiles and loose-object writes).
///
/// `@unchecked Sendable`: the FSEventStream callback fires on `queue` (a private serial
/// queue), but it only ever reads immutable `let` properties captured by value and hops to
/// the main actor before touching anything else. All other mutation (`start`/`stop`) happens
/// on the thread that created the watcher (in practice, the main actor). There is no shared
/// mutable state accessed from multiple threads without synchronization.
final class RepositoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.penzin.Gitter.RepositoryWatcher")
    private let onChange: @MainActor @Sendable () -> Void

    init(path: String, onChange: @escaping @MainActor @Sendable () -> Void) {
        self.onChange = onChange

        var context = FSEventStreamContext(
            version: 0,
            info: nil,
            retain: nil,
            release: nil,
            copyDescription: nil
        )
        context.info = Unmanaged.passUnretained(self).toOpaque()

        let flags = UInt32(kFSEventStreamCreateFlagFileEvents | kFSEventStreamCreateFlagNoDefer)
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            RepositoryWatcher.callback,
            &context,
            [path] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            return
        }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    deinit {
        stop()
    }

    /// C callback for FSEventStreamCreate. Must not capture any Swift context; the watcher
    /// instance is recovered from `clientCallBackInfo`.
    private static let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, _, _ in
        guard let clientCallBackInfo else { return }
        let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

        let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
        var relevant = false
        for index in 0..<numEvents {
            guard let raw = CFArrayGetValueAtIndex(cfArray, index) else { continue }
            let cfString = unsafeBitCast(raw, to: CFString.self)
            let path = cfString as String
            if path.hasSuffix(".lock") || path.contains("/.git/objects/") {
                continue
            }
            relevant = true
            break
        }

        guard relevant else { return }

        let onChange = watcher.onChange
        Task { @MainActor in
            onChange()
        }
    }
}
