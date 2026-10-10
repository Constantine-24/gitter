import AppKit
import Foundation
import GitCore
import Observation

/// What is shown in the detail pane: the working copy, a specific commit, or a stash entry.
enum Selection: Hashable {
    case workingCopy
    case commit(String)
    /// A stash entry, by its sha: its position moves whenever an entry above it is dropped.
    case stash(String)
    /// The changes the compared branch B brings (B3, `RepositoryStore+Compare`): the files and
    /// diff from the comparison's first merge base to B's id. Only while `comparison` is set.
    case comparisonChanges
}

@Observable @MainActor
final class RepositoryStore {
    private(set) var root: URL?
    private(set) var snapshot: RepoSnapshot?
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var gitMissing = false
    var selection: Selection = .workingCopy {
        // Whoever writes it — a click, a sidebar row, a fallback, `open()` — the commit set
        // follows: it is the selection's own commit and nothing else unless `selectRows` /
        // `selectCommits` made it a set whose first is this commit.
        didSet {
            guard case .commit(let sha) = selection else {
                if !selectedCommits.isEmpty { selectedCommits = [] }
                return
            }
            if selectedCommits.first != sha { selectedCommits = [sha] }
        }
    }
    /// The commits selected in the list, in the order it shows them (`CommitSelection`): the
    /// selection's own commit first — the one the detail pane shows — then the rest of a ⌘- or
    /// ⇧-click set. Empty while the working copy or a stash is selected. What Cherry-Pick and
    /// Revert act on.
    private(set) var selectedCommits: [String] = []
    var selectedPath: String?
    private(set) var detailFiles: [FileStatus] = []
    /// The selected stash entry's files and diffs, both parts; nil unless a stash is selected
    /// and loaded. See `RepositoryStore+Detail`.
    private(set) var stashContents: StashContents?
    private(set) var diff: [FileDiff] = []
    /// Which side the loaded `diff` came from. `stagedView` flips the instant the user picks a
    /// row, while the matching `git diff` is still running, so for the time in between the two
    /// disagree. Anything that has to describe the diff actually on screen — the hunk buttons'
    /// labels, the direction their patch is applied in — reads this instead of `stagedView`.
    private(set) var diffIsStaged = false

    /// The selected conflicted file, read for the resolver (`RepositoryStore+Conflicts`): nil
    /// unless the working copy's selected file is unmerged and its read has landed. It can lag
    /// the selection for the moment a read takes, so the views go through `selectedConflict`.
    private(set) var conflictDocument: ConflictDocument?
    /// Where the operation is, read with the document, for the side labels.
    private(set) var conflictProgress: OperationProgress?
    /// The resolver's block choices, in memory only (nothing is written while the user
    /// chooses), kept while the document's `ConflictSnapshot` stays the same and dropped when it
    /// changes.
    private(set) var resolverChoices = ResolverChoices()
    /// The selected file, when it is a resolved conflict that Reopen Conflict… can bring back
    /// (`GitConflictBackend.canReopen`, read when it is selected).
    private(set) var reopenablePath: String?

    /// Where the rebase, cherry-pick, revert, merge, squash or `git am` in progress stopped, and
    /// whether Continue and Skip would run (`RepositoryStore+Continue`): read with every snapshot
    /// that shows an operation, and written with it, so the bar never describes another state
    /// than the file list. Nil with no operation.
    private(set) var operationStop: OperationStop?
    /// The stop the composer was last prefilled for (`ComposerPrefill`): a stop prefills an
    /// empty draft once, so a draft the user cleared stays clear.
    private(set) var prefilledStopKey: ComposerPrefill.Stop?
    /// A cherry-pick or revert range git left halted with no operation (`HaltedSequence`): read
    /// with every snapshot that shows none, and shown in the bar's place for as long as git keeps
    /// it — a later `--continue` would drop a commit, so it must not vanish with a banner.
    private(set) var haltedSequence: HaltedSequence?

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
    ///
    /// Never on a closed store (`close()`, E2 Task 3): its window is gone but its view tree is not
    /// (M3.2), and a sheet attached there would be one nobody can see or answer — while AppKit
    /// refuses every quit over it (M1.4).
    var activeSheet: BranchSheet? {
        didSet {
            if isClosed, activeSheet != nil { activeSheet = nil }
        }
    }

    /// Set once by `close()`, when the store's window has closed (E2 Task 3), and never cleared: a
    /// closed window's view tree lives on (M3.2), so nothing may act for its store again — `open()`,
    /// `refresh()`, `scheduleRefresh`, the automatic fetch, a claim of the lane and the harness's
    /// steps all honour it. A write already on the lane still finishes (`close()`).
    private(set) var isClosed = false

    /// Told at the end of every `open()` that opened something, with the root before and after (the
    /// same one again for a reopen): the window registry's open-repositories list
    /// (`WindowRegistry.makeStore`). Not observed.
    @ObservationIgnored var onRootChange: ((_ old: URL?, _ new: URL?) -> Void)?

