import Foundation

/// One untracked item as a discard sheet showed it, and as `discard` stats it again before it
/// moves the item to the Trash.
///
/// Read with `lstat` semantics: a symlink is a symlink (its own size and date), never what it
/// points at. For a directory, `size` is the total size of everything under it and
/// `modificationDate` the latest date of the directory or anything under it — a directory's
/// own date does not move when a file deep inside it is edited. Everything means everything:
/// the Trash takes the directory whole, ignored files in it included.
public struct UntrackedItem: Sendable, Hashable {
    /// Relative to the repository root, as status names it (`ud/` for a directory).
    public let path: String
    public let isDirectory: Bool
    public let size: UInt64
    public let modificationDate: Date

    public init(path: String, isDirectory: Bool, size: UInt64, modificationDate: Date) {
        self.path = path
        self.isDirectory = isDirectory
        self.size = size
        self.modificationDate = modificationDate
    }
}

/// What the sheet showed, which `discard` re-reads and compares before it changes anything
/// (the stale-confirmation rule).
///
/// Build it with `GitWorkingCopyBackend.discardExpectation(tracked:includingStaged:at:)` or
/// `discardExpectation(untracked:at:)`, the very reads `discard` repeats, so that "unchanged"
/// compares like with like. For `.lines` it is the one unstaged `FileDiff` the patch was built
/// from, which is what `discardExpectation(tracked: [path], includingStaged: false, at:)` gives.
public enum DiscardExpectation: Sendable, Hashable {
    /// The diffs the sheet showed, compared whole: every line's text and the blob ids. Three
    /// changes made after the sheet was shown change neither, so they are invisible to this
    /// check, and the record still holds each of them: one only in line endings, one only
    /// through a clean filter, and one only in the executable bit (a `FileDiff` carries no
    /// mode, and a mode-only diff has no hunks and no blob ids to differ).
    case diffs([FileDiff])
    case untracked([UntrackedItem])
}

/// What to discard. Every tracked kind is recorded in the stash list first (`StashRecord`,
/// `Discarded by Gitter: …`); untracked items go to the Trash.
public enum DiscardRequest: Sendable, Hashable {
    /// The unstaged layer of each path: `restore --worktree`. The staged layer stays. Every path
    /// must be in the index.
    case unstaged(paths: [String], expected: DiscardExpectation)
    /// Both layers: `restore --source=HEAD --staged --worktree`. A new file is removed from the
    /// index and from disk (it is in the record); a rename passes both paths and is undone.
    case stagedAndUnstaged(paths: [String], expected: DiscardExpectation)
    /// Some unstaged lines of one modified file: the worktree reverse-apply of `patch`. Build
    /// the patch with `PatchBuilder.discardPatch`; `lineCount` names it in the record.
    case lines(path: String, patch: Patch, lineCount: Int, expected: DiscardExpectation)
    /// Untracked files or directories, moved to the Trash one by one.
    case untracked(paths: [String], expected: DiscardExpectation)

    /// The paths the request names; for `.lines`, its one path.
    public var paths: [String] {
        switch self {
        case .unstaged(let paths, _), .stagedAndUnstaged(let paths, _), .untracked(let paths, _):
            return paths
        case .lines(let path, _, _, _):
            return [path]
        }
    }

    public var expected: DiscardExpectation {
        switch self {
        case .unstaged(_, let expected), .stagedAndUnstaged(_, let expected),
            .lines(_, _, _, let expected), .untracked(_, let expected):
            return expected
        }
    }

    /// The record's message: `Discarded by Gitter: <names>`, at most three names and then
    /// `and N more`, or `Discarded by Gitter: <n> lines in <name>`. git flattens a newline in
    /// a name to a space when it files the message.
    public var recordMessage: String {
        switch self {
        case .lines(let path, _, let count, _):
            return Stash.discardPrefix + "\(count) \(count == 1 ? "line" : "lines") in \(path)"
        case .unstaged(let paths, _), .stagedAndUnstaged(let paths, _), .untracked(let paths, _):
            let shown = paths.prefix(3).joined(separator: ", ")
            let more = paths.count > 3 ? " and \(paths.count - 3) more" : ""
            return Stash.discardPrefix + shown + more
        }
    }
}

