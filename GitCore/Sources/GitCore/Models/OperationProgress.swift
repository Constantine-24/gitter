import Foundation

/// A commit an operation names: the one it stopped on, the one a rebase replays onto, the one a
/// merge brings in.
public struct CommitRef: Sendable, Hashable {
    /// The full object id.
    public let sha: String
    /// The first line of its message.
    public let subject: String

    public init(sha: String, subject: String) {
        self.sha = sha
        self.subject = subject
    }
}

/// Where a stopped operation is (M 16), read from the files git keeps for it — never counted
/// from Gitter's own memory, so a stop made in a terminal reads the same.
///
/// - A rebase has "step k of N": `rebase-merge/msgnum` / `end` (update-ref steps count, M 18),
///   the branch it will update (`head-name`) and the commit it replays onto (`onto`).
/// - A cherry-pick or revert **range** has only "N remaining": `sequencer/todo`, which lists the
///   current commit first. There is no total on disk, and a single pick or revert has no
///   `sequencer/` at all (`remaining` nil).
/// - A merge has `MERGE_HEAD`, and the name `MERGE_MSG`'s first line gives it (M 26).
public struct OperationProgress: Sendable, Hashable {
    public let operation: RepositoryOperation
    /// Rebase only: `rebase-merge/msgnum`, 1-based.
    public let step: Int?
    /// Rebase only: `rebase-merge/end`.
    public let total: Int?
    /// Cherry-pick / revert range only: the commands in `sequencer/todo`, the current one
    /// included.
    public let remaining: Int?
    /// The commit git stopped on: `REBASE_HEAD`, `CHERRY_PICK_HEAD` or `REVERT_HEAD` (for a
    /// revert, the commit being reverted). Nil at a rebase stop with no commit pending — a
    /// failed `exec`, a `break`.
    public let current: CommitRef?
    /// Rebase only: `rebase-merge/head-name` without `refs/heads/`; nil for a detached rebase.
    public let headName: String?
    /// Rebase only: `rebase-merge/onto`.
    public let onto: CommitRef?
    /// Merge only: `MERGE_HEAD`.
    public let mergeHead: CommitRef?
    /// Merge only: the branch, tag or remote-tracking branch `MERGE_MSG`'s first line names —
    /// `Merge branch 'x'`, `Merge tag 'v1'`, `Merge remote-tracking branch 'origin/x'`, each
    /// optionally followed by ` into <branch>`. Nil for anything else: `-m`, a commit, a
    /// `(early part)`, a fetched branch `of <url>` (M 26: the name is not recoverable there).
    public let mergedName: String?

    public init(
        operation: RepositoryOperation, step: Int? = nil, total: Int? = nil, remaining: Int? = nil,
        current: CommitRef? = nil, headName: String? = nil, onto: CommitRef? = nil,
        mergeHead: CommitRef? = nil, mergedName: String? = nil
    ) {
        self.operation = operation
        self.step = step
        self.total = total
        self.remaining = remaining
        self.current = current
        self.headName = headName
        self.onto = onto
        self.mergeHead = mergeHead
        self.mergedName = mergedName
    }
}

/// The message git has prepared for the commit an operation will make, as the composer should
/// show it: comment lines removed, trailing blank lines trimmed.
public struct PendingMessage: Sendable, Hashable {
    /// The prepared message without its comment lines (and no final newline).
    public let text: String
    /// The comment character git uses for this message: `core.commentChar` (or
    /// `core.commentString`, whichever is set last), `#` by default, and under `auto` the one git
    /// would choose for this text. For a multi-character comment string, its first character —
    /// `text` was stripped with the whole string.
    public let commentChar: Character

    public init(text: String, commentChar: Character) {
        self.text = text
        self.commentChar = commentChar
    }
}

