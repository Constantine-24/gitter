import Foundation
import Testing

/// A remote whose transport blocks until the test lets it go (E2 Task 3, Ruling 2): a push held on
/// the server side (`remote.<name>.receivepack`) or a fetch (`remote.<name>.uploadpack`), on a local
/// bare remote — no network, no ssh, and no timing: the script marks that it is running, then
/// waits for a release file the test creates, and only then `exec`s the real transport.
///
/// GitCore's tests have a slow `receive-pack` of their own (`PushTests.installSlowReceivePack`), but
/// that target is not visible from here; this one waits for a file instead of a `sleep`, so a test
/// decides when the push lands. The marker is written by the same shell that then waits, so the
/// waiting process is in the transport's process group by the time the test sees it, and a cancel
/// (the runner's escalation) ends it. Nothing here kills anything: `letGo()` only creates a file.
///
/// Every test that holds one calls `letGo()` in a `defer`, so a failing test never leaves a
/// transport waiting. The wait also ends when the scratch directory is gone: a test's
/// `repo.remove()` right after `letGo()` can delete the release file before the script's next look,
/// and a script left waiting for it would hold its `git push` — re-parented to launchd, in a
/// process group of its own — for good (found in Task 3's review, and once in this task's own
/// mutation runs).
struct HeldTransport {
    enum Side {
        case receivePack, uploadPack

        var key: String {
            switch self {
            case .receivePack: "receivepack"
            case .uploadPack: "uploadpack"
            }
        }

        var program: String {
            switch self {
            case .receivePack: "git-receive-pack"
            case .uploadPack: "git-upload-pack"
            }
        }
    }

    let started: URL
    let release: URL

    /// Installs the hold on `remote` of `repo`. The script, its marker and its release file are
    /// siblings of the repository, inside the directory `repo.remove()` takes away.
    init(in repo: ScratchRepo, remote: String, side: Side) throws {
        let id = UUID().uuidString
        started = repo.directory.appending(path: "held-\(id).started")
        release = repo.directory.appending(path: "held-\(id).release")
        let script = repo.directory.appending(path: "held-\(id).sh")
        try """
            #!/bin/sh
            : > "\(started.path)"
            while [ ! -e "\(release.path)" ]; do [ -d "\(repo.directory.path)" ] || exit 1; sleep 0.05; done
            exec \(side.program) "$@"

            """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try repo.git("config", "remote.\(remote).\(side.key)", script.path)
    }

    /// Whether the transport has started and is waiting (`waitUntil`, so a transport that never
    /// starts is the test's `.timeLimit`, recorded as `neverCameBack`).
    @MainActor
    @discardableResult
    func waitUntilHeld(sourceLocation: SourceLocation = #_sourceLocation) async -> Bool {
        let path = started.path
        return await waitUntil("the held transport starting", sourceLocation: sourceLocation) {
            FileManager.default.fileExists(atPath: path)
        }
    }

    /// Lets the transport go on. Safe to call more than once.
    func letGo() {
        FileManager.default.createFile(atPath: release.path, contents: nil)
    }

    /// `repo` with a first commit pushed to a local bare `origin` it tracks, a second commit to
    /// push, and the hold on `origin`'s `receive-pack`: `store.push()` then holds the lane with a
    /// write until `letGo()`.
    static func heldPush(in repo: ScratchRepo) throws -> HeldTransport {
        try repo.commit("a.txt", "one\n", "first")
        let bare = try repo.makeBareRemote()
        try repo.git("remote", "add", "origin", bare.path)
        try repo.git("push", "-u", "origin", "main")
        try repo.commit("b.txt", "two\n", "second")
        return try HeldTransport(in: repo, remote: "origin", side: .receivePack)
    }

    /// `repo` with a commit and a local bare `origin` whose `upload-pack` is held: `store.fetch()`
    /// then holds the lane with a read until `letGo()`.
    static func heldFetch(in repo: ScratchRepo) throws -> HeldTransport {
        try repo.commit("a.txt", "one\n", "first")
        let bare = try repo.makeBareRemote()
        try repo.git("remote", "add", "origin", bare.path)
        return try HeldTransport(in: repo, remote: "origin", side: .uploadPack)
    }
}
