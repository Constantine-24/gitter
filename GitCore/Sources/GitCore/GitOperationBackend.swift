import Foundation

/// Where a stopped operation is, and the two ways on from a stop: Continue and Skip.
///
/// The seventh GitCore protocol. Continue and Skip are offered for a rebase, a cherry-pick and a
/// revert only; a merge and a squash conclude with Commit, and `git am` stays abort-only. Every
/// read is of the files git keeps (M 16) and every git vector is pinned in
/// `ForceFlagScannerTests.allowsTheContinueAndSkipVectorsThisMilestoneNeeds`; `--skip` is
/// permitted in exactly its three whole vectors.
///
/// Both writes re-detect the operation as `abort` does and throw
/// `OperationError.operationMismatch` before running anything when it is not the one the UI
/// showed. Neither runs git while its readiness says no.
public protocol GitOperationBackend: Sendable {
    /// Where the operation in progress is; nil when none is. A squash and `git am` report only
    /// their `operation`.
    func operationProgress(at root: URL) async throws -> OperationProgress?

    /// The message git prepared for the operation's next commit, comment lines removed with
    /// the comment character git would use for it (`core.commentChar`/`core.commentString`,
    /// `#` by default; under `auto`, git's own choice for this text) and trailing blank lines
    /// trimmed. Rebase: `rebase-merge/message`; cherry-pick, revert and merge: `MERGE_MSG`;
    /// squash: `SQUASH_MSG`. Nil with no operation, for `git am`, or when the file does not
    /// exist (a rebase's `exec` or `break` stop).
    func pendingMessage(at root: URL) async throws -> PendingMessage?

    /// Every path the operation's own result changes against HEAD — `diff --name-only -z
    /// --no-renames HEAD AUTO_MERGE`, both sides of a rename (M 31). Read only while an
    /// operation is in progress: `AUTO_MERGE` outlives a clean finish and a `stash apply`
    /// writes one with no operation at all. Nil with no operation or no `AUTO_MERGE` (a
    /// `git am` stop, a rebase's `exec` / `break` stop).
    func operationPaths(at root: URL) async throws -> [String]?

    /// Whether `continueOperation` would run; see `ContinueReadiness`.
    func continueReadiness(at root: URL) async throws -> ContinueReadiness

    /// Continues the rebase, cherry-pick or revert the UI showed as `expected`.
    ///
    /// Refuses, running nothing: `.operationMismatch`; `.notReady` unless the readiness is
    /// `.ready`, or `.emptyResult` for a rebase (the UI has said the commit will be left out,
    /// M 30); `.emptyMessage` when the message is empty after git's cleanup. The message goes
    /// only where git has a pending one (`rebase-merge/message`, `MERGE_MSG`), written in place
    /// before git runs; with none (a rebase's `exec` / `break` stop) `message` is not used.
    /// `nil` means git's own prepared message: a rebase gets it back without its comment lines
    /// (it continues under `commit.cleanup=scissors`, which would keep them, M 29); a
    /// cherry-pick or revert leaves the file as git wrote it and strips it itself.
    ///
    /// Runs `rebase|cherry-pick|revert --continue`, the rebase with `commit.cleanup=scissors`
    /// for this one command (M 29): git's editor template is dropped, the user's own
    /// comment-character lines are kept. A cherry-pick or revert strips them whatever the
    /// setting (measured, A2 Task 3). Then reads the repository again: see `ContinueOutcome`.
    func continueOperation(_ expected: RepositoryOperation, message: String?, at root: URL) async throws -> ContinueOutcome

    /// Whether `skip` would run: every path with a tracked change (staged, unstaged or
    /// unmerged; untracked files are not touched by any skip, M 17) must be unmerged or one of
    /// `operationPaths` — with no `AUTO_MERGE`, unmerged only. Renames count by both names.
    func skipReadiness(at root: URL) async throws -> SkipReadiness

    /// Skips the commit the operation stopped on.
    ///
    /// Refuses, running nothing: `.operationMismatch`; `.stoppedCommitChanged` unless the
    /// current commit (`OperationProgress.current`) is `sha` — so never at a stop with no
    /// current commit; `.skipRefused` unless `skipReadiness` is `.ready`. Then files the ready
    /// paths — the partial resolution included, unmerged paths as their worktree bytes — as
    /// `Skipped by Gitter: <short sha> <subject>` (none filed when there are no paths), runs
    /// `rebase|cherry-pick|revert --skip`, and reads the repository again as
    /// `continueOperation` does. With only the stopped commit's changes present, every skip
    /// returns the tree to HEAD (M 32).
    func skip(_ expected: RepositoryOperation, stoppedAt sha: String, at root: URL) async throws -> SkipOutcome
}
