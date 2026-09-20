import Foundation
import GitCore

/// Derived state for the UI: read-only views onto the snapshot and the current selection that
/// the staging and commit extensions, and the views themselves, key their behaviour on.
extension RepositoryStore {

    /// Files with an index-side change. A file changed on both sides appears in both lists.
    ///
    /// An unmerged file counts as staged (`staged == .unmerged`) although its index entry is a
    /// conflict, not a change — which is what the list shows and what the count says. It used
    /// to be load-bearing for keeping `commitButtonTitle` off "Commit All Tracked" mid-merge;
    /// that now follows from `operationInProgress` instead, and holds after the last conflict
    /// is resolved too, which this could never cover.
    var stagedFiles: [FileStatus] {
        snapshot?.status.files.filter { $0.staged != nil } ?? []
    }

    /// Files with a worktree-side change, including untracked ones (`unstaged == .untracked`).
    var unstagedFiles: [FileStatus] {
        snapshot?.status.files.filter { $0.unstaged != nil } ?? []
    }

    /// The merge, cherry-pick, revert, rebase, `git am` or pending squash the repository is
    /// part-way through.
    ///
    /// `RepositoryOperation.blocksUnstaging`, not the presence of conflicts, is what unstaging
    /// is gated on. Resolving and staging the last conflicted file leaves no unmerged entry
    /// behind while the operation is still open, and `git reset` there deletes `MERGE_HEAD`
    /// (or `CHERRY_PICK_HEAD`, `REVERT_HEAD`, or, for a pending squash, `SQUASH_MSG`): the
    /// operation ends silently and the next commit is an ordinary one-parent commit (or, for a
    /// squash, an ordinary commit with no pre-filled message), with nothing on screen to say so.
    ///
    /// The per-file commands are gated on the same state rather than on each file's own, which
    /// is deliberately broader than the harm `git restore --staged` does to any one file:
    ///
    /// - On a still-conflicted file it collapses three index stages into one. Base, ours and
    ///   theirs live only in the index, so that is unrecoverable.
    /// - On a file whose resolution is only *partly* staged it drops the part that was staged.
    ///   The worktree holds the whole resolution, not the half that was in the index, so that
    ///   is unrecoverable too.
    /// - On a fully staged resolution it is in fact harmless: the worktree still holds the
    ///   text and `git add` puts back a byte-identical blob. (Checked, so the rule is not
    ///   defended with a claim that is false.)
    ///
    /// One rule for the whole operation, because a row does not say which of the three it is,
    /// and because two of them cannot be undone.
    var operationInProgress: RepositoryOperation? {
        snapshot?.status.operationInProgress
    }

    /// True while at least one file is still conflicted. Narrower than `operationInProgress`:
    /// it is what the note asks the user to deal with first, not what the gate keys on.
    var hasUnmergedFiles: Bool {
        snapshot?.status.files.contains(where: isUnmerged) ?? false
    }

    /// Whether `file` is one side of an unresolved conflict (`git status` reports both as `U`,
    /// but either alone means "do not unstage this").
    func isUnmerged(_ file: FileStatus) -> Bool {
        file.staged == .unmerged || file.unstaged == .unmerged
    }

    /// The status of the working copy's selected file, if that is what the pane is showing.
    private var selectedWorkingCopyFile: FileStatus? {
        guard selection == .workingCopy, let selectedPath else { return nil }
        return snapshot?.status.files.first { $0.path == selectedPath }
    }

    /// Its diff is `diff --cc` output, which the parser does not match, so the pane comes up
    /// empty and has to explain itself rather than claim there is nothing to see.
    var selectedFileIsUnmerged: Bool {
        selectedWorkingCopyFile.map(isUnmerged) ?? false
    }

    /// Which way hunk- and line-level operations run: the staged side shows what is already in
    /// the index, so acting on it takes changes out again. Derived from `diffIsStaged` rather
    /// than `stagedView`, because the patch is built from the diff that is actually loaded.
    var patchDirection: PatchDirection {
        diffIsStaged ? .unstage : .stage
    }

    var commitButtonTitle: String {
        if draft.amend { return "Amend Commit" }
        // Mid-operation the count is the wrong thing to say, and "Commit All Tracked" is an
        // outright lie: the commit that concludes a merge takes the index as it stands and
        // never sweeps the worktree. See `commit()`.
        if let operation = operationInProgress { return operation.commitButtonTitle }
        switch stagedFiles.count {
        case 0: return "Commit All Tracked"
        case 1: return "Commit 1 File"
        case let count: return "Commit \(count) Files"
        }
    }

    /// True when amending would rewrite a commit that has already been pushed: the branch
    /// tracks an upstream and has nothing of its own ahead of it, so HEAD is the published
    /// commit itself.
    var amendRewritesPublishedHistory: Bool {
        guard draft.amend, let status = snapshot?.status else { return false }
        return status.upstream != nil && status.ahead == 0
    }

    /// Whether the diff currently on screen can be staged or unstaged hunk- or line-wise.
    ///
    /// Beyond what the patch builder supports, the app excludes untracked files (nothing to
    /// patch against) and unmerged ones (their "diff" is a conflict, not a change).
    func canPartiallyStage(_ file: FileDiff) -> Bool {
        guard PatchBuilder.supportsPartial(file, direction: patchDirection),
            let status = selectedWorkingCopyFile
        else { return false }
        return !status.isUntracked && !isUnmerged(status)
    }

    /// Whether this hunk- or line-selection is barred because unstaging it would damage the
    /// operation in progress.
    ///
    /// Only one selection is: the one that covers the entire change of a file being *added*,
    /// on the staged side. `apply` cannot send that through a patch, so it falls back to the
    /// file-level `git restore --staged` — the same command the row's "−" is disabled for, and
    /// gated the same way (`blocksUnstaging`), since it is the very same call. A merge that
    /// adds a file is exactly where this is reachable.
    ///
    /// Everything smaller stays allowed: reverse-applying a patch to the index (`git apply
    /// --cached -R`) was checked against a live merge and leaves `MERGE_HEAD` alone, and
    /// against a pending squash and leaves `SQUASH_MSG` alone too.
    func operationBlocksApplying(_ file: FileDiff, hunkIDs: Set<Hunk.ID>, lineIDs: Set<DiffLine.ID>?)
        -> Bool
    {
        guard operationInProgress?.blocksUnstaging == true, patchDirection == .unstage else {
            return false
        }
        return PatchBuilder.isWholeFileChange(
            file: file, hunkIDs: hunkIDs, lineIDs: lineIDs, direction: .unstage)
    }
}
