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
        // A refusal that reached here without the action that provoked it. Every throw site in
        // `+Branches`/`+BranchSheets` wraps these (see `reporting`), so this is a safety net,
        // not a path — but it still beats `localizedDescription`'s "The operation couldn't be
        // completed. (GitCore.BranchOperationError error 0.)".
        if let refusal = error as? BranchOperationError {
            return refusal.sentence(refusing: "do that")
        }
        return error.localizedDescription
    }
}

/// The verb a refusal is phrased around: "Can't **switch to** "feature": …".
enum BranchVerb: String {
    case switchTo = "switch to"
    case checkOut = "check out"
    case merge = "merge"
    case create = "create"
    case rename = "rename"
    case delete = "delete"
}

/// A refusal, plus what was being attempted when git made it.
///
/// `BranchOperationError` says what git would not do; only the caller knows what was asked, and
/// a banner that says merely "your changes would be overwritten" leaves the user guessing which
/// of the three things they just clicked is the one that did not happen.
///
/// Every case here is a refusal, so every sentence it produces may safely imply that nothing
/// changed. `GitError.commandFailed` is deliberately *not* wrapped: from `merge` or `abort` it
/// can describe a repository that did change, and it keeps git's own words.
struct BranchActionFailure: LocalizedError {
    let verb: BranchVerb
    let target: String
    let refusal: BranchOperationError

    var errorDescription: String? {
        refusal.sentence(refusing: "\(verb.rawValue) \"\(target)\"")
    }
}

/// An action that moves HEAD, refused because the repository is part-way through something.
///
/// Not git's refusal (git would make its own, with the same effect): this one is made before any
/// command runs, so the reflog does not even record an attempt.
struct BranchActionBlocked: LocalizedError {
    let reason: String

    var errorDescription: String? { reason }
}

/// `abort` was asked to end an operation that is no longer the one in progress.
///
/// Said plainly rather than in git's words, because the two errors behind it are thrown *before*
/// any command runs — see `GitBranchBackend.abort` for why a stale request must never reach
/// `git reset --merge`, which would exit 0 and abort a real merge instead.
struct RepositoryMovedOn: LocalizedError {
    var errorDescription: String? { "The repository changed; nothing was aborted." }
}

extension BranchOperationError {

    /// This refusal as a banner sentence. `attempt` reads on from "Can't …" — "switch to
    /// \"feature\"" — for the shapes that need to name what was refused; the ones that name
    /// their own subject ("A branch named \"x\" already exists.") ignore it.
    func sentence(refusing attempt: String) -> String {
        switch self {
        case .wouldOverwrite(let tracked, let untracked):
            // Both lists in one sentence: git can refuse over both at once, and fixing only the
            // files from the first block would earn the same refusal again.
            let opener =
                tracked.isEmpty
                ? "these untracked files are in the way"
                : "your changes to these files would be overwritten"
            return "Can't \(attempt): \(opener) — \(Self.list(tracked + untracked)). "
                + "Commit or move them first."
        case .indexNotClean:
            // Not a file list on purpose: git prints those names space-joined on one line, so a
            // name containing a space could not be told from two names. See the case's own doc.
            return "Can't \(attempt): commit or unstage your staged changes first."
        case .operationInProgress(let phrase):
            return "Can't \(attempt) while \(phrase). Commit or abort it first."
        case .invalidName(let name):
            return "\"\(name)\" is not a valid branch name."
        case .branchExists(let name):
            return "A branch named \"\(name)\" already exists."
        case .cannotDeleteCurrent(let name):
            return "\"\(name)\" is checked out, so it can't be deleted. "
                + "Switch to another branch first."
        case .noSuchBranch(let name):
            return "There is no branch named \"\(name)\" — it may have been deleted since this "
                + "list was loaded."
        case .noOperationInProgress, .operationMismatch:
            return RepositoryMovedOn().errorDescription ?? ""
        }
    }

    /// The first five names, then how many were left out. Git hands over every file it named;
    /// choosing how much of that to show is the UI's job, and a banner listing forty paths is
    /// not one anybody reads.
    private static func list(_ files: [String]) -> String {
        let shown = files.prefix(5).joined(separator: ", ")
        let remaining = files.count - 5
        return remaining > 0 ? "\(shown) (+\(remaining) more)" : shown
    }
}
