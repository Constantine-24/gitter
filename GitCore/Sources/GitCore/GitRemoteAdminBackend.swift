import Foundation

/// Keeping a repository's remotes tidy (milestone B2): prune remote-tracking refs the server no
/// longer has, find the local branches whose upstream is gone, fast-forward a branch that is not
/// checked out, set or unset a branch's upstream, and add, rename, re-point or remove a remote.
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
/// upstream options only as the three upstream vectors (set to a remote or a local branch, unset),
/// and `remote` only as `-v` and the four management vectors (add, set-url and its `--push`
/// twin, rename, remove), each whole, its names after `--end-of-options`.
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
    /// remote lists local branches as prunable, R3); `RemoteOperationError.noURL` when the remote
    /// has no fetch URL (fix round 1, I1). A network failure is `RemoteOperationError`
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

    /// The ref `refs/remotes/<remote>/HEAD` points at, a full name (`refs/remotes/origin/main`),
    /// or nil when there is no such symbolic ref or it dangles (`for-each-ref` does not list a
    /// dangling one). B2 Task 4: a prune that deletes this target leaves `<remote>/HEAD`
    /// dangling, and a later fetch does **not** repair it (measured in Task 1) — the sheet says
    /// so. Read it after `prunePlan`, whose listing re-creates a missing `<remote>/HEAD` (R26).
    /// `RemoteOperationError.noRemote` for a name that is empty, `.` or begins with `-`. Reads
    /// only.
    func remoteHEADTarget(of remote: String, at root: URL) async throws -> String?

    /// Every key of the repository's own configuration (`config --local`) in the section
    /// `branch.<branch>`, as git spells keys (`branch.topic.remote`, `branch.topic.pushremote`):
    /// nothing else — `branch.<branch>.<sub>.<key>` belongs to a branch named `<branch>.<sub>`.
    /// B2 Task 4 (Ruling 2): `git branch -d`/`-D` under a `config.lock` another process holds
    /// deletes the branch, exits 0 and leaves this section behind (R27, measured for `-D` too),
    /// so a clean-up reads it back after each delete. `BranchOperationError.invalidName` for a
    /// name that is empty or begins with `-`. Reads only.
    func branchConfigKeys(of branch: String, at root: URL) async throws -> [String]

    // MARK: - Fast-forward and upstream (B2 Task 2)

    /// Moves `branch` — one that is not checked out — to its upstream's commit, only while it
    /// still holds `tip`, the id the sheet showed. Run it **after the caller's fetch** (on the
    /// lane); it contacts nothing itself.
    ///
    /// Not git's `fetch <r> refs/heads/<up>:refs/heads/<b>`, which auto-follows tags, reports a
    /// branch that is only ahead as rejected and mis-reports its exit code (R14). Refused, in
    /// this order, with nothing written:
    /// - `branch` empty or beginning with `-` (`BranchOperationError.invalidName`), `tip` not a
    ///   full non-zero id (`RemoteAdminRefusal.invalidObjectID`), before any process runs;
    ///   a symbolic branch (an alias of another) is `.invalidName` too — moving it would move
    ///   the branch it names;
    /// - `.moved`: the branch does not hold `tip` (or no longer exists);
    /// - `.noUpstream`; `.ahead(n)`; `.diverged(ahead:behind:)` — decided by `merge-base
    ///   --is-ancestor` between the two fixed ids, which cannot change under it (R15);
    /// - **last, immediately before the write** (the narrowest window, fix round 1):
    ///   `FastForwardRefusal.checkedOut(path:)` when any worktree uses the branch as git counts
    ///   it — its HEAD, a rebase or a bisect started from it, or a `rebase --update-refs` that
    ///   will move it — every worktree asked, a prunable one included. `update-ref` refuses
    ///   none of them (R15).
    ///
    /// Then one compare-and-set: `update-ref --no-deref -m "Gitter: fast-forward <b> to
    /// <upstream>" --end-of-options refs/heads/<b> <new> <tip>`. It runs the
    /// `reference-transaction` hook; a hook's refusal is git's own words (`GitError`), with the
    /// branch where it was. A branch moved since the check is `.moved` (git: "is at X but
    /// expected Y"). Cancelled while it runs: `RemoteAdminPartial.fastForwardOutcomeUnknown` —
    /// never "nothing changed". A worktree that starts using the branch after the last check
    /// and before the write is not seen (R15's residual race).
    func fastForward(_ branch: String, expecting tip: String, at root: URL) async throws -> FastForwardOutcome

    /// Makes `branch` track `ref`, a **full** name: a remote branch (`refs/remotes/<r>/<b>`) or
    /// a local one (`refs/heads/<x>`, which git records as remote `.`). The short form fails
    /// "ambiguous object name" when a tag or a local branch is called `<r>/<b>` (R17). Local
    /// config only, contacts nothing.
    ///
    /// Refused before git runs (nothing written): `.notABranch` for a ref under neither prefix,
    /// a symbolic one, or a remote-tracking one no remote's fetch refspec maps (the "Other"
    /// group); `.ambiguousNamespace` when two remotes map it; `.notFetched` when a
    /// remote-tracking ref does not exist, `BranchOperationError.noSuchBranch` when a local one
    /// does not; `.ownUpstream` for the branch itself (git only warns and writes nothing).
    /// git's own refusals of the first three are read into the same cases; anything else (a
    /// held `config.lock`, R27) is git's words. `BranchOperationError.invalidName` for a branch
    /// name that is empty or begins with `-`, or a ref that is not a plain ref name.
    ///
    /// Runs `branch --set-upstream-to=<ref> --end-of-options <branch>`, then reads
    /// `branch.<b>.remote` and `branch.<b>.merge` back: overlapping fetch refspecs make git
    /// write a server branch nobody chose (R18), thrown as `.mergeMismatch` with both values —
    /// git **has written** it. A failed run is read back too: git writes the two keys one at a
    /// time, so a failure that changed them is `RemoteAdminPartial.upstreamChangedThenFailed`
    /// with what they hold now. `SetUpstreamResult.wroteRebase` reports the
    /// `branch.<b>.rebase=true` that `branch.autoSetupRebase` adds (R17). Cancelled while git
    /// runs or while the write is read back: `RemoteAdminPartial.upstreamOutcomeUnknown`.
    func setUpstream(of branch: String, to ref: String, at root: URL) async throws -> SetUpstreamResult

    /// Removes `branch`'s upstream: `branch --unset-upstream --end-of-options <branch>`, which
    /// unsets `branch.<b>.remote` and `.merge` and leaves `branch.<b>.rebase` and
    /// `.pushRemote` as they are (R17). A failure is read back as Set Upstream's is: changed
    /// keys are `RemoteAdminPartial.upstreamChangedThenFailed`; unchanged ones leave git's own
    /// words — a branch with no upstream ("has no upstream information"), a `config.lock` held
    /// from the start (R27, measured: nothing written). Cancelled while git runs:
    /// `RemoteAdminPartial.upstreamOutcomeUnknown`.
    func unsetUpstream(of branch: String, at root: URL) async throws

    // MARK: - Remote management (B2 Task 3)

    /// Whether `name` can be given to a remote — by Add Remote, or as Rename Remote's new name:
    /// nil, or the problem (`RemoteNameProblem`): git's own rule (`check-ref-format
    /// refs/remotes/<name>/test`, what git asks, R19) plus a leading `-`, `HEAD`, `@`, a
    /// configured remote of that name or one nested with it, compared ignoring case. The sheet's
    /// live check; reads only.
    func remoteNameProblem(_ name: String, at root: URL) async throws -> RemoteNameProblem?

    /// `remote`'s URLs as the configuration writes them (`config --get-all remote.<n>.url` /
    /// `.pushurl`, promise 5) and, for display, where git really fetches from (`ls-remote
    /// --get-url --end-of-options <n>`, which applies `insteadOf` and **contacts nothing** —
    /// verified with only the `file` transport allowed). `RemoteAdminRefusal.noSuchRemote` when
    /// no such remote is configured; `RemoteOperationError.noRemote` for a name that is empty,
    /// `.` or begins with `-`. Reads only.
    func remoteURLs(_ remote: String, at root: URL) async throws -> RemoteURLs

    /// Adds a remote: `remote add --end-of-options <name> <url>`, which writes `remote.<n>.url`
    /// and the default fetch refspec and **fetches nothing** — never `remote add -f`, a plain
    /// `git fetch` with none of Gitter's own fetch's guards (R19). The caller fetches afterwards
    /// with `GitRemoteBackend.fetch(remote:)`, on the lane.
    ///
    /// Refused before anything is written: `RemoteAdminRefusal.unsafeURL` (before git runs),
    /// `.nameProblem` (`remoteNameProblem`'s answer; an empty name or a leading `-` before git
    /// runs). git's own refusals of a name (R19) are read into `.nameProblem` too. A failure
    /// that wrote part of the remote is `RemoteAdminPartial.urlsChangedThenFailed`; a
    /// cancellation while git runs, `.urlsOutcomeUnknown`. Contacts nothing.
    func addRemote(_ name: String, url: String, at root: URL) async throws

    /// Sets `remote`'s fetch URL to `fetch` and its push URL as `push` says: `remote set-url
    /// --end-of-options <n> <url>`, then for `.set(url)` `remote set-url --push --end-of-options
    /// <n> <url>` — each only when the value differs from the configured one — or for `.clear`
    /// `config --unset-all --end-of-options remote.<n>.pushurl` (fix round 1, I3; never `set-url
    /// --push --delete`), which writes nothing when no push URL is configured. `.unchanged` leaves
    /// every `pushurl` as it is. Works on a remote with no URL, giving it one (R22).
    ///
    /// Refused with nothing written: `.unsafeURL` for either URL (before git runs);
    /// `.noSuchRemote`; `.severalURLs` when the remote has more than one `url` — or more than one
    /// `pushurl` and `push` is not `.unchanged` — since a plain `set-url` fails on it (R22). A failure after
    /// the first write is `RemoteAdminPartial.urlsChangedThenFailed` with what the remote holds
    /// now; a cancellation while git runs, `.urlsOutcomeUnknown`. Contacts nothing.
    func setURLs(of remote: String, fetch: String, push: PushURLChange, at root: URL) async throws

    /// Renames a remote: `remote rename --no-progress --end-of-options <old> <new>`, which moves
    /// every ref its default refspec maps (with their reflogs), rewrites `branch.<b>.remote`,
    /// `.pushRemote` and `remote.pushDefault`, and leaves a custom refspec that writes elsewhere
    /// as it was, with a warning (R21). **Run it on the lane**: never beside a fetch.
    ///
    /// Refused with nothing written: `RemoteOperationError.noRemote` for an `old` that is empty,
    /// `.` or begins with `-`; `.noSuchRemote(old)`; `.nameProblem` for `new`
    /// (`remoteNameProblem`, so renaming to a name nested in `old` itself is refused too). A
    /// failure is **read back** (R21: under a held ref or `packed-refs.lock` git exits 128 with
    /// the section renamed and its refspec, the branches' settings and the refs not):
    /// anything changed is `RemoteAdminPartial.renameHalfDone` describing what git left;
    /// nothing changed (a held `config.lock`) is git's words, or the refusal they mean. A
    /// cancellation while git runs is `.renameOutcomeUnknown`. Contacts nothing.
    func renameRemote(_ old: String, to new: String, at root: URL) async throws

    /// What "Remove <remote>…" would delete, strand and change (`RemovalImpact`): the refs
    /// `git remote remove` deletes, computed as git computes them, with the ids they hold; the
    /// commits only those refs hold (one union, `stranded(by:)`); the branches that lose their
    /// upstream; the branches whose push silently goes elsewhere (git unsets only the
    /// repository's own settings: one from the global or a worktree's configuration stays, so a
    /// branch can go on pushing to the removed name — measured); the refs left behind.
    /// `.noSuchRemote` when no such remote is configured. Reads only.
    func removalImpact(of remote: String, at root: URL) async throws -> RemovalImpact

    /// Removes `impact.remote`, only while removing it still means exactly `impact`.
    ///
    /// In order, and nothing is removed until every step before has passed:
    /// 1. Every kept ref is one of `impact.refs` (`BranchOperationError.invalidName`), with a full
    ///    non-zero id (`.invalidObjectID`), before any process runs.
    /// 2. The impact is read again; any difference at all is `.impactChanged` (RF1).
    /// 3. The configuration and `refs/remotes/` the read-back compares against are read, and the
    ///    refs git will delete compared with the sheet's once more from them (`.impactChanged`;
    ///    fix round 1, m1/m2) — before any kept branch exists, so a refusal or a failed read
    ///    creates nothing.
    /// 4. The kept branches (`keeping`: ref → new branch name) are checked and created at the ids
    ///    the sheet showed, exactly as `prune` creates them (`.invalidBranchName`,
    ///    `.branchExists`, `RemoteAdminPartial.keptBranchesThenStopped`).
    /// 5. `remote remove --end-of-options <remote>`. **Run it on the lane.** A failure is read
    ///    back (R23: under a held `packed-refs.lock` or ref lock git exits 1 with the remote and
    ///    its refs kept and every branch setting naming it already unset):
    ///    `RemoteAdminPartial.removeHalfDone` when anything changed or kept branches were
    ///    created; otherwise git's words. Cancelled while git runs: `.removeOutcomeUnknown`.
    ///
    /// Residual race: a ref a process outside Gitter creates between step 3 and git's own
    /// listing — while the kept branches are created — is deleted too. Contacts nothing.
    func removeRemote(_ impact: RemovalImpact, keeping: [String: String], at root: URL) async throws
}