    /// The registry that made this store (`WindowRegistry.makeStore`), which a worktree open is
    /// routed through (Ruling 11); nil for a store made outside one, which then opens in itself.
    @ObservationIgnored weak var registry: WindowRegistry?

    /// A short, non-error message about something that just succeeded ("Fast-forwarded to
    /// feature."). Unlike `lastError` it is never sticky and clears itself after a few seconds.
    private(set) var notice: Notice?

    /// A notice that stays until it is dismissed or replaced: one that carries something to act
    /// on, like a pushed branch's pull-request link. Shown under `notice`, and never cleared by
    /// it. Also ends when another repository is opened, and — for one with links — when the
    /// next push or publish starts. See `RepositoryStore+Notices`.
    private(set) var stickyNotice: Notice?

    /// The sticky notice of a revert git could not commit (`HistoryOutcome
    /// .unsignedRevertLeftStaged`), while it may still be the one on screen: it says the revert's
    /// changes are staged, so the first snapshot with nothing staged — committed or discarded —
    /// takes it down (`setSnapshot`).
    private var stagedRevertNotice: Notice?

    /// The auto-clear for `notice`. Bookkeeping only; views must not touch it.
    // internal (not private): used by +Notices.swift's `showNotice(_:)`
    var noticeTask: Task<Void, Never>?

    /// The network lane: the one fetch, pull, push, publish, force push or remote delete that
    /// is running, or nil. See `RepositoryStore+Remotes` for what holds it and for how long.
    private(set) var remoteActivity: RemoteActivity?

    /// Why the last automatic fetch failed, for a quiet mark on the Fetch button. Never a
    /// banner: being offline is normal. Set and cleared by the automatic fetch
    /// (`RepositoryStore+Remotes`), cleared by a manual fetch from every remote that succeeds,
    /// and by opening a repository: it is about the one that was open.
    private(set) var lastAutoFetchFailure: String?

    /// Fetches every remote now and then, quietly. Started by `open()` once the repository's
    /// first snapshot is in, stopped by the next `open()` and by quitting. Reads "Fetch
    /// Automatically" from `defaults`.
    let autoFetchScheduler: AutoFetchScheduler

    /// Set once the user has decided to quit while the lane was busy (`QuitGuard`): from then on
    /// nothing new is started on the lane — not the automatic fetch, not a cancelled write's
    /// follow-up fetch — so the lane can only free, and the app can go.
    private(set) var isTerminating = false

    /// A lane ending's follow-up (`LaneEnding.then`) that was not started because the user had
    /// decided to quit — with the generation it belongs to. Run if the quit is called off
    /// (`endTerminating`): a stopped push's banner says "fetching to find out", and that fetch
    /// must then happen after all.
    private var followUpHeldForQuit: (generation: Int, run: @MainActor () -> Void)?

    /// How many pieces of lane work have ended with something the user has to read: a banner,
    /// a sheet, or a notice that is more than "it worked" (`LaneEnding.mustBeRead`). A count
    /// rather than the text on screen, because the same banner can come back (a second rejected
    /// push reads word for word like the first) and a banner that went up and was replaced is
    /// still one nobody read. `QuitGuard` takes it when it *asks* about a quit and compares
    /// when the lane frees: anything new calls the quit off.
    private(set) var laneMessagesToRead = 0

    /// The last of those, for `QuitGuard`'s log line.
    private(set) var lastLaneMessageToRead: String?

    /// The push the server just refused for having commits this branch lacks — the only state
    /// "Force Push…" is reachable from. Cleared by the next mutation or network action.
    private(set) var rejectedPush: RejectedPush?

    /// What the error banner's Stash and Continue would do: set with the banner of a switch,
    /// merge or pull refused over local changes (`finishMutation`), and cleared with it — by ×,
    /// by the next mutation or network action, by another sticky banner, and by `open()`.
    /// Read through `offeredStashAndContinue`, which also checks the banner on screen is still
    /// the one it answers. See `RepositoryStore+StashAndContinue`.
    private(set) var stashAndContinueOffer: StashAndContinueOffer?

    /// The banner `stashAndContinueOffer` was made for, word for word.
    private var stashAndContinueBanner: String?

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

    /// Which remotes this session has seen holding which tag (`RemoteTagsSeen`): what the Delete
    /// Tag sheet may name as bringing a tag back (Ruling 2). Written by a tag's push and remote
    /// delete (`RepositoryStore+Tags`), forgotten by `open()` — it is about the repository that
    /// was open.
    private(set) var remoteTagsSeen = RemoteTagsSeen()

    /// The tags deleted while this repository is open (`DeletedTags`): their receipts are the
    /// only way back, so they are kept here — not in the one sticky slot, which any other notice
    /// may take — until restored, back as they were, or `open()`. The sidebar draws each as a
    /// dimmed row with Restore Tag; the delete notice names them all (`recordTagDeleted`).
    private(set) var deletedTags = DeletedTags()

    /// The deleted-tags notice while it may still be the one in the sticky slot: rebuilt as
    /// receipts go (`refreshDeletedTagsNotice`), never brought back once replaced or dismissed.
    private var deletedTagsNotice: Notice?

