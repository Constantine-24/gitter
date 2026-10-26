import Foundation

/// Which history action a `HistoryPlan` is for.
public enum HistoryAction: Sendable, Hashable {
    /// `git cherry-pick --empty=drop`: apply the selected commits on top of HEAD, oldest first.
    case cherryPick
    /// `git revert --no-edit --no-reference`: undo the selected commits, newest first.
    case revert
}

/// What a cherry-pick or revert will do, read before git runs — the sheet's content and the
/// promise the run keeps: `run(_:at:)` makes the plan again and refuses on any difference.
///
/// Made by `GitHistoryBackend.historyPlan(_:shas:at:)` (B2, B4, B5, B8).
public struct HistoryPlan: Sendable, Hashable {
    public let action: HistoryAction
    /// The full object id HEAD was at when the plan was made.
    public let head: String
    /// The commits git will be given, in the order it will get them: a cherry-pick oldest first
    /// by topology (B2 — never by date, which a skewed clock gets wrong), a revert newest first
    /// (B8). Never empty: an empty selection is `HistoryRefusal.nothingToApply`.
    public let commits: [CommitRef]
    /// Cherry-pick only: selected commits that are already ancestors of HEAD (HEAD itself
    /// included). Left out — git would stop on each as an empty pick (B4). In the order they
    /// were selected. Empty for a revert.
    public let leftOut: [CommitRef]
    /// Cherry-pick only: commits of `commits` whose change HEAD already has as a
    /// patch-identical commit (`rev-list --cherry-mark`, B4). They are still given to git, which
    /// drops them (`--empty=drop`); a prediction the outcome confirms (`HistoryOutcome.applied`'s
    /// `dropped`). In `commits` order. Empty for a revert.
    public let mayDrop: [CommitRef]
    /// What HEAD named when the plan was made: `symbolic-ref -q HEAD` (`refs/heads/main`), empty
    /// when detached. The run refuses `.headMoved` when HEAD names anything else now, even at the
    /// same commit — the sheet named a branch. An addition to the brief's interface (fix round 1).
    public let headRef: String

    public init(
        action: HistoryAction, head: String, commits: [CommitRef], leftOut: [CommitRef] = [],
        mayDrop: [CommitRef] = [], headRef: String = ""
    ) {
        self.action = action
        self.head = head
        self.commits = commits
        self.leftOut = leftOut
        self.mayDrop = mayDrop
        self.headRef = headRef
    }
}

/// Why a history plan — or the run or rebase that re-makes it — refused. Thrown before git runs
/// for the action: nothing changed.
public enum HistoryRefusal: Error, Sendable, Hashable {
    /// A merge, cherry-pick, revert, rebase, `git am` or pending squash is in progress — or a
    /// cherry-pick or revert range git left halted (`sequencer/` with no pseudo-ref, reported as
    /// the operation its todo names): a single pick over it would leave a stale sequence
    /// (Ruling 29) and a range is refused by git ("cherry-pick is already in progress").
    case operationInProgress(RepositoryOperation)
    /// Tracked files with uncommitted changes, staged or not (untracked files are allowed). A
    /// clean start keeps a sequence from halting part-way on a tracked collision (B6). Stash
    /// and Continue is the way on.
    case trackedChanges([String])
    /// Merge commits in the selection: git refuses them without `-m`, and second in a range it
    /// does so after applying the first (B5).
    case mergeCommits([CommitRef])
    /// Nothing selected, or every selected commit is already in HEAD (cherry-pick).
    case nothingToApply
    /// Revert only: selected commits HEAD does not contain. Reverting one would apply the
    /// inverse of a change this branch never had (fix round 1, Ruling 6a).
    case notOnBranch([CommitRef])
    /// HEAD names a branch with no commits yet.
    case unbornHead
    /// HEAD is no longer the plan's `head`.
    case headMoved
    /// HEAD is where the plan says, but the plan made now differs from the one given — for a
    /// rebase, the target names another commit now.
    case planChanged
}

