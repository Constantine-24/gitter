import Foundation
import GitCore

/// The error banner, and the bookkeeping that serializes mutations behind `isMutating`.
extension RepositoryStore {

    // MARK: - Errors

    /// Clears the currently displayed error (the banner's dismiss button).
    func dismissError() {
        setError(nil)
        errorIsSticky = false
    }

    // MARK: - Mutation bookkeeping

    /// Claims the store for one git write, returning the generation to hand back to
    /// `finishMutation`, or nil when it cannot be claimed: no repository, or a mutation is
    /// already running (mutations are serialized, which is also what disables the buttons).
    ///
    /// This pair exists so the setters of `isMutating` and `lastError` can stay private while
    /// the staging API lives in another file, where `private(set)` would not reach.
    func beginMutation() -> Int? {
        guard root != nil, !isMutating else { return nil }
        isMutating = true
        // A new attempt supersedes the last one's message: it has been read or ignored by
        // now, and nothing should keep protecting it from the reloads that follow.
        if errorIsSticky {
            setError(nil)
            errorIsSticky = false
        }
        return generation
    }

    /// Releases the claim `beginMutation()` made, showing `failure` in the banner if there was
    /// one. A stale generation means `open()` has already reset everything this would write.
    func finishMutation(generation: Int, failure: Error?) {
        guard self.generation == generation else { return }
        if let failure {
            setError(Self.describe(failure))
            // Protected from the reloads this mutation set off — its own, and the
            // watcher-driven one that git's writes inside `.git` trigger in parallel.
            errorIsSticky = true
        }
        isMutating = false
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