    /// The sidebar filter's text (B3, `SidebarFilter`). View state hosted here, like
    /// `activeSheet` (B3 Ruling 2): the `.searchable` field binds it directly. It survives
    /// refreshes, is cleared by `open()` — it was about the repository that was open — and is
    /// never persisted.
    var sidebarFilter = ""

    /// The worktrees, their changes and this window's among them (B3, `RepositoryStore
    /// +Worktrees`), read after every snapshot and written when that read lands
    /// (`scheduleWorktreeStateRead`, `setWorktreeState`).
    private(set) var worktreeState = WorktreeState()

    /// Two branches compared (B3, `RepositoryStore+Compare`): while set, the commit list column
    /// is in compare mode. One state, read from two ids once; ended by Done, Esc, a sidebar
    /// click and `open()`.
    private(set) var comparison: Comparison?
    /// The files the comparison's changes hold, once read for it (`loadDetail`), or nil: not
    /// read yet, the read failed, or no merge base. Read from the comparison's ids alone, so
    /// they are kept for as long as it is.
    private(set) var comparisonFiles: [FileStatus]?
    /// The refusal banner the last failed comparison put up, so the next comparison that is read
    /// can take exactly that banner down — and no other one (`clearCompareFailure`).
    private var compareFailureBanner: String?

    /// Where git keeps this repository's files for the worktree that is open — its own git
    /// directory and the common one (`RepositoryDirectories`) — read by `open()` for the watcher
    /// and the window title, and by the discard fingerprint. Nil with no repository.
    private(set) var directories: RepositoryDirectories?

    #if DEBUG
        /// How many snapshot loads have run, for the harness's "exactly one refresh when the
        /// lane frees" check.
        private(set) var snapshotLoadCount = 0

        // internal (not private): used by +Refresh.swift's `loadSnapshot()`
        func noteSnapshotLoad() {
            snapshotLoadCount += 1
        }

        /// How many worktree states have been written, for the harness's `reloadtiming` (B3
        /// final review, I2): the snapshot lands before the worktree state's own read.
        private(set) var worktreeStateWrites = 0

        /// The harness's `autofetchfailed:<reason>` step, so the Fetch item's quiet mark can be
        /// drawn without waiting for a real automatic fetch to fail.
        func debugSetLastAutoFetchFailure(_ reason: String?) {
            lastAutoFetchFailure = reason
        }

        /// How many stores this process has built. Every one must be a registered one
        /// (`storesRegistered`, E2 Task 3): a store built anywhere else is one nobody sees, and it
        /// would still fetch (Task 11).
        private(set) static var storesBuilt = 0

        /// How many of those a `WindowRegistry` made (`makeStore`): one per window, in the app.
        private(set) static var storesRegistered = 0

        // internal (not private): used by WindowRegistry.swift's `makeStore`
        static func noteRegistered() {
            storesRegistered += 1
        }

        /// The DEBUG check, "every store the app builds is a registered one": nil when it holds,
        /// otherwise what is wrong. Pure, so a test can check it over the counts it made.
        static func storeCheck(built: Int, registered: Int) -> String? {
            built == registered ? nil : "\(built - registered) store(s) built outside the window registry"
        }

        /// Which store this is, 1 for the first built: in the `AUTOFETCH` lines, so two
        /// schedules from two stores can be told apart in a log.
        let debugSerial: Int

