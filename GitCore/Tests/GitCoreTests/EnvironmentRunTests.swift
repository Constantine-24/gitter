import Foundation
import Testing

@testable import GitCore

/// `runWithEnvironment` and `rerereOff`: an environment for one git call, which is how the
/// record gets `GIT_INDEX_FILE` and every stash apply gets rerere turned off, since a leading
/// `-c` is something the scanner forbids.
@Suite struct EnvironmentRunTests {
    // MARK: - rerereOff

    @Test func rerereOffWithNoCountAddsTheFirstParameter() {
        let inherited = ["PATH": "/usr/bin", "HOME": "/tmp/h"]

        let env = CLIGitBackend.rerereOff(inherited)

        #expect(env["GIT_CONFIG_COUNT"] == "1")
        #expect(env["GIT_CONFIG_KEY_0"] == "rerere.enabled")
        #expect(env["GIT_CONFIG_VALUE_0"] == "false")
        #expect(env["PATH"] == "/usr/bin")
        #expect(env["HOME"] == "/tmp/h")
        #expect(env.count == inherited.count + 3)
    }

    @Test func rerereOffAfterTheUsersOwnParametersKeepsThemAndComesLast() {
        let inherited = [
            "GIT_CONFIG_COUNT": "2",
            "GIT_CONFIG_KEY_0": "user.name", "GIT_CONFIG_VALUE_0": "Someone",
            "GIT_CONFIG_KEY_1": "rerere.enabled", "GIT_CONFIG_VALUE_1": "true",
        ]

        let env = CLIGitBackend.rerereOff(inherited)

        #expect(env["GIT_CONFIG_COUNT"] == "3")
        #expect(env["GIT_CONFIG_KEY_2"] == "rerere.enabled")
        #expect(env["GIT_CONFIG_VALUE_2"] == "false")
        #expect(env["GIT_CONFIG_KEY_0"] == "user.name")
        #expect(env["GIT_CONFIG_VALUE_0"] == "Someone")
        #expect(env["GIT_CONFIG_KEY_1"] == "rerere.enabled")
        #expect(env["GIT_CONFIG_VALUE_1"] == "true")
    }

    /// Later parameters win, measured through git itself: the user's own `rerere.enabled=true`
    /// parameter is overridden by the one `rerereOff` adds after it.
    @Test func gitReadsTheAddedParameterAsTheLastWord() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let users = [
            "GIT_CONFIG_COUNT": "1",
            "GIT_CONFIG_KEY_0": "rerere.enabled", "GIT_CONFIG_VALUE_0": "true",
        ]
        let backend = CLIGitBackend()

        let without = try await backend.runWithEnvironment(
            ["config", "--get", "rerere.enabled"], cwd: repo.root, extra: users)
        let with = try await backend.runWithEnvironment(
            ["config", "--get", "rerere.enabled"], cwd: repo.root,
            extra: CLIGitBackend.rerereOff(users))

