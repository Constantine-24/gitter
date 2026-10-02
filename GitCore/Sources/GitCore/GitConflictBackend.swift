import Foundation

/// Reading and resolving a conflicted path.
///
/// The sixth GitCore protocol, apart from `GitWorkingCopyBackend` because a conflict is read
/// from three index stages and rebuilt with `merge-file`, never from the worktree file alone:
/// binary, symlink and mode conflicts leave no markers (M 1), rerere may have replaced them
/// (M 4), and content can hold lines that look exactly like git's markers (M 5).
///
/// Every git vector this protocol's implementation runs is pinned in
/// `ForceFlagScannerTests.allowsTheConflictReadsThisMilestoneNeeds` and
/// `allowsTheConflictWritesThisMilestoneNeeds`, and every other shape of `merge-file`,
/// `cat-file`, `check-attr`, `restore` and `rm` is a finding.
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
    ///   output matches only through `AUTO_MERGE`; a submodule never matches. An absent
    ///   `AUTO_MERGE` (a `merge -s resolve` stop writes none) can only turn a true into a false.
    ///   A leftover one (a `stash apply`'s, a clean pick's, read at a `-s resolve` or octopus
    ///   stop that writes none) is not read when provably stale — a text conflict exists and it
    ///   differs from HEAD at none of them (Ruling 24); otherwise it can still be read, and is
    ///   equal only when the worktree holds that earlier result for this very path.
    /// - The snapshot carries `file` as given and the SHA-256 of the worktree bytes: a symlink's
    ///   target path, a regular file's content, nil for anything else.
    func conflictDocument(for file: ConflictedFile, at root: URL) async throws -> ConflictDocument

    // MARK: - Writes (A2 Task 2)
    //
    // Every write first re-reads the path's index entries and worktree bytes and throws
    // `ConflictError.changedSinceShown` when they are not the snapshot's, and
    // `.pathTypeChanged` when a directory stands at the path or a leading component is a file:
    // nothing is written then. Bytes git did not write (`ConflictDocument.matchesGitsConflict == false`, read
    // again at the write) are filed first as a `Replaced by Gitter: <path>` stash entry — or,
    // with `recordIfEdited == false`, refused with `.wouldReplaceEdits`. A missing worktree
    // file has no bytes to file. A submodule gets `.notAvailable` from every write. None
    // needs an operation in progress (a `stash apply` leaves conflicts too, M 18) except
    // `reopen`. The operation's own files are never written; only the index entry of the
    // path, its worktree file and, for a record, `refs/stash` change.

    /// Resolves a text conflict block by block: the parse rebuild's segments (worktree form)
    /// with each block replaced by `choices[i]` (`.oursThenTheirs` = ours' bytes then theirs'),
    /// the file ending as the last side written ends in its stage (merge-file gives every side
    /// a final line terminator, Ruling 9) — so all-ours is stage 2's blob and all-theirs stage
    /// 3's — written over the file in place — the executable bit survives (M 9) — then `add`.
    /// `.notAvailable` unless the document is `.blocks`; `.choicesDoNotMatch` unless there is
    /// one choice per block.
    func resolve(_ snapshot: ConflictSnapshot, choices: [BlockChoice], recordIfEdited: Bool, at root: URL) async throws -> ConflictReceipt

    /// The whole file as one side has it: `restore --ours|--theirs`, then `add` — byte-exact
    /// under filters and end-of-line conversion, and for binary, symlink and mode-only
    /// conflicts (M 27). `.stageMissing` when the side has no stage (git would delete the file
    /// and exit 0, M 27): that choice is `delete`.
    func take(_ side: ConflictSide, _ snapshot: ConflictSnapshot, recordIfEdited: Bool, at root: URL) async throws -> ConflictReceipt

    /// Resolves the path as deleted: `rm -q`, the file removed. Any kind but a submodule.
    func delete(_ snapshot: ConflictSnapshot, recordIfEdited: Bool, at root: URL) async throws -> ConflictReceipt

    /// Resolves a deletion conflict by keeping the file: `UD` → `add` of what is there (the
    /// surviving stage, `restore --ours` first only when the file is missing); `DU` → `add`
    /// when the worktree holds stage 3 in worktree form, else `restore --theirs` then `add`
    /// (M 28). `.notAvailable` on any other kind.
    func keep(_ snapshot: ConflictSnapshot, recordIfEdited: Bool, at root: URL) async throws -> ConflictReceipt

    /// How many conflict blocks git still finds in the worktree file of an **unmerged** path:
    /// `diff --check` (M 10) — markers at the path's `conflict-marker-size` only, and not the
    /// lines a stage itself holds (M 5). 0 for a resolved path (its check is worktree against
    /// index).
    func leftoverMarkers(in path: String, at root: URL) async throws -> Int

    /// Stages the worktree as it is (`add`). Throws `.leftoverMarkers(n)` and writes nothing
    /// when `leftoverMarkers` is not 0, unless `allowingMarkers`. Records nothing: the worktree
    /// is what gets staged.
    func markResolved(_ snapshot: ConflictSnapshot, allowingMarkers: Bool, at root: URL) async throws

    /// Whether `reopen` can bring the conflict back: an operation is in progress, the path is
    /// one of its own (unmerged or among `GitOperationBackend.operationPaths` — so never when
    /// that is nil; Ruling 13, a record outlives the operation that made it), the path is
    /// resolved (a stage-0 entry, so not by `rm`), and its resolve-undo record holds stages 2
    /// and 3 of regular files — what `restore --merge` needs (M 11, M 24). Not a symlink or a
    /// gitlink: git would write the marker text as the link's target.
    func canReopen(_ path: String, at root: URL) async throws -> Bool

    /// Brings a resolved conflict back — `restore --merge`: the stages and markers labelled
    /// `ours` / `base` / `theirs` (M 25) — after filing the current resolution (index entry and
    /// worktree bytes) as a `Reopened by Gitter: <path>` entry, always. `.changedSinceShown`
    /// when the worktree's hash is not `expectingWorktreeHash` (nil = no file);
    /// `.notAvailable` when `canReopen` is false.
    func reopen(_ path: String, expectingWorktreeHash: String?, at root: URL) async throws -> ConflictReceipt

    /// What `reopen` would put in the worktree, read from the path's resolve-undo record and
    /// attributes — so a confirmation can say it. Nil when there is no record with stages 2 and 3.
    /// Reads only (`ls-files --resolve-undo`, `check-attr`, `config --get`, `cat-file blob`).
    func reopenedFile(_ path: String, at root: URL) async throws -> ReopenedFile?
}

