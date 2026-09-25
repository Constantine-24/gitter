import AppKit
import Foundation
import GitCore
import Observation

/// What is shown in the detail pane: the working copy, or a specific commit.
enum Selection: Hashable {
    case workingCopy
    case commit(String)
}

@Observable @MainActor
final class RepositoryStore {
    private(set) var root: URL?
    private(set) var snapshot: RepoSnapshot?
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var gitMissing = false
    var selection: Selection = .workingCopy
    var selectedPath: String?
    private(set) var detailFiles: [FileStatus] = []
    private(set) var diff: [FileDiff] = []
    /// Which side the loaded `diff` came from. `stagedView` flips the instant the user picks a
    /// row, while the matching `git diff` is still running, so for the time in between the two
    /// disagree. Anything that has to describe the diff actually on screen — the hunk buttons'
    /// labels, the direction their patch is applied in — reads this instead of `stagedView`.
    private(set) var diffIsStaged = false
    var stagedView = false {
        didSet {
            guard stagedView != oldValue else { return }
            guard selection == .workingCopy, selectedPath != nil else { return }
            loadDiff()
        }
    }

    /// True while a stage/unstage/commit is running; mutations are serialized behind it and
    /// the UI disables its controls. Claimed and released through `beginMutation()` /
    /// `finishMutation(generation:failure:)`, kept in this file so their write to it stays
    /// `private(set)`.
    private(set) var isMutating = false

    /// The commit message being written. Stored properties cannot live in an extension, so it
    /// is declared here even though everything that drives it is in `RepositoryStore+Staging`.
    let draft = CommitDraft()

    /// Which confirmation or form is on screen. The one piece of store state views are meant to
    /// write: a `.sheet(item:)` binding puts nil back on dismissal. Opening one still goes
    /// through `+BranchSheets`, so the store decides which question gets asked.
    var activeSheet: BranchSheet?

    /// A short, non-error message about something that just succeeded ("Fast-forwarded to
    /// feature."). Unlike `lastError` it is never sticky and clears itself after a few seconds.
    private(set) var notice: String?

    /// The auto-clear for `notice`. Bookkeeping only; views must not touch it.
    // internal (not private): used by +Branches.swift's `showNotice(_:)`
    var noticeTask: Task<Void, Never>?

    /// The network lane: the one fetch, pull, push, publish, force push or remote delete that
    /// is running, or nil. See `RepositoryStore+Remotes` for what holds it and for how long.
    private(set) var remoteActivity: RemoteActivity?

    /// Why the last automatic fetch failed, for a quiet mark on the Fetch button. Never a
    /// banner: being offline is normal. Written by Task 11's scheduler.
    private(set) var lastAutoFetchFailure: String?

    /// The push the server just refused for having commits this branch lacks — the only state
    /// "Force Push…" is reachable from. Cleared by the next mutation or network action.
    private(set) var rejectedPush: RejectedPush?

    /// The task running the lane's work, so `cancelRemoteActivity()` can cancel it. Bookkeeping
    /// only, views must not touch it.
    // internal (not private): used by +Remotes.swift
    var remoteTask: Task<Void, Never>?

    /// Bumped by every `beginRemote`, so a progress line or a release from an earlier lane can
    /// never land on a later one.
    private var laneToken = 0

    /// A watcher event was dropped while the lane was busy, **after** the lane's own reload was
    /// begun (it is cleared as that reload starts). The reload covers everything before it; an
    /// event after it — a terminal commit in the instant between the reload and the lane
    /// freeing — would otherwise be lost until the next one, so `runOnLane` reloads once more
    /// when this is set. Only a path the lane does not write itself sets it: the lane's own
    /// writes (`FETCH_HEAD`, `refs/remotes/…`) arrive up to the watcher's 0.2 s latency late —
    /// after its reload began — and would otherwise cost every fetch a second reload. Which
    /// paths are "its own" depends on the kind of work (`RepositoryStore.isLaneOwnWrite`).
    private(set) var watcherEventDuringLane = false

    #if DEBUG
        /// How many snapshot loads have run, for the harness's "exactly one refresh when the
        /// lane frees" check.
        private(set) var snapshotLoadCount = 0

        // internal (not private): used by +Refresh.swift's `loadSnapshot()`
        func noteSnapshotLoad() {
            snapshotLoadCount += 1
        }

        /// The harness's `autofetchfailed:<reason>` step, so the Fetch item's quiet mark can be
        /// drawn before Task 11's scheduler exists to set it for real.
        func debugSetLastAutoFetchFailure(_ reason: String?) {
            lastAutoFetchFailure = reason
        }
    #endif