        #expect(String(decoding: without.stdout, as: UTF8.self) == "true\n")
        #expect(String(decoding: with.stdout, as: UTF8.self) == "false\n")
    }

    /// `withConfig` (A2 Task 3) is `rerereOff` for any key: the rebase continue's
    /// `commit.cleanup=scissors` beats the repository's `verbatim` and a user's inherited
    /// parameter, both measured through git.
    @Test func withConfigIsTheLastWordOnItsKey() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.git(["config", "commit.cleanup", "verbatim"])
        let inherited = [
            "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "commit.cleanup", "GIT_CONFIG_VALUE_0": "whitespace",
            "GIT_CONFIG_PARAMETERS": "'commit.cleanup'='strip'",
        ]
        let backend = CLIGitBackend()
        let get = ["config", "--get", "commit.cleanup"]

        let env = CLIGitBackend.withConfig("commit.cleanup", "scissors", over: inherited)
        let read = try await backend.runWithEnvironment(get, cwd: repo.root, extra: env)

        #expect(env["GIT_CONFIG_COUNT"] == "2")
        #expect(env["GIT_CONFIG_KEY_1"] == "commit.cleanup" && env["GIT_CONFIG_VALUE_1"] == "scissors")
        #expect(env["GIT_CONFIG_KEY_0"] == "commit.cleanup" && env["GIT_CONFIG_VALUE_0"] == "whitespace")
        #expect(String(decoding: read.stdout, as: UTF8.self) == "scissors\n")
        #expect(CLIGitBackend.rerereOff([:]) == CLIGitBackend.withConfig("rerere.enabled", "false", over: [:]))
    }

    /// `GIT_CONFIG_PARAMETERS` — what `git -c` passes down to a child, so present whenever
    /// Gitter was started from inside a git alias or hook — is read *after* the
    /// `GIT_CONFIG_COUNT` parameters (measured: its `rerere.enabled=true` beat a count entry's
    /// `false`). So when it is present, `rerereOff` appends its parameter there too.
    @Test func rerereOffAlsoOutranksAnInheritedGitConfigParameters() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let inherited = ["GIT_CONFIG_PARAMETERS": "'rerere.enabled'='true' 'user.x'='1'"]
        let backend = CLIGitBackend()
        let get = ["config", "--get", "rerere.enabled"]

        let baseline = try await backend.runWithEnvironment(get, cwd: repo.root, extra: inherited)
        #expect(String(decoding: baseline.stdout, as: UTF8.self) == "true\n")

        let env = CLIGitBackend.rerereOff(inherited)
        let off = try await backend.runWithEnvironment(get, cwd: repo.root, extra: env)

        #expect(String(decoding: off.stdout, as: UTF8.self) == "false\n")
        #expect(env["GIT_CONFIG_PARAMETERS"] == "'rerere.enabled'='true' 'user.x'='1' 'rerere.enabled'='false'")
        #expect(CLIGitBackend.rerereOff([:])["GIT_CONFIG_PARAMETERS"] == nil,
                "an absent GIT_CONFIG_PARAMETERS stays absent")
    }

    // MARK: - runWithEnvironment

    @Test func runWithEnvironmentPassesTheExtraVariablesToGit() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }

        let result = try await CLIGitBackend().runWithEnvironment(
            ["config", "--get", "gitter.probe"], cwd: repo.root,
            extra: ["GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "gitter.probe",
                    "GIT_CONFIG_VALUE_0": "yes"])

        #expect(String(decoding: result.stdout, as: UTF8.self) == "yes\n")
        #expect(result.exitCode == 0)
    }

    /// The process's own environment is the base: the suite's isolation variables reach git
    /// too, so the extra is added to it rather than replacing it.
    @Test func runWithEnvironmentKeepsTheProcessEnvironment() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }

        let result = try await CLIGitBackend().runWithEnvironment(
            ["config", "--show-origin", "--list"], cwd: repo.root, extra: ["GITTER_UNRELATED": "1"])

        let text = String(decoding: result.stdout, as: UTF8.self)
        #expect(text.contains("user.name=Tester"))
        #expect(!text.contains("file:/Applications"), "the system config leaked in: \(text)")
    }

    @Test func runWithEnvironmentFailsLikeRun() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let backend = CLIGitBackend()

        await #expect(throws: GitError.self) {
            _ = try await backend.runWithEnvironment(
                ["rev-parse", "--verify", "no-such-ref"], cwd: repo.root, extra: [:])
        }
        do {
            _ = try await backend.runWithEnvironment(
                ["rev-parse", "--verify", "no-such-ref"], cwd: repo.root, extra: [:])
            Issue.record("expected a failure")
        } catch let GitError.commandFailed(code, stderr) {
            #expect(code == 128)
            #expect(stderr == "fatal: Needed a single revision")
        }

        let allowed = try await backend.runWithEnvironment(
            ["rev-parse", "-q", "--verify", "no-such-ref"], cwd: repo.root, extra: [:],
            allowedExitCodes: [1])
        #expect(allowed.exitCode == 1)
        #expect(allowed.stdout.isEmpty)
    }

    // MARK: - VERIFY M-rerere

    /// The spec's VERIFY: config parameters from the environment beat a repository's own
    /// `rerere.enabled=true` + `rerere.autoUpdate=true`. With a resolution recorded, a
    /// conflicting apply under `rerereOff` leaves conflict markers and an unmerged `UU` entry;
    /// the negative control, the same apply without it, lets rerere resolve and stage the file.
    @Test func rerereOffStopsARecordedResolutionFromBeingReplayed() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.git(["config", "rerere.enabled", "true"])
        try await repo.git(["config", "rerere.autoUpdate", "true"])
        try repo.write("f", "base\n")
        try await repo.commitAll("base")
        try repo.write("f", "stash\n")
        try await repo.git(["stash", "push", "-q", "-m", "s"])
        let stash = try await repo.revParse("stash@{0}")
        try repo.write("f", "head\n")
        try await repo.commitAll("head")

        // Record a resolution: the first conflicting apply records the preimage, and `git
        // rerere` after the edit records the postimage.
        _ = try await repo.git(["stash", "apply", "-q", "--no-index", stash], allowedExitCodes: [1])
        try repo.write("f", "resolved\n")
        try await repo.git(["rerere"])
        try await repo.git(["reset", "-q", "--hard"])
        #expect(try await status(repo) == "")

        let backend = CLIGitBackend()
        let apply = ["stash", "apply", "-q", "--no-index", stash]

        // With rerere off: git's own conflict, untouched.
        let off = try await backend.runWithEnvironment(
            apply, cwd: repo.root, extra: CLIGitBackend.rerereOff(ProcessInfo.processInfo.environment),
            allowedExitCodes: [1])
        #expect(off.exitCode == 1)
        let conflicted = try String(contentsOf: repo.root.appendingPathComponent("f"), encoding: .utf8)
        #expect(conflicted.contains("<<<<<<<"), "\(conflicted)")
        #expect(conflicted.contains(">>>>>>>"), "\(conflicted)")
        #expect(try await status(repo) == "UU f\n")
        #expect(!off.stderr.contains("previous resolution"), "\(off.stderr)")

        // Negative control: the same apply without it replays the resolution and stages it.
        try await repo.git(["reset", "-q", "--hard"])
        let on = try await backend.runWithEnvironment(
            apply, cwd: repo.root, extra: [:], allowedExitCodes: [1])
        #expect(on.stderr.contains("Staged 'f' using previous resolution."), "\(on.stderr)")
        let replayed = try String(contentsOf: repo.root.appendingPathComponent("f"), encoding: .utf8)
        #expect(replayed == "resolved\n")
        #expect(try await status(repo) == "M  f\n")
    }

    private func status(_ repo: TestRepo) async throws -> String {
        String(decoding: try await repo.git(["status", "--porcelain"]), as: UTF8.self)
    }
}