/// What a discard did, and what its undo needs.
public struct DiscardReceipt: Sendable, Hashable {
    public let request: DiscardRequest
    /// The entry holding the pre-discard content; nil for untracked items. Its `index` is where
    /// it was filed; the undo finds it again by sha.
    public let record: Stash?
    /// HEAD when the record was made (`W^1`); empty in a repository with no commits.
    public let headAtDiscard: String
    /// Original path (relative to the root) → where the Trash put it. The Trash may rename an
    /// item (M 15), so this URL is the only way to find it again.
    public let trashed: [String: URL]
    /// For `.lines`: the file right after the discard — its bytes, its index entry and HEAD.
    /// The undo reads all three again and refuses unless each is unchanged: a forward patch
    /// finds its context wherever it matches, and in a file that moved on it can put the lines
    /// back in the wrong place (fix rounds 1 and 2, measured). Nil for the other kinds, whose
    /// undo git itself refuses over an edit, and for a `.lines` discard whose state could not
    /// be read afterwards — its undo then refuses.
    public let afterDiscard: DiscardedFileState?
    /// For `.lines`: which form of the record's blob the file's bytes were before the discard —
    /// the only form the undo accepts as "exactly as before" when it decides to drop the record.
    public let recordedForm: RecordedForm?

    public init(
        request: DiscardRequest, record: Stash?, headAtDiscard: String, trashed: [String: URL],
        afterDiscard: DiscardedFileState? = nil, recordedForm: RecordedForm? = nil
    ) {
        self.request = request
        self.record = record
        self.headAtDiscard = headAtDiscard
        self.trashed = trashed
        self.afterDiscard = afterDiscard
        self.recordedForm = recordedForm
    }
}

/// How a file's bytes relate to the blob the record holds for it. A line discard requires the
/// file to be in its checkout form (`checkout`, which is `raw` when checking out converts
/// nothing): a worktree `git apply` writes the whole file back through the checkout
/// conversion, so any other file would have every line's ending rewritten (fix round 3).
public enum RecordedForm: Sendable, Hashable {
    /// The blob's own bytes (`cat-file blob`): no conversion applies to this file.
    case raw
    /// The blob as a checkout writes it (`cat-file --filters`), which differs from the raw
    /// blob: CRLF under `core.autocrlf=true` or `eol=crlf`, or a smudge filter's output.
    case checkout
}

/// One file as a line discard left it, on every layer a later change could move without the
/// file's unstaged diff showing it. An edit that is then staged, or committed, leaves that diff
/// as it was — empty, when the discard took every unstaged change — and so does a change only
/// in line endings; the bytes, the index entry or HEAD do not.
public struct DiscardedFileState: Sendable, Hashable {
    /// The file's bytes on disk.
    public let worktree: Data
    /// `ls-files -s` for the path: mode, blob and stage.
    public let indexEntry: String
    /// HEAD's sha, empty before the first commit.
    public let head: String

    public init(worktree: Data, indexEntry: String, head: String) {
        self.worktree = worktree
        self.indexEntry = indexEntry
        self.head = head
    }
}

/// Why a discard was refused before anything was written: no record, no change, no Trash.
public enum DiscardRefusal: Error, Sendable, Hashable {
    /// The undo of a whole-file discard (`.unstaged`, `.stagedAndUnstaged`) while a merge,
    /// cherry-pick, revert, rebase, `git am` or squash is part-way: its `stash apply` is
    /// refused by git over a conflict and otherwise rewrites `AUTO_MERGE` (measured, A2 Task
    /// 4). The record stays listed, and the undo runs once the operation is concluded. A
    /// discard itself is not refused for an operation (A2; see `partOfOperation`).
    case operationInProgress(RepositoryOperation)
    case unmerged([String])
    case intentToAdd([String])
    case submodules([String])
    case nestedRepositories([String])
    /// A `.lines` discard that has to be a whole-file one: the patch has a context-free hunk,
    /// or the file is binary, renamed, not a plain modification, or not valid UTF-8 — or its
    /// bytes are not its checkout form (see `RecordedForm`), where applying a patch would
    /// rewrite every line's ending. That last check needs the record's blob, so it runs after
    /// the record is filed, and the record is dropped again before this is thrown.
    case needsWholeFile(String)
    /// The file changed after the sheet was shown ("nothing was discarded"): its diff, or the
    /// untracked item's type, size or date, is not what `expected` holds.
    case changedSinceShown([String])
    /// A file and a directory swapped places (`StashRefusal.pathTypeChanged`): what is on disk
    /// is in no record, and the restore would overwrite it.
    case pathTypeChanged([String])
    /// No paths, or nothing changed in them to discard.
    case nothingSelected
    /// A tracked kind named a path git does not track: `.unstaged` needs it in the index,
    /// `.stagedAndUnstaged` in the index or HEAD. An untracked path is discarded as
    /// `.untracked`, to the Trash.
    case notTracked([String])
    /// `.stagedAndUnstaged` during an operation, of paths whose staged side is the operation's
    /// own result: restoring them from HEAD drops that change from the commit the operation
    /// makes — in a rebase, part of the user's own commit (M 21). The paths in
    /// `GitOperationBackend.operationPaths` (Ruling 22: `AUTO_MERGE` alone can be stale), or,
    /// when it cannot tell (a squash with no conflict, an `exec` or `break` stop, M 31), every
    /// named path with a staged change. Their unstaged side can be discarded alone.
    case partOfOperation([String])

