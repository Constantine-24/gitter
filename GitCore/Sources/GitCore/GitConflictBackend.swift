import Foundation

/// Reading — and, from A2 Task 2, resolving — a conflicted path.
///
/// The sixth GitCore protocol, apart from `GitWorkingCopyBackend` because a conflict is read
/// from three index stages and rebuilt with `merge-file`, never from the worktree file alone:
/// binary, symlink and mode conflicts leave no markers (M 1), rerere may have replaced them
/// (M 4), and content can hold lines that look exactly like git's markers (M 5).
///
/// Every git vector this protocol's implementation writes is pinned in
/// `ForceFlagScannerTests.allowsTheConflictReadsThisMilestoneNeeds`, and every other shape of
/// `merge-file`, `cat-file` and `check-attr` is a finding.
public protocol GitConflictBackend: Sendable {
    /// The conflict at `file.path`, read for the resolver. Writes nothing but loose blobs (the
    /// two rebuilds, `merge-file --object-id`): the index, the worktree, refs and the
    /// operation's own files are untouched.
    ///
    /// - The **presentation**: `.submodule` for a gitlink; `.wholeFile` for a deletion
    ///   (`DU`/`UD`/`DD`), a one-sided add (`AU`/`UA`), a symlink, a mode-only add/add, a merge
    ///   driver other than git's text merge (an undefined driver name is text, as in git), a
    ///   binary stage (`merge-file` exit 255) or a parse rebuild that does not split into at
    ///   least one block; `.blocks` otherwise, from the **parse rebuild** — `merge-file
    ///   --diff3` at `ConflictParser.safeMarkerSize` of the stages, in worktree form.
    /// - `matchesGitsConflict`: the worktree is what git wrote. True when it equals
    ///   `AUTO_MERGE`'s entry for the path in worktree form (read only while an operation is
    ///   in progress; no entry = no file), or, for a text path, the **compare rebuild** — the
    ///   user's `merge.conflictStyle`, the path's `conflict-marker-size` — both label-normalised
    ///   (M 26); or, for a whole-file path, the stage git leaves there (ours for binary, symlink,
    ///   mode-only, `merge=binary`, UD, AU; theirs for DU, UA; no file for DD). A driver's
    ///   output matches only through `AUTO_MERGE`; a submodule never matches. A stale or absent
    ///   `AUTO_MERGE` can only turn a true into a false.
    /// - The snapshot carries `file` as given and the SHA-256 of the worktree bytes: a symlink's
    ///   target path, a regular file's content, nil for anything else.
    func conflictDocument(for file: ConflictedFile, at root: URL) async throws -> ConflictDocument
}
