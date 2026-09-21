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
/// - **No force flag, no refspec beginning with `+`, never a prune, and never `git pull`.** The
///   same rule the branch protocol lives under, enforced the same way: `ForceFlagScannerTests`
///   fails the build if one appears anywhere in `GitCore/Sources`, and the exact argument
///   vectors this protocol's implementation writes are pinned there as a contract before the
///   code that writes them exists.
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
}
