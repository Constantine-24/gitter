import Foundation

/// Branch-level operations: naming, creating, switching, detaching, tracking, renaming,
/// deleting and merging.
///
/// These are the first Gitter operations that write working-tree files, so the contract is
/// deliberately narrow:
///
/// - **No force flag is ever passed.** Not `--force`, `-f`, `--discard-changes`, `-B`, `-C`,
///   nor `--merge` on a switch. When a local change stands in the way, git refuses, nothing
///   changes, and the refusal arrives as a `BranchOperationError` naming the files. A test
///   (`ForceFlagScannerTests`) fails the build if such a flag ever appears in `GitCore`.
/// - **Branch names and revisions are not pathspecs.** `literalPathspec` is never applied to
///   them; instead a name that is empty or begins with `-` is rejected before git runs, and
///   revisions and start points are passed after `--end-of-options` on the commands that
///   accept it, so a ref really named `--force` could never be read as a flag.
///
///   That leading-`-` rule is a blanket one, and it does cost something: a ref literally
///   named `--force` or `-x` *can* exist — `git update-ref refs/heads/--force <sha>` makes
///   one — and such a branch is deliberately unreachable from Gitter. It still appears in the
///   sidebar; only operating on it is refused, with `.invalidName`. Reaching it would mean
///   trusting `--end-of-options` in the one position (`switch -c <name>`) where it
///   demonstrably does not work, which is not a trade worth making for a ref nobody creates
///   by accident.
///
/// `GitBackend` (reads) and `GitWorkingCopyBackend` (index and commit writes) stay separate
/// for the same reason they always were: either half can be faked on its own.
public protocol GitBranchBackend: Sendable {
    /// Whether `name` would be accepted as a local branch name.
    ///
    /// Rejected without running git: empty or whitespace-only names, names beginning with `-`,
    /// and four shapes `check-ref-format --branch` *accepts* while meaning something other
    /// than what the user typed (all verified on git 2.54):
    ///
    /// - `refs/…` and `heads/…` — `git branch refs/heads/x` creates
    ///   `refs/heads/refs/heads/x`, and `git branch heads/y` creates `refs/heads/heads/y`.
    /// - anything containing `@{` — `check-ref-format --branch` *expands* branch shorthand, so
    ///   `@{-1}` reports valid and resolves to the previously checked-out branch's name.
    /// - exactly `@` — accepted by git, and a branch nobody can refer to without confusion.
    ///
    /// Everything else is `git check-ref-format --branch <name>` (exit 0 → valid, 128 → not),
    /// so what a name may *contain* stays git's judgement and cannot drift from it: the
    /// control characters, `..`, `~`, `^`, `:`, `?`, `*`, `[`, trailing `.lock`, `HEAD` and
    /// the rest are never re-implemented here.
    ///
    /// This is a name-quality gate for the UI. The backend's own argv safety — rejecting a
    /// leading `-` before any name reaches git — is separate and unconditional.
    func validateBranchName(_ name: String, at root: URL) async throws -> Bool

    /// `git branch --end-of-options <name> [<start>]`, or `git switch -c <name>
    /// [--end-of-options <start>]` when `switchTo`.
    ///
    /// Without `switchTo` this writes one ref and touches nothing else — not HEAD, not the
    /// index, not a single file. With it, a dirty worktree is carried onto the new branch
    /// (there is nothing to conflict with: the new branch starts where HEAD already is, unless
    /// `startPoint` says otherwise, in which case git applies its usual refusal rules).
    ///
    /// Throws `.branchExists` if `name` is taken and `.invalidName` if git (or Gitter) rejects
    /// the name.
    func createBranch(_ name: String, startPoint: String?, switchTo: Bool, at root: URL) async throws

    /// `git switch --no-guess --end-of-options <branch>`.
    ///
    /// `--no-guess` matters: without it, switching to a name that exists only as
    /// `origin/<name>` silently *creates* a local tracking branch. Gitter has an explicit
    /// action for that (`trackRemoteBranch`) and this one must never do it by accident.
    ///
    /// Non-conflicting local changes ride along, which is git's default and Gitter's answer to
    /// "do I have to stash first?". A conflicting change or an untracked file in the way throws
    /// `.wouldOverwrite` (which carries both lists, since git can refuse over both at once),
    /// and a merge/rebase/cherry-pick/revert/am in progress throws `.operationInProgress` — in
    /// every case git changed nothing.
    func switchTo(branch: String, at root: URL) async throws

