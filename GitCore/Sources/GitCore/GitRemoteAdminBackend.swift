import Foundation

/// Keeping a repository's remotes tidy (milestone B2): prune remote-tracking refs the server no
/// longer has, find the local branches whose upstream is gone, fast-forward a branch that is not
/// checked out, and set or unset a branch's upstream.
///
/// The tenth GitCore protocol. Its promise is the milestone's (spec, "The safety promise,
/// extended"):
///
/// - **What the sheet showed is what is deleted.** A prune is never `git fetch --prune`, which
///   deletes whatever the server lacks *at that moment* — measured, a branch the server lost after
///   the listing went with the rest (R6). It is a per-ref compare-and-delete on the id the plan
///   holds: `update-ref --no-deref -d --end-of-options refs/remotes/<r>/<b> <id>`. A ref that moved
///   is skipped and named.
/// - **Commits only the deleted refs hold are counted once, as a union** (R5), and can be kept: the
///   kept branches are created before anything is deleted.
/// - **Every deleted ref is named with its full id**: a remote-tracking ref has no reflog after a
///   clone, and a delete removes any it had (R7).
/// - **What the sheet showed is what is moved.** A fast-forward is a compare-and-set on the tip
///   the sheet showed, and an upstream is named by its full ref and read back after git wrote it.
///
/// Every vector is pinned in `ForceFlagScannerTests`; `fetch --prune` is permitted there only in
/// the dry-run listing shape, `update-ref -d` only on a full `refs/remotes/` (or B1's
/// `refs/tags/`) name with an interpolated expected id, `update-ref -m` only as the
/// fast-forward's `refs/heads/` compare-and-set with both ids interpolated, and `branch`'s
/// upstream options only as the two upstream vectors.
public protocol GitRemoteAdminBackend: Sendable {
    /// Every remote-tracking ref of `remote` the server no longer has, with the id each holds,
    /// and what deleting them all would strand.
    ///
    /// **Contacts the remote** (run it on the remote lane): `git fetch --prune --no-prune-tags
    /// --dry-run --porcelain --no-progress --end-of-options <remote>`, keeping only the pruned
    /// (`-`) lines under `refs/remotes/` (R2, R3). `--no-prune-tags`, because `fetch.pruneTags`
    /// would otherwise list local tags that were never on the server (R8). A dry run is **not**
    /// write-free: it downloads objects and re-creates a missing `refs/remotes/<remote>/HEAD`
    /// (R26) — it moves and deletes nothing else.
    ///
    /// Refused before git runs: `RemoteOperationError.noRemote` for a name that is empty, `.`
    /// or begins with `-`; `RemoteAdminRefusal.noSuchRemote` when no such remote is configured;
    /// `.unsafeRefspec` when one of its fetch refspecs writes outside `refs/remotes/` (a mirror
    /// remote lists local branches as prunable, R3). A network failure is `RemoteOperationError`
    /// when Gitter can word it, git's own (redacted) words otherwise.
    func prunePlan(_ remote: String, at root: URL) async throws -> PrunePlan

    /// The commits reachable from `refs` (full `refs/remotes/…` names) and from no other ref —
    /// not from a local branch, a tag, another remote-tracking ref or any worktree's HEAD; a
    /// symbolic ref holds nothing of its own, and **a stash entry is not a place a commit is
    /// kept** (`GitBranchBackend.commitsOnlyOn`'s rule) — counted as one union (R5), the newest
    /// `StrandedCommits.displayLimit` listed, and which of `refs` reach them. Local reads only. A name that is not a full
    /// `refs/remotes/` ref, or carries revision syntax, is `BranchOperationError.invalidName`
    /// before git runs.
    func stranded(by refs: [String], at root: URL) async throws -> StrandedCommits

    /// Deletes exactly `plan.refs`, each only while it still holds the id the plan showed.
    ///
    /// In order, and nothing is deleted until every step before the deletes has passed:
    /// 1. Every id is checked full and non-zero (`RemoteAdminRefusal.invalidObjectID`), every ref
    ///    a full `refs/remotes/` name, before any process runs.
    /// 2. What the refs that still hold their ids would strand is counted again;
    ///    `.strandedGrew` if it is more than `plan.stranded.count`, or — when the plan listed
    ///    every stranded commit — if any commit now stranded is not one the plan listed.
    /// 3. Every name in `keeping` (plan ref → new branch name) is checked —
    ///    `.invalidBranchName`, `.branchExists` (Ruling 1) — and then every kept branch is created
    ///    at the id the plan showed: `branch --no-track --end-of-options <name> <id>`. If one
    ///    cannot be created after others were, `RemoteAdminPartial.keptBranchesThenStopped` names
    ///    the ones that stay; nothing is deleted.
    /// 4. Each ref is deleted with the compare-and-delete. A ref that moved or is gone is
    ///    `skippedMoved`; one git refused for another reason (a lock, a hook) is `failed`, with
    ///    git's words, and the refs after it are still tried. A cancellation stops the loop: the
    ///    ref being deleted is `outcomeUnknown`, the rest `notTried`.
    ///
    /// Local only: nothing here contacts the remote.
    func prune(_ plan: PrunePlan, keeping: [String: String], at root: URL) async throws -> PruneResult

