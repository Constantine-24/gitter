import Foundation

/// One ref and the id it held when it was read — a remote-tracking ref a prune would delete.
/// Both are spelled in full: `ref` is `refs/remotes/<remote>/<branch>` (never a short name a
/// tag or a branch could shadow), `id` is a full object id. The id is what the delete compares
/// against, and what the notice names afterwards: a pruned remote-tracking ref has no reflog
/// (R7), so this id is the only way back.
public struct RefTip: Sendable, Hashable {
    public let ref: String
    public let id: String

    public init(ref: String, id: String) {
        self.ref = ref
        self.id = id
    }
}

/// The commits that would be reachable from **no other ref** once a set of remote-tracking refs
/// is deleted — counted once, as a union over the whole set (R5: per-ref counts under-count).
public struct StrandedCommits: Sendable, Hashable {
    /// How many there are, exactly.
    public let count: Int
    /// The newest of them, for display: at most `StrandedCommits.displayLimit`.
    public let commits: [CommitRef]
    /// The refs of the set that reach at least one of them — the ones a "keep a local branch"
    /// can be offered for, in the order the set was given.
    public let holders: [String]

    public init(count: Int, commits: [CommitRef], holders: [String]) {
        self.count = count
        self.commits = commits
        self.holders = holders
    }

    /// Nothing stranded.
    public static let none = StrandedCommits(count: 0, commits: [], holders: [])

    /// How many commits `commits` lists at most.
    public static let displayLimit = 20
}

/// What "Prune <remote>…" would delete: every remote-tracking ref of `remote` the server no
/// longer has, with the id each one holds, and what deleting them all would strand.
public struct PrunePlan: Sendable, Hashable {
    public let remote: String
    public let refs: [RefTip]
    public let stranded: StrandedCommits

    public init(remote: String, refs: [RefTip], stranded: StrandedCommits) {
        self.remote = remote
        self.refs = refs
        self.stranded = stranded
    }
}

/// One ref a prune did not delete, for a reason that is not "it moved": git refused the
/// compare-and-delete — a lock another git process holds, a `reference-transaction` hook — or
/// the delete could not be started at all. `gitsWords` is git's own (redacted) words, or the
/// launch failure's. A refused compare-and-delete changes nothing, so the ref is where it was.
public struct RefFailure: Sendable, Hashable {
    public let tip: RefTip
    public let gitsWords: String

    public init(tip: RefTip, gitsWords: String) {
        self.tip = tip
        self.gitsWords = gitsWords
    }
}

/// What a prune did. Every deleted ref is named with the id it held (the only way back, R7).
public struct PruneResult: Sendable, Hashable {
    /// Deleted, each at the id the sheet showed.
    public let deleted: [RefTip]
    /// Left alone because the ref no longer held the id the sheet showed — moved, or already
    /// gone (RF1). Each carries the id the sheet showed.
    public let skippedMoved: [RefTip]
    /// The local branches created before anything was deleted, in the plan's order.
    public let keptBranches: [String]
    /// Left alone because git refused the delete for a reason of its own; every ref after one
    /// of these was still tried.
    public let failed: [RefFailure]
    /// The prune was cancelled while this ref's delete was running: git was stopped part-way, so
    /// whether the ref is gone is **not known** — read it back. At most one.
    public let outcomeUnknown: [RefTip]
    /// Not tried, because the prune was cancelled first: each is exactly where it was.
    public let notTried: [RefTip]

    public init(
        deleted: [RefTip], skippedMoved: [RefTip], keptBranches: [String], failed: [RefFailure] = [],
        outcomeUnknown: [RefTip] = [], notTried: [RefTip] = []
    ) {
        self.deleted = deleted
        self.skippedMoved = skippedMoved
        self.keptBranches = keptBranches
        self.failed = failed
        self.outcomeUnknown = outcomeUnknown
        self.notTried = notTried
    }
}

