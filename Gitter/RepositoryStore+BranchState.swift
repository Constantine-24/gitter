import Foundation
import GitCore

/// Derived branch state: what HEAD is, what the sidebar and the toolbar may offer, and the one
/// setting this milestone remembers.
///
/// Everything here is read-only over the snapshot, like `RepositoryStore+WorkingCopyState`. The
/// actions live in `+Branches`, the sheets in `+BranchSheets`.
extension RepositoryStore {

    // MARK: - HEAD

    /// The branch HEAD is on, or nil when HEAD is detached (or the repository has no commits).
    var currentBranch: String? {
        snapshot?.status.branch
    }

    /// HEAD is on a commit rather than a branch. An empty repository is not detached — it has an
    /// unborn HEAD pointing at a branch that does not exist yet — so the sha is required too.
    var isDetached: Bool {
        snapshot?.status.branch == nil && snapshot?.status.headSha != nil
    }

    var headSha: String? {
        snapshot?.status.headSha
    }

    /// Seven characters, git's own default abbreviation for a short sha in prose.
    var shortHeadSha: String? {
        headSha.map { String($0.prefix(7)) }
    }

    /// What the toolbar's branch button says: "main", or "detached at 1a2b3c4".
    var headLabel: String {
        if let currentBranch { return currentBranch }
        if let shortHeadSha { return "detached at \(shortHeadSha)" }
        return "no commits yet"
    }

    // MARK: - Refs

    var localBranches: [Branch] {
        snapshot?.refs.localBranches ?? []
    }

    var remoteBranches: [Branch] {
        snapshot?.refs.remoteBranches ?? []
    }

    var tags: [Tag] {
        snapshot?.refs.tags ?? []
    }

    // MARK: - What is allowed right now

    /// Why HEAD may not be moved at the moment, phrased for a tooltip, or nil when it may.
    ///
    /// git refuses a switch or a merge part-way through an operation anyway ("cannot switch
    /// branch while merging"), so this is not the safety net — it is the explanation, given
    /// before the user clicks rather than after. A pending squash is included: it has no
    /// `MERGE_HEAD` for git to refuse over, but switching away from staged, uncommitted squash
    /// content is exactly as bad an idea.
    var branchSwitchingBlockedReason: String? {
        guard let operation = operationInProgress else { return nil }
        return "A \(operation.noun.lowercased()) is in progress. Commit or abort it first."
    }

    /// Switching *to* `branch` is possible: it is not where we already are, and nothing is in
    /// progress. Detaching at it is a different question (that is always possible).
    func canSwitch(to branch: String) -> Bool {
        branchSwitchingBlockedReason == nil && branch != currentBranch
    }

    /// Merging `branch` into HEAD is possible. Merging a branch into itself is a no-op git would
    /// report as "Already up to date", which is not worth offering.
    func canMerge(_ branch: String) -> Bool {
        branchSwitchingBlockedReason == nil && branch != currentBranch
    }

    /// Deleting `branch` is possible. The current branch is refused by the backend twice over
    /// (before git runs and again from git's own words); this keeps the menu item from
    /// pretending otherwise. Not gated on an operation in progress: deleting some *other*
    /// branch mid-merge touches neither the worktree nor the index.
    func canDelete(_ branch: String) -> Bool {
        branch != currentBranch
    }

    /// The files an abort or an undo-squash would revert: everything with a staged change, plus
    /// every unresolved conflict.
    ///
    /// That is what `--abort` and `reset --merge` actually take — verified in `AbortKeptAndLost`
    /// — and the sheet lists them by name rather than describing them, because the `.squash`
    /// precondition rests on `SQUASH_MSG` alone and can outlive the squash it belonged to (see
    /// `CLIGitBackend+Abort.swift`). A user whose staged work is not the operation's work can
    /// then see so before agreeing.
    var filesRevertedByAbort: [FileStatus] {
        snapshot?.status.files.filter { $0.staged != nil || $0.unstaged == .unmerged } ?? []
    }

    // MARK: - Remembered merge mode

    // internal (not private): `UserDefaults` key, paired with the two accessors below.
    static let mergeModeKey = "mergeMode"

    /// The mode the merge sheet comes up on: whatever was chosen last, or a plain
    /// fast-forward-if-possible merge, which is what `git merge` does with no flags at all.
    var rememberedMergeMode: MergeMode {
        UserDefaults.standard.string(forKey: Self.mergeModeKey)
            .flatMap(MergeMode.init(rawValue:)) ?? .fastForwardIfPossible
    }

    /// Called by `merge(_:mode:)` itself, so the remembered mode is the one that was really
    /// used and never one that was merely selected in a sheet the user then cancelled.
    // internal (not private): used by +Branches.swift's `merge(_:mode:)`
    func rememberMergeMode(_ mode: MergeMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.mergeModeKey)
    }
}