    /// `git switch --detach --end-of-options <revision>`: check out a commit or tag without
    /// being on a branch. Same refusal rules as `switchTo`.
    func checkoutDetached(_ revision: String, at root: URL) async throws

    /// Check out `origin/feat/x` as a local `feat/x` tracking it.
    ///
    /// The remote name is the first path component and the local branch name is everything
    /// after it, so `origin/feat/x` becomes `feat/x` — not `x`.
    ///
    /// A remote whose own name contains a slash is not special-cased: `my/remote/feature`
    /// (a real shape — `git remote add my/remote …` puts its refs under
    /// `refs/remotes/my/remote/`) yields a local branch called `remote/feature`, keeping a
    /// fragment of the remote's name. The upstream is still set correctly, because git
    /// resolves the full string for `--track`. Untangling it would mean listing the remotes to
    /// find the longest matching prefix; nobody names remotes that way, and the failure is
    /// cosmetic and immediately visible, so this stays as it is. It is tested, not accidental.
    ///
    /// When a local branch of that
    /// name already exists this is a plain switch to it: its tip is not moved and no upstream
    /// is set, because silently retargeting an existing branch is exactly the kind of surprise
    /// this milestone is about avoiding.
    func trackRemoteBranch(_ remoteBranch: String, at root: URL) async throws

    /// `git branch -m --end-of-options <old> <new>`. Renaming the current branch is fine: HEAD
    /// follows it and the worktree is untouched. Throws `.branchExists` when `new` is taken.
    func renameBranch(_ old: String, to new: String, at root: URL) async throws

    /// `git branch -d --end-of-options <name>`, or `-D` when `force`. One of only three actions
    /// in Gitter that can lose work — the other two are aborting an operation and undoing a
    /// pending squash — so the contract is deliberately narrow:
    ///
    /// - The **current branch is always refused**, force or not, and detected twice: before git
    ///   ever runs (`symbolic-ref --short -q HEAD` compared against `name`, so nothing is even
    ///   attempted), and again by reading git's own refusal (see `.cannotDeleteCurrent`), which
    ///   is what also catches a branch checked out in a *linked* worktree — a case Gitter has no
    ///   cheap way to detect up front without listing every worktree.
    /// - **Without `force`,** a branch git considers not fully merged is left exactly as it
    ///   found it — nothing is thrown, nothing changes — and the result carries
    ///   `.notFullyMerged(uniqueCommits:tip:)`: `uniqueCommits` from `commitsOnlyOn(branch:)`
    ///   and `tip` from `rev-parse --verify refs/heads/<name>`, both captured before this call
    ///   does anything destructive (which, on this path, is nothing at all).
    /// - **With `force`,** the branch is deleted outright. The commit at its former tip is not
    ///   lost: git keeps the object (verified — `cat-file -e <tip>` still succeeds right after),
    ///   so a user who sees the warning's tip sha can recreate the branch with
    ///   `git branch <name> <tip>`.
    ///
    /// A name that does not exist throws `.noSuchBranch`; an invalid one throws `.invalidName`
    /// before git runs, same as every other method here.
    ///
    /// One case this method cannot protect against: when HEAD is **detached exactly at a
    /// branch's tip**, that branch is not current (`symbolic-ref` finds no branch at all, so the
    /// up-front check above doesn't fire) and git considers it trivially merged into HEAD, so
    /// even a plain `-d` deletes it without complaint (verified) — its commits then hang on the
    /// detached HEAD alone, reachable from no other ref, until the next checkout moves HEAD away
    /// and leaves them to the reflog. Warning about *that* is the switching code's job, before it
    /// ever leaves HEAD detached there (see the spec).
    func deleteBranch(_ name: String, force: Bool, at root: URL) async throws -> BranchDeletion