/// What a cherry-pick or revert did, read back from the repository after git ran.
public enum HistoryOutcome: Sendable, Hashable {
    /// git finished: `count` new commits on HEAD; `dropped` are the commits `--empty=drop` left
    /// out as already applied ("dropping <sha> … -- patch contents already upstream").
    case applied(count: Int, dropped: [CommitRef])
    /// The action is now A2's: a cherry-pick or revert in progress (a conflict, a signing or
    /// `prepare-commit-msg` failure on a pick, B7), or a range git left halted with `sequencer/`
    /// and no pseudo-ref (an untracked file in a later commit's way, an already-undone commit in
    /// a revert range — `GitOperationBackend.haltedSequence`). Commits made before the stop stay.
    case stopped
    /// A single revert of a change HEAD already undoes: "nothing to commit", exit 1, nothing
    /// changed (B10).
    case alreadyReverted(CommitRef)
    /// A single revert whose commit git could not make — a signing failure (`commit.gpgSign`) or
    /// a `prepare-commit-msg` hook saying no (measured, Task 1): the revert is **staged**, HEAD
    /// has not moved, and there is no `REVERT_HEAD` and no `sequencer/`, so no operation can be
    /// detected and `revert --abort` refuses ("no cherry-pick or revert in progress"). Committing
    /// the staged change, or discarding it, is the way on. Everything git wrote, stderr then
    /// stdout.
    case unsignedRevertLeftStaged(gitsWords: String)
    /// git refused or failed and nothing above describes the result. Everything git wrote.
    case failed(gitsWords: String)
}

/// What a rebase onto a chosen target will replay, read before git runs (B11–B16).
public struct RebasePlan: Sendable, Hashable {
    /// The full object id HEAD was at when the plan was made.
    public let head: String
    /// The full object id of the commit the branch is rebased onto — what git is given (B17:
    /// a short name could be read as a tag of the same name).
    public let target: String
    /// The commits git will replay, oldest first:
    /// `log --reverse --topo-order --cherry-pick --right-only --no-merges <target>...HEAD` (B12).
    /// Empty when git will say "up to date" (the target is an ancestor of HEAD and the history
    /// between is a straight line, B11) and for a fast-forward (the target is a descendant).
    public let replayed: [CommitRef]
    /// Merge commits in `target..HEAD` the rebase drops, replaying their sides in a line (B12,
    /// `--no-rebase-merges` B13).
    public let flattenedMerges: Int
    /// Commits in `target..HEAD` whose change the target already has (patch-identical, B12):
    /// skipped.
    public let skippedAsApplied: Int
    /// Commits in `target..HEAD` already on some remote-tracking branch (B15): rewriting them
    /// rewrites published history. `rebase(_:at:)` refuses with `.planChanged` when it rose
    /// since the plan, and runs when it fell (`runsAs`).
    public let alreadyPushed: Int
    /// The target as the caller named it (a branch, a full ref name, a sha). `rebase(_:at:)`
    /// resolves it again and refuses with `.planChanged` when it no longer names `target`.
    /// An addition to the brief's interface, defaulting to `target`.
    public let targetName: String
    /// What HEAD named when the plan was made: `symbolic-ref -q HEAD`, empty when detached — the
    /// branch the rebase rewrites. `rebase(_:at:)` refuses `.headMoved` when HEAD names anything
    /// else now, even at the same commit. An addition to the brief's interface (fix round 1).
    public let headRef: String

    public init(
        head: String, target: String, replayed: [CommitRef], flattenedMerges: Int, skippedAsApplied: Int,
        alreadyPushed: Int, targetName: String? = nil, headRef: String = ""
    ) {
        self.headRef = headRef
        self.head = head
        self.target = target
        self.replayed = replayed
        self.flattenedMerges = flattenedMerges
        self.skippedAsApplied = skippedAsApplied
        self.alreadyPushed = alreadyPushed
        self.targetName = targetName ?? target
    }

    /// Whether this plan, made again just before the run, still runs as `shown` — the plan the
    /// sheet showed — so the run may go ahead (B4 2d). Everything must be equal but
    /// `alreadyPushed`, which may have **fallen**: the sheet's warning was then stronger than the
    /// truth (a remote-tracking branch went). A count that rose means the warning was too weak.
    /// An automatic fetch in between can move it either way.
    func runsAs(_ shown: RebasePlan) -> Bool {
        let unpushedCount = RebasePlan(
            head: head, target: target, replayed: replayed, flattenedMerges: flattenedMerges,
            skippedAsApplied: skippedAsApplied, alreadyPushed: shown.alreadyPushed, targetName: targetName,
            headRef: headRef)
        return unpushedCount == shown && alreadyPushed <= shown.alreadyPushed
    }
}
