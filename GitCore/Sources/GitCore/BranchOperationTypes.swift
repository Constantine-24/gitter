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
    /// A force delete was asked for against a tip the branch no longer has.
    ///
    /// `forceDeleteBranch` is the only place this is thrown, and it is the whole reason that
    /// method takes an `expectedTip`. The warning the user answered named a commit count and a
    /// tip sha; `refs/heads/<name>` is a live ref that a terminal (or a second Gitter window)
    /// can move between the warning going up and the button being clicked — a commit, a
    /// `git update-ref`, or a rename plus a fresh branch under the old name. Deleting whatever
    /// the ref points at *now* would orphan commits the warning never mentioned, and the
    /// recreate command it printed would put back only the tip it did name, losing the rest
    /// silently. So the delete fails closed and the user is asked again against the new numbers.
    ///
    /// `expected` is what the sheet showed, `actual` what `refs/heads/<name>` resolves to now.
    /// Both are full object names (40 characters in a sha1 repository): an abbreviation is not
    /// accepted on either side, since a prefix match is a weaker promise than the one the sheet
    /// makes.
    case branchMoved(name: String, expected: String, actual: String)
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
    ///
    /// **For a squash this is Gitter's own refusal, not git's.** A squash of a
    /// fast-forwardable branch does not go through the strategy either, so git starts it with a
    /// dirty index — and `git reset --merge`, the only way to undo a pending squash, then
    /// destroys whatever was staged beforehand along with the squash. `merge(_:mode:at:)`
    /// checks the index itself before running a squash; see `requireACleanIndexForASquash`.
    case indexNotClean
    /// A **rebase** was refused because something tracked is uncommitted — staged or not, and
    /// whether or not the rebase would touch it. Stricter than a merge, and measured on git
    /// 2.54 with a change to a file neither side changes: `error: cannot rebase: You have
    /// unstaged changes.` / `error: cannot rebase: Your index contains uncommitted changes.`
    /// (both at once add an `additionally, your index…` line), each with `error: Please commit
    /// or stash them.`, exit 1, nothing changed. An untracked file does not count.
    ///
    /// **Usually Gitter's own refusal, made before git runs**, because git's can be switched
    /// off from configuration: `rebase.autoStash=true` makes git stash the change, rebase, and
    /// re-apply it without a word of refusal (measured) — the forbidden `--autostash` reached
    /// through the user's config. See `CLIGitBackend.rebase(onto:at:)`. git's own sentences
    /// still map here, for a change made between that check and the rebase.
    case treeNotClean
    /// `abort` was asked to end an operation while the repository is in the middle of nothing.
    /// Thrown before git runs, and not merely for tidiness: verified on git 2.54, the command
    /// `abort(.squash)` would have run — `git reset --merge` — exits **0** in a clean
    /// repository and silently throws away everything that was staged. A stale "Abort" button
    /// in the UI would be enough to lose a user's staged work without a single error message.
    case noOperationInProgress
    /// `abort` was asked to end `expected` while `actual` is what is really in progress.
    ///
    /// The UI can be a refresh behind — an operation can have been finished or abandoned in a
    /// terminal since the last snapshot. Four of the five `--abort`s would catch that
    /// themselves (verified on git 2.54: the wrong one during a merge exits 128 and leaves
    /// `MERGE_HEAD` alone), but `reset --merge` would not: run during a real merge it exits 0
    /// and aborts **the merge** — `MERGE_HEAD` and every unmerged entry gone — under a button
    /// labelled "Undo Squash". Thrown before git runs, from a fresh look at the repository
    /// rather than from the snapshot.
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
    ///
    /// The one mode with a precondition Gitter enforces on top of git's: **the index must match
    /// HEAD**, or `.indexNotClean` is thrown before git runs. Git would allow the squash
    /// whenever it can fast-forward, and the resulting pending squash cannot be undone without
    /// also destroying whatever was staged before it — the squashed changes and the user's own
    /// are the same staged changes by then.
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

/// What `unreferencedCommits(at:)` found: the commit HEAD is on, and how many commits hang on it
/// and on nothing else.
///
/// One value rather than two calls because the confirmation sheet shows both and is later
/// answered against both. A sha read at one moment and a count read at another could describe two
/// different states of the repository, and the sheet would then promise something that was never
/// true at once. The count is asked *about the sha*, not about `HEAD`, so the pair holds together
/// however HEAD wanders afterwards.
///
/// Comparing two of these is the whole of the staleness check the store makes before it acts on
/// the answer: equal means the repository still holds what the user was warned about.
public struct UnreferencedCommits: Sendable, Hashable {
    /// The full object name HEAD resolves to, or nil in a repository with no commits (an unborn
    /// HEAD, where `count` is 0 because there is nothing there at all).
    public let headSha: String?
    /// Commits reachable from `headSha` and from no branch, tag or remote-tracking ref: the ones
    /// a move of HEAD away from here would leave to the reflog.
    public let count: Int

    public init(headSha: String?, count: Int) {
        self.headSha = headSha
        self.count = count
    }
}
