import Foundation
import GitCoreTestSupport
@testable import GitCore

/// A throwaway git repository in a temp directory, driven by real `git` commands via
/// `ProcessRunner`. Each test creates its own and cleans it up when done.
struct TestRepo {
    let root: URL
    private let runner = ProcessRunner()

    /// Written out rather than left to the memberwise initialiser so that *constructing* a
    /// repository is one of the two places `TestGitEnvironment` is guaranteed to have run —
    /// see there for what the developer's own `~/.gitconfig` would otherwise do to this suite.
    init(root: URL) {
        precondition(TestGitEnvironment.isolated)
        self.root = root
    }

    static func makeEmpty() async throws -> TestRepo {
        let repo = TestRepo(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-test-\(UUID().uuidString)", isDirectory: true))
        try FileManager.default.createDirectory(at: repo.root, withIntermediateDirectories: true)
        try await repo.git(["init", "-q", "-b", "main"])
        try await repo.git(["config", "user.email", "t@t"])
        try await repo.git(["config", "user.name", "Tester"])
        // Isolate commit tests from the developer's global config: a global
        // `commit.gpgsign=true` would make every commit try to sign (and hang or fail waiting
        // on a passphrase), and a global `core.hooksPath` would run hooks from outside this
        // repo instead of the ones a test writes under `.git/hooks`.
        try await repo.git(["config", "commit.gpgsign", "false"])
        try await repo.git(["config", "core.hooksPath", ".git/hooks"])
        return repo
    }

    @discardableResult
    func git(_ arguments: [String], allowedExitCodes: Set<Int32> = []) async throws -> Data {
        // The other guaranteed touch of `TestGitEnvironment`: a repository could in principle be
        // decoded or copied rather than initialised, but nothing runs git without coming here.
        precondition(TestGitEnvironment.isolated)
        return try await runner.run(
            "/usr/bin/git", arguments, cwd: root, allowedExitCodes: allowedExitCodes)
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Writes `contents` to `relativePath` (typically under `.git/hooks`) and marks it
    /// executable, as a hook needs to be for git to run it.
    func writeExecutable(_ relativePath: String, _ contents: String) throws {
        try write(relativePath, contents)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: root.appendingPathComponent(relativePath).path
        )
    }

    func commitAll(_ message: String) async throws {
        try await git(["add", "-A"])
        try await git(["commit", "-q", "-m", message])
    }

    /// The exact bytes the index holds for `path` (`git show :<path>`), which is what a
    /// patch applied with `--cached` produces. Byte-exact on purpose: a wrong no-newline
    /// marker corrupts the index by joining two lines, which only shows up in the raw bytes.
    func indexContent(of path: String) async throws -> Data {
        try await git(["show", ":" + path])
    }

    /// Whether `path` has an entry in the index at all.
    func isInIndex(_ path: String) async throws -> Bool {
        let out = try await git(["ls-files", "--", path])
        return !out.isEmpty
    }

    func headSha() async throws -> String {
        let out = try await git(["rev-parse", "HEAD"])
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func revParse(_ ref: String) async throws -> String {
        let out = try await git(["rev-parse", ref])
        return String(decoding: out, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func cleanUp() {
        try? FileManager.default.removeItem(at: root)
    }
}
