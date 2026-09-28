import Foundation

/// Why a stash write was refused before git ran anything that could change the repository.
///
/// Thrown, not returned: nothing happened, so there is no outcome to report.
public enum StashRefusal: Error, Sendable, Hashable {
    /// A merge, cherry-pick, revert, rebase, `git am` or pending squash is part-way through. A
    /// full push silently ends a stopped merge, cherry-pick or squash, and moves a rebase's
    /// staged resolution into the entry (M 13); an apply mixes the entry into a half-done
    /// operation. Gitter refuses both itself rather than relying on git.
    case operationInProgress(RepositoryOperation)
    /// Paths with conflict stages. Every push and apply refuses them (`f: needs merge`, M 13),
    /// and the record cannot build a tree from them (M A.0).
    case unmergedPaths([String])
    /// Paths added with `git add -N` — including one whose file has since been deleted, and the
    /// deleted half of an intent-to-add pair git reports as a rename. A push refuses them
    /// (`Entry 'n' not uptodate`, M 14) or, for a deleted one, silently drops the entry; the
    /// record would turn one into a staged empty file (M A.0).
    case intentToAdd([String])
    /// Submodules (gitlinks). Stash cannot save the work inside one (M 14).
    case submodules([String])
    /// Untracked directories that are repositories of their own, or paths inside one. git
    /// does not look inside them (M 4, 16).
    case nestedRepositories([String])
    /// A file and a directory swapped places: a tracked file or symlink whose path is now a
    /// real directory on disk (`p` → `p/x`), or a path with a leading component that is now a
    /// file or symlink (`d/a` → the file `d`). Status shows only a deletion, and neither the
    /// record nor a plain push would hold the untracked content, which the restore then
    /// overwrites (measured, fix round 1).
    case pathTypeChanged([String])
    /// `stash@{index}` no longer names the entry's sha: the list changed since the `Stash`
    /// value was read (another push, a drop in a terminal, or another linked worktree, M 17).
    case stashListChanged
    /// `stashPaths` was given no paths.
    case nothingSelected
}

/// What a push — `stashAll` or `stashPaths` — did.
///
/// Decided by `refs/stash` before and after, never by git's exit code (M A.7): a push can exit
/// 1 after filing an entry, and exit 0 without filing one.
public enum StashPushOutcome: Sendable, Hashable {
    /// The entry was filed and the changes are out of the files.
    case saved(Stash)
    /// Nothing was filed: there was nothing git would save (or only an entry holding nothing,
    /// which Gitter dropped again, M A.7).
    case nothingToSave
    /// The entry was filed, but git (or the step after it) then failed: the changes are in the
    /// entry *and* may still be in the files. `gitsWords` is what failed, verbatim. `trashed`
    /// names every untracked item `stashPaths` had already moved to the Trash before the
    /// failure — original path (relative to the root) → where it went — so each can be found
    /// and put back; the Trash may rename an item, so the URL is the only way to find it (M 15).
    case savedWithError(Stash, gitsWords: String, trashed: [String: URL] = [:])
}

/// What an apply (or the apply half of a pop) did.
public enum StashApplyOutcome: Sendable, Hashable {
    /// Applied cleanly.
    case applied
    /// Applied with conflicts in these paths (found with `ls-files -u`: with `-q` git reports a
    /// conflict only by its exit code, M A.1). The entry is kept.
    case conflicts([String])
    /// git refused because these files have changes of their own that the apply would
    /// overwrite. Nothing changed (M 6).
    case refused(wouldOverwrite: [String])
    /// The tracked part landed, but these untracked files from the entry were not restored
    /// because a file of that name exists (M 6). The entry is kept.
    case partiallyApplied(untrackedNotRestored: [String])
    /// Anything else, in git's own words.
    case failed(gitsWords: String)
}

/// The stash: reading the list and showing an entry, pushing, applying, popping and dropping.
public protocol GitStashBackend: Sendable {
    /// Every entry of `refs/stash`'s reflog, newest first (`stash@{0}` first). Empty when there
    /// is no stash, and in a repository with no commits.
    ///
    /// Runs `git stash list -z --format=%H%x1f%gd%x1f%gs%x1f%ct%x1f%P`, and never `--date`,
    /// which would turn `%gd` into a date (M 1).
    func stashes(at root: URL) async throws -> [Stash]

    /// What an entry holds: the tracked part (`W^1` → `W`, with renames), then — when the entry
    /// has a third parent — every untracked file in it as an addition. Both are read with
    /// `diff-tree` and explicit flags, which the user's diff config cannot reshape (M A.6).
    func stashDiff(_ stash: Stash, at root: URL) async throws -> [FileDiff]

    /// `git stash push -q --message <message>` (+ `--include-untracked`): every change.
    ///
    /// Throws `StashRefusal` before running git while an operation is in progress, while any
    /// path is unmerged, while any intent-to-add entry exists, or while any tracked path shown
    /// as deleted swapped type with what is on disk (`pathTypeChanged`) — the last with or
    /// without `includeUntracked`, since `-u` never takes an ignored file. A nil or empty message gives
    /// git's own `WIP on <branch>: <sha> <subject>`. An entry git files although it holds
    /// nothing (an untracked nested repository with `-u`, M A.7) is dropped again by its
    /// verified position and reported as `.nothingToSave`.
    func stashAll(message: String?, includeUntracked: Bool, at root: URL) async throws -> StashPushOutcome

    /// Stashes exactly `paths`: Gitter's own record of them (`StashRecord`, filed as
    /// `On <branch>: <message>`), then `restore --source=HEAD --staged --worktree` of the
    /// tracked ones. Untracked files are recorded too, and then moved to the Trash — `restore`
    /// refuses an untracked path, and refuses every other path with it. An untracked directory
    /// is taken as its untracked, not ignored, files.
    ///
    /// Throws `StashRefusal` for no paths, an operation in progress, and unmerged,
    /// intent-to-add, submodule and nested-repository paths, before anything is written.
    func stashPaths(_ paths: [String], message: String, at root: URL) async throws -> StashPushOutcome

    /// `git stash apply -q --no-index <sha>` with rerere turned off (`rerereOff`). By sha, so
    /// an entry is applied even if its position moved. `--no-index`: the index is never
    /// restored (with anything staged, `--index` refuses and unstages it, M A.2), which also
    /// beats a `stash.index=true` in the user's config.
    ///
    /// Throws `StashRefusal.operationInProgress` or `.unmergedPaths` before running git.
    func apply(_ stash: Stash, at root: URL) async throws -> StashApplyOutcome

    /// An apply, then — only when it was `.applied` — a verified drop. Any other outcome keeps
    /// the entry, as git's own pop does. Gitter never runs the `pop` subcommand.
    ///
    /// Throws `StashRefusal.stashListChanged` before applying when `stash@{index}` is no longer
    /// `stash.sha`. If the list changes between the apply and the drop, the entry is kept and
    /// the outcome is still `.applied`: the changes are in the files, and the entry stays
    /// listed where the next read shows it.
    func pop(_ stash: Stash, at root: URL) async throws -> StashApplyOutcome

    /// `git stash drop -q stash@{index}`, only after `rev-parse stash@{index}` gave `stash.sha`.
    /// Throws `StashRefusal.stashListChanged` otherwise, including when the position no longer
    /// exists. The window between the check and the drop is one process start (M 17).
    func drop(_ stash: Stash, at root: URL) async throws
}
