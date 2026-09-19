import Foundation
@testable import GitCore

/// A throwaway git repository in a temp directory, driven by real `git` commands via
/// `ProcessRunner`. Each test creates its own and cleans it up when done.
struct TestRepo {
    let root: URL
    private let runner = ProcessRunner()

    static func makeEmpty() async throws -> TestRepo {
        let repo = TestRepo(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-test-\(UUID().uuidString)", isDirectory: true))
        try FileManager.default.createDirectory(at: repo.root, withIntermediateDirectories: true)
        try await repo.git(["init", "-q", "-b", "main"])
        try await repo.git(["config", "user.email", "t@t"])
        try await repo.git(["config", "user.name", "Tester"])
        return repo
    }

    @discardableResult
    func git(_ arguments: [String], allowedExitCodes: Set<Int32> = []) async throws -> Data {
        try await runner.run("/usr/bin/git", arguments, cwd: root, allowedExitCodes: allowedExitCodes)
    }

    func write(_ relativePath: String, _ contents: String) throws {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true
        )
        try contents.write(to: url, atomically: true, encoding: .utf8)
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