/// A local branch whose upstream is configured and no longer exists (`%(upstream:track)` is
/// `[gone]`, R9) — a remote upstream pruned away, or a local (`.`) upstream deleted.
public struct GoneBranch: Sendable, Hashable {
    /// The short name (`topic`, not `refs/heads/topic`).
    public let name: String
    /// Its tip, a full object id.
    public let tip: String
    /// The gone upstream, as a full ref name: `refs/remotes/origin/topic`, or `refs/heads/base`
    /// for a local upstream.
    public let upstream: String
    /// Commits on no other ref (`commitsOnlyOn`, the branch delete's own count): 0 means a
    /// delete loses nothing.
    public let uniqueCommits: Int
    /// The worktree it is checked out in — this one or another (`%(worktreepath)`) — or nil.
    /// git refuses to delete a branch checked out anywhere (R10).
    public let checkedOutAt: String?

    public init(name: String, tip: String, upstream: String, uniqueCommits: Int, checkedOutAt: String?) {
        self.name = name
        self.tip = tip
        self.upstream = upstream
        self.uniqueCommits = uniqueCommits
        self.checkedOutAt = checkedOutAt
    }
}

/// A remote-administration action Gitter refused. Each is thrown before anything was deleted.
public enum RemoteAdminRefusal: Error, Sendable, Hashable {
    /// The remote's fetch refspec (the associated value) writes outside `refs/remotes/` — a
    /// mirror remote lists local branches as prunable (R3). Refused before git runs, as fetch
    /// refuses it.
    case unsafeRefspec(String)
    /// More commits would be stranded now than the sheet said: something changed since.
    case strandedGrew
    /// A branch to keep cannot be created under this name: a branch, a tag, a remote-tracking
    /// branch or a remote has it already (compared ignoring case, as the file system does), or
    /// two kept refs were given the same name.
    case branchExists(String)
    /// An id that is not a full (40 or 64 lower-case hex digits), non-zero object id, refused
    /// before git ran: an empty or all-zero expected value makes `update-ref -d` delete
    /// unconditionally (R6, B19), and makes a fast-forward's compare-and-set a plain move.
    case invalidObjectID
    /// No remote of this name is configured.
    case noSuchRemote(String)
    /// A name a kept branch cannot have: git's `check-ref-format --branch` refuses it, or it is
    /// one New Branch refuses (`refs/…`, `heads/…`, `@`, `@{…}`), or a root-ref name
    /// (`HEAD`, `MERGE_HEAD`, …) that would shadow git's own (Ruling 1).
    case invalidBranchName(String)

    // B2 Task 3: remote management. Each is thrown with nothing written.

    /// A name Add Remote or Rename Remote cannot give a remote (`RemoteNameProblem`).
    case nameProblem(RemoteNameProblem)
    /// A URL Gitter does not write: empty, beginning with `-` (an option to whatever transport
    /// reads it, `-oProxyCommand=…`), an `ext::` command line (R20: stored without a word, run
    /// by git's `ext` transport), or one holding a control character. Refused before git runs.
    case unsafeURL
    /// The remote has more than one `url` (or, when a push URL is being set, more than one
    /// `pushurl`): a plain `set-url` fails on it (R22, exit 128), and which one to replace is a
    /// choice the sheet does not offer. Shown read-only instead.
    case severalURLs
    /// What Remove Remote would delete, strand or change is no longer what the sheet showed
    /// (RF1): a ref moved, appeared or went, a branch's upstream or push remote changed.
    case impactChanged
}

// MARK: - Remote management (B2 Task 3)

