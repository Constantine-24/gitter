import Foundation

/// Errors produced by the Git layer. Parsers never throw; only process execution does.
public enum GitError: Error, Sendable, Equatable {
    /// `git` exited non-zero. Carries the exit code and captured stderr.
    case commandFailed(exitCode: Int32, stderr: String)
    /// The executable could not be launched at all.
    case launchFailed(String)
    /// `commit(message:...)` was called with a message that is empty or contains only
    /// whitespace. Thrown before git runs at all.
    case emptyCommitMessage
    /// `commit(message:amend: true, ...)` was called while the repository is part-way through
    /// `operation`. Thrown before git runs at all — see `GitWorkingCopyBackend.commit` for the
    /// measured table of which four of the six git would otherwise have gone through with.
    case amendDuringOperation(RepositoryOperation)
    /// A git command was built with `count` arguments, more than `limit`
    /// (`CLIGitBackend.argumentLimit`). Thrown before git runs at all: `Process` raises an
    /// Objective-C exception — a crash — for more than 4096 (Ruling 26).
    case tooManyArguments(count: Int, limit: Int)
}