        static func logStores(_ event: String) {
            let problem = storeCheck(built: storesBuilt, registered: storesRegistered).map { " | \($0)" } ?? ""
            FileHandle.standardError.write(
                Data("STORES built: \(storesBuilt), registered: \(storesRegistered)\(problem) | \(event)\n".utf8))
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
    /// checkout and merge writes, the network, the stash, conflicts, the operation in progress
    /// the history actions (cherry-pick, revert, rebase onto), tags, the remotes'
    /// housekeeping (B2), comparing two branches and worktrees (B3). Twelve protocols so a fake
    /// can implement any one on its own.
    typealias Backend = any GitBackend & GitWorkingCopyBackend & GitBranchBackend & GitRemoteBackend
        & GitStashBackend & GitConflictBackend & GitOperationBackend & GitHistoryBackend
        & GitTagBackend & GitRemoteAdminBackend & GitCompareBackend & GitWorktreeBackend

    let backend: Backend
    // internal (not private): used by +Opening.swift's `checkGitAvailability()`
    let gitPath: String
    /// Where a discard puts untracked items: the user's Trash. A seam, like `backend`.
    // internal (not private): used by +Discard.swift
    let trasher: any Trasher
    /// Where everything the app remembers is read and written — the last repository, the merge
    /// and pull modes, "Fetch Automatically" (through `autoFetchScheduler`). `.standard` in the
    /// app (`AppModel`); a scratch suite under test, so a test never touches the user's own.
    // internal (not private): used by +Opening.swift, +BranchState.swift, +Branches.swift,
    // +RemoteSheets.swift and the DEBUG hooks
    let defaults: UserDefaults

    private var watcher: RepositoryWatcher?
    // internal (not private), bookkeeping only, views must not touch this: used by +Refresh.swift
    var refreshTask: Task<Void, Never>?
    // internal (not private), bookkeeping only, views must not touch this: used by +Detail.swift
    var detailTask: Task<Void, Never>?
    // internal (not private), bookkeeping only, views must not touch this: used by +Detail.swift
    var diffTask: Task<Void, Never>?
    // internal (not private), bookkeeping only, views must not touch this: used by +Conflicts.swift
    var conflictTask: Task<Void, Never>?
    // internal (not private), bookkeeping only, views must not touch this: used by +Compare.swift
    var compareTask: Task<Void, Never>?
    /// The worktree state's read (B3 final review, I2), started after a snapshot lands and
    /// cancelled by `open()`; `worktreeReadSchedule` says when one starts and whether it is written.
    // internal (not private), bookkeeping only, views must not touch this: used by +Worktrees.swift
    var worktreeReadTask: Task<Void, Never>?
    // internal (not private), bookkeeping only, views must not touch this: used by +Worktrees.swift
    var worktreeReadSchedule = WorktreeReadSchedule()
    /// The Remove Worktree sheet's check (B3 Task 5), cancelled when the sheet closes.
    // internal (not private), bookkeeping only, views must not touch this: used by +Worktrees.swift
    var worktreeCheckTask: Task<Void, Never>?
    /// The most recently scheduled snapshot load; new ones chain behind it. See `refresh()`.
    // internal (not private), bookkeeping only, views must not touch this: used by +Refresh.swift
    var lastRefresh: Task<Void, Never>?
    /// True while a chained load exists that has not begun reading git yet.
    // internal (not private), bookkeeping only, views must not touch this: used by +Refresh.swift
    var refreshIsQueued = false

    // internal (not private): used by RepositoryStore+Opening.swift's `lastRepositoryToReopen(in:)`
    static let lastRepositoryPathKey = "lastRepositoryPath"

    init(
        backend: Backend = CLIGitBackend(),
        gitPath: String = "/usr/bin/git",
        trasher: any Trasher = FileManagerTrasher(),
        defaults: UserDefaults
    ) {
        self.backend = backend
        self.gitPath = gitPath
        self.trasher = trasher
        self.defaults = defaults
        autoFetchScheduler = AutoFetchScheduler.fromEnvironment(defaults: defaults)
        #if DEBUG
            Self.storesBuilt += 1
            debugSerial = Self.storesBuilt
        #endif
    }

    // MARK: - Opening

    func open(_ url: URL) {
        // A closed window's store opens nothing again (RF3): its window is gone.
        guard !isClosed else { return }
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
        let previousRoot = root
        if let refusal = Self.notARepository(url) {
            lastError = refusal
            errorIsSticky = true
            return
        }

        watcher?.stop()
        watcher = nil

        refreshTask?.cancel()
        detailTask?.cancel()
        diffTask?.cancel()
        conflictTask?.cancel()
        compareTask?.cancel()
        // `lastRefresh` is deliberately left in place: a load still in flight for the old root
        // writes nothing (it re-checks `root` before it lands), and keeping the chain intact
        // keeps this repository's first load from overlapping it.

        // Reset all repository-derived state so nothing from the previous repository lingers
        // on screen (or gets raced against) while the new repository's first snapshot loads.
        snapshot = nil
        detailFiles = []
        stashContents = nil
        setDiff([], staged: stagedView)
        setConflict(nil, progress: nil)
        reopenablePath = nil
        operationStop = nil
        prefilledStopKey = nil
        haltedSequence = nil
        selection = .workingCopy
        selectedPath = nil
        lastError = nil
        errorIsSticky = false
        // A question asked about the previous repository ("delete this unmerged branch?") must
        // never be answered against this one, and its notice is about a repository nobody is
        // looking at any more.
        activeSheet = nil
        // A worktree removal's check is about the repository being left.
        worktreeCheckTask?.cancel()
        dismissNotice()
        // Its link or its undo is for the repository being left.
        stickyNotice = nil
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
        clearStashAndContinueOffer()
        remoteTagsSeen = RemoteTagsSeen()
        deletedTags = DeletedTags()
        deletedTagsNotice = nil
        // The filter was typed for the repository being left (B3 Ruling 2), and its worktrees
        // are not this one's.
        sidebarFilter = ""
        worktreeState = WorktreeState()
        // A worktree read in flight is the repository being left's (B3 final review, I2).
        worktreeReadTask?.cancel()
        worktreeReadTask = nil
        worktreeReadSchedule.reset()
        // A comparison is of this repository's branches (B3): opening another ends it.
        comparison = nil
        comparisonFiles = nil
        compareFailureBanner = nil
        // The automatic fetch belongs to the repository it fetches: the old one's schedule
        // stops here, and its mark says nothing about this one. This one's starts once its first
        // snapshot is in (below), so the first tick can see whether it has a remote at all.
        autoFetchScheduler.stop()
        lastAutoFetchFailure = nil
        // Everything in flight for the previous repository — including a reopen of this very
        // path — is now stale and will drop its result.
        generation += 1

        root = standardized
        defaults.set(standardized.path, forKey: Self.lastRepositoryPathKey)
        // Neither a test's scratch folder nor a harness's fixture is one of the user's recent
        // repositories (B3 Ruling 7): that list lives outside the defaults.
        let environment = ProcessInfo.processInfo.environment
        switch Self.openRecentRefusal(testHost: TestHost.isRunningTests, environment: environment) {
        case nil: NSDocumentController.shared.noteNewRecentDocumentURL(standardized)
        case .testHost: break
        case .scriptedLaunch:
            #if DEBUG
                DebugLaunchHooks.log("launch guard: \(standardized.lastPathComponent) is not added to Open Recent")
            #endif
            break
        }

        // A linked worktree's HEAD, index and refs are outside its root (R28): the watcher is
        // given where they are (`RepositoryWatcher.paths`).
        directories = RepositoryDirectories.resolve(root: standardized)
        watcher = RepositoryWatcher(paths: RepositoryWatcher.paths(root: standardized, directories: directories)) {
            [weak self] paths in
            self?.scheduleRefresh(changed: paths)
        }

        let openedGeneration = generation
        Task {
            await refresh()
            guard generation == openedGeneration, !isTerminating, !isClosed else { return }
            autoFetchScheduler.start(for: self)
        }

        onRootChange?(previousRoot, standardized)
    }

    /// The window showing this store has closed (`WindowRegistry.windowClosed`, E2 Task 3). A
    /// closed window keeps its view tree and its store (M3.2), so everything that would go on
    /// working for it is stopped here: the file watcher, the automatic fetch's schedule, every read
    /// in flight — the reloads, the detail, diff, conflict, comparison and worktree reads, a read on
    /// the network lane — and the sheet and the notices go. From here on `isClosed` stops anything
    /// new.
    ///
    /// **A write on the lane is let finish** (a push, a publish, a delete on a remote): cancelling
    /// it would leave the server in a state nobody is told about. Nor is `generation` bumped while
    /// one runs — the write's own completion must still free the lane (`finishRemote` drops a stale
    /// lane's release), or the store would never leave the registry and `QuitGuard` would wait on it
    /// for good. With the lane free, the bump makes anything else in flight drop its result.
    func close() {
        guard !isClosed else { return }
        isClosed = true
        watcher?.stop()
        watcher = nil
        refreshTask?.cancel()
        refreshTask = nil
        detailTask?.cancel()
        diffTask?.cancel()
        conflictTask?.cancel()
        compareTask?.cancel()
        worktreeReadTask?.cancel()
        worktreeReadTask = nil
        worktreeCheckTask?.cancel()
        autoFetchScheduler.stop()
        activeSheet = nil
        dismissNotice()
        stickyNotice = nil
        if let remoteActivity, !remoteActivity.isWrite { cancelRemoteActivity() }
        if remoteActivity == nil { generation += 1 }
    }

    /// Whether the file watcher is running: from `open()` until the next one, or `close()`.
    var isWatching: Bool { watcher != nil }

    // MARK: - Selection

    func select(_ newSelection: Selection) {
        // Another entry's files must not stand under this one's header while it loads.
        if newSelection != selection { stashContents = nil }
        selection = newSelection
        setDiff([], staged: stagedView)
        loadDetail()
    }

    /// The commit list's selection changed to `rows` (`CommitSelection.resolve`): the detail
    /// pane moves to the first selected commit — or to the working copy — and the set is kept in
    /// the order `shown`. An empty set changes nothing.
    func selectRows(_ rows: Set<Selection>, shown: [Selection]) {
        let previous = CommitSelection.table(selection: selection, commits: selectedCommits)
        guard let resolved = CommitSelection.resolve(rows, previous: previous, shown: shown) else {
            return
        }
        apply(resolved)
    }

    /// Selects `shas` as a set, ordered as `shown` (the log's order; nil reads it from the
    /// snapshot). The debug harness's `selectcommits:` step.
    func selectCommits(_ shas: [String], shown: [String]? = nil) {
        let order = (shown ?? snapshot?.commits.map(\.sha) ?? []).map(Selection.commit)
        guard let resolved = CommitSelection.resolve(Set(shas.map(Selection.commit)), previous: [], shown: order)
        else { return }
        apply(resolved)
    }

    private func apply(_ resolved: CommitSelection.Resolved) {
        // The set first, so `selection`'s `didSet` finds its commit at the front and keeps it.
        selectedCommits = resolved.commits
        if resolved.detail != selection { select(resolved.detail) }
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
        endStagedRevertNoticeIfDone()
        // A deleted tag back exactly as it was — a fetch brought it back — needs no restore.
        if deletedTags.pruningTagsBack(newSnapshot?.refs.tags ?? []) { refreshDeletedTagsNotice() }
        // Here rather than in `+Refresh` because this is the one place the snapshot is written,
        // and "an operation has begun" is only ever learned from a new one. See
        // `reconcileAmendWithOperation` for why a ticked Amend cannot be left ticked.
        reconcileAmendWithOperation()
    }

    /// Shows `notice` in the sticky slot as the staged revert's (`stagedRevertNotice`).
    /// internal (not private(set) write): used by +History.swift's `confirmHistoryAction`
    func showStagedRevertNotice(_ notice: Notice) {
        stickyNotice = notice
        stagedRevertNotice = notice
    }

    private func endStagedRevertNoticeIfDone() {
        guard let shown = stagedRevertNotice else { return }
        // Dismissed or replaced since: no longer this notice's slot to clear.
        guard stickyNotice == shown else {
            stagedRevertNotice = nil
            return
        }
        guard let files = snapshot?.status.files, !files.contains(where: { $0.staged != nil }) else {
            return
        }
        stickyNotice = nil
        stagedRevertNotice = nil
    }

    /// internal (not private(set) write): used by +Worktrees.swift's `scheduleWorktreeStateRead()`,
    /// when the worktrees read after a snapshot land (B3 final review, I2).
    func setWorktreeState(_ state: WorktreeState) {
        worktreeState = state
        #if DEBUG
            worktreeStateWrites += 1
        #endif
    }

    /// Starts, replaces or (nil) ends the comparison; its files go with it.
    /// internal (not private(set) write): used by +Compare.swift
    func setComparison(_ newComparison: Comparison?) {
        comparison = newComparison
        comparisonFiles = nil
    }

    /// A comparison was refused: its sentence goes up as a sticky banner, remembered as the
    /// comparison's own. internal (not private(set) write): used by +Compare.swift
    func showCompareFailure(_ message: String) {
        showStickyError(message)
        compareFailureBanner = message
    }

    /// A comparison was read: the refusal of an earlier attempt is out of date, and comes down —
    /// only while it is still the banner on screen. internal: used by +Compare.swift
    func clearCompareFailure() {
        if let banner = compareFailureBanner, lastError == banner {
            lastError = nil
            errorIsSticky = false
        }
        compareFailureBanner = nil
    }

    /// internal (not private(set) write): used by +Detail.swift, with the files read for
    /// `comparison` while it is still the one on screen
    func setComparisonFiles(_ files: [FileStatus]?) {
        comparisonFiles = files
    }

    /// internal (not private(set) write): used by +Refresh.swift
    func setLoading(_ value: Bool) {
        isLoading = value
    }

    /// internal (not private(set) write): used by +Detail.swift
    func setDetailFiles(_ files: [FileStatus]) {
        detailFiles = files
    }

    /// internal (not private(set) write): used by +Detail.swift
    func setStashContents(_ contents: StashContents?) {
        stashContents = contents
    }

    /// internal (not private(set) write): used by +Notices.swift's `showNotice(_:)`/
    /// `dismissNotice()`, which own the auto-clear timing.
    func setNotice(_ newNotice: Notice?) {
        notice = newNotice
    }

    /// internal (not private(set) write): used by +Notices.swift's `showStickyNotice(_:)`/
    /// `dismissStickyNotice()`.
    func setStickyNotice(_ newNotice: Notice?) {
        stickyNotice = newNotice
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
        // Stash and Continue answers the refusal on screen, which this attempt supersedes —
        // and it is itself a mutation, which must not find its own offer still up.
        clearStashAndContinueOffer()
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
            // A refusal a stash answers: the banner and its Stash and Continue go up together,
            // for this generation only (a stale one returned above).
            if let offered = failure as? RefusalWithStashOffer {
                stashAndContinueOffer = offered.offer
                stashAndContinueBanner = lastError
            }
        }
        isMutating = false
    }

