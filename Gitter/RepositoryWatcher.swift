import CoreServices
import Foundation

/// Watches a repository root (including `.git/`) for filesystem changes and calls `onChange`
/// on the main actor with the paths that changed, after filtering out noise (lockfiles and
/// loose object writes).
///
/// A **linked worktree** (B3, R28) keeps none of that under its root: its `.git` is a file, and
/// git writes its HEAD, index and `FETCH_HEAD` in its own git directory
/// (`<common>/worktrees/<id>`), and the refs, `packed-refs` and configuration in the common
/// one. One stream takes several paths, so `paths(root:directories:)` adds exactly the ones the
/// watcher VERIFY measured (B3 Task 3): its git directory, `<common>/refs`, `<common>/packed-refs`
/// (a file, reported even when it is only created later), `<common>/config`, and the main
/// worktree's `<common>/HEAD`. Never the whole common directory — not its objects, not the other
/// worktrees' index files.
///
/// `.git/index` is deliberately *not* filtered: `git add`/`reset`/`rm --cached` touch only
/// the index, and ignoring it made staging invisible to the live refresh. Our own reads
/// can't feed the loop back, because `ProcessRunner` sets `GIT_OPTIONAL_LOCKS=0`, which
/// stops `status`/`diff` from rewriting the index's stat cache.
///
/// `@unchecked Sendable`: the FSEventStream callback fires on `queue` (a private serial
/// queue), but it only ever reads immutable `let` properties captured by value and hops to
/// the main actor before touching anything else. All other mutation (`start`/`stop`) happens
/// on the thread that created the watcher (in practice, the main actor). The stream itself
/// holds a retained (`passRetained`) reference to `self` for its whole lifetime, released only
/// from the stream's own `release` callback once `FSEventStreamRelease` deallocates it, so the
/// object the callback dereferences is guaranteed to be alive for as long as the stream can
/// still invoke it.
final class RepositoryWatcher: @unchecked Sendable {
    private var stream: FSEventStreamRef?
    private let queue = DispatchQueue(label: "dev.penzin.Gitter.RepositoryWatcher")
    private let onChange: @MainActor @Sendable ([String]) -> Void

    /// Every path one stream watches for the repository opened at `root`: the root alone for a
    /// main worktree (its `.git/` is inside it), and for a linked one the places git writes for it
    /// outside it (see the type's comment). `directories` nil — no `.git` found — watches the
    /// root alone, as before.
    static func paths(root: URL, directories: RepositoryDirectories?) -> [String] {
        guard let directories, directories.isLinkedWorktree else { return [root.path] }
        let common = directories.commonDirectory
        return [root.path, directories.gitDirectory.path]
            + ["refs", "packed-refs", "config", "HEAD"].map { common.appendingPathComponent($0).path }
    }

    init(paths: [String], onChange: @escaping @MainActor @Sendable ([String]) -> Void) {
        self.onChange = onChange

        // `info` is a +1 (passRetained) reference: the C stream effectively co-owns this
        // object until it is invalidated/released, which drives the matching `release`
        // callback below. Without this, a callback already queued or running could
        // dereference a deallocated `self` (the lifetime race this retain closes).
        let info = Unmanaged.passRetained(self).toOpaque()
        var context = FSEventStreamContext(
            version: 0,
            info: info,
            retain: nil,
            release: { info in
                guard let info else { return }
                Unmanaged<RepositoryWatcher>.fromOpaque(info).release()
            },
            copyDescription: nil
        )

        // `kFSEventStreamCreateFlagUseCFTypes` makes `eventPaths` a genuine `CFArrayRef` of
        // `CFStringRef`s in the callback; without it, `eventPaths` is a `char **` and bit-
        // casting it to `CFArray` (as an earlier version of this file did) is undefined
        // behavior. See Apple's FSEvents documentation for `FSEventStreamCallback`.
        let flags = UInt32(
            kFSEventStreamCreateFlagFileEvents
                | kFSEventStreamCreateFlagNoDefer
                | kFSEventStreamCreateFlagUseCFTypes
        )
        guard let created = FSEventStreamCreate(
            kCFAllocatorDefault,
            RepositoryWatcher.callback,
            &context,
            paths as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.2,
            flags
        ) else {
            // No stream was created, so the `release` callback above will never run.
            // Balance the `passRetained` above ourselves to avoid leaking `self` forever.
            Unmanaged<RepositoryWatcher>.fromOpaque(info).release()
            return
        }

        stream = created
        FSEventStreamSetDispatchQueue(created, queue)
        FSEventStreamStart(created)
    }

