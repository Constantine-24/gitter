import Foundation

/// Write operations against the working copy and index.
///
/// Reads stay on `GitBackend`, which is provably side-effect free; mutations live here instead,
/// so either half can be faked independently in tests.
public protocol GitWorkingCopyBackend: Sendable {
    /// `git add -- <paths>`. Stages the given paths, whether modified, deleted, or untracked.
    /// A no-op (does not invoke git) when `paths` is empty. One call however many paths, all
    /// or nothing: the paths go in a pathspec file (Ruling 26).
    func stage(paths: [String], at root: URL) async throws

    /// `git restore --staged -- <paths>`. In a repository with no commits yet (where `restore`
    /// has nothing to restore to), falls back to `git rm --cached -q -- <paths>`, which leaves
    /// the paths untracked and unchanged on disk. A no-op when `paths` is empty. The paths go
    /// in a pathspec file, as `stage`'s.
    func unstage(paths: [String], at root: URL) async throws

    /// What `git add -A` stages — every modified, deleted and untracked path — except an
    /// unmerged path, which stays unmerged: `add -A` would resolve it with its markers in
    /// (M 22). Runs `add -- <paths>` over the status's list; a no-op when nothing is left.
    func stageAll(at root: URL) async throws

    /// `git reset -q`. In a repository with no commits yet, falls back to
    /// `git rm --cached -r -q -- .`, which leaves every path untracked and unchanged on disk.
    /// A no-op when the index is already empty in such a repository (where that fallback
    /// command would otherwise fail with "pathspec '.' did not match any files").
    func unstageAll(at root: URL) async throws

    /// `git apply --cached --whitespace=nowarn [--reverse] <tmpfile>`, the
    /// hunk- and line-level half of staging.
    ///
    /// `--cached` patches the index alone, so the worktree is never read or written; that is
    /// what makes staging a subset of a file's changes safe. Pass `reverse: true` for a patch
    /// `PatchBuilder` built with `.unstage`, whose new side is the current index.
    ///
    /// **Before git runs, the index must still be exactly what the patch's diff was loaded
    /// from**: its entry for `patch.path` holds `patch.oldBlob` when staging, and the staged
    /// change is exactly `patch.oldBlob → patch.newBlob` (HEAD and index) when unstaging. git
    /// would otherwise apply a hunk with context wherever its context matches — measured: `X`
    /// staged into the wrong one of two identical blocks. A mismatch, a missing or abbreviated
    /// id, an unmerged or missing entry all throw `GitError.commandFailed` whose first line
    /// reads like git's own (`error: <path>: patch does not apply`), with the index untouched.
    ///
    /// A patch that git itself then refuses throws `GitError.commandFailed` with git's stderr
    /// unchanged, and `git apply` leaves the index exactly as it was. That includes a hunk with
    /// no context line (`patch.hasContextFreeHunk`): `--unidiff-zero` is never passed, so git
    /// applies such a hunk only to an index that is exactly its preimage, never at an offset.
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

    // MARK: - Discard

    /// What a discard sheet for tracked paths shows, and exactly what `discard` re-reads for
    /// its stale check: per path, in order, `workingCopyDiff(staged: true)` when
    /// `includingStaged`, then `workingCopyDiff(staged: false)` when the index has the path (a
    /// staged deletion or rename source has no unstaged side). `.unstaged` and `.lines` use
    /// `includingStaged: false`, `.stagedAndUnstaged` `true`.
    func discardExpectation(tracked paths: [String], includingStaged: Bool, at root: URL) async throws
        -> DiscardExpectation

    /// What a discard sheet for untracked items shows, and what `discard` stats again: each
    /// item's type, size and date (see `UntrackedItem`). A path that does not exist is left
    /// out, so it cannot match what a sheet showed.
    func discardExpectation(untracked paths: [String], at root: URL) async throws -> DiscardExpectation