    // MARK: - Network lane bookkeeping

    /// The lane's activity when it is one that stops the user: everything except the automatic
    /// fetch. An automatic fetch never makes the user wait — Fetch, Pull, Push and the sheets'
    /// buttons stay available, and starting any of them stops it (`beginRemote`) — so the
    /// blocked reasons read this rather than `remoteActivity`.
    var blockingRemoteActivity: RemoteActivity? {
        remoteActivity?.kind == .autoFetch ? nil : remoteActivity
    }

    /// Whether `lane` is still the one on the lane: not freed, not replaced (a user's action
    /// pre-empting an automatic fetch), not left behind by `open()`.
    // internal (not private): used by +Remotes.swift's automatic fetch
    func isCurrentLane(_ lane: RemoteLane) -> Bool {
        lane.token == laneToken && generation == lane.generation && remoteActivity != nil
    }

    // internal (not private(set) write): used by +Remotes.swift's `runOnLane`, once the lane's
    // banner, sheet or notice is up
    func noteLaneMessageToRead(_ text: String) {
        laneMessagesToRead += 1
        lastLaneMessageToRead = text
    }

    // internal (not private(set) write): used by +Remotes.swift's automatic fetch and its
    // manual fetch from every remote
    func setLastAutoFetchFailure(_ reason: String?) {
        lastAutoFetchFailure = reason
    }

