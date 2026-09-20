import GitCore

/// What the UI says about an operation the repository is part-way through.
///
/// Kept out of `GitCore`, which has no opinion about wording, and out of the views that need
/// it, which would otherwise have to agree on six strings each by hand.
///
/// Every message names a way *forward* and a way out, because the app offers neither an abort
/// nor a `--continue` button: the only honest advice for those is a terminal. A merge,
/// cherry-pick and revert are finished by committing. A rebase is only advanced by it — the
/// commit lands and `git rebase --continue` then moves on to the next one. `git am` is not
/// advanced by it at all: `git am --continue` does the commit itself. A pending squash is
/// finished by committing too; its way out is `git reset --merge`, which undoes it and removes
/// `SQUASH_MSG` (see the design doc's evidence table).
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
        case .merge: "Commit to complete it, or run `git merge --abort` in a terminal."
        case .cherryPick: "Commit to complete it, or run `git cherry-pick --abort` in a terminal."
        case .revert: "Commit to complete it, or run `git revert --abort` in a terminal."
        case .rebase: "Commit the resolution, or run `git rebase --abort` in a terminal."
        case .applyingPatches:
            "Run `git am --continue` to carry on, or `git am --abort`, in a terminal."
        case .squash:
            "Commit to finish it, or run `git reset --merge` in a terminal to undo the squash."
        }
    }
}
