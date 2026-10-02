import Foundation
import GitCore

/// The error banner: dismissing it, and describing an `Error` for it.
extension RepositoryStore {

    // MARK: - Errors

    /// Clears the currently displayed error (the banner's dismiss button).
    func dismissError() {
        setError(nil)
        clearSticky()
        // The banner's "Pull" / "Force Push…" and "Stash and Continue" belong to the message
        // just dismissed.
        setRejectedPush(nil)
        clearStashAndContinueOffer()
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
            case .amendDuringOperation(let operation):
                // The backend's own refusal, reached only when the store's gate did not see the
                // operation yet (a terminal started one between two refreshes). Same sentence as
                // the disabled toggle's tooltip, so the two never describe the state differently.
                return operation.amendBlockedHelp
            case .tooManyArguments(let count, let limit):
                // GitCore's guard (Ruling 26): this one command was not started. Earlier commands
                // of the same action (a record, say) may have run, so the sentence is about the
                // command, not the action. Every path list goes through a pathspec file or in
                // batches, so this is a safety net for a vector nobody has written yet, not a path.
                return "Gitter stopped before a git command that needed \(count) arguments, more than "
                    + "the \(limit) one git process can take; that command did not run."
            }
        }
        // A refusal that reached here without the action that provoked it. Every throw site in
        // `+Branches`/`+BranchSheets` wraps these (see `reporting`), so this is a safety net,
        // not a path — but it still beats `localizedDescription`'s "The operation couldn't be
        // completed. (GitCore.BranchOperationError error 0.)".
        if let refusal = error as? ConflictError {
            return ConflictWording.error(refusal)
        }
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
    case rebaseOnto = "rebase onto"
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

/// The detached-HEAD warning was answered after the repository had moved on underneath it.
///
/// The warning names a commit and a number of commits that hang on it alone; confirming it means
/// agreeing to leave *those* behind. HEAD can move while the sheet is up — a terminal, a second
/// Gitter window — and acting then would strand commits nobody was warned about, or refuse to
/// act on a warning that no longer applies. So it fails closed and says what it found instead,
/// the way a force delete against a moved tip does.
struct DetachedHeadMovedOn: LocalizedError {
    /// What git says now, read immediately before the action would have run.
    let now: UnreferencedCommits

    var errorDescription: String? {
        guard let sha = now.headSha else {
            return "The repository changed since that warning. Nothing happened. Ask again to "
                + "see what it would cost now."
        }
        return "The repository changed since that warning — HEAD is now at \(sha.prefix(7)), "
            + "\(Self.holding(now.count)). Nothing happened. Ask again to see what it would "
            + "cost now."
    }

    private static func holding(_ count: Int) -> String {
        switch count {
        case 0: "and nothing hangs on it alone any more"
        case 1: "holding 1 commit on no branch, tag or remote"
        default: "holding \(count) commits on no branch, tag or remote"
        }
    }
}

extension BranchOperationError {

    /// This refusal as a banner sentence. `attempt` reads on from "Can't …" — "switch to
    /// \"feature\"" — for the shapes that need to name what was refused; the ones that name
    /// their own subject ("A branch named \"x\" already exists.") ignore it.
    func sentence(refusing attempt: String) -> String {
        switch self {
        case .wouldOverwrite(let tracked, let untracked):
            // Both lists, kept apart: git can refuse over both at once, so naming only the first
            // would earn the same refusal again — but "your changes to these files" is simply
            // false of an untracked file, which has no changes, only a name in the way.
            let clause =
                switch (tracked.isEmpty, untracked.isEmpty) {
                case (false, true):
                    "your changes to \(Self.list(tracked)) would be overwritten"
                case (true, _):
                    "these untracked files are in the way: \(Self.list(untracked))"
                case (false, false):
                    "your changes to \(Self.list(tracked)) would be overwritten, and these "
                        + "untracked files are in the way: \(Self.list(untracked))"
                }
            return "Can't \(attempt): \(clause). Commit or move them first."
        case .indexNotClean:
            // Not a file list on purpose: git prints those names space-joined on one line, so a
            // name containing a space could not be told from two names. See the case's own doc.
            return "Can't \(attempt): commit or unstage your staged changes first."
        case .treeNotClean:
            // Stricter than a merge, and the sentence says so: a change to a file the rebase
            // never touches refuses it too, staged or not. Untracked files do not count.
            return "Can't \(attempt): a rebase needs every change committed first, staged or not."
        case .operationInProgress(let phrase):
            return "Can't \(attempt) while \(phrase). Commit or abort it first."
        case .invalidName(let name):
            return "\"\(name)\" is not a valid branch name."
        case .branchExists(let name):
            return "A branch named \"\(name)\" already exists."
        case .cannotDeleteCurrent(let name):
            return "\"\(name)\" is checked out, so it can't be deleted. "
                + "Switch to another branch first."
        case .branchMoved(let name, _, let actual):
            // Names neither sha in full and neither side of the comparison: what the user needs
            // is that the warning they just read is out of date and that nothing was deleted.
            // The short sha is there so "it moved" is checkable against a terminal.
            return "\"\(name)\" changed since that warning — it now points at "
                + "\(actual.prefix(7)). Nothing was deleted. Try Delete again to see what it "
                + "would cost now."
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
