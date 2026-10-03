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

    /// Every path the operation's own result changes against HEAD, both sides of a rename
    /// (M 31) — a superset (Ruling 22): ort's `AUTO_MERGE` diff unless detectably stale, the
    /// paths the operation's source commits change (`MERGE_HEAD` since its merge bases, the
    /// commits `SQUASH_MSG` lists, the picked, reverted or replayed commit — a merge commit
    /// against its mainline — `git am`'s current patch), and the unmerged paths.
    /// `AUTO_MERGE` is read only while an operation is in progress, and alone it is not
    /// enough: only ort writes it, so a `-s resolve` or octopus stop sits over a stale one.
    /// When the source cannot be read — a squash whose `SQUASH_MSG` lists no commit, a rebase's
    /// `exec` / `break` / `edit` stop, any source read that fails (a missing commit named in
    /// `SQUASH_MSG` or `MERGE_HEAD`) — the `AUTO_MERGE` diff and the unmerged paths when a text
    /// conflict shows `AUTO_MERGE` fresh, else nil. Nil with no operation. A failed source read
    /// never throws.
    func operationPaths(at root: URL) async throws -> [String]?

    /// Whether `continueOperation` would run; see `ContinueReadiness`.
    func continueReadiness(at root: URL) async throws -> ContinueReadiness

    /// Continues the rebase, cherry-pick or revert the UI showed as `expected`.
    ///
    /// Refuses, running nothing, each on its own (not only the first the readiness names):
    /// `.operationMismatch`; `.notReady(.notContinuable)`; `.notReady(.unresolved)`;
    /// `.notReady(.emptyResult)` for a cherry-pick or revert (a rebase may go on, after the UI
    /// has said the commit will be left out, M 30); `.notReady(.unstagedChanges)`;
    /// `.notReady(.otherStagedChanges(current))` unless `acknowledgingOtherStaged` is exactly
    /// the current set of other staged paths (as a set; an empty one when there are none) — a
    /// list rather than a yes, so a file staged or unstaged between the confirmation and the run
    /// is refused; `.emptyMessage` when the message is empty after git's cleanup. The message goes
    /// only where git has a pending one (`rebase-merge/message`, `MERGE_MSG`), written in place
    /// before git runs; with none (a rebase's `exec` / `break` stop) `message` is not used.
    /// `nil` means git's own prepared message: a rebase gets it back without its comment lines
    /// (it continues under `commit.cleanup=scissors`, which would keep them, M 29); a
    /// cherry-pick or revert leaves the file as git wrote it and strips it itself.
    ///
    /// Runs `rebase|cherry-pick|revert --continue`, the rebase with `commit.cleanup=scissors`
    /// for this one command (M 29): git's editor template is dropped, the user's own
    /// comment-character lines are kept. A cherry-pick or revert strips them whatever the
    /// setting (measured, A2 Task 3). A revert's carries `--no-reference` (final review I1):
    /// `sequencer/opts` does not keep it, and under `revert.reference=true` the rest of a range
    /// would get git's placeholder subject. Then reads the repository again: see `ContinueOutcome`
    /// (`.sequenceHalted` when a pick or revert range made a commit and stranded the rest).
    func continueOperation(
        _ expected: RepositoryOperation, message: String?, acknowledgingOtherStaged: [String], at root: URL
    ) async throws -> ContinueOutcome

    /// Whether `skip` would run. `.notSkippable` with no rebase, pick or revert, and for a rebase
    /// with no commit pending (`exec`, `break`, `edit` stop; Ruling 19). `.otherChanges` unless
    /// every path with a tracked change (staged, unstaged or unmerged; untracked files are not
    /// touched by any skip, M 17) is unmerged or one of `operationPaths` — when that is nil,
    /// unmerged only; renames count by both names. `.needsCleanPaths` for those of them git
    /// would refuse to reset: an untracked file at the path (all three), or — for a pick or
    /// revert — a worktree that differs from a non-unmerged index entry (fix round 1).
    func skipReadiness(at root: URL) async throws -> SkipReadiness

    /// Skips the commit the operation stopped on.
    ///
    /// Refuses, running nothing and filing nothing: `.operationMismatch`;
    /// `.skipRefused(.notSkippable)`; `.stoppedCommitChanged` unless the current commit
    /// (`OperationProgress.current`) is `sha`; `.skipRefused` unless `skipReadiness` is
    /// `.ready`. Readiness is decided before anything is filed. Then files the ready
    /// paths — the partial resolution included, unmerged paths as their worktree bytes — as
    /// `Skipped by Gitter: <short sha> <subject>` (none filed when there are no paths), runs
    /// `rebase|cherry-pick --skip` or `revert --skip --no-reference` (as `continueOperation`'s
    /// revert), and reads the repository again as
    /// `continueOperation` does. With only the stopped commit's changes present, every skip
    /// returns the tree to HEAD (M 32).
    func skip(_ expected: RepositoryOperation, stoppedAt sha: String, at root: URL) async throws -> SkipOutcome

    /// A cherry-pick or revert range git left halted with no operation (`HaltedSequence`): what
    /// `.sequenceHalted` leaves, and what a later `--continue` would partly drop. Nil while any
    /// operation is in progress, with no `sequencer/todo`, or with no pick/revert line in it.
    func haltedSequence(at root: URL) async throws -> HaltedSequence?

    /// The halted range's list when a single cherry-pick or revert is stopped over it (Ruling
    /// 29, measured): `sequencer/todo` exists and its first line is not the commit the
    /// pseudo-ref (`CHERRY_PICK_HEAD` / `REVERT_HEAD`) names, or not the same command. At a
    /// genuine range stop — first, middle or last — it always is. Nil otherwise, and with no
    /// cherry-pick or revert in progress. Continue, Skip and Abort refuse while it is non-nil
    /// (`OperationError.staleSequence`).
    func staleSequence(at root: URL) async throws -> HaltedSequence?

    /// The commits a cherry-pick or revert range has already made in this run, oldest first,
    /// which its `--abort` takes off the branch (final review I2, measured on git 2.54): the range
    /// wrote `sequencer/head` (HEAD when it began) and keeps `sequencer/abort-safety` at the last
    /// commit it made, and `--abort` resets to `sequencer/head` only while HEAD is
    /// `abort-safety` — HEAD moved since, it warns "You seem to have moved HEAD. Not rewinding"
    /// and keeps every commit. So: `sequencer/head..HEAD` when HEAD is `abort-safety` and not
    /// `sequencer/head`; empty at the range's first stop, for a single pick or revert (git writes
    /// no `sequencer/` for one), with HEAD moved, and for any other operation. The commits stay
    /// in git's reflog. Reads only.
    func commitsAbortRemoves(at root: URL) async throws -> [CommitRef]
}

extension GitOperationBackend {
    /// `continueOperation` with nothing acknowledged: refused while any other staged path
    /// exists.
    public func continueOperation(
        _ expected: RepositoryOperation, message: String?, at root: URL
    ) async throws -> ContinueOutcome {
        try await continueOperation(expected, message: message, acknowledgingOtherStaged: [], at: root)
    }
}