    /// The user has decided to quit while the lane was busy (`QuitGuard`). Nothing new starts on
    /// the lane from here, and the automatic fetch's schedule stops. (The alert's "Don't Quit"
    /// never gets here.)
    func beginTerminating() {
        isTerminating = true
        autoFetchScheduler.stop()
    }

    /// The quit was called off after all: "Wait" was chosen, and the write it waited for ended
    /// with a banner the user has to read. Everything is available again, the schedule too.
    func endTerminating() {
        guard isTerminating else { return }
        isTerminating = false
        let held = followUpHeldForQuit
        followUpHeldForQuit = nil
        // First, so the schedule's immediate tick finds the lane busy with it and skips.
        if let held, held.generation == generation { held.run() }
        if root != nil, !isClosed { autoFetchScheduler.start(for: self) }
    }

    /// Keeps a lane ending's follow-up for `endTerminating` instead of starting it while quitting.
    // internal (not private(set) write): used by +Remotes.swift's `runOnLane`
    func holdFollowUpForQuit(_ followUp: @escaping @MainActor () -> Void) {
        followUpHeldForQuit = (generation, followUp)
    }

    /// The banner `beginRemote` would show refusing this claim now, or nil — asked without
    /// claiming anything, so a sheet's Confirm can refuse while the sheet is still up. The same
    /// three refusals, in its order: quitting, the lane taken by anything but an automatic
    /// fetch (which a user's claim stops instead), the mutation slot held.
    // internal (not private): used by +Tags.swift's `confirmDeleteRemoteTag`
    func laneClaimRefusal(_ kind: RemoteActivity.Kind, holdingMutation: Bool) -> String? {
        Self.laneClaimRefusal(
            kind, holdingMutation: holdingMutation, isTerminating: isTerminating,
            remoteActivity: remoteActivity, isMutating: isMutating)
    }

