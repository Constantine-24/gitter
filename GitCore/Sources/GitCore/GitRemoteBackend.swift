import Foundation

/// Operations that talk to another repository: fetch now, and — as this milestone grows —
/// push, publish, force-push behind a lease, delete a remote branch and rebase onto an
/// upstream.
///
/// The fourth GitCore protocol, and separate from the other three for the reason they are
/// separate from each other: either half can be faked on its own. It is also the only one
/// whose operations are **slow, cancellable and fallible for reasons that have nothing to do
/// with the repository**, which is what shapes the contract:
///
/// - **Every method takes a `progress` callback and is cancellable.** Cancellation is task
///   cancellation: cancel the task and the child git is terminated (see
///   `ProcessRunner.runStreaming`), and the call throws `CancellationError`.
/// - **A throw does not mean nothing changed.** Unlike `GitBranchBackend`, where every
///   `BranchOperationError` is a refusal, a network operation can fail half-way through with
///   work already done — measured, for `fetch --all`, in `fetch`'s own doc comment. Only the
///   errors thrown *before git runs* promise a no-op, and they say so in
///   `RemoteOperationError`. A caller must re-read the repository rather than infer.
/// - **No bare force flag, no refspec beginning with `+`, never a prune, and never `git
///   pull`.** The same rule the branch protocol lives under, enforced the same way:
///   `ForceFlagScannerTests` fails the build if one appears anywhere in `GitCore/Sources`, and
///   the exact argument vectors this protocol's implementation writes are pinned there as a
///   contract before the code that writes them exists. Since Task 6 two of those vectors do
///   carry a force — `forcePush` and `deleteRemoteBranch` each send
///   `--force-with-lease=<ref>:<tip>`, and it is the *only* force this package permits. A
///   lease is a claim about what the destination holds, made with the sha a confirmation sheet
///   showed, so the server refuses rather than overwrites when the branch has moved. The bare
///   `--force`, `-f` and `--force-with-lease` (which leases against a remote-tracking ref this
///   app's own fetch rewrites) stay findings everywhere.
public protocol GitRemoteBackend: Sendable {
    /// Bring the remote-tracking refs up to date with the server, changing nothing local:
    /// `git fetch --progress --no-prune <remote>`, or `git fetch --progress --no-prune --all`
    /// when `remote` is nil.
    ///
    /// **It never moves a local branch and never touches the worktree.** That is the whole
    /// reason Gitter fetches rather than pulls: after this, `origin/main` is where the server
    /// says it is, `main` is exactly where the user left it, and what to do about the
    /// difference is a separate decision the user makes.
    ///
    /// **`--no-prune`, not merely "no `--prune`".** Pruning deletes remote-tracking refs for
    /// branches that are gone from the server, and that can drop the last ref to commits — a
    /// loss, and one that needs its own confirmation. Leaving the flag out does not prevent it:
    /// pruning is a configuration as much as a flag, and `fetch.prune=true` is one of the first
    /// lines in many people's `~/.gitconfig`. Measured on git 2.54, in a repository whose
    /// colleague had deleted a branch on the server:
    ///
    /// | config | flag | what the fetch did |
    /// |---|---|---|
    /// | `fetch.prune=true` | — | ` - [deleted] (none) -> origin/doomed` |
    /// | `fetch.prune=true` | `--no-prune` | nothing; the ref stayed |
    /// | `remote.origin.prune=true` | — | ` - [deleted] (none) -> origin/doomed` |
    /// | `remote.origin.prune=true` | `--no-prune` | nothing; the ref stayed |
    /// | `fetch.prune` + `fetch.pruneTags` | — | the ref **and the local tag**, both deleted |
    /// | `fetch.prune` + `fetch.pruneTags` | `--no-prune` | both kept |
    /// | `fetch.pruneTags=true` alone | — | nothing: a tag is pruned only when pruning happens |
    ///
    /// So one flag covers all four keys, on both vectors (`--all` included, measured). There is
    /// no `--no-prune-tags`: it exists and git accepts it — here and after `--all` — but with
    /// `--no-prune` already there it would be a second flag saying what the first has said.
    ///
    /// Consequence, stated in the README: a "gone" upstream only shows up in Gitter after a
    /// prune done elsewhere.
    ///
    /// **`remote` is validated before git runs** and `.noRemote` is thrown for a name Gitter
    /// will not pass on. All three refusals were measured on git 2.54 and each has its own
    /// reason:
    ///
    /// - A name beginning with `-` — git does block it (`fatal: strange pathname '-x'
    ///   blocked`), so this is not a hole being closed; it is refused here so the user is told
    ///   which name was wrong, under the same rule every other name in this package gets.
    /// - An empty or whitespace-only name — **git exits 0 and does nothing**, which is the
    ///   worst of the three answers. Measured: `git fetch --progress --end-of-options ""`
    ///   prints nothing on stdout or stderr, writes an *empty* `FETCH_HEAD`, moves no ref and
    ///   contacts nothing. (An earlier version of this comment said git reads an empty remote
    ///   as the current directory. It does not: `git fetch .` prints `From .` and writes a
    ///   44-byte `FETCH_HEAD` naming this repository's HEAD. The empty name is quieter than
    ///   that, not louder.) A fetch that reports success while doing nothing is exactly what
    ///   this milestone's "never report a failed network operation as nothing changed" promise
    ///   is about, read from the other side.
    /// - `"."` — **git accepts it.** `git fetch .` prints `From .`, fetches this repository's
    ///   own HEAD into `FETCH_HEAD` and exits 0. A fetch that quietly succeeds while
    ///   contacting nothing is worse than one that fails, so this is the refusal that earns its
    ///   keep.
    ///
    /// The name is also passed after `--end-of-options` (verified on git 2.54: `fetch` accepts
    /// it in that position), so a remote whose name merely resembles an option is still read as
    /// a remote.
    ///
    /// **A failure may be partial, and this is where that is measured.** With `--all`, git
    /// 2.54 fetches the remotes in order and reports the first failure at the end: one good
    /// local remote and one that is not a repository gives exit **1** (not the 128 a
    /// single-remote failure gives), stderr holding both the successful `From …` block and
    /// `error: could not fetch <name>` — and the good remote's refs are **already updated**.
    /// This throws in that case, because a fetch that did not fetch everything did not succeed,
    /// and it deliberately reports nothing about what did get through: there is no return value
    /// to mislead a caller with. The caller re-reads the snapshot. Never render this throw as
    /// "nothing changed".
    ///
    /// **What it throws there is `GitError.commandFailed`, in git's own words, not a
    /// `RemoteOperationError`.** A diagnosed cause is a statement about *the* operation, and a
    /// `--all` is several: "the repository could not be found" is false for every remote that
    /// succeeded, and it throws away the one thing only git knows — which remote failed. Git's
    /// stderr names the loser and shows the successes, so a UI that shows it is telling the
    /// truth about a half-failure that has no single cause. A single-remote fetch is diagnosed
    /// as before: there, one cause is the whole truth. The words are redacted
    /// (`RemoteFailureParser.redactingCredentials`) before they leave here, because a remote URL
    /// can have a token in it.
    ///
    /// `progress` receives git's stderr progress lines as they arrive — "remote: Counting
    /// objects: 57% (4/7)" — each already trimmed of the padding spaces git uses to erase the
    /// longer line before it, and never empty. **It is called on a background queue** (the
    /// pipe's readability queue, see `ProcessRunner.runStreaming`), never on the caller's
    /// executor and never on the main actor, and it must not block: the pipe is not drained
    /// while it runs. A callback that wants to update the UI hops to the main actor itself.
    ///
    /// - Throws: `RemoteOperationError` for a network failure Gitter recognises,
    ///   `GitError.commandFailed` with git's own words for one it does not, and
    ///   `CancellationError` if the task was cancelled.
    func fetch(
        remote: String?, at root: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws

    /// Send `branch` to `remoteRef` on `remote`:
    /// `git push --porcelain --progress --no-follow-tags [-u] --end-of-options <remote>
    /// refs/heads/<branch>:<remoteRef>`.
    ///
    /// **One ref goes to the server, and it is the one named here.** `--no-follow-tags` is on
    /// this vector and on both lease vectors for the reason `fetch` carries `--no-prune`:
    /// leaving `--follow-tags` out does not keep tags off the server, because
    /// `push.followTags=true` turns it on from the user's own configuration. Measured on git
    /// 2.54, every one of the four vectors then also published annotated tags — the **delete**
    /// included. Pushing tags is not in this milestone and no confirmation names one. The full
    /// measured table, and the neighbouring keys that were checked and cannot re-enable it, are
    /// in `CLIGitBackend+Push.swift`.
    ///
    /// **The backend never works out where a branch goes.** `remote` and `remoteRef` are the
    /// caller's to choose, and there is exactly one way to choose them: `PushTarget.resolve`,
    /// which reads `Branch.pushRemote` / `Branch.pushRef` and never `upstreamRemote` /
    /// `upstreamRef` — under `branch.<name>.pushRemote` or `remote.pushDefault` those name a
    /// different repository than the one the branch pushes to. See `PushTarget` for the rules
    /// and the measured rows behind them.
    ///
    /// **The outcome is read from `--porcelain` stdout, never from the exit code.** Every
    /// rejection exits 1, so the code cannot tell one from another; and the code is not even
    /// about our ref — measured on git 2.54, a push whose branch went through while a second
    /// refspec was refused exits 1 all the same. `PushPorcelainParser` matches the result line
    /// by the destination that was asked for, so a result line for a ref nobody here named is
    /// skipped rather than mistaken for ours. Since `--no-follow-tags` joined the vectors, a
    /// push **Gitter** makes can no longer produce one; the rule stays because the parser is a
    /// pure function over stdout and must not depend on the vector being spelled right.
    ///
    /// **A rejection comes back rather than being thrown**, as a merge conflict does for
    /// `MergeOutcome`: the server considered the push and said no, which is a different fact
    /// from "git could not run" or "the host could not be reached".
    ///
    /// **`remoteMessages` is filled in for every outcome, success included.** The hosting
    /// service's "create a pull request" URL is printed by a `post-receive` hook *after* the
    /// push has gone through, and arrives exactly as a declining hook's reason does — as
    /// `remote:` lines on stderr. See `PushResult`.
    ///
    /// **What `-u` writes, and the trap in it.** Measured on git 2.54: `-u` sets
    /// `branch.<name>.remote` and `branch.<name>.merge` — the **upstream** — and leaves
    /// `branch.<name>.pushremote` alone. In a triangular setup (`branch.<name>.pushRemote` or
    /// `remote.pushDefault` pointing somewhere else) a `push -u <pushRemote>` therefore
    /// *repoints the upstream* at the repository being pushed to, so the branch afterwards
    /// fetches from and counts its ahead/behind against a different server than it did before:
    ///
    /// ```
    /// $ git config branch.tri.pushRemote fork       # upstream is origin/tri
    /// $ git push --porcelain --progress -u --end-of-options fork refs/heads/tri:refs/heads/tri
    /// branch 'tri' set up to track 'fork/tri'.
    /// $ git config --get-regexp '^branch\.tri\.'
    /// branch.tri.remote fork
    /// branch.tri.pushremote fork
    /// branch.tri.merge refs/heads/tri
    /// ```
    ///
    /// `merge` is likewise set to `remoteRef`, whatever it is: publishing `other` to
    /// `refs/heads/renamed` leaves the branch tracking `origin/renamed`. A caller that offers
    /// `setUpstream: true` for anything but a first publish onto the branch's own name owes the
    /// user a word about that.
    ///
    /// **`-u` is best-effort in git, so Gitter reads it back.** git writes the upstream *after*
    /// the push and does not fail the push when it cannot: measured on git 2.54 with
    /// `.git/config` made unwritable, the push goes through, git exits **0**, the `branch '…'
    /// set up to track '…'.` notice is absent, and the explanation is two `error:` lines on
    /// stderr with no `remote:` prefix — which neither the porcelain parser nor
    /// `remoteMessages` reads. Every implementation therefore reads the configuration back
    /// after a `setUpstream: true` push and answers in `PushResult.upstream`, which
    /// distinguishes `.set`, `.notSet` and `.unknown` (the read-back itself could not be run —
    /// a state that occurs *with* the upstream correctly written, so it must never be worded
    /// as "not set"); git's own
    /// `error:` lines come back in `PushResult.errorLines` so the caller can quote them.
    ///
    /// **Names are refused before git runs**, and the refusal really is a no-op: `branch` by
    /// `requireName`'s rules plus "no `:`", `remote` by the same three shapes `fetch` refuses
    /// (`RemoteOperationError.noRemote`), and `remoteRef` must be a full `refs/heads/…` name
    /// with no `:` in it. Both sides go into one refspec argument, so a `:` in either would
    /// make a refspec with a destination nobody chose.
    ///
    /// **A cancelled push says nothing about the server.** Cancelling terminates git wherever
    /// it had got to, which may be after the server accepted the update and before this end
    /// heard about it, so the call throws `CancellationError` and the remote may or may not have
    /// been written. Never render that as "nothing was pushed": fetch and look.
    ///
    /// `progress` receives git's stderr progress lines as they arrive, on a background queue —
    /// see `fetch` for the full threading contract.
    ///
    /// - Throws: `BranchOperationError.invalidName` or `RemoteOperationError.noRemote` for a
    ///   name refused before git runs (nothing happened), `RemoteOperationError` for a network
    ///   failure Gitter recognises, `GitError.commandFailed` with git's own words for one it
    ///   does not, and `CancellationError` if the task was cancelled.
    func push(
        _ branch: String, to remote: String, remoteRef: String, setUpstream: Bool,
        at root: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws -> PushResult

    /// Send `branch` to `remoteRef` on `remote` **over commits the server already has**, but
    /// only while that ref is still at `expectedRemoteTip`:
    /// `git push --porcelain --progress --no-follow-tags --force-with-lease=<remoteRef>:<tip>
    /// --end-of-options <remote> refs/heads/<branch>:<remoteRef>`.
    ///
    /// **This is the operation that can destroy somebody else's commits, and the lease is the
    /// whole of what stands between it and that.** `expectedRemoteTip` is the sha the
    /// confirmation sheet showed while it counted what would be lost. git compares it against
    /// what the server holds *at the moment of the push*, and refuses with
    /// `.rejected(.staleLease)` — `[rejected] (stale info)` — if they differ, leaving the
    /// server untouched. The stale-confirmation rule of the previous milestone, enforced by the
    /// server rather than by a re-read that could itself be overtaken.
    ///
    /// **The sha is spelled out because the alternative is a lease that lies.** A bare
    /// `--force-with-lease` leases against `refs/remotes/<remote>/<branch>` — a ref *Gitter's
    /// own auto-fetch rewrites*. Measured on git 2.54, the same divergence with the colleague's
    /// newest commit fetched between the sheet and the push: the explicit-sha form answers
    /// `[rejected] (stale info)` and the bare form exits **0** with `(forced update)` and the
    /// colleague's commit off the branch. So the sha is passed, and `refs/remotes/*` is never
    /// consulted by this method — deleting the tracking ref first, or fetching first, changes
    /// nothing about the outcome (all three are tested).
    ///
    /// **The lease names the destination**, `<remoteRef>`, not the local branch: it is a
    /// statement about a ref on the server, and under a rename or a `remote.<name>.push`
    /// refspec those are two different refs.
    ///
    /// **`expectedRemoteTip` must be a full object name** — 40 or 64 lower-case hex characters,
    /// and not all zeros — or `RemoteOperationError.invalidLease` is thrown before git runs. See
    /// that case for the five shapes measured and why three of them are accepted by git and
    /// still wrong.
    ///
    /// **A forced push and a fast-forward are told apart, truthfully.** When the server is
    /// exactly at the lease and the local branch is ahead of it, nothing is discarded and git
    /// says so: the porcelain flag is a space and the summary is `<from>..<to>`, so the outcome
    /// is `.pushed` and not `.forced`. A backend that reported `.forced` for every leased push
    /// would have Gitter announce a loss that did not happen.
    ///
    /// Everything else is `push`'s: the outcome is read from `--porcelain` stdout and never
    /// from the exit code, a rejection is an outcome rather than an error, `remoteMessages`
    /// carries the server's words for every outcome, and the names are refused before git runs
    /// by the same three checks. `PushResult.upstream` is always `.notRequested` — a force
    /// push is never asked to write an upstream.
    ///
    /// **A cancelled force push says nothing about the server**, exactly as a cancelled `push`
    /// does, and here the stakes are higher: it may have been cancelled after the server
    /// accepted the rewrite and before this end heard about it. Never render it as "nothing was
    /// pushed"; fetch and look.
    ///
    /// - Throws: `RemoteOperationError.invalidLease` for an expected tip that is not a full
    ///   object name, `BranchOperationError.invalidName` or `RemoteOperationError.noRemote` for
    ///   a name refused before git runs (nothing happened in any of the three cases),
    ///   `RemoteOperationError` for a network failure Gitter recognises,
    ///   `GitError.commandFailed` with git's own words for one it does not, and
    ///   `CancellationError` if the task was cancelled.
    func forcePush(
        _ branch: String, to remote: String, remoteRef: String, expectedRemoteTip: String,
        at root: URL, progress: @escaping @Sendable (String) -> Void
    ) async throws -> PushResult

    /// Delete `branch` on `remote`, but only while it is still at `expectedTip`:
    /// `git push --porcelain --progress --no-follow-tags
    /// --force-with-lease=refs/heads/<branch>:<tip> --end-of-options <remote>
    /// :refs/heads/<branch>`.
    ///
    /// **`--no-follow-tags` is not redundant here, surprising as that is.** Measured on git
    /// 2.54 with `push.followTags=true`, a push whose only refspec deletes a ref *still*
    /// publishes annotated tags: `-⇥:refs/heads/doomed⇥[deleted]` arrived with
    /// `*⇥refs/tags/annotated:…⇥[new tag]` beside it. A sheet that said "the branch will be
    /// deleted" would have been followed by a tag appearing on the server.
    ///
    /// The refspec with an empty source side is how a branch is deleted on a server; `--delete`
    /// and `-d` say the same thing and are both forbidden in this package, because the lease is
    /// what makes the deletion answerable for and a flag would invite writing it without one.
    ///
    /// **The lease is the same mechanism as `forcePush`'s, and it matters as much.** The sheet
    /// says how many of the branch's commits exist nowhere else
    /// (`commitsOnlyOnRemoteBranch`); a commit pushed to that branch while the sheet was open
    /// was never in that count. With the tip pinned, git answers `.rejected(.staleLease)` and
    /// the branch stays. `expectedTip` is validated exactly as `forcePush`'s is —
    /// `RemoteOperationError.invalidLease`, before git runs.
    ///
    /// **What a successful delete does on this side, measured on git 2.54.** git removes the
    /// local `refs/remotes/<remote>/<branch>` along with the remote ref — a prune of the one
    /// ref the command is about, with no `--prune` anywhere, which is why `fetch`'s `--no-prune`
    /// does not contradict it. The **local branch is untouched**, and so is its configuration:
    /// `branch.<b>.remote` and `branch.<b>.merge` stay, which is precisely what makes the
    /// branch's tracking read `[gone]` afterwards.
    ///
    /// **Two refusals come from the server rather than from here.** Deleting the branch the
    /// server's HEAD points at is denied by default — measured against a bare repository:
    /// `[remote rejected] (deletion of the current branch prohibited)`, with `remote: error:
    /// refusing to delete the current branch: refs/heads/main` beside it — and it is
    /// configuration (`receive.denyDeleteCurrent`), not a law, so it is asked rather than
    /// assumed. Deleting a branch that is **not there** is `[rejected] (stale info)`: the lease
    /// named a sha and the ref holds nothing. Both come back as outcomes for the caller to say
    /// something true about; neither is smoothed into a success.
    ///
    /// There is no `progress` parameter because a deletion transfers no objects: git sends one
    /// command and prints no counters. It is still cancellable, and a cancelled deletion says
    /// nothing about whether the server carried it out.
    ///
    /// - Throws: the same set as `forcePush`.
    func deleteRemoteBranch(
        _ branch: String, on remote: String, expectedTip: String, at root: URL
    ) async throws -> PushResult

    /// Replay the current branch's own commits on top of `upstream`:
    /// `git rebase --end-of-options <upstream>`. The "Rebase" answer in the pull sheet.
    ///
    /// **It is the one method here that talks to no remote.** `upstream` is whatever the fetch
    /// before it left in `refs/remotes/*`; it is on this protocol because a pull is, and it is
    /// not cancellable in any sense that matters — a rebase is local and quick, and killing one
    /// half-way would leave a rebase in progress rather than nothing.
    ///
    /// `upstream` is a **ref name or a full object name** — `origin/main`,
    /// `refs/remotes/origin/main`, a sha — refused as `BranchOperationError.invalidName` before
    /// git runs when it is anything else, by the same guard as `commits(in:notIn:)`. git reads
    /// the argument as a revision, so `origin/main~1` would otherwise be accepted.
    ///
    /// **Refusals, all before anything changes** — and only ever thrown when no rebase is in
    /// progress after git ran. A rebase that stopped part-way can print refusal-shaped text
    /// (an untracked file in the way of a replayed commit, or a commit subject git echoes in
    /// "Could not apply …"); that is `.conflicts`, never one of these:
    /// - `.operationInProgress` while a merge, cherry-pick, revert, rebase, `am` or squash is
    ///   under way — asked of the repository, because git's own answer then is the tree
    ///   refusal, which names the wrong problem.
    /// - `.treeNotClean` over **any** uncommitted tracked change, staged or not, related or not
    ///   — Gitter's own check, because `rebase.autoStash=true` would otherwise have git stash
    ///   and re-apply it silently. See `BranchOperationError.treeNotClean`.
    /// - `.wouldOverwrite(tracked: [], untracked: […])` when an untracked file is where the
    ///   upstream has a tracked one: the checkout that starts the rebase refuses under its own
    ///   header ("could not detach HEAD"), and nothing moves (measured). Any other untracked
    ///   file is left alone and does not refuse.
    ///
    /// Anything else git says — a `pre-rebase` hook refusing, "fatal: invalid upstream" — is
    /// `GitError.commandFailed` in git's own words.
    ///
    /// **The outcome is read back, never taken from the exit code**: see `RebaseOutcome`.
    ///
    /// **Two things the user's configuration can add, measured on git 2.54 and not
    /// prevented**, because the vector is pinned by the scanner's contract test and carries no
    /// flag against them: `rebase.updateRefs=true` also moves every *other* local branch that
    /// points into the rewritten commits ("Updated the following refs with --update-refs"), and
    /// `rebase.backend=apply` keeps the stopped state in `rebase-apply/` rather than
    /// `rebase-merge/` (which `operationInProgress` already reads as `.rebase`). A plain rebase
    /// also **drops merge commits** among the branch's own commits, replaying what was under
    /// them — the sheet's "rewrites N commits" is true of the commits, not of their shape.
    ///
    /// **While it is stopped on a conflict, HEAD is detached.** `status --porcelain=v2 --branch`
    /// says `# branch.head (detached)`, so the snapshot's `status.branch` is nil, and HEAD may
    /// be a rewritten commit no ref holds yet — while `refs/heads/<b>` and its tracking counts
    /// have not moved at all. The operation guard is what keeps the detached-HEAD confirmation
    /// from being asked about that state.
    func rebase(onto upstream: String, at root: URL) async throws -> RebaseOutcome

    /// The commits reachable from `revision` but not from `base`, newest first, at most
    /// `limit` of them: `git log -n <limit> -z --format=… <base>..<revision> --`.
    ///
    /// What the force-push sheet lists. `commitCount(in:notIn:)` answers "how many"; this
    /// answers "which", so the sheet can name the author and the subject of work that is about
    /// to be taken off a branch — the difference between "3 commits will be discarded" and
    /// three lines the user recognises as somebody else's afternoon.
    ///
    /// **`limit` is clamped to at least 1.** `git log -n 0` prints nothing, so a caller whose
    /// arithmetic produced a zero would be handed an empty list and would draw a sheet saying
    /// nothing is at stake — the one wrong answer this pair must never give. A visibly
    /// incomplete list is recoverable; a false reassurance is not.
    ///
    /// **Both parameters are ref names, not revisions**, despite what they are called, and both
    /// are refused before git runs when they carry revision syntax. They are the two halves of
    /// one `<base>..<revision>` argument, so `base = "refs/heads/main."` would silently make it
    /// `refs/heads/main...<revision>` — the **symmetric** difference — and `revision = "a..b"`
    /// a range nobody chose. `..`, `^`, `~`, `:`, `@{…}` and a leading or trailing `.` are
    /// `BranchOperationError.invalidName`; see `requireRefNameOrObjectName` for the table.
    ///
    /// The accepted forms are a full ref name (`refs/heads/main`,
    /// `refs/remotes/origin/main`), a short remote-tracking name (`origin/main`), `HEAD`, and a
    /// full object name. A name git cannot resolve throws (`fatal: bad revision …`) rather than
    /// answering with an empty list, for the same reason the limit is clamped.
    func commits(
        in revision: String, notIn base: String, limit: Int, at root: URL
    ) async throws -> [Commit]

    /// How many commits on `refs/remotes/<remoteBranch>` are held by **no** local branch, no
    /// tag and no other remote-tracking ref — the number the delete-a-remote-branch sheet is
    /// built on.
    ///
    /// `remoteBranch` is the short remote-tracking name, `origin/topic`, as git prints it.
    ///
    /// **The ref must not cover itself**, or the answer would always be 0, so it is excluded
    /// from `--remotes` — and the spelling is a fact measured rather than guessed:
    /// `--exclude=<pattern>` applies to the **next** `--branches`/`--tags`/`--remotes`, and its
    /// pattern lives in that option's own namespace. So the pattern is `origin/topic`, relative
    /// to `refs/remotes/`; `--exclude=refs/remotes/origin/topic` matches nothing and was
    /// measured returning 0 where the truth is 3.
    ///
    /// **The symbolic refs under `refs/remotes` are excluded as well, by name, because a symref
    /// is not an independent holder.** Measured: `--remotes` lists `refs/remotes/<r>/HEAD` as a
    /// ref of its own, so when it points at the branch being asked about it covers that
    /// branch's commits and the count comes back 0 for a deletion that would strand them. It
    /// holds nothing on its own — deleting the branch leaves it dangling.
    ///
    /// **They are listed (`for-each-ref --format='%(refname)%00%(symref)' refs/remotes`) and
    /// excluded one by one, not matched with `--exclude=*/HEAD`.** That glob stood here until
    /// Task 6's fix round, defended by "`HEAD` is not a valid branch name, so it costs
    /// nothing". Only a *whole-name* `HEAD` is refused: measured on git 2.54,
    /// `git check-ref-format --branch x/HEAD` prints `x/HEAD` and `git branch x/HEAD` succeeds,
    /// and `*` in an `--exclude` pattern crosses `/`. So the glob was wrong in **both**
    /// directions — it excluded a real `refs/remotes/other/x/HEAD` (3 where the truth is 0,
    /// over-warning) and missed every symref not called `HEAD`, such as one `git symbolic-ref
    /// refs/remotes/origin/default` makes (0 where the truth is 3, which is the direction that
    /// costs work). Naming them is exact in every case and costs one extra `for-each-ref`.
    ///
    /// **What is *not* treated as a holder, said plainly, because Task 8's sheet has to word
    /// this.** The question asked is "held by no branch, tag or other remote-tracking ref" —
    /// `--branches`, `--tags` and `--remotes`, and nothing else. It is **not** "unreachable"
    /// and must never be worded that way: `refs/stash`, `refs/notes/*` and any other ref
    /// outside those three namespaces are not consulted, nor is a **detached HEAD**, nor
    /// another **worktree's** HEAD or index, nor the **reflog** — which keeps a deleted
    /// branch's commits alive for `gc.reflogExpire` (90 days by default) and is exactly why a
    /// commit this count calls stranded is usually still recoverable by hand. The truthful
    /// phrase for a sheet is **"held by no branch, tag or other remote"**.
    ///
    /// The name is refused before git runs when it is empty, begins with `-`, contains a glob
    /// character (`*`, `?`, `[`), or is a revision rather than a ref name (see
    /// `commits(in:notIn:limit:)` for the accepted forms). Git's own `check-ref-format` forbids
    /// the globs in a ref name, and one of them in the `--exclude=` argument would exclude refs
    /// nobody named and **inflate** the count — a sheet warning about commits that are in fact
    /// safe elsewhere.
    func commitsOnlyOnRemoteBranch(_ remoteBranch: String, at root: URL) async throws -> Int
}
