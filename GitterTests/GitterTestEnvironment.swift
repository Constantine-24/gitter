import Foundation

/// The developer's own git configuration and network, kept out of GitterTests (E2 Task 1).
///
/// The test host is the app itself, and the stores a test builds start the real `/usr/bin/git`
/// through `ProcessRunner`, which inherits this process's environment. Without this the machine's
/// `~/.gitconfig` is in force for every one of them: a `url.<base>.insteadOf` that rewrites HTTPS
/// to SSH, a global `commit.gpgsign`, a `fetch.prune`. This is `setenv` in the *test* process and
/// nothing else; production code is untouched.
///
/// The same sets and unsets as GitCore's `TestGitEnvironment.isolated`
/// (GitCore/Tests/GitCoreTests/TestGitEnvironment.swift), whose comment holds the measurements
/// behind each line (notably that `GIT_CONFIG_NOSYSTEM=1` is what stops Apple's Xcode-bundled
/// gitconfig). Change the two together.
///
/// Touched by `makeTestStore` and `ScratchRepo`, which every store and repository in the target
/// go through, each with `precondition(GitterTestEnvironment.isolated)`.
enum GitterTestEnvironment {
    /// Always `true`; the value is not the point, the side effect is.
    static let isolated: Bool = {
        setenv("GIT_CONFIG_GLOBAL", "/dev/null", 1)
        setenv("GIT_CONFIG_SYSTEM", "/dev/null", 1)
        setenv("GIT_CONFIG_NOSYSTEM", "1", 1)
        // Local transports only: `file` for the bare remotes the tests make, and `ssh` only so a
        // URL that names it fails by running `/usr/bin/false`. No agent socket, no prompt.
        setenv("GIT_ALLOW_PROTOCOL", "file:ssh", 1)
        setenv("GIT_SSH", "/usr/bin/false", 1)
        setenv("GIT_TERMINAL_PROMPT", "0", 1)
        unsetenv("SSH_AUTH_SOCK")
        // Everything that beats `GIT_SSH` when inherited from the shell that started the run.
        for name in ["GIT_SSH_COMMAND", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT"] { unsetenv(name) }
        for name in ProcessInfo.processInfo.environment.keys
        where name.hasPrefix("GIT_CONFIG_KEY_") || name.hasPrefix("GIT_CONFIG_VALUE_") {
            unsetenv(name)
        }
        return true
    }()
}
