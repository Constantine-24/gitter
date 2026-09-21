import GitCore

/// What the UI says about an operation the repository is part-way through.
///
/// Kept out of `GitCore`, which has no opinion about wording, and out of the views that need
/// it, which would otherwise have to agree on six strings each by hand.
///
/// Every message names a way *forward* and a way out. The way forward differs per operation: a
/// merge, cherry-pick and revert are finished by committing; a rebase is only advanced by it —
/// the commit lands and `git rebase --continue` then moves on to the next one, which still needs
/// a terminal; `git am` is not advanced by a commit at all (`git am --continue` does the commit
/// itself); a pending squash is finished by committing too. The way *out* is the same for all
/// six and no longer a terminal: the button in the operation note, which opens `AbortSheet` and
/// runs `GitBranchBackend.abort` (see the design doc's evidence table for what each one keeps).
extension RepositoryOperation {

    /// Sentence-initial: every use of it starts a line.
    var noun: String {
        switch self {
        case .merge: "Merge"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        case .rebase: "Rebase"
        case .applyingPatches: "Patch application"
        case .squash: "Squash"
        }
    }

    /// The commit button's title while this is in progress.
    ///
    /// It replaces the file count, which mid-operation says the wrong thing: with everything
    /// resolved and staged, "Commit 1 File" describes a one-file commit and hides that this is
    /// the merge concluding. Where the commit does not conclude the operation, the title stays
    /// the plain verb rather than claiming otherwise.
    var commitButtonTitle: String {
        switch self {
        case .merge: "Commit Merge"
        case .cherryPick: "Commit Cherry-Pick"
        case .revert: "Commit Revert"
        case .rebase, .applyingPatches: "Commit"
        case .squash: "Commit Squash"
        }
    }

    /// The note above the working-copy file list, explaining why half its buttons are off.
    ///
    /// The two halves are the two states the gate covers: conflicts still to resolve, and
    /// everything resolved but the operation still open — the case where nothing is unmerged
    /// and the old gate let go. A conflicting `--squash` behaves exactly like a conflicting
    /// merge here (verified: no `MERGE_HEAD`, but an unmerged entry in the status same as any
    /// other conflict), so it takes the same conflicts wording rather than its own "pending"
    /// phrasing, which only fits the no-conflicts case.
    func note(hasConflicts: Bool) -> String {
        let lead = "\(noun) in progress"
        let finish =
            switch self {
            case .merge, .cherryPick, .revert, .squash: "commit."
            case .rebase: "commit, then run `git rebase --continue` in a terminal."
            case .applyingPatches: "run `git am --continue` in a terminal."
            }
        if hasConflicts {
            return "\(lead) — resolve conflicts in your editor, stage the files, then \(finish)"
        }
        switch self {
        case .merge, .cherryPick, .revert:
            return "\(lead) — commit to complete it."
        case .rebase, .applyingPatches:
            return "\(lead) — \(finish)"
        case .squash:
            return "Squash pending — commit to finish."
        }
    }

    /// Why HEAD may not be moved while this is in progress: the tooltip on a disabled Switch,
    /// Merge or Check Out item, and the banner if one is reached anyway.
    ///
    /// A pending squash gets its own sentence because the rest of the UI never calls it a thing
    /// "in progress" — the note says "Squash pending", the button says "Undo Squash…" — and a
    /// tooltip that invented a third vocabulary would read as a different state altogether.
    var movingHeadBlocked: String {
        switch self {
        case .squash: "A squash is pending. Commit it or undo it first."
        case .merge, .cherryPick, .revert, .rebase, .applyingPatches:
            "A \(noun.lowercased()) is in progress. Commit or abort it first."
        }
    }

    /// The tooltip on "Unstage All", on a staged row's "−", and on a hunk button that would
    /// take a whole file back out of the index.
    var unstagingBlockedHelp: String {
        "Unstaging would abandon the \(noun.lowercased()). \(wayOut)"
    }

    private var wayOut: String {
        switch self {
        case .merge, .cherryPick, .revert: "Commit to complete it, or use \(abortActionName)."
        case .rebase: "Commit the resolution, or use \(abortActionName)."
        case .applyingPatches:
            "Run `git am --continue` in a terminal to carry on, or use \(abortActionName)."
        case .squash: "Commit to finish it, or use \(abortActionName)."
        }
    }

    /// What the button that ends this operation is called, without its ellipsis: the title case
    /// a sentence can point at ("…or use Abort Merge.") as well as name a control.
    ///
    /// Not built from `noun`, which would give "Abort Patch application", and not one word for
    /// all six: what `reset --merge` does to a pending squash is an undo, not an abort, and the
    /// rest of the UI already calls that state "Squash pending" rather than an operation in
    /// progress. `git am` stops rather than aborts, because what it undoes — patches already
    /// committed — is not work the user did here.
    var abortActionName: String {
        switch self {
        case .merge: "Abort Merge"
        case .cherryPick: "Abort Cherry-Pick"
        case .revert: "Abort Revert"
        case .rebase: "Abort Rebase"
        case .applyingPatches: "Stop Applying Patches"
        case .squash: "Undo Squash"
        }
    }