    /// Discards what `request` names, after recording it (tracked kinds) or on its way to the
    /// Trash (untracked). In this order, each step only if the one before it passed:
    ///
    /// 1. **Guard**, before anything runs: `DiscardRefusal` for unmerged, intent-to-add,
    ///    submodule and nested-repository paths, a file and a directory that swapped places
    ///    (the record's own refusals, run first), a path the kind cannot take (`notTracked`),
    ///    during an operation the staged side of its own paths (`.partOfOperation`, M 21 —
    ///    nothing else is refused for an operation, M 20), and for `.lines` anything but a
    ///    plain modification of a text file that is valid UTF-8, or a patch with a context-free
    ///    hunk (`needsWholeFile`). After the record, a `.lines` file must also be in its checkout
    ///    form (`RecordedForm`), or the record is dropped again and `needsWholeFile` thrown.
    /// 2. **Stale check**: `discardExpectation` again, compared with `request.expected`;
    ///    any difference is `.changedSinceShown`, with no record written.
    /// 3. **Record** (tracked kinds): `StashRecord`, `request.recordMessage`.
    /// 4. **Change**: `restore --no-recurse-submodules --worktree`, `restore
    ///    --no-recurse-submodules --source=HEAD --staged --worktree`, `apply --reverse
    ///    --whitespace=nowarn` of the patch on the worktree (never `--unidiff-zero`), or the
    ///    Trash, one item at a time.
    ///
    /// When step 4 fails for a tracked kind, the same diffs are read once more. If they are
    /// still exactly `expected`, git changed nothing (`restore` and `apply` are all or nothing,
    /// M 9, A.5), so the record is dropped again — by its verified position — and git's error
    /// is thrown as it is: an `index.lock` leaves no entry behind. Otherwise, or if that drop
    /// fails, `DiscardFailure` names the record. A Trash that fails part-way throws
    /// `DiscardFailure` naming what already went.
    ///
    /// **The window.** Between the stale check and the record, and between the record and step
    /// 4, lie a process start or two in which another program can still edit a file. An edit in
    /// the first window is in the record but was never shown; one in the second is overwritten
    /// by step 4 and is in no record. No git option closes either; they are the same window
    /// `applyToIndex` documents for staging.
    func discard(_ request: DiscardRequest, trasher: any Trasher, at root: URL) async throws -> DiscardReceipt

    /// Puts a discard back:
    ///
    /// - `.unstaged`: `stash apply -q --no-index` of the record (rerere off), then the drop.
    /// - `.stagedAndUnstaged`: the same apply, then — only while HEAD is still
    ///   `receipt.headAtDiscard` and no path had a staged change before the apply —
    ///   `restore --no-recurse-submodules --source=<record>^2 --staged` of the paths W^2 or the
    ///   index knows. With HEAD moved, that would stage a reversal of the new commit (M B b);
    ///   over a staged edit made since, it would overwrite that edit. Either way it is skipped:
    ///   `.restoredUnstaged`.
    /// - `.lines`: first the file's bytes, index entry and HEAD are read again and must equal
    ///   `receipt.afterDiscard`, else `.refused` with nothing applied — in a file that moved
    ///   on, even by an edit that was then staged or committed, the forward patch's context can
    ///   match elsewhere and git would put the lines there (fix rounds 1 and 2). Then `apply
    ///   --whitespace=nowarn` of the same patch on the worktree. The record is dropped only
    ///   when the file's bytes equal the record's copy in the form they had before the discard
    ///   (`receipt.recordedForm`): raw (`cat-file blob`) or as a checkout writes it (`cat-file
    ///   --filters`); otherwise it is kept: `.restoredUnverified`.
    /// - `.untracked`: each item back from the Trash; one whose path exists again is not
    ///   overwritten (`.partiallyRestored`), and the others still come back.
    ///
    /// Every drop is the verified one (`GitStashBackend.drop`), of the record found again **by
    /// sha** in the current list — so an entry pushed since, which moved the record down, is
    /// never the one dropped. If the list changes between that read and the drop, the drop is
    /// refused and the record kept; the outcome is still `.restored`, since the content is
    /// back. A refused or conflicted apply keeps the record.
    ///
    /// Throws `DiscardRefusal.operationInProgress` (or `.unmerged`) before anything runs for
    /// `.unstaged` and `.stagedAndUnstaged`: an operation cannot take their `stash apply`
    /// (git refuses it over a conflict, and otherwise it rewrites `AUTO_MERGE`; measured, A2
    /// Task 4). `.lines` and `.untracked` undo during an operation too — the forward patch and
    /// the Trash leave its files alone. `DiscardFailure` when step 2 of a staged-side undo
    /// fails.
    func undoDiscard(_ receipt: DiscardReceipt, trasher: any Trasher, at root: URL) async throws
        -> UndoDiscardOutcome
}
