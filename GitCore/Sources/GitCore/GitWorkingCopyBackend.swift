import Foundation

/// Write operations against the working copy and index.
///
/// Reads stay on `GitBackend`, which is provably side-effect free; mutations live here instead,
/// so either half can be faked independently in tests. Commit operations (`commit`,
/// `headMessage`) are added by a later task.
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

    /// `git apply --cached --whitespace=nowarn [--unidiff-zero] [--reverse] <tmpfile>`, the
    /// hunk- and line-level half of staging.
    ///
    /// `--cached` patches the index alone, so the worktree is never read or written; that is
    /// what makes staging a subset of a file's changes safe. Pass `reverse: true` for a patch
    /// `PatchBuilder` built with `.unstage`, whose new side is the current index.
    /// `--unidiff-zero` is passed exactly when `patch.needsUnidiffZero`, i.e. when some hunk
    /// came out with no context line at all; `git apply` may otherwise refuse such a hunk.
    ///
    /// A patch that no longer matches the index — because the index moved on after the diff
    /// was loaded — throws `GitError.commandFailed` with git's stderr unchanged, and `git
    /// apply` leaves the index exactly as it was.
    func applyToIndex(patch: Patch, reverse: Bool, at root: URL) async throws
}