/// What `restore --merge` writes for a reopened path (measured on git 2.54, A2 Task 5 fix
/// round 1). In every case the stages come back and the path is unmerged again.
public enum ReopenedFile: Sendable, Hashable {
    /// Text: git's conflict markers, labelled `ours` / `base` / `theirs`.
    case markers
    /// A binary stage (a NUL in the first 8 000 bytes): stage 2's bytes and no markers — git
    /// warns "Cannot merge binary files" and exits 0.
    case oursVersion
    /// Stage 2's bytes and no markers too, but because git is told not to merge the path — its
    /// `merge` attribute is unset (`-merge`, or the `binary` macro) or `binary` (`merge=binary`,
    /// or `merge.default=binary`) — whatever its content (final review L170: text too). The
    /// value is the attribute as `check-attr` reads it: `unset` or `binary`.
    case oursByAttribute(String)
    /// A mode-only add/add (stages 2 and 3 hold the same blob): the content stays and the mode
    /// goes back to stage 2's.
    case oursMode
    /// A merge driver the user defined (or `union`): whatever it writes.
    case driver(String)
}

/// Why a conflict write refused. Each names the path it was asked about.
public enum ConflictError: Error, Sendable, Hashable {
    /// The stages or the worktree hash differ from the snapshot the UI showed.
    case changedSinceShown(String)
    /// The worktree holds bytes git did not write; retry with `recordIfEdited` to file them.
    case wouldReplaceEdits(String)
    /// The side taken has no stage (`take(.theirs)` on `UD`, `take(.ours)` on `DU`).
    case stageMissing(String, ConflictSide)
    /// Not offered for this path: blocks on a whole-file path, a submodule, `keep` on a kind
    /// that deletes nothing, `reopen` without a record or an operation.
    case notAvailable(String)
    /// The number of choices is not the number of blocks.
    case choicesDoNotMatch(String)
    /// `markResolved` found this many blocks still marked.
    case leftoverMarkers(Int)
    /// The path is no longer a file, a symlink or nothing — a directory stands there, or a
    /// leading component is a file — so git would delete what is there without a trace.
    case pathTypeChanged(String)
}

/// What a resolving write did: the path, and the stash entry it filed first, if any.
public struct ConflictReceipt: Sendable, Hashable {
    public let path: String
    public let recorded: Stash?

    public init(path: String, recorded: Stash?) {
        self.path = path
        self.recorded = recorded
    }
}
