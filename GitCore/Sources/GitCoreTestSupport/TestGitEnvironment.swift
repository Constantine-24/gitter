import Foundation

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
/// - `TestRepo`'s own runner and `isolatedRunner()` — both behind a
///   `precondition(TestGitEnvironment.isolated)` in GitCoreTests.
/// - `CLIGitBackend()`, which builds its own runner and is the object under test. Every use of
///   it in the suite operates on a `TestRepo`'s `root`, so the repository — and with it this
///   `setenv` — exists before git is started.
/// - `StreamingRunnerTests` and two cases in `ProcessRunnerTests`, which start `/bin/sh`,
///   `/bin/sleep` and one executable that does not exist; `ownProcesses(matching:)` and its
///   tests, which start the process listing and `/bin/sh`. None of them is git, so there is
///   no configuration for the developer's machine to leak in through.
///
/// What the audit caught: three cases in `ProcessRunnerTests` that really did run
/// `/usr/bin/git` on a bare `ProcessRunner()`. They were isolated only by whichever other suite
/// happened to have built a `TestRepo` first, and `swift test --filter ProcessRunnerTests` ran
/// them against the developer's own configuration.
///
/// **Shared with GitterTests** (E3 Task 2): the test host there is the app, whose stores start
/// the real `/usr/bin/git` through `ProcessRunner` too, so `makeTestStore` and `ScratchRepo`
/// touch it the same way, each with `precondition(TestGitEnvironment.isolated)`. This target
/// imports no GitCore (measurement B2.2), so `isolatedRunner()` stays in GitCoreTests.
public enum TestGitEnvironment {
    /// Always `true`; the value is not the point, the side effect is.
    public static let isolated: Bool = {
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
        // Fix round 1 (I3): everything that beats `GIT_SSH` when inherited from the shell that
        // started `swift test` — `GIT_SSH_COMMAND`, and a `core.sshCommand` passed through the
        // environment (`GIT_CONFIG_PARAMETERS`, `GIT_CONFIG_COUNT` with its `KEY_n`/`VALUE_n`).
        // A repository's own `core.sshCommand` — the fetch test's fake — still wins, as it should.
        for name in ["GIT_SSH_COMMAND", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT"] { unsetenv(name) }
        for name in ProcessInfo.processInfo.environment.keys
        where name.hasPrefix("GIT_CONFIG_KEY_") || name.hasPrefix("GIT_CONFIG_VALUE_") {
            unsetenv(name)
        }
        return true
    }()
}
