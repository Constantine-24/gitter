import Foundation

/// Errors produced by the Git layer. Parsers never throw; only process execution does.
public enum GitError: Error, Sendable, Equatable {
    /// `git` exited non-zero. Carries the exit code and captured stderr.
    case commandFailed(exitCode: Int32, stderr: String)
    /// The executable could not be launched at all.
    case launchFailed(String)
}
