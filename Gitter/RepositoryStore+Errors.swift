import Foundation
import GitCore

/// The error banner: dismissing it, and describing an `Error` for it.
extension RepositoryStore {

    // MARK: - Errors

    /// Clears the currently displayed error (the banner's dismiss button).
    func dismissError() {
        setError(nil)
        clearSticky()
    }

    // internal (not private): used by RepositoryStore+Refresh.swift and +Detail.swift
    static func describe(_ error: Error) -> String {
        if let gitError = error as? GitError {
            switch gitError {
            case .commandFailed(let exitCode, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "git exited with code \(exitCode)" : stderr
            case .launchFailed(let path):
                return "Failed to launch: \(path)"
            case .emptyCommitMessage:
                return "Enter a commit message."
            }
        }
        return error.localizedDescription
    }
}