    /// The refusal the record's own (`StashRecord`) surfaces as. `stashListChanged` is never
    /// thrown by a record, and has no discard counterpart: nil.
    init?(_ refusal: StashRefusal) {
        switch refusal {
        case .operationInProgress(let operation): self = .operationInProgress(operation)
        case .unmergedPaths(let paths): self = .unmerged(paths)
        case .intentToAdd(let paths): self = .intentToAdd(paths)
        case .submodules(let paths): self = .submodules(paths)
        case .nestedRepositories(let paths): self = .nestedRepositories(paths)
        case .pathTypeChanged(let paths): self = .pathTypeChanged(paths)
        case .nothingSelected: self = .nothingSelected
        case .stashListChanged: return nil
        }
    }
}

/// A discard, or an undo, that stopped part-way after something was written. Nothing is lost:
///
/// - discard, tracked kinds: the record was filed, then the change failed in a way that may
///   have changed the files. `receipt.record` holds the pre-discard content and stays listed.
///   (When the failed change provably changed nothing, the record is dropped again and git's
///   error is thrown as it is — see `GitWorkingCopyBackend.discard`.)
/// - discard, untracked: `receipt.trashed` names every item already in the Trash; undoing the
///   receipt puts them back.
/// - undo, `.stagedAndUnstaged`: the content came back (step 1), but restoring the staged
///   part failed; the record is kept, and holds that staged part.
public struct DiscardFailure: Error, Sendable, Hashable {
    public let receipt: DiscardReceipt
    /// What failed, in git's words where git said something.
    public let gitsWords: String

    public init(receipt: DiscardReceipt, gitsWords: String) {
        self.receipt = receipt
        self.gitsWords = gitsWords
    }
}

/// What an undo did.
public enum UndoDiscardOutcome: Sendable, Hashable {
    /// Back exactly as before the discard, both layers; the record is dropped (or, when the
    /// stash list changed under it, kept and listed — the content is back either way).
    case restored
    /// `.stagedAndUnstaged` after HEAD moved, or after a path's staged side changed since the
    /// discard: the content came back, but the staged split was not restored — that would
    /// stage a reversal of the new commit (M B b), or overwrite the staged edit. The record is
    /// dropped as for `.restored`.
    case restoredUnstaged
    /// Something was put back, but the files cannot be shown to be exactly what the record
    /// holds, so the record is kept and listed rather than dropped. Two ways here:
    /// - `.lines`: the forward patch applied, onto a file whose bytes, index entry and HEAD
    ///   were all as the discard left them — but the file is then neither the record's blob
    ///   nor that blob as a checkout writes it. The worktree holds the file with the lines
    ///   put back where the patch's context sits, and nothing else changed; only a clean
    ///   filter that does not round-trip is known to get here.
    /// - `.unstaged` / `.stagedAndUnstaged`: git applied the record's tracked part but reported
    ///   files it did not restore (`StashApplyOutcome.partiallyApplied`). A record has no
    ///   untracked part, so this is not expected; the worktree then holds whatever that apply
    ///   wrote, and the record holds the pre-discard content.
    case restoredUnverified(recordKept: Stash?)
    /// Nothing changed, because the files were edited since the discard (or git refused for
    /// another reason, given in its words). The record, when there is one, stays listed.
    case refused(String, recordKept: Stash?)
    /// The record went back with conflicts in these paths (a staged edit on the same lines
    /// since the discard, M A.1): the files hold git's markers, and the record stays listed.
    case conflicted([String], recordKept: Stash?)
    /// Untracked items: these could not be put back because a file of that name exists again
    /// (Cocoa error 516, M 15); nothing was overwritten, and they are still in the Trash.
    case partiallyRestored(notRestored: [String])
}
