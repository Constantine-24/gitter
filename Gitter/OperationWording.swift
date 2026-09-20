import GitCore

/// What the UI says about an operation the repository is part-way through.
///
/// Kept out of `GitCore`, which has no opinion about wording, and out of the two views that
/// need it, which would otherwise have to agree on four strings each by hand.
///
/// Every message names a way *forward* — commit, or continue — and a way out, because the app
/// offers neither an abort nor a `--continue` button: the only honest advice for those is a
/// terminal. Only a merge, cherry-pick and revert are finished by committing; a rebase is
/// merely advanced by it, and says so.
extension RepositoryOperation {

    /// Sentence-initial: every use of it starts a line.
    var noun: String {
        switch self {
        case .merge: "Merge"
        case .cherryPick: "Cherry-pick"
        case .revert: "Revert"
        case .rebase: "Rebase"
        }
    }

    /// The note above the working-copy file list, explaining why half its buttons are off.
    ///
    /// The two halves are the two states the gate covers: conflicts still to resolve, and
    /// everything resolved but the operation still open — the case where nothing is unmerged
    /// and the old gate let go.
    func note(hasConflicts: Bool) -> String {
        if hasConflicts {
            return "\(noun) in progress — resolve conflicts in your editor, stage the files, then commit."
        }
        switch self {
        case .merge, .cherryPick, .revert:
            return "\(noun) in progress — commit to complete it."
        case .rebase:
            return "Rebase in progress — commit, then run `git rebase --continue` in a terminal."
        }
    }

    /// The tooltip on "Unstage All" and on a staged row's "−" while this is in progress.
    var unstagingBlockedHelp: String {
        switch self {
        case .merge:
            "Unstaging would abandon the merge. Commit to complete it, or run `git merge --abort` in a terminal."
        case .cherryPick:
            "Unstaging would abandon the cherry-pick. Commit to complete it, or run `git cherry-pick --abort` in a terminal."
        case .revert:
            "Unstaging would abandon the revert. Commit to complete it, or run `git revert --abort` in a terminal."
        case .rebase:
            "Unstaging would abandon the rebase. Commit the resolution, or run `git rebase --abort` in a terminal."
        }
    }
}