/// Whether `continueOperation` would run.
public enum ContinueReadiness: Sendable, Hashable {
    /// No path is unmerged and the stopped commit's result differs from HEAD (or no commit is
    /// pending: a rebase's `exec` / `break` / `edit` stop).
    case ready
    /// These paths are still unmerged; git would refuse (M 14).
    case unresolved([String])
    /// Nothing is unmerged and the stopped commit's result equals HEAD (M 30): a rebase would
    /// drop the commit without a word, and a cherry-pick or revert refuses (exit 1). Continue is
    /// allowed for a rebase only, after the UI has said the commit will be left out; Skip is the
    /// way on for the other two. Judged on the operation's own paths (`operationPaths`; the
    /// whole index without `AUTO_MERGE`): an unrelated staged file does not make the result
    /// non-empty — git would commit it alone under the stopped commit's title (fix round 1).
    case emptyResult
    /// Tracked files whose worktree differs from the index (not unmerged). A rebase refuses any
    /// of them (exit 1, "You must edit all merge conflicts…"); a cherry-pick or revert range
    /// commits the current commit and then refuses the next one that touches such a file,
    /// stranding the sequence (M 17). A single pick or revert keeps them, so it is not blocked.
    case unstagedChanges([String])
    /// Staged paths that are not the operation's (neither unmerged nor among `operationPaths`):
    /// git commits them into the stopped commit. Continue needs them acknowledged, by name.
    /// Not judged without `AUTO_MERGE` (a rebase's `exec` / `break` stop refuses staged changes
    /// itself; at an `edit` stop amending is the point).
    case otherStagedChanges([String])
    /// No rebase, cherry-pick or revert is in progress (a merge and a squash conclude with
    /// Commit; `git am` is abort-only).
    case notContinuable
}

/// What a continue (or a skip) left.
public enum ContinueOutcome: Sendable, Hashable {
    /// Exit 0, no operation in progress, nothing unmerged.
    case finished
    /// The operation stopped again, on another commit or step (a conflict in the next commit,
    /// usually); the new position.
    case stoppedAgain(OperationProgress)
    /// The operation ended but left these paths unmerged: a rebase's autostash that conflicted
    /// when it was applied back (M 18). The changes are safe in the stash list.
    case finishedWithConflicts([String])
    /// git refused or failed and the operation is where it was — a hook, a signing failure,
    /// unstaged changes during a rebase (M 14, M 18, Task 3's RF5) — or it ended with an error.
    /// Everything git wrote, stderr then stdout, trimmed.
    case failed(gitsWords: String)
    /// A cherry-pick or revert range made a commit and then refused the next one (local changes
    /// or untracked files it would overwrite): `sequencer/` is left with no `CHERRY_PICK_HEAD` /
    /// `REVERT_HEAD`, so no operation is detected, and a later `--continue` would end the
    /// sequence silently, dropping the rest (M 17). Everything git wrote, stderr then stdout.
    case sequenceHalted(gitsWords: String)
}

/// Whether `skip` would run.
public enum SkipReadiness: Sendable, Hashable {
    /// Every tracked change belongs to the stopped commit (unmerged, or among `operationPaths`);
    /// `paths` are the ones Skip files first and git then discards — both names of a rename.
    case ready(paths: [String])
    /// These tracked changes are not the stopped commit's: `rebase --skip` would reset them
    /// (M 17), and a cherry-pick or revert range could collide with them and silently drop the
    /// rest of the sequence. Skip is refused until they are committed, stashed or discarded.
    case otherChanges([String])
    /// The stopped commit's paths git cannot reset as they stand (fix round 1, measured): an
    /// untracked file at one of them (a path the commit deleted, recreated), refused by all
    /// three; and for a cherry-pick or revert, one whose worktree differs from its index entry
    /// ("Entry 'p' not uptodate. Cannot merge.", exit 128). Stage or remove them first.
    case needsCleanPaths([String])
    /// No rebase, cherry-pick or revert is in progress, or a rebase has no commit pending — an
    /// `exec`, `break` or `edit` stop, where `rebase --skip` skips nothing (Ruling 19).
    case notSkippable
}

/// What a skip left, and the entry it filed first (nil when there was nothing to file).
public struct SkipOutcome: Sendable, Hashable {
    public let outcome: ContinueOutcome
    public let recorded: Stash?

    public init(outcome: ContinueOutcome, recorded: Stash?) {
        self.outcome = outcome
        self.recorded = recorded
    }
}

/// Why a continue or skip refused before running git.
public enum OperationError: Error, Sendable, Hashable {
    /// The repository is not in the operation the UI showed (it ended, or another began, in a
    /// terminal).
    case operationMismatch(expected: RepositoryOperation, found: RepositoryOperation?)
    /// The operation is no longer stopped on the commit the UI showed.
    case stoppedCommitChanged
    /// The message has nothing left once git's cleanup removes what it removes.
    case emptyMessage
    /// `continueReadiness` does not allow it.
    case notReady(ContinueReadiness)
    /// `skipReadiness` does not allow it.
    case skipRefused(SkipReadiness)
}
