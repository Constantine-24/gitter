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
}
