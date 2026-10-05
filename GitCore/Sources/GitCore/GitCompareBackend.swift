import Foundation

/// Comparing two branches (milestone B3): the commits only on each side and the changes the
/// second brings. Read-only.
///
/// The eleventh GitCore protocol. Its promise is the milestone's first (spec, "The safety
/// promise, extended"): **a comparison is one state.** Both tips are read to object ids once,
/// and every count, list, merge base and diff is taken from those ids — so a branch that moves
/// half-way through cannot mix two states into one answer (R11, R12). Measured on git 2.54:
///
/// - Names are full refs only. A short `v1` is the *tag* when a tag and a branch share the
///   name, and a branch called `heads/v1` is shadowed by `refs/heads/v1` (R10).
/// - `diff-tree` given a 3-dot range prints nothing and exits 0 (R6), so the changes are never
///   asked for with a range: they run from the first merge-base id to B's id, which is
///   byte-identical to `git diff A...B` with the working-copy pins (R5).
/// - `merge-base --all` exiting 1 with no output is "no shared history", a state rather than
///   an error (R7). Several lines are criss-cross merges; the first is the one `git diff A...B`
///   uses and only warns about on stderr (R8).
///
/// Every vector is pinned in `ForceFlagScannerTests` (`compareContract`), and a `...` in a
/// `diff-tree` vector is a finding there.
public protocol GitCompareBackend: Sendable {
    /// Reads `a` against `b`: each tip resolved once with `rev-parse --verify --quiet
    /// --end-of-options <ref>^{commit}` (R11), then — from the two ids only — the counts
    /// (`rev-list --count --left-right`, R1), the commits only on each side (newest first, at
    /// most `Comparison.listLimit` each, R2, R3) and every merge base (`merge-base --all`, R7,
    /// R8).
    ///
    /// `a` and `b` are full refs under `refs/heads/` or `refs/remotes/`. Refused before git
    /// runs: anything else (`CompareRefusal.notABranch`, naming it, `a` first) and the same ref
    /// twice (`.sameRef`). A ref that does not exist is `.missing`, naming it. Two different
    /// refs at the same commit are not refused: that is a comparison of `0` and `0`.
    func compare(_ a: String, _ b: String, at root: URL) async throws -> Comparison

    /// The files B brings: `diff-tree --name-status -M` from `c.mergeBases.first` to `c.b.id`,
    /// sorted by path. `CompareRefusal.noMergeBase` before git runs when there is no merge base;
    /// an id that is not a full object id is `BranchOperationError.invalidName`, also before
    /// git runs.
    func comparisonFiles(_ c: Comparison, at root: URL) async throws -> [FileStatus]

    /// The diff B brings, as `comparisonFiles` reads it — of every file, or of `path` alone —
    /// with the commit-diff arguments and `--full-index`: `git diff A...B`'s bytes, whatever
    /// the user's diff configuration (R5). Refused as `comparisonFiles` is.
    func comparisonDiff(_ c: Comparison, path: String?, at root: URL) async throws -> [FileDiff]
}
