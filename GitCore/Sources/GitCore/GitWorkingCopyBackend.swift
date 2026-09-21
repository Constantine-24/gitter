import Foundation

/// Write operations against the working copy and index.
///
/// Reads stay on `GitBackend`, which is provably side-effect free; mutations live here instead,
/// so either half can be faked independently in tests.
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

    /// `git commit -q [-a] [--amend] -F <tmpfile>`, then `git rev-parse HEAD` to return the
    /// resulting sha, trimmed.
    ///
    /// The message is written to a private temp file outside the worktree (never passed as
    /// `-m`, which would need shell-safe quoting of arbitrary user text) and removed afterward
    /// regardless of outcome. A message that is empty or entirely whitespace throws
    /// `GitError.emptyCommitMessage` before git ever runs.
    ///
    /// `allTracked` adds `-a`, staging every already-tracked modification and deletion before
    /// committing; it never sweeps in untracked files. `amend` adds `--amend`.
    ///
    /// No `--cleanup` flag is passed, so git applies its own default. Because the message
    /// always arrives via `-F` (never interactively edited), that default is `whitespace`, not
    /// `strip`: leading/trailing blank lines and trailing whitespace are trimmed and
    /// consecutive blank lines collapsed, but lines starting with `#` are kept as ordinary
    /// content.
    ///
    /// A rejection — nothing to commit, a signing failure, a failing hook — throws
    /// `GitError.commandFailed` with git's stderr unchanged, and leaves HEAD and the index
    /// exactly as they were.
    ///
    /// **`amend` is refused outright while an operation is in progress**, with
    /// `GitError.amendDuringOperation`, thrown before git runs. What is in progress is re-read
    /// from the repository at that moment, not taken from a snapshot, so a merge a terminal
    /// started a fraction of a second ago still counts. Git's own rule covers only two of the
    /// six (measured on git 2.54, conflicts resolved and staged so nothing else could refuse):
    ///
    /// | in progress | `git commit --amend` |
    /// |---|---|
    /// | merge | refused, exit 128, "You are in the middle of a merge -- cannot amend." |
    /// | cherry-pick | refused, exit 128, "…in the middle of a cherry-pick…" |
    /// | revert | accepted — tip rewritten, `REVERT_HEAD` deleted, the revert vanishes |
    /// | rebase | accepted — tip rewritten, the rebase left standing on a commit now on no ref |
    /// | `git am` | accepted — tip rewritten, `rebase-apply/` left behind |
    /// | pending squash | accepted — tip rewritten, `SQUASH_MSG` deleted, the squash folded in |
    ///
    /// In those four the previous tip ends up reachable from no ref, with nothing said about
    /// it. All six are refused here, so the answer does not depend on which of git's own checks
    /// happens to exist; `AmendDuringOperationTests` pins every cell.
    func commit(message: String, amend: Bool, allTracked: Bool, at root: URL) async throws -> String

    /// `git log -1 --format=%B`, with trailing whitespace and newlines trimmed.
    ///
    /// Returns `""` in a repository with no commits yet, where `log` would otherwise fail.
    func headMessage(at root: URL) async throws -> String
}
