import Foundation

/// `abort(_:at:)` — ending a merge, cherry-pick, revert, rebase or `git am`, and undoing a
/// pending squash. See `GitBranchBackend.abort` for the contract; this file is the evidence
/// behind it.
///
/// **Why every one of them keeps some uncommitted work and destroys the rest.** Five of the six
/// commands reset the index *two-way* (git's `reset --merge` semantics): a file whose index
/// entry has to change is written over, a file that differs only between the index and the
/// worktree is left exactly as the user last saved it, and a file that would have to be changed
/// *while* holding unstaged edits makes the whole reset refuse rather than guess. That single
/// rule explains the table: a pre-existing edit survives (its index entry does not need to
/// move), an edit made during the operation to an untouched file survives (same reason),
/// anything *staged* dies (its index entry must go back to HEAD, and the worktree copy matches
/// the index so nothing is at risk to stop it), and every conflict resolution dies (those index
/// entries must go back too).
///
/// `git rebase --abort` is the exception and resets **hard**: it takes the unstaged edit with
/// it. Verified on git 2.54 — the same starting point, `rebase --abort` overwrites the edit
/// where `merge --abort` refuses over it. That is why the confirmation sheet cannot use one
/// sentence for all six.
///
/// **What none of them touch: untracked files.** No abort here is `git clean`, and every
/// untracked file — created before the operation or during it — is still there afterwards.
/// Verified for all seven states.
///
/// **The "unable to reconstruct" case git's own documentation warns about.** `git merge
/// --abort` is documented as being "in some cases unable to reconstruct" pre-merge uncommitted
/// changes. Chased down on git 2.54: the case cannot arise from a *pre-existing* edit, because
/// a merge that would rewrite a dirty file is refused before it starts ("Your local changes to
/// the following files would be overwritten by merge", nothing changes) — both for a file the
/// merge would conflict on and for one it would merge cleanly, and for a fast-forward too. What
/// is reachable is an edit made *after* the merge began, to a file the merge rewrote; then the
/// abort exits 128 with "error: Entry '<file>' not uptodate. Cannot merge." / "fatal: Could not
/// reset index file to revision 'HEAD'." and — verified — changes nothing whatsoever: index,
/// worktree, HEAD and `MERGE_HEAD` are all exactly as they were. Cherry-pick, revert and the
/// squash undo behave identically.
///
/// `git am --abort` is the one that does **not** leave a clean failure. It clears the
/// conflicted index first and rewinds the branch second, so the same refusal ("fatal: failed to
/// clean index") arrives with the conflict already gone, the branch still carrying the commits
/// `am` made, and `rebase-apply/` still in place — the snapshot still reports
/// `.applyingPatches`, and a second attempt fails the same way. `anAbortedAmCanFailHalfWay`
/// pins it. Gitter cannot prevent this; it must simply never claim a failed abort was a no-op.
extension CLIGitBackend {
    public func abort(_ operation: RepositoryOperation, at root: URL) async throws {
        // Asked of the repository, never of the caller's snapshot. Both refusals below are
        // thrown before a single git *mutation* runs, and both matter: `reset --merge` with no
        // squash pending exits 0 and silently discards staged work, and `rebase --abort` during
        // a merge exits 0 while doing nothing at all (both verified on git 2.54). Either would
        // be reported to the user as a successful abort.
        guard let actual = try await operationInProgress(at: root) else {
            throw BranchOperationError.noOperationInProgress
        }
        guard actual == operation else {
            throw BranchOperationError.operationMismatch(expected: operation, actual: actual)
        }

        // One complete literal vector per case, chosen by this switch and never assembled from
        // a condition, so the suite's force-flag scanner can read exactly what reaches git.
        // Nothing here takes a ref, a path or any other user-supplied argument: these six
        // vectors are the whole command line, which is also why none of them needs
        // `--end-of-options`.
        //
        // `--abort` and not `--quit` or `--skip`: `--quit` drops the sequencer's state without
        // undoing its work (leaving the half-applied result staged, with nothing on screen to
        // say an operation was ever under way) and `--skip` throws away the commit git stopped
        // on. Neither is what "Abort" means to the person who clicked it.
        //
        // `.squash` is the odd one out because a pending squash has no operation to abort:
        // `git merge --abort` refuses it ("fatal: There is no merge to abort (MERGE_HEAD
        // missing)") since `--squash` never writes `MERGE_HEAD`. `reset --merge` is what
        // unstages the squashed changes and removes `SQUASH_MSG` with them — including for a
        // squash whose net diff was empty, where removing that message is the entire job.
        let arguments: [String]
        switch operation {
        case .merge: arguments = ["merge", "--abort"]
        case .cherryPick: arguments = ["cherry-pick", "--abort"]
        case .revert: arguments = ["revert", "--abort"]
        case .rebase: arguments = ["rebase", "--abort"]
        case .applyingPatches: arguments = ["am", "--abort"]
        case .squash: arguments = ["reset", "--merge"]
        }

        // `runBranchCommand` rethrows anything `BranchRefusalParser` does not recognise as
        // `GitError.commandFailed`, git's own words intact — which is where the "not uptodate"
        // refusal above lands. It is deliberately not given a case of its own: it is not a
        // clean refusal for `am`, so a typed "nothing changed" error would be a lie there.
        try await runBranchCommand(arguments, at: root)
    }
}