    /// Bumped by every `open()`. Anything loaded or run asynchronously captures it and drops
    /// its result if it no longer matches: comparing `root` is not enough, because reopening
    /// the *same* repository mid-flight leaves the root equal while everything on screen has
    /// been reset.
    private(set) var generation = 0

    /// True while `lastError` holds a message a mutation put there. Such a message outlives
    /// the reloads the mutation itself provokes; see `loadSnapshot()`.
    // Direct writes stay in this file; see `clearSticky()` / `clearErrorUnlessSticky()` below.
    private var errorIsSticky = false

    /// Everything the store can ask git to do: reads, index and commit writes, branch,
    /// checkout and merge writes, and the network. Four protocols so a fake can implement any
    /// one on its own.
    typealias Backend = any GitBackend & GitWorkingCopyBackend & GitBranchBackend & GitRemoteBackend

    let backend: Backend
    // internal (not private): used by +Opening.swift's `checkGitAvailability()`
    let gitPath: String

    private var watcher: RepositoryWatcher?
    // internal (not private), bookkeeping only, views must not touch this: used by +Refresh.swift
    var refreshTask: Task<Void, Never>?
    // internal (not private), bookkeeping only, views must not touch this: used by +Detail.swift
    var detailTask: Task<Void, Never>?
    // internal (not private), bookkeeping only, views must not touch this: used by +Detail.swift
    var diffTask: Task<Void, Never>?
    /// The most recently scheduled snapshot load; new ones chain behind it. See `refresh()`.
    // internal (not private), bookkeeping only, views must not touch this: used by +Refresh.swift
    var lastRefresh: Task<Void, Never>?
    /// True while a chained load exists that has not begun reading git yet.
    // internal (not private), bookkeeping only, views must not touch this: used by +Refresh.swift
    var refreshIsQueued = false

    // internal (not private): used by RepositoryStore+Opening.swift's `reopenLastRepository()`
    static let lastRepositoryPathKey = "lastRepositoryPath"

    init(
        backend: Backend = CLIGitBackend(),
        gitPath: String = "/usr/bin/git"
    ) {
        self.backend = backend
        self.gitPath = gitPath
    }

    // MARK: - Opening