    /// The trailing button in the operation note. The ellipsis is the promise that it asks first,
    /// and every one of these does: it opens `AbortSheet` and runs nothing.
    var abortButtonTitle: String {
        abortActionName + "…"
    }

    /// The notice after the abort has run and git has come back without complaint.
    var abortedNotice: String {
        switch self {
        case .squash: "Squash undone."
        case .applyingPatches: "Stopped applying patches."
        case .merge, .cherryPick, .revert, .rebase: "\(noun) aborted."
        }
    }

    // MARK: - The abort confirmation

    /// The five sentences `AbortSheet` is built from.
    ///
    /// They live here rather than in the view for the same reason as everything above: they are
    /// pure functions of the operation, the app has no test target to pin a view with, and the
    /// wording is the safety promise — six operations' worth of "what goes, what stays", each
    /// line traceable to one cell of the kept/lost table in `GitBranchBackend.abort`. A view is
    /// the one place where that is neither readable next to its siblings nor reachable from
    /// anywhere else.

    /// The headline. A pending squash is undone, not aborted, and `git am` stops — the same
    /// distinction `abortActionName` makes, for the same reason.
    var abortQuestion: String {
        switch self {
        case .merge: "Abort the merge?"
        case .cherryPick: "Abort the cherry-pick?"
        case .revert: "Abort the revert?"
        case .rebase: "Abort the rebase?"
        case .applyingPatches: "Stop applying patches?"
        case .squash: "Undo the pending squash?"
        }
    }

    /// What this abort throws away.
    var abortDiscards: String {
        switch self {
        case .merge, .cherryPick, .revert:
            let it = noun.lowercased()
            return "Aborting discards the \(it)'s changes, every conflict resolution — including "
                + "the ones you already staged — and anything else you staged since the \(it) "
                + "began."
        case .rebase:
            return "Aborting discards everything the rebase has replayed, every conflict "
                + "resolution, anything you staged since it began — and any uncommitted edits "
                + "you have made since the rebase started, anywhere in the working copy."
        case .applyingPatches:
            return "Stopping discards every conflict resolution and anything you staged since it "
                + "began, and removes the patches that were already applied."
        case .squash:
            return "Undoing discards everything currently staged — the squashed changes, any "
                + "conflict resolutions, and anything else in the index, including work you "
                + "staged before the squash if the squash was started outside Gitter. The "
                + "prepared \"Squashed commit of the following:\" message goes too."
        }
    }

    /// What survives it.
    var abortKeeps: String {
        switch self {
        case .merge, .cherryPick, .revert:
            return "Kept: uncommitted edits you had before, edits you have made since to files "
                + "the \(noun.lowercased()) did not touch, and all untracked files."
        case .applyingPatches:
            return "Kept: uncommitted edits you had before, edits you have made since to files "
                + "the patches did not touch, and all untracked files."
        case .rebase:
            return "Kept: untracked files, and nothing else — `git rebase --abort` restores the "
                + "working copy completely."
        case .squash:
            return "Kept: unstaged edits and all untracked files."
        }
    }

    /// What happens to commits, which is the half of the table a file list cannot show.
    ///
    /// `rewindsCommits` is the store's `abortRewindsCommits` — read live, because it is a fact
    /// about the repository (an `am` that has already committed something) rather than about the
    /// operation's name.
    func abortHistory(rewindsCommits: Bool) -> String {
        if rewindsCommits {
            return "The patches already applied leave the branch: nothing but the reflog will "
                + "reach those commits afterwards."
        }
        switch self {
        case .squash: return "No commit is created or removed."
        case .rebase:
            // Not "\"<branch>\" goes back…", which the design's draft wording had: git detaches
            // HEAD for the duration of a rebase (verified — `status --porcelain=v2` reports
            // `# branch.head (detached)`), so there is no branch name on screen to quote.
            return "Your branch goes back to the commit it was on before the rebase."
        case .merge, .cherryPick, .revert, .applyingPatches:
            return "Your branch and history go back to exactly where they were."
        }
    }

    /// The empty list. It is a real state, not a sign that something went wrong: a squash whose
    /// net diff was empty stages nothing at all, and removing `SQUASH_MSG` is then the entire job.
    var abortRevertsNothing: String {
        switch self {
        case .squash:
            "Nothing is staged, so no file in your working copy changes — the pending squash and "
                + "its prepared message are all that go."
        case .merge, .cherryPick, .revert, .rebase, .applyingPatches:
            "No tracked file is staged or conflicted, so no file in your working copy changes."
        }
    }
}
