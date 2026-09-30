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
    ///   (`DU`/`UD`/`DD`), a one-sided add (`AU`/`UA`), a symlink, a mode-only add/add, a `merge`
    ///   attribute other than the text driver, a binary stage (`merge-file` exit 255) or a parse
    ///   rebuild that does not split; `.blocks` otherwise, from the **parse rebuild** —
    ///   `merge-file --diff3` at `ConflictParser.safeMarkerSize` of the stages, in worktree form.
    /// - `matchesGitsConflict`: the **compare rebuild** — the user's `merge.conflictStyle`, the
    ///   path's `conflict-marker-size` — in worktree form equals the worktree bytes once both
    ///   lose their marker labels (M 26). false when the file is missing, and for a submodule
    ///   and every whole-file reason but `.unparsable` (there is no rebuild to compare).
    /// - The snapshot carries `file` as given and the SHA-256 of the worktree bytes: a symlink's
    ///   target path, a regular file's content, nil for anything else.
    func conflictDocument(for file: ConflictedFile, at root: URL) async throws -> ConflictDocument
}