    func open(_ url: URL) {
        // Once git itself is confirmed missing, no repository can be opened. Keep the banner
        // up instead of letting a reopen quietly clear it — and if the user dismissed it since,
        // put it back so "Open Repository…" doesn't silently do nothing.
        guard !gitMissing else {
            lastError = Self.gitMissingMessage(at: gitPath)
            // Sticky, like a mutation's own message: a repository may already be open, and its
            // watcher-driven reload succeeds and would clear this a fraction of a second later.
            errorIsSticky = true
            return
        }

        // A push, publish, force push or delete on a remote cannot be abandoned quietly:
        // cancelling it leaves the server in an unknown state, and the sentence that says so —
        // and the fetch that finds out — belong to *this* repository, which is about to be
        // replaced on screen. So opening another one waits: the user can Stop the write (and
        // read what that means here) and then open. A fetch or a pull's fetch writes nothing on
        // the server and is still cancelled below.
        if let remoteActivity, remoteActivity.isWrite {
            lastError = RemoteWording.openRefusedDuringWrite(remoteActivity)
            errorIsSticky = true
            return
        }

        let standardized = url.standardizedFileURL
        let dotGit = standardized.appending(path: ".git")
        guard FileManager.default.fileExists(atPath: dotGit.path) else {
            lastError = "Not a Git repository: \(standardized.path)"
            errorIsSticky = true
            return
        }

        watcher?.stop()
        watcher = nil

        refreshTask?.cancel()
        detailTask?.cancel()
        diffTask?.cancel()
        // `lastRefresh` is deliberately left in place: a load still in flight for the old root
        // writes nothing (it re-checks `root` before it lands), and keeping the chain intact
        // keeps this repository's first load from overlapping it.

        // Reset all repository-derived state so nothing from the previous repository lingers
        // on screen (or gets raced against) while the new repository's first snapshot loads.
        snapshot = nil
        detailFiles = []
        setDiff([], staged: stagedView)
        selection = .workingCopy
        selectedPath = nil
        lastError = nil
        errorIsSticky = false
        // A question asked about the previous repository ("delete this unmerged branch?") must
        // never be answered against this one, and its notice is about a repository nobody is
        // looking at any more.
        activeSheet = nil
        dismissNotice()
        // A half-written message belongs to the repository it was written for, and a mutation
        // in flight can only be for the old one.
        draft.reset()
        // Released here and not left to the mutation itself: the generation below makes its
        // `finishMutation` stale, and a stale one returns early — so without this the flag
        // would stay set for the new repository and every button would stay disabled.
        isMutating = false
        // A transfer for the previous repository is of no use to this one, and its lane must not
        // make this one's Fetch and Push read "busy". Its task drops its own result on the
        // generation below.
        remoteTask?.cancel()
        remoteTask = nil
        remoteActivity = nil
        rejectedPush = nil
        // Everything in flight for the previous repository — including a reopen of this very
        // path — is now stale and will drop its result.
        generation += 1

        root = standardized
        UserDefaults.standard.set(standardized.path, forKey: Self.lastRepositoryPathKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(standardized)

        watcher = RepositoryWatcher(path: standardized.path) { [weak self] paths in
            self?.scheduleRefresh(changed: paths)
        }

        Task { await refresh() }
    }

    // MARK: - Selection

    func select(_ newSelection: Selection) {
        selection = newSelection
        setDiff([], staged: stagedView)
        loadDetail()
    }

    func selectPath(_ path: String?) {
        selectedPath = path
        loadDiff()
    }

    // MARK: - State mutators for other files
    // Narrow setters for `private(set)` state whose writer lives in another file. Each pairs
    // with exactly the caller(s) named below; nothing else should call these.

    /// internal (not private(set) write): used by +Opening.swift's `checkGitAvailability()`
    func setGitMissing(_ value: Bool) {
        gitMissing = value
    }

    /// internal (not private(set) write): used by +Refresh.swift
    func setSnapshot(_ newSnapshot: RepoSnapshot?) {
        snapshot = newSnapshot
        // Here rather than in `+Refresh` because this is the one place the snapshot is written,
        // and "an operation has begun" is only ever learned from a new one. See
        // `reconcileAmendWithOperation` for why a ticked Amend cannot be left ticked.
        reconcileAmendWithOperation()
    }

    /// internal (not private(set) write): used by +Refresh.swift
    func setLoading(_ value: Bool) {
        isLoading = value
    }

    /// internal (not private(set) write): used by +Detail.swift
    func setDetailFiles(_ files: [FileStatus]) {
        detailFiles = files
    }

    /// internal (not private(set) write): used by +Branches.swift's `showNotice(_:)`/
    /// `dismissNotice()`, which own the auto-clear timing.
    func setNotice(_ message: String?) {
        notice = message
    }

    /// internal (not private(set) write): used by +Refresh.swift, +Detail.swift, +Errors.swift
    /// and +Opening.swift
    func setError(_ message: String?) {
        lastError = message
    }

    /// Clears `errorIsSticky` without touching `lastError`: what the original, unsplit code
    /// wrote as a bare `errorIsSticky = false` next to a `lastError` write it made its own way.
    /// internal (not private(set) write): used by +Refresh.swift, +Detail.swift, +Errors.swift
    func clearSticky() {
        errorIsSticky = false
    }

    /// The `if !errorIsSticky { lastError = nil }` a successful snapshot load does; the read has
    /// to move here too since `errorIsSticky` is only readable from this file.
    /// internal (not private(set) write): used by +Refresh.swift's `loadSnapshot()`
    func clearErrorUnlessSticky() {
        if !errorIsSticky {
            lastError = nil
        }
    }

    // MARK: - Mutation bookkeeping

    /// Claims the store for one git write, returning the generation to hand back to
    /// `finishMutation`, or nil when it cannot be claimed: no repository, or a mutation is
    /// already running (mutations are serialized, which is also what disables the buttons).
    ///
    /// This pair exists so the setters of `isMutating` and `lastError` can stay private while
    /// the staging API lives in another file, where `private(set)` would not reach.
    // internal (not private): used by +Staging.swift's `mutate()`
    func beginMutation() -> Int? {
        guard root != nil, !isMutating else { return nil }
        isMutating = true
        // "Force Push…" answers the refusal of *that* push. Once anything else has happened the
        // branch may not be where it was, and the banner offering it goes with it.
        rejectedPush = nil
        // A new attempt supersedes the last one's message: it has been read or ignored by
        // now, and nothing should keep protecting it from the reloads that follow.
        if errorIsSticky {
            lastError = nil
            errorIsSticky = false
        }
        // Same for a success notice, which would otherwise sit next to this attempt's banner
        // claiming the previous action worked — true, but read as if it were about this one.
        dismissNotice()
        return generation
    }

    /// Releases the claim `beginMutation()` made, showing `failure` in the banner if there was
    /// one. A stale generation means `open()` has already reset everything this would write.
    /// internal (not private): used by +Staging.swift's `mutate()`; kept next to `beginMutation`.
    func finishMutation(generation: Int, failure: Error?) {
        guard self.generation == generation else { return }
        if let failure {
            lastError = Self.describe(failure)
            // Protected from the reloads this mutation set off — its own, and the
            // watcher-driven one that git's writes inside `.git` trigger in parallel.
            errorIsSticky = true
        }
        isMutating = false
    }

    // MARK: - Network lane bookkeeping

    /// Claims the network lane — and, for a write, the mutation slot as well — returning the
    /// ticket to hand back to `finishRemote`, or nil when it cannot be claimed. A refusal says
    /// why in the banner: a second network action is refused with a reason, never queued and
    /// never silently dropped.
    ///
    /// `quiet` is for the follow-up fetch after a cancelled or failed write: it must not clear
    /// the banner that says the remote may or may not have changed, which is the one thing the
    /// user has to read.
    // internal (not private): used by +Remotes.swift's `runOnLane`
    func beginRemote(
        _ kind: RemoteActivity.Kind, remote: String?, holdingMutation: Bool, quiet: Bool = false
    ) -> RemoteLane? {
        guard root != nil else { return nil }
        if let remoteActivity {
            if !quiet { showStickyError(RemoteWording.laneBusy(remoteActivity)) }
            return nil
        }
        watcherEventDuringLane = false
        var mutationGeneration: Int?
        if holdingMutation {
            guard let claimed = beginMutation() else {
                showStickyError(RemoteWording.mutationBusy)
                return nil
            }
            mutationGeneration = claimed
        } else if !quiet {
            // What `beginMutation` does for a mutation: a new attempt supersedes the last one's
            // message and notice.
            if errorIsSticky {
                lastError = nil
                errorIsSticky = false
            }
            dismissNotice()
        }
        rejectedPush = nil
        laneToken += 1
        remoteActivity = RemoteActivity(kind: kind, remote: remote, progress: nil)
        return RemoteLane(
            token: laneToken, generation: generation, mutationGeneration: mutationGeneration)
    }

    /// Frees the lane `lane` holds. Does nothing for a lane `open()` has already reset or a
    /// later one replaced. The mutation slot, if the lane holds it, is released separately by
    /// `finishMutation`, after the banner is decided.
    // internal (not private): used by +Remotes.swift's `runOnLane`
    func finishRemote(_ lane: RemoteLane) {
        guard lane.token == laneToken, generation == lane.generation else { return }
        // A refusal made while this lane was busy ("Wait for the fetch to finish…") is about a
        // state that has just ended; left up, it would sit beside the fetch's own notice
        // telling the user to wait for something already done. The same for "wait before
        // opening another repository": the write it waited for is over, and opening is allowed.
        if let remoteActivity,
            lastError == RemoteWording.laneBusy(remoteActivity)
                || lastError == RemoteWording.openRefusedDuringWrite(remoteActivity)
        {
            lastError = nil
            errorIsSticky = false
        }
        remoteActivity = nil
        remoteTask = nil
    }

    // internal (not private(set) write): used by +Refresh.swift's `scheduleRefresh` (true) and
    // +Remotes.swift's `laneRefresh` (false, as the lane's reload begins)
    func setWatcherEventDuringLane(_ value: Bool) {
        watcherEventDuringLane = value
    }

    /// Stores git's latest progress segment — **made plain first**: the progress stream is
    /// git's whole stderr, and that includes the server's own `remote:` lines, which can carry
    /// escape sequences and URLs with credentials in them. Done here, on the main-actor hop the
    /// relay already throttles to ten a second, so the pipe's queue stays as cheap as it was.
    /// A segment that is nothing once made plain leaves the previous one standing.
    // internal (not private): used by +Remotes.swift's progress relay
    func setRemoteProgress(_ text: String, lane: RemoteLane) {
        guard lane.token == laneToken, generation == lane.generation, remoteActivity != nil
        else { return }
        let shown = RemoteWording.plain(text)
        guard !shown.isEmpty else { return }
        remoteActivity?.progress = shown
    }

    /// A banner that the reloads it provokes must not erase, for work that does not go through
    /// `mutate` (a fetch holds only the lane) or for a refusal made before anything ran.
    // internal (not private): used by +Remotes.swift and +RemoteSheets.swift
    func showStickyError(_ message: String) {
        lastError = message
        errorIsSticky = true
    }

    // internal (not private(set) write): used by +Remotes.swift, right after the banner it
    // belongs to has been put up
    func setRejectedPush(_ value: RejectedPush?) {
        rejectedPush = value
    }

    /// The one place `diff` is written, so `diffIsStaged` can never drift from it.
    /// internal (not private): used by +Detail.swift's `loadDiff()`; kept here since it writes
    /// `diff`/`diffIsStaged` and both stay `private(set)`.
    func setDiff(_ newDiff: [FileDiff], staged: Bool) {
        diff = newDiff
        diffIsStaged = staged
    }
}
