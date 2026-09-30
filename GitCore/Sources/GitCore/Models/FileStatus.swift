import Foundation

public enum ChangeKind: Sendable, Hashable {
    case modified, added, deleted, renamed, copied, typeChanged, unmerged, untracked, ignored
    case unknown(Character)

    /// Maps a porcelain XY character. '.' returns nil.
    public static func from(porcelain c: Character) -> ChangeKind? {
        // M->modified, A->added, D->deleted, R->renamed, C->copied, T->typeChanged, U->unmerged, '?'->untracked, '!'->ignored, '.'->nil, else unknown(c)
        switch c {
        case "M":
            return .modified
        case "A":
            return .added
        case "D":
            return .deleted
        case "R":
            return .renamed
        case "C":
            return .copied
        case "T":
            return .typeChanged
        case "U":
            return .unmerged
        case "?":
            return .untracked
        case "!":
            return .ignored
        case ".":
            return nil
        default:
            return .unknown(c)
        }
    }
}

public struct FileStatus: Sendable, Hashable, Identifiable {
    public let path: String
    public let originalPath: String?     // for renames/copies
    public let staged: ChangeKind?       // index side (X). nil when unchanged.
    public let unstaged: ChangeKind?     // worktree side (Y). nil when unchanged.

    /// A submodule (gitlink): porcelain v2's `sub` field begins with `S`. Stash ignores one
    /// (M 14), so stash and discard refuse it.
    public let isSubmodule: Bool
    /// An entry added with `git add -N`: in the index with no content yet. A record would turn
    /// it into a staged empty file (M A.0), so stash and discard refuse it.
    public let isIntentToAdd: Bool
    /// An untracked directory (`? dir/`) that holds a `.git` of its own — another repository,
    /// whose files git will not look inside (M 4, 16). Set by the backend, which stats the
    /// directory: porcelain v2 does not say.
    public let isNestedRepository: Bool
    /// The `u` record's kind and stages; nil for every path that is not unmerged. `staged` and
    /// `unstaged` stay `.unmerged` for such a path, so every existing check keeps working.
    public let conflict: ConflictedFile?

    public var id: String { path }
    public var isUntracked: Bool { unstaged == .untracked }

    /// The same entry with `isNestedRepository` set.
    func with(isNestedRepository: Bool) -> FileStatus {
        FileStatus(
            path: path, originalPath: originalPath, staged: staged, unstaged: unstaged,
            isSubmodule: isSubmodule, isIntentToAdd: isIntentToAdd,
            isNestedRepository: isNestedRepository, conflict: conflict)
    }

    public init(
        path: String, originalPath: String?, staged: ChangeKind?, unstaged: ChangeKind?,
        isSubmodule: Bool = false, isIntentToAdd: Bool = false, isNestedRepository: Bool = false,
        conflict: ConflictedFile? = nil
    ) {
        self.path = path
        self.originalPath = originalPath
        self.staged = staged
        self.unstaged = unstaged
        self.isSubmodule = isSubmodule
        self.isIntentToAdd = isIntentToAdd
        self.isNestedRepository = isNestedRepository
        self.conflict = conflict
    }
}

/// A multi-step git operation the repository is part-way through.
///
/// None of these can be read off the index: once the last conflict is resolved and staged, the
/// status has no unmerged entry left while the operation is still open. Each is recorded in the
/// git directory instead — and each is lost or damaged by `git reset`, which is why the app
/// asks about them at all.
///
/// `applyingPatches` is `git am`, kept apart from `rebase` although the two share the
/// `rebase-apply/` directory: git refuses `git rebase --abort` while an `am` is running
/// ("It looks like 'git am' is in progress"), so advice that named a rebase would be a dead
/// end.
///
/// `squash` is a `git merge --squash` that has staged its combined changes but not yet been
/// committed. Unlike the other five it has no pseudo-ref of its own (`git status` calls it
/// ordinary staged content), so it is found by `.git/SQUASH_MSG` instead — and checked *last*,
/// after all the others: a leftover `SQUASH_MSG` from an earlier, never-committed squash can in
/// principle sit next to a real merge/cherry-pick/revert/rebase/am, and the operation the user
/// is actually in the middle of has to win. (Reproducing that exact combination through git
/// commands alone turns out not to be possible — starting a second merge while a squash is
/// still staged is refused, "Your local changes... would be overwritten by merge" — so the test
/// for it fabricates the leftover file by hand; see `squashLeftoverDoesNotMaskARealMerge`.)
public enum RepositoryOperation: Sendable, Hashable {
    case merge, cherryPick, revert, rebase, applyingPatches, squash

