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
