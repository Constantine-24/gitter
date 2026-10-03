import Foundation
import Testing

@testable import GitCore

/// Repository shapes and queries the tag suites (`TagCreateTests`, `TagDeleteTests`,
/// `TagRemoteTests`) share.
extension TestRepo {
    /// What `refs/tags/<name>` holds — the tag object for an annotated tag — or nil when there
    /// is no such tag.
    func tagObject(_ name: String) async throws -> String? {
        let data = try await git(["rev-parse", "--verify", "-q", "refs/tags/\(name)"], allowedExitCodes: [1])
        let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return id.isEmpty ? nil : id
    }

    /// `cat-file -t` of `rev`: `commit` for a lightweight tag's ref, `tag` for an annotated one.
    func objectType(_ rev: String) async throws -> String {
        String(decoding: try await git(["cat-file", "-t", rev]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The tag as Gitter's own listing reads it — the `Tag` a sheet would hold.
    func listedTag(_ name: String) async throws -> GitCore.Tag {
        let snapshot = try await CLIGitBackend().snapshot(at: root)
        return try #require(snapshot.refs.tags.first { $0.name == name })
    }

    /// A failing `gpg.program` (logs its arguments, exits 1) and `key=true`, so that any tag git
    /// decides to sign fails (B17). Never a real gpg, never a key. Returns the log's path: it
    /// stays absent while gpg is never called.
    func failTagSigning(_ key: String) async throws -> URL {
        let log = root.appendingPathComponent(".git/fake-gpg.log")
        try writeExecutable(
            ".git/fake-gpg.sh",
            "#!/bin/sh\necho \"$@\" >> \"\(log.path)\"\necho fakegpg: refusing >&2\nexit 1\n")
        try await git(["config", "gpg.program", root.appendingPathComponent(".git/fake-gpg.sh").path])
        try await git(["config", key, "true"])
        return log
    }

    /// The bare remote's `refs/tags/<name>`, or nil.
    static func remoteTag(_ bare: URL, _ name: String) async throws -> String? {
        let id = try await bareGit(bare, ["rev-parse", "--verify", "-q", "refs/tags/\(name)"], allowedExitCodes: [1])
        return id.isEmpty ? nil : id
    }
}

/// A shell script standing in for `/usr/bin/git`: one line per launch (its first argument),
/// then the real git. What "refused before git runs" is proved with.
struct GitLaunchLog {
    let directory: URL
    var wrapper: URL { directory.appendingPathComponent("git") }
    private var log: URL { directory.appendingPathComponent("log") }

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-tag-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = "#!/bin/sh\nprintf '%s\\n' \"$1\" >> '\(directory.path)/log'\nexec /usr/bin/git \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    }

    /// A backend that runs git through the wrapper.
    var backend: CLIGitBackend { CLIGitBackend(gitPath: wrapper.path) }

    /// The subcommand of every launch so far, in order.
    var launches: [String] {
        ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    /// Nothing was launched through the wrapper.
    func assertNothingRan(sourceLocation: SourceLocation = #_sourceLocation) {
        #expect(launches.isEmpty, "git ran: \(launches)", sourceLocation: sourceLocation)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}

@Suite struct GitLaunchLogTests {
    /// The negative control: a call that does launch git is seen, so "nothing ran" can fail.
    @Test func noticesALaunch() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }

        _ = try await git.backend.run(["rev-parse", "--git-dir"], cwd: repo.root)

        #expect(git.launches == ["rev-parse"])
        withKnownIssue("git really ran") { git.assertNothingRan() }
    }
}
