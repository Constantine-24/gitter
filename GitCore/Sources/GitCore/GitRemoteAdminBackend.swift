import Foundation

/// Keeping a repository's remotes tidy (milestone B2): prune remote-tracking refs the server no
/// longer has, and find the local branches whose upstream is gone.
///
/// The tenth GitCore protocol. Its promise is the milestone's (spec, "The safety promise,
/// extended"):
///
/// - **What the sheet showed is what is deleted.** A prune is never `git fetch --prune`, which
///   deletes whatever the server lacks *at that moment* — measured, a branch the server lost after
///   the listing went with the rest (R6). It is a per-ref compare-and-delete on the id the plan
///   holds: `update-ref --no-deref -d --end-of-options refs/remotes/<r>/<b> <id>`. A ref that moved
///   is skipped and named.
/// - **Commits only the deleted refs hold are counted once, as a union** (R5), and can be kept: the
///   kept branches are created before anything is deleted.
/// - **Every deleted ref is named with its full id**: a remote-tracking ref has no reflog after a
///   clone, and a delete removes any it had (R7).
///
/// Every vector is pinned in `ForceFlagScannerTests`; `fetch --prune` is permitted there only in
/// the dry-run listing shape, and `update-ref -d` only on a full `refs/remotes/` (or B1's
/// `refs/tags/`) name with an interpolated expected id.
public protocol GitRemoteAdminBackend: Sendable {
    /// Every remote-tracking ref of `remote` the server no longer has, with the id each holds,
    /// and what deleting them all would strand.
    ///
    /// **Contacts the remote** (run it on the remote lane): `git fetch --prune --no-prune-tags
    /// --dry-run --porcelain --no-progress --end-of-options <remote>`, keeping only the pruned
    /// (`-`) lines under `refs/remotes/` (R2, R3). `--no-prune-tags`, because `fetch.pruneTags`
    /// would otherwise list local tags that were never on the server (R8). A dry run is **not**
    /// write-free: it downloads objects and re-creates a missing `refs/remotes/<remote>/HEAD`
    /// (R26) — it moves and deletes nothing else.
    ///
    /// Refused before git runs: `RemoteOperationError.noRemote` for a name that is empty, `.`
    /// or begins with `-`; `RemoteAdminRefusal.noSuchRemote` when no such remote is configured;
    /// `.unsafeRefspec` when one of its fetch refspecs writes outside `refs/remotes/` (a mirror
    /// remote lists local branches as prunable, R3). A network failure is `RemoteOperationError`
    /// when Gitter can word it, git's own (redacted) words otherwise.
    func prunePlan(_ remote: String, at root: URL) async throws -> PrunePlan

    /// The commits reachable from `refs` (full `refs/remotes/…` names) and from no other ref —
    /// not from a local branch, a tag, another remote-tracking ref or any worktree's HEAD; a
    /// symbolic ref holds nothing of its own, and **a stash entry is not a place a commit is
    /// kept** (`GitBranchBackend.commitsOnlyOn`'s rule) — counted as one union (R5), the newest
    /// `StrandedCommits.displayLimit` listed, and which of `refs` reach them. Local reads only. A name that is not a full
    /// `refs/remotes/` ref, or carries revision syntax, is `BranchOperationError.invalidName`
    /// before git runs.
    func stranded(by refs: [String], at root: URL) async throws -> StrandedCommits

    /// Deletes exactly `plan.refs`, each only while it still holds the id the plan showed.
    ///
    /// In order, and nothing is deleted until every step before the deletes has passed:
    /// 1. Every id is checked full and non-zero (`RemoteAdminRefusal.invalidObjectID`), every ref
    ///    a full `refs/remotes/` name, before any process runs.
    /// 2. What the refs that still hold their ids would strand is counted again;
    ///    `.strandedGrew` if it is more than `plan.stranded.count`, or — when the plan listed
    ///    every stranded commit — if any commit now stranded is not one the plan listed.
    /// 3. Every name in `keeping` (plan ref → new branch name) is checked —
    ///    `.invalidBranchName`, `.branchExists` (Ruling 1) — and then every kept branch is created
    ///    at the id the plan showed: `branch --no-track --end-of-options <name> <id>`. If one
    ///    cannot be created after others were, `RemoteAdminPartial.keptBranchesThenStopped` names
    ///    the ones that stay; nothing is deleted.
    /// 4. Each ref is deleted with the compare-and-delete. A ref that moved or is gone is
    ///    `skippedMoved`; one git refused for another reason (a lock, a hook) is `failed`, with
    ///    git's words, and the refs after it are still tried. A cancellation stops the loop: the
    ///    ref being deleted is `outcomeUnknown`, the rest `notTried`.
    ///
    /// Local only: nothing here contacts the remote.
    func prune(_ plan: PrunePlan, keeping: [String: String], at root: URL) async throws -> PruneResult

    /// Whether `name` can be a branch kept by a prune: nil, or the refusal `prune` would throw
    /// for it (`.invalidBranchName`, `.branchExists`) — the sheet's live check. Reads only.
    func keepBranchNameProblem(_ name: String, at root: URL) async throws -> RemoteAdminRefusal?

    /// Every local branch whose upstream is configured and gone (`[gone]`, R9), remote and
    /// local (`.`) upstreams alike, in ref order. A branch whose `branch.<b>.remote` names a
    /// remote that does not exist has no upstream at all to git, and is not listed (R9). One
    /// `for-each-ref`, plus the branch delete's own unique-commit count per gone branch. Reads
    /// only — correct with `config.lock` held by another process (Ruling 2).
    func goneBranches(at root: URL) async throws -> [GoneBranch]
}