    static func laneClaimRefusal(
        _ kind: RemoteActivity.Kind, holdingMutation: Bool, isTerminating: Bool,
        remoteActivity: RemoteActivity?, isMutating: Bool
    ) -> String? {
        if isTerminating { return RemoteWording.refusedWhileQuitting }
        if let remoteActivity, !(remoteActivity.kind == .autoFetch && kind != .autoFetch) {
            return RemoteWording.laneBusy(remoteActivity)
        }
        if holdingMutation, isMutating { return RemoteWording.mutationBusy }
        return nil
    }

    /// Claims the network lane — and, for a write, the mutation slot as well — returning the
    /// ticket to hand back to `finishRemote`, or nil when it cannot be claimed. A refusal says
    /// why in the banner: a second network action is refused with a reason, never queued and
    /// never silently dropped.
    ///
    /// `quiet` is for the follow-up fetch after a cancelled or failed write: it must not clear
    /// the banner that says the remote may or may not have changed, which is the one thing the
    /// user has to read.
    ///
    /// **An automatic fetch gives way.** Anything else claiming the lane while one runs cancels
    /// it and takes the lane; the task that ran it is returned as `preempted`, and the caller
    /// waits for it before starting git, so two fetches never write the same refs at once (a
    /// cancelled git is gone within the runner's escalation). If the claim fails for another
    /// reason — the mutation slot is taken — the automatic fetch is left running.
    ///
    /// While quitting (`isTerminating`) nothing is claimed. The user's own action says why in
    /// the banner — a click that does nothing and says nothing reads as a broken button; the
    /// quiet ones (the automatic fetch, a write's follow-up fetch) say nothing. That banner is
    /// not a lane's ending, so it does not call a held quit off (`laneMessagesToRead`).
    // internal (not private): used by +Remotes.swift's `runOnLane`
    func beginRemote(
        _ kind: RemoteActivity.Kind, remote: String?, holdingMutation: Bool, quiet: Bool = false
    ) -> (lane: RemoteLane, preempted: Task<Void, Never>?)? {
        // A closed window's store claims nothing, and says nothing: nobody would see it.
        guard root != nil, !isClosed else { return nil }
        guard !isTerminating else {
            if !quiet, kind != .autoFetch { showStickyError(RemoteWording.refusedWhileQuitting) }
            return nil
        }
        let preempting = remoteActivity?.kind == .autoFetch && kind != .autoFetch
        if let remoteActivity, !preempting {
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
        var preempted: Task<Void, Never>?
        if preempting {
            preempted = remoteTask
            remoteTask?.cancel()
            remoteTask = nil
        }
        // "Force Push…" answers the refusal on screen; the automatic fetch is not something the
        // user did, and must not take that answer away every ten minutes. (The force push reads
        // its lease with a fetch of its own, so a tracking ref moved meanwhile changes nothing.)
        if kind != .autoFetch {
            rejectedPush = nil
            clearStashAndContinueOffer()
        }
        // A pushed branch's link is about the push before this one; this one says its own.
        switch kind {
        case .push, .publish, .forcePush:
            if stickyNotice?.links.isEmpty == false { stickyNotice = nil }
        case .fetch, .autoFetch, .pull, .deleteRemoteBranch, .pushTag, .deleteRemoteTag, .prune,
            .fastForward, .renameRemote, .removeRemote:
            break
        }
        laneToken += 1
        remoteActivity = RemoteActivity(kind: kind, remote: remote, progress: nil)
        return (
            RemoteLane(
                token: laneToken, generation: generation, mutationGeneration: mutationGeneration),
            preempted
        )
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
        // Another banner: the refusal Stash and Continue answered is off the screen.
        clearStashAndContinueOffer()
    }

    /// The offer, while the banner on screen is still the refusal it was made for — never
    /// beside some other message that happened to replace it (a failed reload, say, which
    /// writes `lastError` without going through any of the places that clear the offer).
    var offeredStashAndContinue: StashAndContinueOffer? {
        guard let offer = stashAndContinueOffer, let lastError, lastError == stashAndContinueBanner
        else { return nil }
        return offer
    }

    // internal (not private(set) write): used by +Errors.swift's `dismissError()`
    func clearStashAndContinueOffer() {
        stashAndContinueOffer = nil
        stashAndContinueBanner = nil
    }

    // internal (not private(set) write): used by +Tags.swift, once a remote has answered
    func noteRemoteTag(_ name: String, on remote: String, id: String?) {
        remoteTagsSeen.note(name, on: remote, id: id)
    }

    /// Keeps `receipt` and puts up the deleted-tags notice naming every tag still deleted —
    /// over whatever sticky notice was there, as any new sticky notice does.
    /// internal (not private(set) write): used by +Tags.swift's `confirmDeleteTag`
    func recordTagDeleted(_ receipt: TagReceipt) {
        deletedTags.add(receipt)
        let notice = TagWording.deletedNotice(deletedTags.receipts)
        stickyNotice = notice
        deletedTagsNotice = notice
    }

    /// Ends these receipts: their tags were restored (or are back).
    /// internal (not private(set) write): used by +Tags.swift's `finishTagRestore`
    func forgetDeletedTags(_ receipts: [TagReceipt]) {
        deletedTags.remove(receipts)
        refreshDeletedTagsNotice()
    }

    /// The deleted-tags notice, rebuilt for the receipts left — or taken down with the last —
    /// while it is still the one on screen. Replaced or dismissed, it stays gone: the rows
    /// under Tags still offer every receipt.
    private func refreshDeletedTagsNotice() {
        guard let shown = deletedTagsNotice else { return }
        guard stickyNotice == shown else {
            deletedTagsNotice = nil
            return
        }
        let next = deletedTags.receipts.isEmpty ? nil : TagWording.deletedNotice(deletedTags.receipts)
        stickyNotice = next
        deletedTagsNotice = next
    }

    // internal (not private(set) write): used by +Remotes.swift, right after the banner it
    // belongs to has been put up
    func setRejectedPush(_ value: RejectedPush?) {
        rejectedPush = value
    }

    /// The one place the resolver's document is written: the choices follow its snapshot
    /// (`ResolverChoices.show`), so they can never outlive the conflict they were made for.
    /// internal (not private): used by +Conflicts.swift's `loadConflict()`
    func setConflict(_ document: ConflictDocument?, progress: OperationProgress?) {
        conflictDocument = document
        conflictProgress = progress
        resolverChoices.show(document?.snapshot, blockCount: document.flatMap(ResolverOffer.blocks(of:))?.count ?? 0)
    }

    /// internal (not private(set) write): used by +Conflicts.swift's `chooseBlock`
    func setBlockChoice(_ index: Int, _ choice: BlockChoice) {
        resolverChoices.choose(index, choice)
    }

    /// internal (not private(set) write): used by +Conflicts.swift's `loadConflict()`
    func setReopenablePath(_ path: String?) {
        reopenablePath = path
    }

    /// internal (not private(set) write): used by +Refresh.swift's `loadSnapshot()`, right after
    /// `setSnapshot`, with the stop read for that snapshot.
    func setOperationStop(_ stop: OperationStop?, halted: HaltedSequence?) {
        operationStop = stop
        haltedSequence = halted
    }

    /// Prefills the composer for the stop on screen (`ComposerPrefill.apply`). `restart` forgets
    /// which stop it last filled for: after a Continue the draft was used and reset, and the stop
    /// it stopped at again must fill it, although the reload before saw that stop already.
    /// internal (not private(set) write): used by +Refresh.swift and +Continue.swift
    func syncDraftWithOperation(restart: Bool = false) {
        if restart { prefilledStopKey = nil }
        prefilledStopKey = ComposerPrefill.apply(operationStop, lastKey: prefilledStopKey, to: draft)
    }

    /// The one place `diff` is written, so `diffIsStaged` can never drift from it.
    /// internal (not private): used by +Detail.swift's `loadDiff()`; kept here since it writes
    /// `diff`/`diffIsStaged` and both stay `private(set)`.
    func setDiff(_ newDiff: [FileDiff], staged: Bool) {
        diff = newDiff
        diffIsStaged = staged
    }
}
