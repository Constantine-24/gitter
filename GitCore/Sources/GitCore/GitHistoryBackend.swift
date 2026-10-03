import Foundation

/// Cherry-pick, revert and rebase onto a chosen target — the history actions A2 already knows
/// how to finish (B1).
///
/// The eighth GitCore protocol. Every action is two steps: a **plan**, read before anything
/// runs (refusals happen there and change nothing), and a **run** that makes the plan again and
/// refuses — `.headMoved`, `.planChanged`, or the plan's own refusal — when the repository no
/// longer matches the one the sheet showed. Stops are A2's: the operation bar, Continue, Skip,
/// Abort, and the halted and stale sequence handling.
///
/// Vectors, each pinned whole in `ForceFlagScannerTests`:
/// `cherry-pick --empty=drop --end-of-options <shas…>`,
/// `revert --no-edit --no-reference --end-of-options <shas…>` and
/// `rebase --no-autostash --no-update-refs --no-rebase-merges --end-of-options <full sha>` —
/// user config cannot widen or rewrite them (B4, B9, B13, B17).
public protocol GitHistoryBackend: Sendable {
    /// The plan for cherry-picking or reverting `shas` (full object ids, the commit list's; any
    /// order, duplicates ignored).
    ///
    /// Refuses (`HistoryRefusal`), in this order: `.operationInProgress` — an operation, or a
    /// halted range's `sequencer/`; `.unbornHead`; `.mergeCommits`; `.nothingToApply` (no
    /// commit, or — a pick — every one already in HEAD); `.trackedChanges`. A sha that is not a
    /// full object id is `BranchOperationError.invalidName`. Reads only.
    func historyPlan(_ action: HistoryAction, shas: [String], at root: URL) async throws -> HistoryPlan

    /// Runs `plan`: refuses `.headMoved` when HEAD is not `plan.head`, then makes the plan again
    /// from its commits (and `leftOut`) and refuses with its refusal, or `.planChanged` when it
    /// differs. Then runs the vector and reads the repository back; see `HistoryOutcome`. A
    /// refusal git printed with nothing changed (a staged change made after the check, "is a
    /// merge but no -m option was given") is thrown: `BranchOperationError` / `.mergeCommits`.
    func run(_ plan: HistoryPlan, at root: URL) async throws -> HistoryOutcome

    /// The plan for rebasing the current branch (or a detached HEAD) onto `target`: a local
    /// branch name (preferred over a tag of the same name, RF2), a remote-tracking name, a full
    /// ref name or a full object id; refused as `BranchOperationError.invalidName` when it is
    /// anything else (`main~1`, `a..b`), `.noSuchBranch` when it resolves to no commit.
    /// Refuses (`HistoryRefusal`) `.operationInProgress`, `.unbornHead`, `.trackedChanges`.
    /// Reads only.
    func rebasePlan(onto target: String, at root: URL) async throws -> RebasePlan

    /// Runs `plan`: refuses `.headMoved`, then the plan's own refusals, then `.planChanged`
    /// (the target moved, or anything the sheet showed changed). Then rebases onto
    /// `plan.target` — the full object id — and reads the outcome back as
    /// `GitRemoteBackend.rebase(onto:at:)` does.
    func rebase(_ plan: RebasePlan, at root: URL) async throws -> RebaseOutcome
}