    /// Whether unstaging while this operation is in progress can silently damage or end it —
    /// what `RepositoryStore`'s "Unstage All" and per-file unstage gates key on.
    ///
    /// True for the first five: plain `git reset` (what "Unstage All" runs) deletes their
    /// pseudo-ref outright, ending the operation with nothing on screen to say so, and on a
    /// still-conflicted file it also collapses the index's three merge stages into one —
    /// unrecoverable.
    ///
    /// `squash` looks safe at first glance, and two of the three commands "unstage" can run
    /// during it really are: verified in a scratch repo, `git restore --staged <path>` (the
    /// per-file unstage, even given *every* staged path at once) and `git apply --cached -R`
    /// (hunk/line unstage) both leave `.git/SQUASH_MSG` untouched. But "Unstage All" does not
    /// use either of those — it runs plain `git reset -q` — and *that*, verified the same way,
    /// deletes `SQUASH_MSG` even though the worktree keeps every line unstaged rather than
    /// discarded.
    ///
    /// Two things go with it, and only the first is Gitter's own. `SQUASH_MSG` is *the* marker
    /// a pending squash is detected by (there is no pseudo-ref), so deleting it ends the
    /// squash as far as the app can tell: the note, the "Commit Squash" button and "Undo
    /// Squash…" all vanish, the staged changes stay staged with nothing to say where they came
    /// from, and the next commit is an ordinary one. The second is a loss only outside Gitter:
    /// with the file present, a plain `git commit` *in a terminal* opens pre-filled with
    /// "Squashed commit of the following:" and the squashed commits' own messages (verified on
    /// git 2.54 by capturing `COMMIT_EDITMSG` from a fake `GIT_EDITOR`). Gitter never shows
    /// that text — every commit it makes passes `-F <the draft>`, so the composer is whatever
    /// the user typed — so this half is not a loss the app could have shown either way. It is
    /// recorded because the state does not belong to Gitter alone.
    ///
    /// Since this one property gates both the safe commands and the destructive one, the
    /// destructive one decides it — contrary to this milestone's design doc, which expected
    /// `git reset -q` to leave `SQUASH_MSG` alone and marked that expectation itself as
    /// something to verify before relying on it.
    public var blocksUnstaging: Bool {
        switch self {
        case .merge, .cherryPick, .revert, .rebase, .applyingPatches, .squash: return true
        }
    }
}

public struct WorkingCopyStatus: Sendable, Hashable {
    public let headSha: String?          // nil in an empty repo ("(initial)")
    public let branch: String?           // nil when detached ("(detached)")
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let files: [FileStatus]
    /// Set by the backend, not by `StatusParser`: porcelain v2 does not report it.
    public let operationInProgress: RepositoryOperation?

    public init(
        headSha: String?, branch: String?, upstream: String?, ahead: Int, behind: Int,
        files: [FileStatus], operationInProgress: RepositoryOperation? = nil
    ) {
        self.headSha = headSha
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
        self.operationInProgress = operationInProgress
    }

    /// The same status with `files` replaced — how the backend adds what only the file system
    /// can say (`FileStatus.isNestedRepository`).
    func with(files: [FileStatus]) -> WorkingCopyStatus {
        WorkingCopyStatus(
            headSha: headSha, branch: branch, upstream: upstream, ahead: ahead, behind: behind,
            files: files, operationInProgress: operationInProgress
        )
    }

    /// The same status with `operationInProgress` replaced — how the backend completes what
    /// the parser could not know.
    public func with(operationInProgress: RepositoryOperation?) -> WorkingCopyStatus {
        WorkingCopyStatus(
            headSha: headSha, branch: branch, upstream: upstream, ahead: ahead, behind: behind,
            files: files, operationInProgress: operationInProgress
        )
    }

    public static let empty = WorkingCopyStatus(headSha: nil, branch: nil, upstream: nil, ahead: 0, behind: 0, files: [])
}