/// Why a name cannot be given to a remote — by Add Remote, or as the new name of Rename Remote.
/// Git's own rule plus Gitter's (R19).
public enum RemoteNameProblem: Sendable, Hashable {
    /// Empty, or only whitespace.
    case empty
    /// git refuses it (`fatal: '<n>' is not a valid remote name`: `.`, `a..b`, `x.lock`,
    /// `trail/`, a space, …), or Gitter does: a leading `-` (git accepts `-x` after
    /// `--end-of-options`, and every Gitter vector would then have to keep it from being read as
    /// an option), or a control character.
    case invalid
    /// `HEAD` or `@`: git accepts both (R19), and both already mean something to git's revision
    /// syntax.
    case reserved
    /// A remote of this name is configured — compared ignoring case, as the file system
    /// compares `refs/remotes/<name>/`: `Origin` beside `origin` would share their refs on a
    /// case-insensitive volume. A remote with no URL counts.
    case exists
    /// The name is inside the namespace of the configured remote named here, or that remote is
    /// inside its namespace (`origin/sub` beside `origin`, or `up` beside `up/stream`): git
    /// refuses both ("is a subset of" / "is a superset of existing remote"), and their
    /// remote-tracking refs would share a directory. Compared ignoring case.
    case nested(String)
}

/// A remote's URLs **as the configuration writes them** (spec, promise 5) — never the
/// `insteadOf`-rewritten ones `git remote -v` prints (R20): an Edit URL sheet pre-filled from
/// those and saved would replace the user's `https://…` with the rewritten `git@…` for good.
public struct RemoteURLs: Sendable, Hashable {
    /// Every `remote.<name>.url`, in order (`config --get-all`). git fetches from the first.
    /// Empty for a remote with no URL (R22).
    public let fetch: [String]
    /// Every `remote.<name>.pushurl`, in order. Empty when the remote pushes to its fetch URL.
    public let push: [String]
    /// Where git really fetches from: the first `url` after every `url.<base>.insteadOf`
    /// rewrite (`ls-remote --get-url`, which contacts nothing — verified). Nil when the remote
    /// has no URL, or its first is empty (git would then use the remote's name as a path).
    /// For display only, and only when it differs: "git connects to …".
    public let effectiveFetch: String?

    public init(fetch: [String], push: [String], effectiveFetch: String?) {
        self.fetch = fetch
        self.push = push
        self.effectiveFetch = effectiveFetch
    }
}

/// What Edit URL does to a remote's push URL (fix round 1, I3).
public enum PushURLChange: Sendable, Hashable {
    /// Every `pushurl` stays as it is.
    case unchanged
    /// The push URL becomes this one (`remote set-url --push`).
    case set(String)
    /// No push URL: the remote pushes to its fetch URL again (`config --unset-all
    /// remote.<n>.pushurl`). With none configured, nothing is written.
    case clear
}

/// A local branch whose push destination Remove Remote changes **without being asked**: its
/// push went to the removed remote through `branch.<b>.pushRemote` or `remote.pushDefault`, and
/// git unsets both (R23) — so the branch silently starts pushing wherever is left.
public struct PushRedirect: Sendable, Hashable {
    /// The branch's short name.
    public let branch: String
    /// Where its push goes afterwards, by the rule git applies (`branch.<b>.pushRemote`, then
    /// `remote.pushDefault`, then `branch.<b>.remote`) with every setting git unsets gone — those
    /// naming the removed remote **in the repository's own configuration**: a remote's name, `.`
    /// (its upstream is a local branch), or nil — nothing configured, so Gitter offers Publish…
    /// (a bare `git push` would fall back to `origin`). It can be the removed remote's own name:
    /// git keeps a setting from another scope (a global or worktree `remote.pushDefault`,
    /// measured), and the branch then pushes to a remote that no longer exists.
    public let nowPushesTo: String?

    public init(branch: String, nowPushesTo: String?) {
        self.branch = branch
        self.nowPushesTo = nowPushesTo
    }
}

