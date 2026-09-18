import Foundation
import Testing
@testable import GitCore

@Suite struct ProcessRunnerTests {
    @Test func capturesStdoutOfSuccessfulCommand() async throws {
        let runner = ProcessRunner()
        let out = try await runner.run("/usr/bin/git", ["--version"], cwd: URL(fileURLWithPath: "/"))
        #expect(String(decoding: out, as: UTF8.self).hasPrefix("git version"))
    }

    @Test func throwsWithExitCodeAndStderrOnFailure() async {
        let runner = ProcessRunner()
        await #expect {
            _ = try await runner.run("/usr/bin/git", ["rev-parse", "HEAD"], cwd: URL(fileURLWithPath: "/"))
        } throws: { error in
            guard case let GitError.commandFailed(code, stderr) = error else { return false }
            return code != 0 && stderr.contains("not a git repository")
        }
    }

    @Test func throwsWhenExecutableIsMissing() async {
        let runner = ProcessRunner()
        await #expect(throws: GitError.self) {
            _ = try await runner.run("/nonexistent/git", [], cwd: URL(fileURLWithPath: "/"))
        }
    }

    @Test func allowedExitCodesReturnsStdoutInsteadOfThrowing() async throws {
        let runner = ProcessRunner()
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-processrunner-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("f.txt")
        try "line1\n".write(to: file, atomically: true, encoding: .utf8)

        // `git diff --no-index` exits 1 when the compared paths differ, which is expected
        // usage, not a failure; allowedExitCodes lets callers treat that as success and
        // still get the diff it wrote to stdout.
        let out = try await runner.run(
            "/usr/bin/git", ["diff", "--no-index", "/dev/null", file.path], cwd: dir,
            allowedExitCodes: [1]
        )
        #expect(String(decoding: out, as: UTF8.self).contains("+++ "))
    }

    /// Regression guard for the pipe-draining race: the old implementation nil'd the
    /// readability handlers and then called `readDataToEndOfFile()` on the same descriptors
    /// from the termination handler, so a handler still running could append its chunk after
    /// the tail had already been appended, corrupting the order of large outputs.
    @Test func largeStdoutIsCapturedInOrder() async throws {
        let runner = ProcessRunner()
        let out = try await runner.run(
            "/bin/sh",
            ["-c", "i=0; while [ $i -lt 40000 ]; do echo line$i; i=$((i+1)); done"],
            cwd: URL(fileURLWithPath: "/")
        )
        let lines = String(decoding: out, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 40000)
        #expect(lines == (0..<40000).map { "line\($0)"[...] })
    }
}
