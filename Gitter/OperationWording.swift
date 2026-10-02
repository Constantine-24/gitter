import GitCore

/// What the UI says about an operation the repository is part-way through.
///
/// Kept out of `GitCore`, which has no opinion about wording, and out of the views that need
/// it, which would otherwise have to agree on six strings each by hand.
///
/// Every message names a way *forward* and a way out. The way forward differs per operation: a
/// merge and a pending squash are finished by committing; a rebase, cherry-pick and revert by
/// Continue (A2: the operation bar and the composer, `ContinueWording`), which makes the commit
/// and goes on; `git am` stays abort-only in Gitter, so `git am --continue` in a terminal is
/// still its way forward. The way *out* is the same for all six: the bar's abort button, which
/// opens `AbortSheet` and runs `GitBranchBackend.abort` (see the design doc's evidence table for
/// what each one keeps).
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

    /// The composer's button title while this is in progress.
    ///
    /// It replaces the file count, which mid-operation says the wrong thing: with everything
    /// resolved and staged, "Commit 1 File" describes a one-file commit and hides that this is
    /// the merge concluding. A rebase, cherry-pick or revert stop is concluded by Continue (spec,
    /// "Commit": `commit -F` is not offered there, M 15), so the button says so. `git am` keeps
    /// the plain verb rather than claiming a commit concludes it.
    var commitButtonTitle: String {
        switch self {
        case .merge: "Commit Merge"
        case .cherryPick: "Continue Cherry-Pick"
        case .revert: "Continue Revert"
        case .rebase: "Continue Rebase"
        case .applyingPatches: "Commit"
        case .squash: "Commit Squash"
        }
    }

    /// The operation bar's sentence when there is no progress to tell (`ContinueWording.bar`).
    ///
    /// The two halves are the two states the gate covers: conflicts still to resolve, and
    /// everything resolved but the operation still open — the case where nothing is unmerged
    /// and the old gate let go. A conflicting `--squash` behaves exactly like a conflicting
    /// merge here (verified: no `MERGE_HEAD`, but an unmerged entry in the status same as any
    /// other conflict), so it takes the same conflicts wording rather than its own "pending"
    /// phrasing, which only fits the no-conflicts case. Conflicts are resolved in Gitter (A2), and
    /// only `git am` still needs a terminal to go on.
    func note(hasConflicts: Bool) -> String {
        let lead = "\(noun) in progress"
        switch self {
        case .merge:
            return hasConflicts ? "\(lead) — resolve the conflicts, then commit." : "\(lead) — commit to complete it."
        case .squash:
            return hasConflicts ? "\(lead) — resolve the conflicts, then commit." : "Squash pending — commit to finish."
        case .rebase, .cherryPick, .revert:
            return hasConflicts ? "\(lead) — resolve the conflicts, then continue." : "\(lead) — continue when ready."
        case .applyingPatches:
            return hasConflicts
                ? "\(lead) — resolve the conflicts, then run `git am --continue` in a terminal."
                : "\(lead) — run `git am --continue` in a terminal."
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
        case .cherryPick, .revert, .rebase:
            "A \(noun.lowercased()) is in progress. Continue or abort it first."
        case .merge, .applyingPatches:
            "A \(noun.lowercased()) is in progress. Commit or abort it first."
        }
    }

    /// The tooltip on "Unstage All", on a staged row's "−", and on a hunk button that would
    /// take a whole file back out of the index.
    var unstagingBlockedHelp: String {
        "Unstaging would abandon the \(noun.lowercased()). \(wayOut)"
    }

    /// The tooltip on the disabled Amend toggle, and the banner if a commit reaches the store
    /// with Amend still ticked.
    ///
    /// Per operation rather than one sentence, because what amending destroys is different in
    /// each: git itself refuses only the merge and the cherry-pick, and in the other four the
    /// commit the operation was standing on ends up on no ref with nothing said about it. See
    /// `GitWorkingCopyBackend.commit` for the measured table.
    var amendBlockedHelp: String {
        "\(amendWouldDo) \(wayOut)"
    }

    private var amendWouldDo: String {
        switch self {
        case .merge, .cherryPick, .revert:
            "Amending would rewrite the commit this \(noun.lowercased()) is being built on and "
                + "take the \(noun.lowercased()) with it."
        case .rebase:
            "Amending would rewrite the commit the rebase stopped on and leave the rebase "
                + "standing on one that is on no branch."
        case .applyingPatches:
            "Amending would rewrite the commit the last patch made and leave it on no branch."
        case .squash:
            "Amending now would fold the squash into the previous commit."
        }
    }

    private var wayOut: String {
        switch self {
        case .merge: "Commit to complete it, or use \(abortActionName)."
        case .cherryPick, .revert: "Continue to complete it, or use \(abortActionName)."
        case .rebase: "Continue the rebase, or use \(abortActionName)."
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

    /// The trailing button in the operation bar. The ellipsis is the promise that it asks first,
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
    /// pure functions of the operation, a test can pin them where it could not pin a view, and the
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
            // The last sentence is literally true — `git reset --merge` removes `SQUASH_MSG`
            // (verified on git 2.54) — and it is kept because the message is git's, not
            // Gitter's: the composer only shows a copy of it, prefilled into an empty draft (A2,
            // `ComposerPrefill`) and taken back with the squash when left untouched, while a
            // plain `git commit` in a terminal opens pre-filled with the file itself, so a user
            // who was about to do that is losing something real. "Git's" is what says whose it is.
            return "Undoing discards everything currently staged — the squashed changes, any "
                + "conflict resolutions, and anything else in the index, including work you "
                + "staged before the squash if the squash was started outside Gitter. Git's "
                + "\"Squashed commit of the following:\" message goes too."
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
                + "git's message for it are all that go."
        case .merge, .cherryPick, .revert, .rebase, .applyingPatches:
            "No tracked file is staged or conflicted, so no file in your working copy changes."
        }
    }
}
