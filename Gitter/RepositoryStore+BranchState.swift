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

    /// Where HEAD is, as a noun phrase that reads inside a sentence: `"main"` with its quotes,
    /// or `the detached HEAD at 1a2b3c4`.
    ///
    /// `headLabel` is a *label* — it is what a button says on its own, and "detached at 1a2b3c4"
    /// is not something a sentence can be built around. This is the other half, and it is one
    /// property because three places need the same phrase: what a merge merges into
    /// (`MergeSheet`, `LocalBranchMenu`) and what `git branch -d` compared a branch against
    /// (`DeleteBranchSheet`). They had three copies, and only two of them said anything sensible
    /// about a detached HEAD — the menu's simply said "HEAD", so the same merge was described
    /// two different ways depending on where the user started it.
    ///
    /// The menu item that uses it is therefore longer while HEAD is detached
    /// ("Merge into the detached HEAD at 1a2b3c4…"). That is the honest length: on a branch —
    /// which is where the menu is nearly always used — it is just the quoted name.
    ///
    /// A repository with no commits has nothing to name, so it falls back to the bare word.
    var headPhrase: String {
        if let currentBranch { return "\"\(currentBranch)\"" }
        if let shortHeadSha { return "the detached HEAD at \(shortHeadSha)" }
        return "HEAD"
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
    /// so these reasons are rendered *in* the menu (see `MenuReasons` and `LocalBranchMenu`),
    /// and three wordings for one fact would be three grey lines explaining the same thing.
    nonisolated static let currentBranchReason = "This is the branch you are on."

    /// Why switching to `branch` is off right now, or nil when it is available. Detaching at it
    /// is a different question (that is always possible). A branch another worktree has checked
    /// out, or a rebase or bisect there holds, cannot be checked out here (B3, R14): git refuses,
    /// and the reason says which worktree to open instead.
    func switchBlockedReason(for branch: String) -> String? {
        if branch == currentBranch { return Self.currentBranchReason }
        return worktreeHeldReason(branch) ?? branchSwitchingBlockedReason
    }

    /// Why merging `branch` into HEAD is off right now, or nil when it is available.
    func mergeBlockedReason(for branch: String) -> String? {
        if branch == currentBranch { return Self.currentBranchReason }
        return branchSwitchingBlockedReason
    }

    /// Why deleting `branch` is off right now, or nil when it is available. Not gated on an
    /// operation in progress: deleting some *other* branch mid-merge touches neither the
    /// worktree nor the index. Off for a branch another worktree holds (B3, R14): git refuses.
    func deleteBlockedReason(for branch: String) -> String? {
        branch == currentBranch ? Self.currentBranchReason : worktreeHeldReason(branch)
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

    /// What the abort now offered does to commits that are already made.
    ///
    /// Every abort puts HEAD back where it was *when the operation started*. For a merge, a
    /// squash, a single cherry-pick or revert, and a range's first stop that is where HEAD still
    /// is. Not so for two (final review I2, measured on git 2.54): `git am`, whose `--abort`
    /// rewinds the branch past the patches it already committed, and a cherry-pick or revert
    /// range that made commits before stopping again (a Continue, in the app or a terminal) —
    /// its `--abort` resets to `sequencer/head` and those commits leave the branch, reachable
    /// only from the reflog. The range's commits are read with the stop
    /// (`GitOperationBackend.commitsAbortRemoves`), so the sheet can name them; a rebase has its
    /// own sentence. `OperationBarState.abortRewind` decides.
    var abortRewind: AbortRewind {
        OperationBarState.abortRewind(operationInProgress, operationStop)
    }

    // MARK: - Remembered merge mode

    // internal (not private): `UserDefaults` key, paired with the two accessors below.
    static let mergeModeKey = "mergeMode"

    /// The mode the merge sheet comes up on: whatever was chosen last, or a plain
    /// fast-forward-if-possible merge, which is what `git merge` does with no flags at all.
    var rememberedMergeMode: MergeMode {
        defaults.string(forKey: Self.mergeModeKey)
            .flatMap(MergeMode.init(rawValue:)) ?? .fastForwardIfPossible
    }

    /// Recorded once git has actually merged with it, never when one is merely asked for: a
    /// sheet the user cancelled, a merge refused because something is in progress, one parked
    /// behind the detached-HEAD confirmation, and — the case this used to get wrong — one git
    /// itself refused over a dirty worktree or a staged change all leave the remembered mode
    /// alone. Every refusal is a throw, so "the call returned" is exactly the line between them;
    /// see `+Branches`' `run(_:backend:at:defaults:)` for which outcomes that covers.
    ///
    /// `static` because that is where it is called from — the merge's own argument vector, in
    /// `+Branches`' `run` — and because it touches nothing but `defaults`, the store's own
    /// (`RepositoryStore.defaults`), which `run` is handed.
    // internal (not private): used by +Branches.swift's `run(_:backend:at:defaults:)`
    static func rememberMergeMode(_ mode: MergeMode, in defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: Self.mergeModeKey)
    }

    // MARK: - Remembered pull mode

    // internal (not private): `UserDefaults` key, paired with the two accessors below.
    static let pullModeKey = "pullMode"

    /// What the pull sheet comes up on: whatever last ran, or Merge — the answer that rewrites
    /// nothing.
    var rememberedPullMode: PullMode {
        defaults.string(forKey: Self.pullModeKey)
            .flatMap(PullMode.init(rawValue:)) ?? .merge
    }

    /// Recorded once the pull's merge or rebase has really run, exactly as `rememberMergeMode`
    /// is: a sheet the user cancelled, or a rebase refused over a dirty tree, leaves it alone.
    // internal (not private): used by +Branches.swift's `run` and +RemoteSheets.swift
    static func rememberPullMode(_ mode: PullMode, in defaults: UserDefaults) {
        defaults.set(mode.rawValue, forKey: Self.pullModeKey)
    }
}