/// Everything "Remove <remote>…" would delete, strand and change, read before the sheet opens
/// and compared again, whole, before git runs (RF1).
public struct RemovalImpact: Sendable, Hashable {
    public let remote: String
    /// Every ref `git remote remove` deletes, with the id each holds now (R23: a deleted
    /// remote-tracking ref loses its reflog, so this id is the only way back). Exactly what git
    /// deletes: the `refs/remotes/` refs one of the remote's fetch refspecs maps (a negative
    /// refspec honoured) and no other remote's does — so under a custom refspec this can hold a
    /// ref outside `refs/remotes/<remote>/`, and a symbolic `refs/remotes/<remote>/HEAD` (its id
    /// is its target's). In ref order.
    public let refs: [RefTip]
    /// The commits only `refs` hold, counted once as a union (R5, Ruling 5).
    public let stranded: StrandedCommits
    /// The local branches whose upstream is on this remote (`branch.<b>.remote`): git unsets
    /// their `remote` and `merge` (R23), so they are left with **no** upstream — not `[gone]` —
    /// and keep `branch.<b>.rebase`. Short names, in ref order.
    public let upstreamOf: [String]
    /// The local branches that push to this remote through `pushRemote` or `pushDefault`, and
    /// where each pushes afterwards. In ref order.
    public let pushRedirects: [PushRedirect]
    /// Refs under `refs/remotes/<remote>/` that `git remote remove` leaves behind, because none
    /// of its refspecs maps them (a custom refspec, a ref made by hand) and no other remote's
    /// does either: they stay, and show in the "Other" group. Full names, in ref order.
    public let leftBehind: [String]

    public init(
        remote: String, refs: [RefTip], stranded: StrandedCommits, upstreamOf: [String],
        pushRedirects: [PushRedirect], leftBehind: [String]
    ) {
        self.remote = remote
        self.refs = refs
        self.stranded = stranded
        self.upstreamOf = upstreamOf
        self.pushRedirects = pushRedirects
        self.leftBehind = leftBehind
    }
}

/// What a failed `git remote rename` left (R21), read back after it exited non-zero. git renames
/// the configuration section first and moves the refs and the branches' settings afterwards, so
/// a lock held by a concurrent fetch leaves the section renamed and the rest where it was.
///
/// When `configured == [new]` and `refsUnderNew` is empty, renaming `new` back to `old` restores
/// exactly the state before (measured: git rewrites no refspec, moves no ref and no setting,
/// since none name `new`), after which the rename can be tried again.
public struct RenameLeftover: Sendable, Hashable {
    public let old: String
    public let new: String
    /// Which of `old` and `new` are configured remotes now, in that order: `[new]` when git
    /// renamed the section and stopped.
    public let configured: [String]
    /// The fetch refspecs of the remote now named `new` that still write under
    /// `refs/remotes/<old>/` — a fetch through it updates the old refs.
    public let refspecsStillOld: [String]
    /// Every configuration key still naming `old` (`branch.<b>.remote`, `branch.<b>.pushremote`,
    /// `remote.pushdefault`), as git spells keys: those branches name a remote that is no longer
    /// configured, so they have no upstream at all.
    public let configStillNamingOld: [String]
    /// The refs still under `refs/remotes/<old>/`, and the refs now under `refs/remotes/<new>/`,
    /// full names in ref order.
    public let refsUnderOld: [String]
    public let refsUnderNew: [String]
    /// git's own (redacted) words.
    public let gitsWords: String

    public init(
        old: String, new: String, configured: [String], refspecsStillOld: [String],
        configStillNamingOld: [String], refsUnderOld: [String], refsUnderNew: [String], gitsWords: String
    ) {
        self.old = old
        self.new = new
        self.configured = configured
        self.refspecsStillOld = refspecsStillOld
        self.configStillNamingOld = configStillNamingOld
        self.refsUnderOld = refsUnderOld
        self.refsUnderNew = refsUnderNew
        self.gitsWords = gitsWords
    }
}

/// What a failed `git remote remove` left (R23), read back after it exited non-zero. git unsets
/// every branch's `remote`/`merge`/`pushRemote` naming the remote, and `remote.pushDefault`,
/// **before** it deletes the refs and the section — so a lock held by a concurrent fetch leaves
/// the remote and its refs and the branch settings already gone. Running the removal again
/// finishes it (measured).
public struct RemovalLeftover: Sendable, Hashable {
    public let remote: String
    /// Whether `remote.<remote>` is still configured.
    public let stillConfigured: Bool
    /// The refs of the sheet's `refs` that are still there, each with the id it holds now.
    public let refsLeft: [RefTip]
    /// The refs of the sheet's `refs` that are gone, each with the id the sheet showed — the
    /// only way back (R7).
    public let refsDeleted: [RefTip]
    /// The configuration keys naming the remote that git had already unset
    /// (`branch.<b>.remote`, `.merge`, `.pushremote`, `remote.pushdefault`), as git spells keys.
    public let configRemoved: [String]
    /// The local branches created to keep stranded commits, before git ran. They stay.
    public let keptBranches: [String]
    /// git's own (redacted) words.
    public let gitsWords: String

