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
        operationInProgress?.movingHeadBlocked
    }

    /// The one sentence behind every item a branch's own menu turns off when that branch is the
    /// one HEAD is on: it cannot be switched to (we are there), merged into itself (git would
    /// say "Already up to date"), or deleted (the backend refuses, twice over).
    ///
    /// Deliberately one sentence for all three. A disabled menu item shows no tooltip on macOS,
    /// so these reasons are rendered *in* the menu (see `BranchContextMenu`), and three wordings
    /// for one fact would be three grey lines explaining the same thing.
    static let currentBranchReason = "This is the branch you are on."

    /// Why switching to `branch` is off right now, or nil when it is available. Detaching at it
    /// is a different question (that is always possible).
    func switchBlockedReason(for branch: String) -> String? {
        if branch == currentBranch { return Self.currentBranchReason }
        return branchSwitchingBlockedReason
    }

    /// Why merging `branch` into HEAD is off right now, or nil when it is available.
    func mergeBlockedReason(for branch: String) -> String? {
        if branch == currentBranch { return Self.currentBranchReason }
        return branchSwitchingBlockedReason
    }

    /// Why deleting `branch` is off right now, or nil when it is available. Not gated on an
    /// operation in progress: deleting some *other* branch mid-merge touches neither the
    /// worktree nor the index.
    func deleteBlockedReason(for branch: String) -> String? {
        branch == currentBranch ? Self.currentBranchReason : nil
    }

    func canSwitch(to branch: String) -> Bool {
        switchBlockedReason(for: branch) == nil
    }

    func canMerge(_ branch: String) -> Bool {
        mergeBlockedReason(for: branch) == nil
    }

    func canDelete(_ branch: String) -> Bool {
        deleteBlockedReason(for: branch) == nil
    }

    /// The files an abort or an undo-squash would revert, so the sheet can name them instead of
    /// describing them in the abstract.
    ///
    /// Two lists, because the six aborts do not all take the same thing — the kept/lost table in
    /// `GitBranchBackend.abort` is the source for both:
    ///
    /// - **merge, squash, cherry-pick, revert, `am`**: everything **staged** goes back to HEAD,
    ///   and so does every conflict resolution, staged or not. An *unstaged* edit to a file the
    ///   operation did not touch is **kept**, so it is not listed.
    /// - **rebase**: `git rebase --abort` resets **hard**, so unstaged edits go too — even in
    ///   files the rebase never touched. Every one of them was made since the rebase began (git
    ///   refuses to *start* a rebase over a dirty tracked file), so during a rebase this lists
    ///   every tracked change on either side.
    ///
    /// Untracked files are never listed: none of these commands is `git clean`, and every
    /// untracked file survives all six (verified for all seven starting states).
    ///
    /// Naming them matters most for a pending squash, whose precondition rests on `SQUASH_MSG`
    /// alone and can outlive the squash it belonged to (see `CLIGitBackend+Abort.swift`): a user
    /// whose staged work is not the squash's work can see so before agreeing.
    var filesRevertedByAbort: [FileStatus] {
        guard let files = snapshot?.status.files else { return [] }
        guard abortAlsoDiscardsUnstagedEdits else {
            return files.filter { $0.staged != nil || $0.unstaged == .unmerged }
        }
        return files.filter { $0.staged != nil || ($0.unstaged != nil && !$0.isUntracked) }
    }

    /// Whether the abort now offered also throws away edits that were never staged.
    ///
    /// True for a rebase alone: `rebase --abort` resets hard where the other five reset the
    /// index two-way and leave an unstaged edit exactly where the user last saved it (verified
    /// on git 2.54 from the same starting point — `merge --abort` even *refuses* over one). The
    /// sheet needs two wordings, and this is which.
    var abortAlsoDiscardsUnstagedEdits: Bool {
        operationInProgress == .rebase
    }

    /// Whether the abort now offered also rewinds commits that are already made.
    ///
    /// True for `git am` alone: it is the one operation that has already committed something
    /// when it stops, and `am --abort` rewinds the branch past those commits. Nothing else here
    /// moves a branch backwards — every other abort puts HEAD and the refs back exactly where
    /// they were *when the operation started*, which for those five is where they still are.
    var abortRewindsCommits: Bool {
        operationInProgress == .applyingPatches
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

    /// Recorded the moment the merge is actually attempted, never when one is merely asked for:
    /// a sheet the user cancelled, a merge refused because something is in progress, and one
    /// parked behind the detached-HEAD confirmation all leave the remembered mode alone.
    ///
    /// `static` because that is where it is called from — the merge's own argument vector, in
    /// `+Branches`' `run` — and because it touches nothing but `UserDefaults`.
    // internal (not private): used by +Branches.swift's `run(_:backend:at:)`
    static func rememberMergeMode(_ mode: MergeMode) {
        UserDefaults.standard.set(mode.rawValue, forKey: Self.mergeModeKey)
    }
}
