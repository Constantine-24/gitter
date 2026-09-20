import Foundation

/// The value types `GitBranchBackend` hands back: what git refused, how the user asked to
/// merge, and what a merge or a delete actually did.
///
/// Split out of `GitBranchBackend.swift` for length only — every one of these is documented
/// against the protocol method that returns it, and `BranchRefusalParser` is what turns git's
/// stderr into `BranchOperationError`.

/// A refusal git made that Gitter can describe precisely, rather than dumping stderr.
///
/// Every case here is a refusal: git did nothing. That is the point of the whole type — the
/// UI can say "these files would be overwritten, commit or move them first" and the user
/// knows their work is still exactly where they left it. Anything git says that
/// `BranchRefusalParser` does not recognise stays `GitError.commandFailed`.
public enum BranchOperationError: Error, Sendable, Equatable {
    /// Files the operation would have written over: `tracked` are files with local changes
    /// (staged or not) that differ between here and there, `untracked` are files git does not
    /// know about that the checkout would have clobbered.
    ///
    /// One case rather than two because **git can refuse over both at once** — verified on
    /// git 2.54, a single `git switch` prints the "Your local changes…" block and then the
    /// "The following untracked working tree files…" block. Reporting only the first would
    /// have the user fix that file, retry, and be refused all over again. Either list may be
    /// empty; never both. Both hold every file git named, in git's order — truncating for
    /// display is the UI's job.
    case wouldOverwrite(tracked: [String], untracked: [String])
    /// git refuses to switch branches, or to start a merge, part-way through something.
    /// Carries the operation as a phrase that completes "while …": `merging`,
    /// `cherry-picking`, `reverting`, `rebasing`, `applying patches`, and — when all git will
    /// say is that unmerged entries exist, which any of those four could have left —
    /// `resolving conflicts`.
    case operationInProgress(String)
    /// The name is not a valid branch name — either git's `check-ref-format` said so, or it is
    /// empty or starts with `-` (which git would read as an option), which Gitter rejects
    /// before git ever runs.
    case invalidName(String)
    /// A branch of that name is already there. Creating, renaming or copying onto it would
    /// overwrite the other branch, so git refuses and so does Gitter.
    case branchExists(String)
    /// The current branch cannot be deleted — either because Gitter checked `symbolic-ref
    /// --short -q HEAD` before running git at all, or because git itself refused with "cannot
    /// delete branch '<name>' used by worktree at '<path>'" (verified on git 2.54). That one
    /// message covers two shapes Gitter treats the same way: the branch is current in *this*
    /// worktree, or it is checked out in a *linked* worktree elsewhere. Either way deleting it
    /// would either move HEAD out from under the checkout or corrupt the other worktree, so
    /// both are refused identically.
    case cannotDeleteCurrent(String)
    /// No local branch of that name exists — git said `branch '<name>' not found` (verified on
    /// git 2.54) to a `branch -d`/`-D` for a name that was never created, or already deleted by
    /// someone else since Gitter last listed branches, or `merge: <name> - not something we can
    /// merge` to a merge of a name that resolves to nothing.
    case noSuchBranch(String)
    /// A **true merge** was refused because the index holds something that differs from HEAD.
    ///
    /// Verified on git 2.54 and worth stating plainly, because it surprised this
    /// implementation: `merge-ort` requires the index to match HEAD *entirely*, so a staged
    /// change to a file the merge never touches refuses the merge just as a staged change to a
    /// contested file does. A fast-forward does not go through the strategy at all and is
    /// happily allowed with the same staged change, which then rides along untouched.
    ///
    /// git's own words for it are "Your local changes to the following files would be
    /// overwritten by merge:" — the same header as `.wouldOverwrite` — but that sentence is
    /// simply not true of an untouched file, and the way out is different ("commit or unstage",
    /// not "move that file"), so this is its own case. No file list: unlike every other block
    /// in these messages, `merge-ort` prints the names space-joined on ONE line, so a name
    /// containing a space could not be told from two names. See `BranchRefusalParser`.
    case indexNotClean
    /// `abort` was asked to end an operation while the repository is in the middle of nothing.
    /// Thrown before git runs, and not merely for tidiness: verified on git 2.54, the command
    /// `abort(.squash)` would have run — `git reset --merge` — exits **0** in a clean
    /// repository and silently throws away everything that was staged. A stale "Abort" button
    /// in the UI would be enough to lose a user's staged work without a single error message.
    case noOperationInProgress
    /// `abort` was asked to end `expected` while `actual` is what is really in progress.
    ///
    /// The UI can be a refresh behind — an operation can have been finished or abandoned in a
    /// terminal since the last snapshot — and the wrong `--abort` is not harmless: verified on
    /// git 2.54, `git rebase --abort` during a merge exits **0** while doing nothing at all, so
    /// running it would report success and leave the merge exactly where it was. Thrown before
    /// git runs, from a fresh look at the repository rather than from the snapshot.
    case operationMismatch(expected: RepositoryOperation, actual: RepositoryOperation)
}