    /// How many commits are reachable from `name` and from **no other ref** — what the "Delete"
    /// warning shows as "N commits exist only on this branch".
    ///
    /// `git rev-list --count refs/heads/<name> --not --exclude=refs/heads/<name> --all`.
    /// Verified on git 2.54, precisely:
    ///
    /// - **"No other ref" means any other local branch, any remote-tracking ref
    ///   (`refs/remotes/…`), any tag, or the stash** — `refs/stash` is a real, single ref under
    ///   `refs/` and `--all` picks it up like any other, so a branch whose only unmerged commit
    ///   is also the parent of a stash entry counts as 0, not 1. It does **not** mean a
    ///   reflog entry: a commit some *other* ref's history once passed through but no longer
    ///   points at (e.g. after `git branch -f other main`) still counts as unique here, because
    ///   `--all` expands live ref tips only, never reflogs.
    /// - **This is a different question from what `git branch -d` itself asks**, and the two can
    ///   disagree in one direction, not the other. `-d` compares the branch against its
    ///   `@{upstream}` if one is set, otherwise against HEAD — a single ref, and the "if one is
    ///   set" half is tested on its own, not just inferred: a branch with a commit pushed (so it
    ///   has an upstream) and then one *more*, unpushed, commit — merged into HEAD by a merge
    ///   commit — still makes `-d` refuse, because it checks the (unadvanced) upstream and never
    ///   even looks at HEAD once an upstream is configured. `commitsOnlyOn` reports 0 there too
    ///   (the extra commit is reachable via HEAD once merged). So `-d` can *refuse* a branch this
    ///   method reports as 0 — merged into some other ref (another branch, or the branch's own
    ///   upstream), just not into HEAD. The reverse cannot happen: whenever `-d` succeeds, the
    ///   ref it compared against (HEAD or upstream) is itself always part of `--all`'s reachable
    ///   set (git's own docs: `--all` "pretend[s] as if … HEAD" is listed, even detached, even
    ///   with no branch pointing at it — verified), so every commit `-d` judged "merged" is
    ///   provably already counted as reachable elsewhere too — tested directly for the upstream
    ///   case too: a branch merged only into its upstream, not HEAD, deletes with a warning on
    ///   stderr that Gitter ignores (`deleteBranch` only special-cases the refusal text), and its
    ///   commit stays reachable from the surviving remote-tracking ref. **When git refuses a
    ///   plain delete but this returns 0, the count is still the truth** — "0 commits exist only
    ///   here" — it just means git's narrower HEAD/upstream rule doesn't yet agree, not that the
    ///   warning is wrong.
    /// - **Calling this for the branch HEAD is currently on always returns 0**, whatever its
    ///   real merge status, because `--all`'s HEAD-inclusion makes a branch trivially reachable
    ///   from itself once it *is* HEAD. `deleteBranch` never hits this — it refuses the current
    ///   branch before calling here — but no other caller should read 0 for the current branch
    ///   as "safe to delete".
    func commitsOnlyOn(branch: String, at root: URL) async throws -> Int

    /// How many commits are reachable from HEAD but from **no branch, tag or remote-tracking
    /// ref** — the commits a move of HEAD would strand.
    ///
    /// `git rev-list --count HEAD --not --branches --tags --remotes`. Meaningful only while HEAD
    /// is detached: on a branch the branch itself references HEAD, so the answer is 0 by
    /// construction, and an unborn HEAD is 0 because there is nothing there at all.
    ///
    /// **It throws rather than guessing.** An unborn HEAD is recognised by git's own words
    /// ("ambiguous argument 'HEAD'", exit 128); every other failure — including the other exit
    /// 128, "not a git repository" — propagates. This number is the only input to the
    /// confirmation that stands between the user and losing commits, so a question that could
    /// not be asked must fail closed, never answer 0.
    ///
    /// This backs the fourth loss-capable action in the design doc. `deleteBranch`'s doc comment
    /// describes how the state is reached: detached exactly at a branch's tip, `git branch -d`
    /// deletes that branch without complaint (git calls it merged into HEAD), and the next
    /// switch leaves its commits to the reflog with only a stderr warning. The store asks this
    /// before every action that would move HEAD *away* from a detached HEAD and, when it is
    /// non-zero, confirms first.
    ///
    /// Deliberately not `--all`: that would include HEAD itself (and the stash), making the
    /// answer always 0. The three ref namespaces are named explicitly instead.
    func unreferencedCommitCount(at root: URL) async throws -> Int

