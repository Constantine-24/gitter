import Foundation

/// Write operations against the working copy and index.
///
/// Reads stay on `GitBackend`, which is provably side-effect free; mutations live here instead,
/// so either half can be faked independently in tests. This task declares only the four
/// file-level operations; hunk/line staging (`applyToIndex`) and commit operations (`commit`,
/// `headMessage`) are added by later tasks.
public protocol GitWorkingCopyBackend: Sendable {
    /// `git add -- <paths>`. Stages the given paths, whether modified, deleted, or untracked.
    /// A no-op (does not invoke git) when `paths` is empty.
    func stage(paths: [String], at root: URL) async throws

    /// `git restore --staged -- <paths>`. In a repository with no commits yet (where `restore`
    /// has nothing to restore to), falls back to `git rm --cached -q -- <paths>`, which leaves
    /// the paths untracked and unchanged on disk. A no-op when `paths` is empty.
    func unstage(paths: [String], at root: URL) async throws

    /// `git add -A`. Stages every modified, deleted, and untracked path in the worktree.
    func stageAll(at root: URL) async throws

    /// `git reset -q`. In a repository with no commits yet, falls back to
    /// `git rm --cached -r -q -- .`, which leaves every path untracked and unchanged on disk.
    /// A no-op when the index is already empty in such a repository (where that fallback
    /// command would otherwise fail with "pathspec '.' did not match any files").
    func unstageAll(at root: URL) async throws
}