    public init(
        remote: String, stillConfigured: Bool, refsLeft: [RefTip], refsDeleted: [RefTip],
        configRemoved: [String], keptBranches: [String], gitsWords: String
    ) {
        self.remote = remote
        self.stillConfigured = stillConfigured
        self.refsLeft = refsLeft
        self.refsDeleted = refsDeleted
        self.configRemoved = configRemoved
        self.keptBranches = keptBranches
        self.gitsWords = gitsWords
    }
}

/// A remote-administration action that stopped part-way and left something behind — not a
/// refusal: what it names is in the repository now, or (the `…OutcomeUnknown` cases) may be.
public enum RemoteAdminPartial: Error, Sendable, Hashable {
    // B2 Task 3: remote management. A failed git command is not assumed to be a no-op (spec,
    // promise 4): each failure is read back, and one that changed nothing stays git's words.

    /// `git remote rename` failed after changing something (R21): what it left.
    case renameHalfDone(left: RenameLeftover)
    /// `git remote remove` failed after changing something, or after Gitter created kept
    /// branches (R23): what it left.
    case removeHalfDone(left: RemovalLeftover)
    /// Rename Remote was cancelled while git ran: what the configuration and the refs hold now
    /// is **not known** — read them back.
    case renameOutcomeUnknown(old: String, new: String)
    /// Remove Remote was cancelled while git ran: whether the remote, its refs and the branch
    /// settings naming it are still there is **not known**. `keptBranches` were created before
    /// git ran and stay.
    case removeOutcomeUnknown(remote: String, keptBranches: [String])
    /// Add Remote or Edit URL was cancelled while git was writing: the remote's URLs are **not
    /// known** — read them back.
    case urlsOutcomeUnknown(remote: String)
    /// Add Remote or Edit URL failed (git's words, `gitsWords`) **after** writing part of what
    /// it was asked to: `now` is what the remote's configuration holds (nil: no such remote).
    /// `remote add` writes `url` and `fetch` one at a time; Edit URL writes the fetch URL and
    /// then the push URL.
    case urlsChangedThenFailed(remote: String, now: RemoteURLs?, gitsWords: String)

    /// A prune created the kept branches `kept` (in the plan's order), then could not create
    /// `failedName` — git's (redacted) words, or `.branchExists` for a name taken since the
    /// check — and stopped: **nothing was deleted**, and the branches in `kept` stay.
    case keptBranchesThenStopped(kept: [String], failedName: String, gitsWords: String)
    /// A fast-forward was cancelled while its compare-and-set was running: git was stopped
    /// part-way (or never started — the runner cannot say which), so `branch` is at `from` or
    /// at `to` and **which is not known** — read it back. Never "nothing changed".
    case fastForwardOutcomeUnknown(branch: String, from: String, to: String)
    /// Set or Unset Upstream was cancelled while git was writing `branch.<b>.*`, or while the
    /// write was being read back: what the configuration holds now is **not known**.
    case upstreamOutcomeUnknown(branch: String)
    /// Set or Unset Upstream failed (git's words, `gitsWords`) **after** changing the
    /// configuration: git writes `branch.<b>.remote` and `.merge` one at a time, so a failure
    /// between them leaves half. Read back: `remote` and `merge` are what the keys hold now
    /// (nil = not set; several values joined with ", ").
    case upstreamChangedThenFailed(branch: String, remote: String?, merge: String?, gitsWords: String)
}