    /// Merge `branch` into whatever HEAD is (a branch, or a detached HEAD — git allows both and
    /// so does this), the way `mode` says.
    ///
    /// The one command in this protocol that rewrites working-tree files wholesale, so three
    /// rules shape it:
    ///
    /// - **No force flag and no strategy option.** Not `-X ours`/`-X theirs`, not
    ///   `--strategy-option`, not `--autostash`, not `--allow-unrelated-histories`. Everything
    ///   git refuses stays refused, and nothing this method runs can pick a side of a conflict
    ///   on the user's behalf.
    /// - **A conflict is a return value, not a throw.** `.conflicts` comes back with the
    ///   half-done merge left in place, byte for byte as git wrote it. Nothing is aborted,
    ///   reset or retried here; the in-progress UI takes it from there.
    /// - **The outcome is read from the repository, never from git's prose or its exit code.**
    ///   Verified on git 2.54: a refused merge that would have fast-forwarded exits 1 and a
    ///   refused true merge exits 2, so the code alone cannot even tell refusal from conflict.
    ///
    /// Refusals, all of which change nothing: `.wouldOverwrite` when a tracked or untracked
    /// file stands in the way, `.indexNotClean` when a true merge finds anything staged (see
    /// that case — it fires even for files the merge does not touch) **and, for `.squash`
    /// alone, when Gitter's own index check finds anything staged even though git would have
    /// gone ahead** (a squash that fast-forwards skips the strategy; undoing the pending squash
    /// afterwards would destroy that staged work — see `MergeMode.squash`), `.operationInProgress`
    /// when a merge is already part-way through, `.noSuchBranch` for a name git cannot resolve,
    /// and `.invalidName` before git runs for a name that would be read as an option.
    ///
    /// **A throw does not by itself mean nothing changed.** Every `BranchOperationError` above
    /// is a refusal and leaves the repository untouched, but `GitError.commandFailed` — git's
    /// own words, for anything Gitter does not recognise — covers both kinds. Unrelated
    /// histories changes nothing; a `pre-merge-commit` or `commit-msg` hook that exits non-zero
    /// fails the merge *after* git resolved it, leaving `MERGE_HEAD` set and the result staged
    /// (verified on git 2.54). A caller must not render every throw as "your work is untouched";
    /// the snapshot's `operationInProgress` is what says whether a merge is now under way.
    func merge(_ branch: String, mode: MergeMode, at root: URL) async throws -> MergeOutcome

    /// End the operation the repository is part-way through, throwing its work away:
    /// `merge --abort`, `cherry-pick --abort`, `revert --abort`, `rebase --abort`,
    /// `am --abort`, and `reset --merge` for a pending squash.
    ///
    /// The second of the four actions in Gitter that can lose work, so what it keeps and what
    /// it destroys is spelled out — verified on git 2.54, pinned by a test per cell in
    /// `AbortKeptAndLostTests`, with the full evidence in `CLIGitBackend+Abort.swift`:
    ///
    /// | | merge · squash · cherry-pick · revert · am | rebase |
    /// |---|---|---|---|
    /// | uncommitted edit already there, in another file | kept | *cannot happen* |
    /// | change **staged** already, in another file | *cannot happen* † | *cannot happen* |
    /// | untracked file already there | kept | kept |
    /// | unstaged edit made since it began, another file | **kept** | **discarded** |
    /// | anything staged since it began | discarded | discarded |
    /// | conflict resolution, staged or not | discarded | discarded |
    /// | untracked file created since it began | kept | kept |
    /// | HEAD, the branch, every ref | back to where they were | back to where they were |
    ///
    /// "Cannot happen" is literal, and tested: git refuses to *start* a rebase while any tracked
    /// file has an unstaged change, and refuses to start **any** of them — five different
    /// messages, four different exit codes — while the index differs from HEAD. `am` is the one
    /// operation that has already committed something when it stops, and its abort rewinds the
    /// branch past those commits.
    ///
    /// † two exceptions, recorded rather than papered over. A **squash** that fast-forwards is
    /// the one operation git *will* start with a dirty index, and undoing it **discards** that
    /// pre-existing staged work; `merge(_:mode:at:)` refuses to create the state (see
    /// `MergeMode.squash`), but a terminal still can. A **`git am`** refused over a dirty index
    /// leaves `rebase-apply/applying` behind, so the snapshot reports an `am` that applied
    /// nothing; aborting that succeeds and **keeps** the staged work.
    ///
    /// Before running anything this asks the repository what is *really* in progress and throws
    /// `.noOperationInProgress` or `.operationMismatch(expected:actual:)` — see those cases for
    /// why a wrong or stale request must never reach git.
    ///
    /// **An abort can fail, and one of them is not atomic.** A file the operation rewrote that
    /// now has an unstaged edit makes every one of these aborts except `rebase`'s refuse
    /// ("Entry '<file>' not uptodate. Cannot merge.", `GitError.commandFailed`); for merge,
    /// squash, cherry-pick and revert nothing changes at all, but `git am --abort` cleans the
    /// conflicted index *before* rewinding, leaving the resolution destroyed, the branch
    /// unrewound and the `am` still in progress. Never render a failed abort as "nothing
    /// happened"; re-read the snapshot.
    func abort(_ operation: RepositoryOperation, at root: URL) async throws
}
