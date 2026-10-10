import Foundation
import GitCoreTestSupport
import Testing

@testable import GitCore

// `TestGitEnvironment.isolated` itself, with the measurements behind each line, is in
// GitCoreTestSupport's TestGitEnvironment.swift, shared with GitterTests.

/// A `ProcessRunner` for the handful of test helpers that run git somewhere there is no
/// `TestRepo` — a bare repository, or a clone that does not exist yet. Identical to
/// `ProcessRunner()`, except that asking for it is what guarantees `TestGitEnvironment` has run.
func isolatedRunner() -> ProcessRunner {
    precondition(TestGitEnvironment.isolated)
    return ProcessRunner()
}

/// Proof that no configuration reaches this suite from outside the repository the test made.
///
/// Read through `ProcessRunner` rather than by inspecting the environment, because what matters
/// is not which variables are set but what the git the tests actually start ends up reading.
@Suite struct GitConfigIsolationTests {
    @Test func noConfigurationReachesTheSuiteFromOutsideItsOwnRepository() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }

        let data = try await repo.git(["config", "--show-origin", "--list"])
        let text = String(decoding: data, as: UTF8.self)
        let origins = text.split(separator: "\n").compactMap {
            $0.split(separator: "\t", maxSplits: 1).first.map(String.init)
        }

        // A baseline that can fail: the repository's own config really is being listed, so an
        // empty answer below would be a broken probe rather than perfect isolation.
        #expect(text.contains("user.name=Tester"), "\(text)")
        #expect(!origins.isEmpty)
        for origin in Set(origins) {
            #expect(origin == "file:.git/config", "configuration reached the suite from \(origin)")
        }
    }

    /// B2's mechanical network guard (global constraints, after incident R0): no git this suite
    /// starts can reach a network host. Only local transports are allowed, and an ssh URL runs
    /// `/usr/bin/false` instead of ssh — unless a test names a fake ssh of its own with
    /// `core.sshCommand`, which beats `GIT_SSH` (measured, git 2.54). The environment is checked
    /// first, so the behavioural half never runs unguarded.
    @Test func noGitTheSuiteStartsCanReachTheNetwork() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let environment = ProcessInfo.processInfo.environment
        try #require(environment["GIT_ALLOW_PROTOCOL"] == "file:ssh")
        try #require(environment["GIT_SSH"] == "/usr/bin/false")
        // Fix round 1 (I3): each of these beats `GIT_SSH` — measured, a fake named by any of them
        // ran — so one inherited from the shell that started `swift test` would run its ssh.
        try #require(environment["GIT_SSH_COMMAND"] == nil)
        try #require(environment["GIT_CONFIG_PARAMETERS"] == nil)
        try #require(environment["GIT_CONFIG_COUNT"] == nil)
        try #require(environment.keys.filter { $0.hasPrefix("GIT_CONFIG_KEY_") || $0.hasPrefix("GIT_CONFIG_VALUE_") }.isEmpty)
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")

        let anyExit = Set((1...255).map { Int32($0) })
        let http = try await CLIGitBackend().runWithEnvironment(
            ["ls-remote", "http://fake.invalid/x.git"], cwd: repo.root, extra: [:], allowedExitCodes: anyExit)
        #expect(http.exitCode != 0)
        #expect(http.stderr.contains("transport 'http' not allowed"), "\(http.stderr)")

        let ssh = try await CLIGitBackend().runWithEnvironment(
            ["ls-remote", "ssh://git@fake.invalid/x.git"], cwd: repo.root, extra: [:], allowedExitCodes: anyExit)
        #expect(ssh.exitCode != 0)
        #expect(ssh.stderr.contains("Could not read from remote repository"), "\(ssh.stderr)")
        #expect(!ssh.stderr.contains("ssh:"), "a real ssh ran: \(ssh.stderr)")
        #expect(!ssh.stderr.contains("FAKE-SSH"), "an inherited ssh command ran: \(ssh.stderr)")
    }
}