// MARK: - Fast-forward and upstream (B2 Task 2)

/// What "Fast-Forward <branch>" did.
public enum FastForwardOutcome: Sendable, Hashable {
    /// The branch was moved from `from` (the tip the sheet showed) to `to` (its upstream's
    /// commit), both full ids, with the reflog entry `Gitter: fast-forward <b> to <upstream>`.
    case fastForwarded(from: String, to: String)
    /// The branch already held its upstream's commit: nothing was written.
    case upToDate
}

/// Why a fast-forward was refused. Every case is a refusal: **nothing was written**.
public enum FastForwardRefusal: Error, Sendable, Hashable {
    /// The branch is in use by a worktree — this one or another, a prunable one included — at
    /// `path`, as git itself counts it (`branch -f` refuses the same branches): checked out
    /// there, being rebased or bisected there, or due to be moved by a `rebase --update-refs`
    /// running there (fix round 1). `update-ref` refuses none of them (R15): moving one leaves
    /// that worktree showing a staged reversal, or that rebase unable to finish. The
    /// checked-out branch keeps today's Pull.
    case checkedOut(path: String)
    /// The branch has no upstream, or one that does not resolve: none configured, a
    /// `branch.<b>.remote` naming a remote that does not exist, a fetch refspec that does not
    /// map `branch.<b>.merge` (R16), or an upstream that is gone.
    case noUpstream
    /// The branch has this many commits its upstream does not, and its upstream has none it
    /// lacks: there is nothing to fast-forward to.
    case ahead(Int)
    /// Both sides have commits the other lacks: only a merge or a rebase could combine them.
    case diverged(ahead: Int, behind: Int)
    /// The branch no longer holds the tip the sheet showed — moved or deleted, before the check
    /// or between the check and the compare-and-set (RF1). git's compare-and-set refused, so
    /// whatever moved it is what the branch holds now.
    case moved
}

/// Why Set Upstream was refused. Every case but `mergeMismatch` is thrown before anything was
/// written.
public enum UpstreamRefusal: Error, Sendable, Hashable {
    /// The remote-tracking ref (a full name) does not exist: not fetched yet, or pruned since.
    case notFetched(String)
    /// The ref is not a remote branch a remote's fetch refspec maps — a ref in the "Other"
    /// group, a symbolic ref (`refs/remotes/<r>/HEAD`), or a ref outside `refs/remotes/` (R17:
    /// git's "starting point '…' is not a branch").
    case notABranch(String)
    /// Two remotes' fetch refspecs map the same tracking namespace, so git cannot tell which
    /// remote the branch would track (R17: "not tracking: ambiguous information for ref").
    case ambiguousNamespace(String)
    /// **git wrote the upstream**, and `branch.<b>.merge` read back is `written`, not the
    /// `expected` server branch: overlapping fetch refspecs make git reverse-map through the
    /// first that matches (R18), where the expected mapping is the most specific one. The
    /// configuration now says `written`; this is not a refusal of the write but the read-back
    /// saying the write is not what was asked for. When the remote written differs too (never
    /// measured), both values are spelled `<remote> <merge>`.
    case mergeMismatch(expected: String, written: String)
    /// The upstream asked for is the branch itself (`refs/heads/<branch>`): git only warns
    /// ("not setting branch '<b>' as its own upstream"), exits 0 and writes nothing (measured).
    case ownUpstream(String)
}

/// What Set Upstream wrote beyond the upstream itself.
///
/// Named `SetUpstreamResult`, not the plan's `UpstreamResult`: that name is the push `-u`
/// read-back's (`RemoteOperationTypes.swift`), public since the remote milestone.
public struct SetUpstreamResult: Sendable, Hashable {
    /// `branch.autoSetupRebase=always|remote` made git also write `branch.<b>.rebase=true`
    /// (R17): read before and after, true when it is `true` now and was not before — the pull
    /// of this branch now rebases.
    public let wroteRebase: Bool

    public init(wroteRebase: Bool) {
        self.wroteRebase = wroteRebase
    }
}
