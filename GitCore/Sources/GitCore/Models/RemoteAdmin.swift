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
}

/// A remote-administration action that stopped part-way and left something behind — not a
/// refusal: what it names is in the repository now, or (the two `…OutcomeUnknown` cases) may
/// be. Task 3 adds rename's and remove's half-done states here.
public enum RemoteAdminPartial: Error, Sendable, Hashable {
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
    /// The branch is in use by a worktree — this one or another — at `path`: checked out there
    /// (`%(worktreepath)`), or being rebased or bisected there, which is how git itself counts
    /// it (`branch -f` refuses the same branches). `update-ref` refuses none of them (R15), and
    /// moving one leaves that worktree showing a staged reversal. The checked-out branch keeps
    /// today's Pull.
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
