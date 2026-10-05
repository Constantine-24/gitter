import Foundation

/// Worktrees (milestone B3): list them, read one's changes, check what removing one would lose,
/// add one for an existing local branch, and remove one.
///
/// The twelfth GitCore protocol. Its promises are the milestone's second, third and fourth
/// (spec, "The safety promise, extended"), and each rests on a measured git fact (git 2.54):
///
/// - **Remove deletes only what the sheet showed and the user confirmed.** git's own `worktree
///   remove`, without `--force`, is not a safe final guard: it deletes ignored files and folders —
///   a repository nested in one included — files `info/exclude` hides, assume-unchanged and
///   skip-worktree edits, and, under `status.showUntrackedFiles=no`, untracked files (R21). A
///   rebase, a bisect or a clean merge in progress does not stop it either (R20). So Gitter checks
///   every one of those itself (`removalCheck`), makes the check again just before git runs, and
///   runs git with `status.showUntrackedFiles=normal` put back through the environment, which
///   makes git refuse a file that appeared in between (R21, R24).
/// - **Add never checks out or creates a branch the user did not choose.** `add <path> <name>`
///   creates a tracking branch for a remote-only name whatever `--no-guess-remote` says, detaches
///   at a `refs/heads/…` name, and omitting the name creates a branch named after the folder
///   (R17). Gitter passes only the short name of a branch it has just checked is
///   `refs/heads/<name>`, and reads `list` back.
/// - **A failed or cancelled write is read back.** `add` exits with a failing `post-checkout`
///   hook's code after the worktree is complete (R19); a removal is confirmed by `list`, not by
///   git's exit code.
///
/// Paths are matched as git matches them, by real path (`/var` is `/private/var`, R23), and given
/// to git exactly as `list` printed them. Every vector is pinned in `ForceFlagScannerTests`
/// (`worktreeContract`); `worktree prune`, `move`, `repair`, `lock`, `unlock` and every `--force`
/// are findings there.
public protocol GitWorktreeBackend: Sendable {
    /// Every worktree, the main one first (`worktree list --porcelain -z`, R13), each with the
    /// branch a rebase or bisect there holds (R14).
    func worktrees(at root: URL) async throws -> [Worktree]

    /// `worktree`'s changes: `status --porcelain=v2 -z --untracked-files=normal`, run in its folder
    /// (R15). Throws for a worktree whose folder is missing.
    func worktreeChanges(_ worktree: Worktree, at root: URL) async throws -> WorktreeChanges

    /// What removing `worktree` would lose, and why it is refused, if it is. `root` is this
    /// window's worktree. The worktree is looked up again in `list` by its path, and its current
    /// record is what the result holds; one no longer listed is
    /// `WorktreeRemovalPartial.changedSinceShown`.
    ///
    /// The main worktree is refused (`.isMain`) without reading anything else. A missing one has
    /// no changes (`nil`) and is not walked: only a lock refuses it. Any other is refused for every
    /// one of `WorktreeRemovalRefusal`'s reasons that applies — and for one it could not rule out:
    /// a folder or state file it cannot read, a walk past `WorktreeWalkLimit.standard`.
    func removalCheck(_ worktree: Worktree, at root: URL) async throws -> WorktreeRemoval

    /// Adds a worktree at the absolute `path` for the existing local branch `branch` (its short
    /// name): `worktree add -q --end-of-options <path> <branch>`, then `list` read back whatever
    /// git's exit code (R19).
    ///
    /// Refused before git runs (`AddWorktreeRefusal`): a path that is not absolute, that exists
    /// and is not an empty folder, or that lies inside a listed worktree (by real path); a branch
    /// that is not a plain `refs/heads/<branch>` right before git runs (R17); a branch checked out
    /// in a worktree or held there by a rebase or bisect (R14). A failure git leaves nothing
    /// behind for is thrown as git's error (`GitError.commandFailed`).
    func addWorktree(path: String, branch: String, at root: URL) async throws -> AddWorktreeResult

    /// Removes the worktree `removal` describes, only if nothing it showed has changed, and
    /// returns the kept branches created first (B3 Ruling 1).
    ///
    /// - A removal with refusals throws its first refusal, before git runs.
    /// - `keeping` maps a holder in `removal.stranded.holders` (the worktree's path) to the name of
    ///   a branch to create at its HEAD first; any other key is `BranchOperationError.invalidName`,
    ///   before git runs.
    /// - The check is made again: any difference is `WorktreeRemovalPartial.changedSinceShown`,
    ///   with nothing written.
    /// - Kept branches are created with B2's `createKeptBranches`; its refusals and its
    ///   `RemoteAdminPartial.keptBranchesCancelled` come through as they are.
    /// - Then `worktree remove --end-of-options <path as listed>`, with
    ///   `status.showUntrackedFiles=normal` forced (R21), and `list` read back: gone returns the
    ///   kept branches; still listed is `.refusedByGit`; cancelled, or unreadable afterwards,
    ///   `.outcomeUnknown`. `worktree prune` is never run (R25).
    func removeWorktree(_ removal: WorktreeRemoval, keeping: [String: String], at root: URL) async throws -> [String]
}