    func stop() {
        guard let stream else { return }
        // Clear `self.stream` before touching the C API: `FSEventStreamRelease` below can
        // synchronously drop the stream's retain count to zero and invoke the `release`
        // context callback, which releases the extra reference this class was keeping itself
        // alive with. If that was the last reference, `deinit` runs re-entrantly and calls
        // `stop()` again; with `self.stream` already `nil`, that re-entrant call is a no-op
        // instead of double-stopping/invalidating/releasing an already-torn-down stream.
        self.stream = nil
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
    }

    deinit {
        stop()
    }

    /// C callback for FSEventStreamCreate. Must not capture any Swift context; the watcher
    /// instance is recovered from `clientCallBackInfo`.
    private static let callback: FSEventStreamCallback = { _, clientCallBackInfo, numEvents, eventPaths, _, _ in
        guard let clientCallBackInfo else { return }
        let watcher = Unmanaged<RepositoryWatcher>.fromOpaque(clientCallBackInfo).takeUnretainedValue()

        // Valid only because `kFSEventStreamCreateFlagUseCFTypes` was passed at creation time,
        // which makes `eventPaths` a `CFArray` of `CFString` rather than a `char **`.
        let cfArray = unsafeBitCast(eventPaths, to: CFArray.self)
        var relevant: [String] = []
        for index in 0..<numEvents {
            guard let raw = CFArrayGetValueAtIndex(cfArray, index) else { continue }
            let cfString = unsafeBitCast(raw, to: CFString.self)
            let path = cfString as String
            if path.hasSuffix(".lock") || path.contains("/.git/objects/") {
                continue
            }
            relevant.append(path)
        }

        guard !relevant.isEmpty else { return }

        let onChange = watcher.onChange
        Task { @MainActor in
            onChange(relevant)
        }
    }
}

/// Where git keeps a repository's files for the worktree opened at a root, found as git finds
/// them: `<root>/.git` is the git directory when it is a folder; when it is a file (a linked
/// worktree) its `gitdir:` line names it. The common directory — refs, `packed-refs`, the
/// configuration, `info/` — is named by the git directory's `commondir` file, relative to it
/// (`../..`, measured), and is the git directory itself when there is none. That is
/// `rev-parse --absolute-git-dir` and `--git-common-dir`, read without starting git: the watcher
/// is created and the discard fingerprint taken synchronously.
struct RepositoryDirectories: Hashable, Sendable {
    let gitDirectory: URL
    let commonDirectory: URL

    var isLinkedWorktree: Bool { gitDirectory.path != commonDirectory.path }

    /// Nil when there is no `.git` at `root`, or its `gitdir:` line cannot be read.
    static func resolve(root: URL) -> RepositoryDirectories? {
        let dotGit = root.appendingPathComponent(".git")
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: dotGit.path, isDirectory: &isDirectory) else { return nil }
        let gitDirectory: URL
        if isDirectory.boolValue {
            gitDirectory = dotGit
        } else {
            guard let path = firstLine(of: dotGit, after: "gitdir: ") else { return nil }
            gitDirectory = resolved(path, against: root)
        }
        let common = firstLine(of: gitDirectory.appendingPathComponent("commondir"), after: "")
            .map { resolved($0, against: gitDirectory) }
        return RepositoryDirectories(gitDirectory: gitDirectory, commonDirectory: common ?? gitDirectory)
    }

    /// The first line of `file`, past `prefix`, trimmed; nil when unreadable, empty or not
    /// starting with it.
    private static func firstLine(of file: URL, after prefix: String) -> String? {
        guard let text = try? String(contentsOf: file, encoding: .utf8),
            let line = text.split(separator: "\n", omittingEmptySubsequences: false).first, line.hasPrefix(prefix)
        else { return nil }
        let value = String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        return value.isEmpty ? nil : value
    }

    /// `path` as an absolute, standardized URL: as it is when absolute, else against `base`.
    private static func resolved(_ path: String, against base: URL) -> URL {
        (path.hasPrefix("/") ? URL(fileURLWithPath: path) : base.appendingPathComponent(path)).standardizedFileURL
    }
}