    /// Whether `name` can be a branch kept by a prune: nil, or the refusal `prune` would throw
    /// for it (`.invalidBranchName`, `.branchExists`) — the sheet's live check. Reads only.
    func keepBranchNameProblem(_ name: String, at root: URL) async throws -> RemoteAdminRefusal?

    /// Every local branch whose upstream is configured and gone (`[gone]`, R9), remote and
    /// local (`.`) upstreams alike, in ref order. A branch whose `branch.<b>.remote` names a
    /// remote that does not exist has no upstream at all to git, and is not listed (R9). One
    /// `for-each-ref`, plus the branch delete's own unique-commit count per gone branch. Reads
    /// only — correct with `config.lock` held by another process (Ruling 2).
    func goneBranches(at root: URL) async throws -> [GoneBranch]

    // MARK: - Fast-forward and upstream (B2 Task 2)

    /// Moves `branch` — one that is not checked out — to its upstream's commit, only while it
    /// still holds `tip`, the id the sheet showed. Run it **after the caller's fetch** (on the
    /// lane); it contacts nothing itself.
    ///
    /// Not git's `fetch <r> refs/heads/<up>:refs/heads/<b>`, which auto-follows tags, reports a
    /// branch that is only ahead as rejected and mis-reports its exit code (R14). Refused up
    /// front, in this order, with nothing written:
    /// - `branch` empty or beginning with `-` (`BranchOperationError.invalidName`), `tip` not a
    ///   full non-zero id (`RemoteAdminRefusal.invalidObjectID`), before any process runs;
    ///   a symbolic branch (an alias of another) is `.invalidName` too — moving it would move
    ///   the branch it names;
    /// - `FastForwardRefusal.checkedOut(path:)`: checked out in any worktree, this one included,
    ///   or being rebased or bisected in one — `update-ref` refuses neither (R15);
    /// - `.moved`: the branch does not hold `tip` (or no longer exists);
    /// - `.noUpstream`; `.ahead(n)`; `.diverged(ahead:behind:)` — decided by `merge-base
    ///   --is-ancestor` between the two fixed ids, which cannot change under it (R15).
    ///
    /// Then one compare-and-set: `update-ref --no-deref -m "Gitter: fast-forward <b> to
    /// <upstream>" --end-of-options refs/heads/<b> <new> <tip>`. It runs the
    /// `reference-transaction` hook; a hook's refusal is git's own words (`GitError`), with the
    /// branch where it was. A branch moved since the check is `.moved` (git: "is at X but
    /// expected Y"). Cancelled while it runs: `RemoteAdminPartial.fastForwardOutcomeUnknown` —
    /// never "nothing changed".
    func fastForward(_ branch: String, expecting tip: String, at root: URL) async throws -> FastForwardOutcome

    /// Makes `branch` track the remote branch `ref`, a **full** remote-tracking name
    /// (`refs/remotes/<r>/<b>`): the short form fails "ambiguous object name" when a tag or a
    /// local branch is called `<r>/<b>` (R17). Local config only, contacts nothing.
    ///
    /// Refused before git runs (nothing written): `.notABranch` for a ref outside
    /// `refs/remotes/`, a symbolic one or one no remote's fetch refspec maps (the "Other"
    /// group); `.ambiguousNamespace` when two remotes map it; `.notFetched` when it does not
    /// exist. git's own refusals of the same three are read into the same cases; anything else
    /// (a held `config.lock`, R27) is git's words. `BranchOperationError.invalidName` for a
    /// branch name that is empty or begins with `-`, or a ref that is not a plain ref name.
    ///
    /// Runs `branch --set-upstream-to=refs/remotes/<r>/<b> --end-of-options <branch>`, then
    /// reads `branch.<b>.remote` and `branch.<b>.merge` back: overlapping fetch refspecs make git
    /// write a server branch nobody chose (R18), thrown as `.mergeMismatch` with both values —
    /// git **has written** it. `SetUpstreamResult.wroteRebase` reports the
    /// `branch.<b>.rebase=true` that `branch.autoSetupRebase` adds (R17). Cancelled while git
    /// runs or while the write is read back: `RemoteAdminPartial.upstreamOutcomeUnknown`.
    func setUpstream(of branch: String, to ref: String, at root: URL) async throws -> SetUpstreamResult

    /// Removes `branch`'s upstream: `branch --unset-upstream --end-of-options <branch>`, which
    /// unsets `branch.<b>.remote` and `.merge` and leaves `branch.<b>.rebase` and
    /// `.pushRemote` as they are (R17). A branch with no upstream is git's own words ("has no
    /// upstream information"), as is a held `config.lock` (R27). Cancelled while git runs:
    /// `RemoteAdminPartial.upstreamOutcomeUnknown`.
    func unsetUpstream(of branch: String, at root: URL) async throws
}
