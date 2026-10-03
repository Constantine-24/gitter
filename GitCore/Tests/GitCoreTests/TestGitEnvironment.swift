import Foundation
import Testing

@testable import GitCore

/// The developer's own git configuration, kept out of this suite.
///
/// Every git the tests run is a real `/usr/bin/git` started by `ProcessRunner`, which inherits
/// this process's environment — so without this, the machine's `~/.gitconfig` is in force for
/// all of them. That is not a theoretical worry: a global `fetch.prune=true` changes what
/// `fetch` does to refs, `url.<base>.insteadOf` rewrites a remote's URL out from under a test,
/// `init.defaultBranch` names the branch a bare repository starts on, and `commit.gpgsign`
/// makes every commit reach for a key. A suite that passes only on a machine configured like
/// this one is not a suite.
///
/// **Production behaviour is untouched.** `ProcessRunner` and `ProcessRunner+Streaming` are not
/// modified and know nothing about this: the user's own configuration is exactly what makes
/// their real remotes work, and Gitter must keep reading it. This is `setenv` in the *test*
/// process, and nothing else.
///
/// Three variables, and the third is not redundant — measured on git 2.54.0 (Apple Git-157):
///
/// ```
/// $ GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git config --show-origin --list
/// file:/Applications/Xcode.app/…/usr/share/git-core/gitconfig   credential.helper=osxkeychain
/// file:/Applications/Xcode.app/…/usr/share/git-core/gitconfig   init.defaultbranch=main
/// file:.git/config                                              core.repositoryformatversion=0
/// …
/// ```
///
/// `GIT_CONFIG_SYSTEM` *is* honoured (pointing it at a file with a marker key lists that
/// marker), but Apple's git reads that Xcode-bundled gitconfig **in addition** to it, and only
/// `GIT_CONFIG_NOSYSTEM=1` stops it. Its `init.defaultbranch=main` is why the bare repositories
/// in `BranchTestSupport` now spell `git init --bare -b main` for themselves: without it they
/// would start on `master`, and a clone of a bare repository whose HEAD names a branch that
/// does not exist checks nothing out.
///
/// **How it is made hard to forget.** Swift Testing has no global setup hook, so this is a
/// `static let` — initialised at most once, by whichever test gets there first — and it is
/// touched by `TestRepo.init` and `TestRepo.git`, which every repository in the suite goes
/// through. The few places that run git without a `TestRepo` (the bare repositories, the
/// colleague's clone, `RemoteState.capture`) take their runner from `isolatedRunner()`, which
/// touches it too.
///
/// **The whole target audited, so "every git" is a claim and not a hope.** `git grep` for
/// `ProcessRunner()` and `Process()` across `Tests/` leaves exactly three kinds of caller:
///
/// - `TestRepo`'s own runner and `isolatedRunner()` — both behind the precondition above.
/// - `CLIGitBackend()`, which builds its own runner and is the object under test. Every use of
///   it in the suite operates on a `TestRepo`'s `root`, so the repository — and with it this
///   `setenv` — exists before git is started.
/// - `StreamingRunnerTests` and two cases in `ProcessRunnerTests`, which start `/bin/sh`,
///   `/bin/sleep`, `/usr/bin/pgrep` and one executable that does not exist. None of them is
///   git, so there is no configuration for the developer's machine to leak in through.
///
/// What the audit caught: three cases in `ProcessRunnerTests` that really did run
/// `/usr/bin/git` on a bare `ProcessRunner()`. They were isolated only by whichever other suite
/// happened to have built a `TestRepo` first, and `swift test --filter ProcessRunnerTests` ran
/// them against the developer's own configuration.
enum TestGitEnvironment {
    /// Always `true`; the value is not the point, the side effect is.
    static let isolated: Bool = {
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        // B2's mechanical network guard (incident R0: a probe reached the user's real origin).
        // Local transports only: `file` for every bare remote here, and `ssh` solely for the one
        // fetch test that names a fake ssh script with `core.sshCommand`
        // (`gitsOwnWordsForAPartialFetchLeaveTheAskpassLineOut`). Any other ssh runs
        // `/usr/bin/false`: `GIT_SSH` is what git uses when no `core.sshCommand` is set, and
        // `core.sshCommand` beats it (measured, git 2.54) — `GIT_SSH_COMMAND` would beat the
        // fake too. No agent socket, no prompt. `noGitTheSuiteStartsCanReachTheNetwork` checks it.
        setenv("GIT_ALLOW_PROTOCOL", "file:ssh", 1)
        setenv("GIT_SSH", "/usr/bin/false", 1)
        setenv("GIT_TERMINAL_PROMPT", "0", 1)
        unsetenv("SSH_AUTH_SOCK")
        return true
    }()
}

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
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["GIT_TERMINAL_PROMPT"] == "0")

        let anyExit = Set((1...255).map { Int32($0) })
        let http = try await CLIGitBackend().runWithEnvironment(
            ["ls-remote", "http://127.0.0.1/x.git"], cwd: repo.root, extra: [:], allowedExitCodes: anyExit)
        #expect(http.exitCode != 0)
        #expect(http.stderr.contains("transport 'http' not allowed"), "\(http.stderr)")

        let ssh = try await CLIGitBackend().runWithEnvironment(
            ["ls-remote", "ssh://git@127.0.0.1/x.git"], cwd: repo.root, extra: [:], allowedExitCodes: anyExit)
        #expect(ssh.exitCode != 0)
        #expect(ssh.stderr.contains("Could not read from remote repository"), "\(ssh.stderr)")
        #expect(!ssh.stderr.contains("ssh:"), "a real ssh ran: \(ssh.stderr)")
    }
}
