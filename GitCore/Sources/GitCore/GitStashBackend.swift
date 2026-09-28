import Foundation

/// The stash: reading the list and showing an entry. Writing to it (push, store, apply, pop,
/// drop) joins this protocol with the record that discard is built on.
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
}