/// How the user chose to merge, in the sheet that appears every time.
///
/// Each case maps to ONE complete, literal argument vector in `CLIGitBackend.merge` — never a
/// flag assembled from a condition — so the suite's force-flag scanner can read what actually
/// reaches git.
public enum MergeMode: String, Sendable, CaseIterable {
    /// `merge --ff --no-edit`: move HEAD straight to the branch when history allows, otherwise
    /// make a merge commit.
    case fastForwardIfPossible
    /// `merge --no-ff --no-edit`: always record a merge commit, even when a fast-forward was
    /// possible.
    case alwaysMergeCommit
    /// `merge --ff --squash`: put the branch's whole change in the index as one pending commit,
    /// leaving HEAD where it is.
    case squash
}

/// What `merge(_:mode:at:)` did, decided by inspecting the repository afterwards rather than by
/// reading git's prose or its exit code (a refused fast-forward exits 1 and a refused true
/// merge exits 2 — verified on git 2.54 — so the code says nothing useful on its own).
///
/// `.conflicts` is a normal outcome, not a failure: git has left a half-done merge in the
/// worktree exactly as the user would see it on the command line, and Gitter's existing
/// in-progress UI takes over from there. Nothing is cleaned up, aborted or retried.
public enum MergeOutcome: Sendable, Hashable {
    /// The branch was already reachable from HEAD. Nothing changed at all — not even a
    /// `SQUASH_MSG` (verified: `--squash` prints "Already up to date. (nothing to squash)").
    case alreadyUpToDate
    /// HEAD now *is* the branch's tip; no commit was created.
    case fastForwarded
    /// A new commit with two parents, the first being where HEAD was.
    case merged
    /// HEAD did not move; the branch's change is staged and `SQUASH_MSG` is written, so the
    /// snapshot reports `RepositoryOperation.squash` until the user commits it.
    ///
    /// The staged change **may be empty**: a branch that changed a file and then changed it
    /// back is not an ancestor of HEAD, so there is something to squash, but its net diff is
    /// nothing. Verified on git 2.54 — exit 0, `SQUASH_MSG` written, nothing staged. This is
    /// still `.squashed` rather than `.alreadyUpToDate`, because the `SQUASH_MSG` git left
    /// behind is real and the snapshot reports `.squash` regardless; the way out is undoing the
    /// squash, not a different answer here.
    case squashed
    /// Unmerged entries are in the index and the worktree holds conflict markers. For a normal
    /// merge `MERGE_HEAD` is set and the snapshot reports `.merge`; for a squash there is no
    /// `MERGE_HEAD`, `SQUASH_MSG` is written, and the snapshot reports `.squash`. See the
    /// type's own note: an outcome, never an error.
    case conflicts
}

/// What `deleteBranch` did. `.notFullyMerged` is not a failure: git refused a *plain* `-d` and
/// changed nothing, so the branch is exactly where it was, and the UI now has what it needs to
/// ask "delete anyway?" — the count of commits that would become unreachable from anywhere
/// else, and the tip sha a user could recreate the branch from if they change their mind after
/// a force delete.
public enum BranchDeletion: Sendable, Hashable {
    case deleted
    case notFullyMerged(uniqueCommits: Int, tip: String)
}
