import Foundation
import GitCore

/// Fetch, pull and push: the network lane.
///
/// **One lane.** At most one network operation runs (`remoteActivity`); a second one is refused
/// with a reason in the banner, never queued (see `RemoteActivity`). What each holds:
///
/// | action | lane | mutation slot |
/// |---|---|---|
/// | fetch | while it runs | never — staging, committing and branch actions stay usable; a fetch writes only `refs/remotes/*`, and Gitter refuses a fetch whose refspec would write anywhere else (`FetchRefspec`); git's own ref locking arbitrates |
/// | pull | for its fetch | for the merge or rebase after it, through `perform`/`mutate` |
/// | push, publish, force push, delete on a remote | while it runs | while it runs — nothing may move the branch between the decision and the push |
/// | automatic fetch | while it runs — but it **gives way**: anything above stops it and takes the lane (`beginRemote`) | never |
///
/// **One reload.** While the lane is busy the watcher's reloads are dropped (`scheduleRefresh`);
/// `runOnLane` reloads once, still holding the lane, and only then frees it and puts up the
/// banner or notice, so the message the user reads belongs to the state on screen.
///
/// **Nothing here decides where a push goes** except `PushTarget.resolve`, and no sentence is
/// written here: they are all in `RemoteWording`.
extension RepositoryStore {

    // MARK: - Derived state

    /// The branch HEAD is on, as a ref with its tracking and push fields; nil when detached or
    /// unborn.
    var currentBranchRef: Branch? {
        guard let name = currentBranch else { return nil }
        return localBranches.first { $0.name == name }
    }

    /// Of the current branch; `.none` when HEAD is detached.
    var currentTracking: Tracking {
        currentBranchRef?.tracking ?? .none
    }

    /// Everything the blocked reasons are decided on, read in one place. An automatic fetch on
    /// the lane blocks nothing (`blockingRemoteActivity`): the user's action stops it.
    var remoteGate: RemoteWording.Gate {
        RemoteWording.Gate(
            hasRepository: root != nil && snapshot != nil, activity: blockingRemoteActivity,
            isMutating: isMutating, operation: operationInProgress, isDetached: isDetached,
            branch: currentBranchRef, remotes: snapshot?.refs.remotes ?? [])
    }

    var fetchBlockedReason: String? { RemoteWording.fetchBlocked(remoteGate) }
    var pullBlockedReason: String? { RemoteWording.pullBlocked(remoteGate) }
    var pushBlockedReason: String? { RemoteWording.pushBlocked(remoteGate) }

    /// Why "Delete on <remote>…" is off: only a busy lane or a running mutation stops it. A
    /// deletion on the server touches neither the worktree nor HEAD, so an operation in
    /// progress and a detached HEAD do not.
    var deleteRemoteBranchBlockedReason: String? {
        guard remoteGate.hasRepository else { return RemoteWording.noRepository }
        return sheetBusyReason
    }

    /// Why a remote sheet's confirming button is off: the lane is busy, or another change holds
    /// the mutation slot. The one sentence all four sheets (pull, publish, force push, delete on
    /// a remote) show under their text; what is *stale* about a sheet is each sheet's own.
    var sheetBusyReason: String? {
        if let activity = blockingRemoteActivity { return RemoteWording.laneBusy(activity) }
        if isMutating { return RemoteWording.mutationBusy }
        return nil
    }

    /// Push, Publish or Re-publish — decided on the push remote, not on the upstream.
    var pushKind: PushKind {
        RemoteWording.pushKind(branch: currentBranchRef, remotes: snapshot?.refs.remotes ?? [])
    }

    /// "Push", "Publish" or "Re-publish", from `pushKind`.
    var pushButtonTitle: String { RemoteWording.pushTitle(pushKind) }

    /// The ahead count the Push button may draw, or nil: only when the push goes to exactly
    /// the upstream the count is measured against (`PushTarget.aheadCountToDisplay`). A
    /// triangular branch, a refused target, a local or gone upstream, and a detached HEAD get
    /// none.
    var pushAheadCount: Int? {
        guard let branch = currentBranchRef else { return nil }
        return PushTarget.aheadCountToDisplay(for: branch, remotes: snapshot?.refs.remotes ?? [])
    }

    /// The behind count the Pull button may draw, or nil (`PullPlan.behindCountToDisplay`):
    /// none when detached, gone, without an upstream, or tracking a local branch.
    var pullBehindCount: Int? {
        currentBranchRef.flatMap(PullPlan.behindCountToDisplay(for:))
    }

    /// The Push item's tooltip while it is enabled: where a push would go.
    var pushHelp: String {
        RemoteWording.pushHelp(
            pushKind, branch: currentBranchRef, remotes: snapshot?.refs.remotes ?? [])
    }

    /// Whether the error banner on screen is the refusal "Force Push…" answers, and so should
    /// carry the "Pull" and "Force Push…" buttons.
    var bannerOffersForcePush: Bool {
        guard let rejectedPush, let lastError else { return false }
        return rejectedPush.banner == lastError
    }

    // MARK: - Fetch

    /// `git fetch <remote>`, or `git fetch --all` for nil. Holds only the lane.
    func fetch(remote: String? = nil) {
        if let reason = fetchBlockedReason {
            showStickyError(reason)
            return
        }
        startFetch(remote: remote, quiet: false)
    }

    /// The fetch itself. `quiet` is the re-read after a cancelled or failed write: it says
    /// nothing on success or failure, because the banner already on screen — "the remote may or
    /// may not have been updated" — is the message, and this only brings the badges up to date.
    ///
    /// A failed `fetch --all` may already have updated the remotes that answered (measured in
    /// Task 4), so a failure reloads like a success and shows git's words, which name the
    /// remote that failed.
    private func startFetch(remote: String?, quiet: Bool) {
        runOnLane(.fetch, remote: remote, holdingMutation: false, quiet: quiet) {
            backend, root, lane, progress in
            do {
                try await backend.fetch(remote: remote, at: root, progress: progress)
                // Every remote answered, so whatever the last automatic fetch ran into is over.
                // A fetch from one remote says nothing about the others.
                return LaneEnding(notice: quiet ? nil : RemoteWording.fetched(from: remote)) {
                    [self] in
                    if remote == nil { setLastAutoFetchFailure(nil) }
                }
            } catch where Self.isCancellation(error) {
                return LaneEnding(notice: quiet ? nil : RemoteWording.fetchStopped(from: remote))
            } catch {
                guard !quiet else { return LaneEnding() }
                return LaneEnding(
                    failure: RemoteWording.failure(
                        error, attempt: remote.map { "fetch from \"\($0)\"" } ?? "fetch",
                        isWrite: false))
            }
        }
    }

    // MARK: - Pull

    /// Fetch the upstream's remote, then — on the tracking re-read *after* that fetch — do
    /// nothing, fast-forward, or ask Merge or Rebase (`PullPlan.decide`). There is no
    /// `git pull`: its behaviour depends on three config keys and it does two things in one
    /// process, so Gitter does the two things itself.
    ///
    /// A branch whose upstream is another local branch has nothing to fetch; it goes straight
    /// to the decision.
    func pull() {
        if let reason = pullBlockedReason {
            showStickyError(reason)
            return
        }
        guard let branch = currentBranchRef, let upstream = branch.upstream else { return }
        let fetchRemote = branch.upstreamRemote

        runOnLane(.pull, remote: fetchRemote, holdingMutation: false) { [self] backend, root, lane, progress in
            if let fetchRemote {
                do {
                    try await backend.fetch(remote: fetchRemote, at: root, progress: progress)
                } catch where Self.isCancellation(error) {
                    return LaneEnding(notice: RemoteWording.fetchStopped(from: fetchRemote))
                } catch {
                    return LaneEnding(
                        failure: RemoteWording.failure(
                            error, attempt: "fetch from \"\(fetchRemote)\"", isWrite: false))
                }
            }
            // The decision needs the tracking *after* the fetch, so the one reload happens here,
            // still holding the lane.
            await laneRefresh(lane)
            // Stop pressed after the fetch finished, while the reload ran: the reload is not
            // cancellable and has completed, but nothing after it may start — Stop means stop.
            if Task.isCancelled {
                return LaneEnding(
                    notice: RemoteWording.pullStoppedAfterFetch(fetchRemote),
                    alreadyRefreshed: true)
            }
            guard let now = currentBranchRef, now.name == branch.name else {
                return LaneEnding(failure: RemoteWording.pullBranchChanged, alreadyRefreshed: true)
            }
            let upstreamNow = now.upstream ?? upstream
            switch PullPlan.decide(now.tracking) {
            case .nothingToDo:
                return LaneEnding(
                    notice: RemoteWording.alreadyUpToDate(with: upstreamNow),
                    alreadyRefreshed: true)
            case .fastForward:
                // Runs synchronously once the lane is free, and `perform` claims the mutation
                // slot synchronously, so there is no instant with neither held.
                //
                // A pull holds only the lane for its fetch, so a commit or a branch action may
                // have claimed the slot meanwhile — and `mutate` returns silently when it cannot
                // claim it. The pull does not wait (a queued merge would run against a branch
                // the user has since moved, the same reason the lane is never queued); it says
                // why nothing was merged instead of saying nothing.
                return LaneEnding(alreadyRefreshed: true) { [self] in
                    guard !isMutating else {
                        showStickyError(RemoteWording.pullSlotBusy)
                        return
                    }
                    integratePull(upstream: upstreamNow, mode: .fastForwardIfPossible)
                }
            case .askHowToIntegrate(let ahead, let behind):
                return LaneEnding(
                    sheet: .pullDiverged(ahead: ahead, behind: behind, upstream: upstreamNow),
                    alreadyRefreshed: true)
            case .noUpstream:
                return LaneEnding(
                    failure: RemoteWording.noUpstream(now.name), alreadyRefreshed: true)
            case .upstreamGone:
                return LaneEnding(
                    failure: RemoteWording.upstreamGone(now), alreadyRefreshed: true)
            }
        }
    }

    // MARK: - Push

    /// Push the current branch where `PushTarget.resolve` says — and nowhere else. An
    /// unpublished branch publishes: straight away with a single remote, through the publish
    /// sheet with several.
    func push() {
        if let reason = pushBlockedReason {
            showStickyError(reason)
            return
        }
        guard let branch = currentBranchRef, let remotes = snapshot?.refs.remotes else { return }
        switch PushTarget.resolve(branch, remotes: remotes) {
        case .push(let remote, let ref):
            send(branch, to: remote, remoteRef: ref, publishing: false)
        case .unpublished:
            if remotes.count == 1, let only = remotes.first {
                send(branch, to: only.name, remoteRef: "refs/heads/" + branch.name, publishing: true)
            } else {
                activeSheet = .publish(branch: branch.name)
            }
        case .refused(let refusal):
            // Unreachable while `pushBlockedReason` covers it; said anyway rather than ignored.
            showStickyError(RemoteWording.refused(refusal, branch: branch.name))
        }
    }

    /// One push, holding the lane and the mutation slot. `publishing` passes `-u` and reads
    /// the upstream back.
    // internal (not private): used by +RemoteSheets.swift's `confirmPublish`
    func send(_ branch: Branch, to remote: String, remoteRef: String, publishing: Bool) {
        let name = branch.name
        let wasGone = branch.tracking == .gone
        let previousUpstream = branch.upstream
        runOnLane(publishing ? .publish : .push, remote: remote, holdingMutation: true) {
            [self] backend, root, lane, progress in
            let result: PushResult
            do {
                result = try await backend.push(
                    name, to: remote, remoteRef: remoteRef, setUpstream: publishing, at: root,
                    progress: progress)
            } catch {
                return writeFailed(
                    error, kind: publishing ? .publish : .push, branch: name, remote: remote,
                    attempt: "push \"\(name)\" to \"\(remote)\"")
            }

            if let banner = RemoteWording.rejected(
                result.outcome, branch: name, remote: remote,
                remoteMessages: result.remoteMessages)
            {
                guard case .rejected(let rejection) = result.outcome,
                    rejection == .fetchFirst || rejection == .nonFastForward
                else { return LaneEnding(failure: banner) }
                // Brings the remote-tracking ref up to what the server refused over, so the
                // badge shows the behind count and "Force Push…" has something to count. A
                // failure here changes nothing about the rejection.
                try? await backend.fetch(remote: remote, at: root, progress: progress)
                return LaneEnding(
                    failure: banner,
                    rejected: RejectedPush(
                        branch: name, remote: remote, remoteRef: remoteRef,
                        rejection: rejection, banner: banner))
            }

            var lines = [
                RemoteWording.pushed(
                    result.outcome, branch: name, remote: remote, remoteRef: remoteRef,
                    publishing: publishing, wasGone: wasGone)
            ]
            if publishing {
                lines.append(
                    RemoteWording.upstreamAfterPublish(
                        result, branch: name, remote: remote, remoteRef: remoteRef,
                        previousUpstream: previousUpstream))
            }
            var notice = lines.compactMap { $0 }.joined(separator: " ")
            let links = RemoteWording.pullRequestLinks(result.remoteMessages)
            if !links.isEmpty { notice += "\n" + links.joined(separator: "\n") }
            // Pushed, but the upstream was not set, or could not be checked: a success that says
            // something is wrong, which a quit must not carry away unread (`QuitGuard`).
            let warns = result.upstream == .notSet || result.upstream == .unknown
            return LaneEnding(notice: notice, mustBeRead: warns)
        }
    }

    /// What a push, force push or delete that threw says, and the fetch that re-reads the truth
    /// after it. Cancelled means *unknown*, never "nothing changed"; a failure in git's own words
    /// may have happened part-way too, and gets the same re-read.
    // internal (not private): used by +RemoteSheets.swift
    func writeFailed(
        _ error: Error, kind: RemoteActivity.Kind, branch: String, remote: String,
        attempt: String
    ) -> LaneEnding {
        if Self.isCancellation(error) {
            return LaneEnding(
                failure: RemoteWording.cancelledWrite(kind, branch: branch, remote: remote)
            ) { [self] in startFetch(remote: remote, quiet: true) }
        }
        let message = RemoteWording.failure(error, attempt: attempt, isWrite: true)
        guard case GitError.commandFailed = error else { return LaneEnding(failure: message) }
        return LaneEnding(failure: message) { [self] in startFetch(remote: remote, quiet: true) }
    }

    // MARK: - Automatic fetch

    /// Why the scheduler's tick does nothing this time, or nil to fetch. Not a sentence for the
    /// user — nothing about the automatic fetch is ever said in a banner — but what the DEBUG
    /// log prints for each tick.
    ///
    /// Not skipped for a running mutation: a fetch writes only `refs/remotes/*` — and Gitter
    /// refuses a fetch whose refspec would write anywhere else (`FetchRefspec`; the remote is
    /// then skipped and `lastAutoFetchFailure` says so) — and holds only the lane, like the
    /// manual one.
    var autoFetchSkipReason: String? {
        guard AutoFetchScheduler.isEnabled else { return "turned off" }
        guard !isTerminating else { return "quitting" }
        guard root != nil, let snapshot else { return "no repository" }
        if let remoteActivity { return "the lane is busy (\(remoteActivity.kind))" }
        if let operationInProgress { return "an operation is in progress (\(operationInProgress))" }
        if snapshot.refs.remotes.isEmpty { return "no remotes" }
        return nil
    }

    /// One tick of the schedule: `git fetch --all` on the lane as `.autoFetch`, stopped after
    /// `timeout`. Quiet in every outcome — no banner, no notice, no sheet, and the banner or
    /// notice already on screen is left alone (`quiet` claim):
    ///
    /// | outcome | what it leaves |
    /// |---|---|
    /// | fetched | `lastAutoFetchFailure` cleared; the one reload shows the new badges |
    /// | failed | `lastAutoFetchFailure` = git's reason, made plain, one line |
    /// | a remote's refspec writes outside `refs/remotes/` | that remote skipped, the rest fetched; `lastAutoFetchFailure` names it and the fix |
    /// | took longer than `timeout` | stopped; `lastAutoFetchFailure` says so |
    /// | stopped by the user (Stop, ⌘.) | nothing changes but the reload |
    /// | pre-empted by the user's own Fetch, Pull, Push or a sheet's confirm | nothing, no reload: the user's action has the lane and reloads itself |
    ///
    /// It can never ask for anything: git runs with stdin at `/dev/null` and
    /// `GIT_TERMINAL_PROMPT=0`, and ssh with `SSH_ASKPASS_REQUIRE=force` unless the user set an
    /// askpass of their own (`ProcessRunner.runStreaming`), so it never stops on a terminal —
    /// measured in Task 11's review, see the spec's "Auto-fetch".
    func autoFetchTick(timeout: Duration) {
        if let reason = autoFetchSkipReason {
            #if DEBUG
                Self.logAutoFetch("tick skipped: \(reason)")
            #endif
            return
        }
        #if DEBUG
            Self.logAutoFetch("tick: fetching every remote (store \(debugSerial))")
        #endif
        runOnLane(.autoFetch, remote: nil, holdingMutation: false, quiet: true) {
            [self] backend, root, lane, _ in
            do {
                // No progress callback: the toolbar says only that it is running.
                let finished = try await Self.fetchAll(
                    backend: backend, root: root, within: timeout)
                let reason = finished ? nil : RemoteWording.autoFetchTimedOut(after: timeout)
                #if DEBUG
                    Self.logAutoFetch("ended: \(reason ?? "fetched")")
                #endif
                return LaneEnding { [self] in setLastAutoFetchFailure(reason) }
            } catch where Self.isCancellation(error) {
                let preempted = !isCurrentLane(lane)
                #if DEBUG
                    Self.logAutoFetch("ended: \(preempted ? "pre-empted" : "stopped")")
                #endif
                // Pre-empted: the lane is the user's now and their action reloads; a reload here
                // would only run beside it. Stopped: some refs may have moved; the one reload.
                return LaneEnding(alreadyRefreshed: preempted)
            } catch {
                let reason = RemoteWording.autoFetchFailure(error)
                #if DEBUG
                    Self.logAutoFetch("ended: failed: \(reason)")
                #endif
                return LaneEnding { [self] in setLastAutoFetchFailure(reason) }
            }
        }
    }

    /// Turning "Fetch Automatically" off stops an automatic fetch that is running; turning it on
    /// waits for the next tick.
    func autoFetchSettingChanged(enabled: Bool) {
        guard !enabled, remoteActivity?.kind == .autoFetch else { return }
        remoteTask?.cancel()
    }

    /// `git fetch --all`, or false once `timeout` has passed first — the fetch is then
    /// cancelled, and this returns once its git has gone (the runner's escalation bounds that).
    /// A failure or a cancellation of the caller is thrown.
    private nonisolated static func fetchAll(
        backend: Backend, root: URL, within timeout: Duration
    ) async throws -> Bool {
        try await withThrowingTaskGroup(of: Bool.self) { group in
            group.addTask {
                try await backend.fetch(remote: nil, at: root, progress: { _ in })
                return true
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                return false
            }
            defer { group.cancelAll() }
            return try await group.next() ?? false
        }
    }

    #if DEBUG
        static func logAutoFetch(_ message: String) {
            FileHandle.standardError.write(Data("AUTOFETCH \(message)\n".utf8))
        }
    #endif

    // MARK: - Cancel

    /// Stops whatever the lane is running. The running work sees `CancellationError` and says
    /// what that means for its kind: nothing for a fetch beyond "some refs may have moved", and
    /// "may or may not have been updated" — then a fetch — for a write.
    func cancelRemoteActivity() {
        guard remoteActivity != nil else { return }
        remoteTask?.cancel()
    }

    // MARK: - Running on the lane

    /// Claims the lane (and the slot, for a write), runs `work` with a progress callback that
    /// is safe to call from git's pipe queue, reloads once unless `work` already did, frees the
    /// lane, and then says what happened.
    // internal (not private): used by +RemoteSheets.swift
    func runOnLane(
        _ kind: RemoteActivity.Kind, remote: String?, holdingMutation: Bool,
        quiet: Bool = false,
        _ work: @escaping @MainActor (
            Backend, URL, RemoteLane, @escaping @Sendable (String) -> Void
        ) async -> LaneEnding
    ) {
        guard let root,
            let claim = beginRemote(
                kind, remote: remote, holdingMutation: holdingMutation, quiet: quiet)
        else { return }
        let lane = claim.lane
        let preempted = claim.preempted
        let relay = ProgressRelay { [weak self] text in
            self?.setRemoteProgress(text, lane: lane)
        }
        let backend = self.backend
        remoteTask = Task { @MainActor [self] in
            // An automatic fetch this claim stopped: its git is going, and this one's starts
            // only once it has gone (see `beginRemote`).
            await preempted?.value
            let ending = await work(backend, root, lane) { relay.send($0) }
            if !ending.alreadyRefreshed { await laneRefresh(lane) }
            let missedWatcherEvent = watcherEventDuringLane
            finishRemote(lane)
            // A sheet the lane ends with never goes over one the user already has open — a new
            // branch form, a merge question — which a plain assignment would silently replace.
            // The same question with fresher numbers may replace itself; anything else becomes
            // a banner saying what was found and how to ask again.
            var failure = ending.failure
            var sheet = ending.sheet
            if let asked = sheet, let open = activeSheet, !open.asksTheSameQuestion(as: asked) {
                sheet = nil
                failure = [failure, RemoteWording.sheetNotShown(asked)].compactMap { $0 }
                    .joined(separator: " ")
            }
            if let mutationGeneration = lane.mutationGeneration {
                if generation == lane.generation {
                    if let sheet { activeSheet = sheet }
                }
                finishMutation(
                    generation: mutationGeneration,
                    failure: failure.map(RemoteBannerText.init))
            } else {
                guard generation == lane.generation else { return }
                if let sheet { activeSheet = sheet }
                if let failure { showStickyError(failure) }
            }
            guard generation == lane.generation else { return }
            // What a held quit must not carry away unread (`QuitGuard`).
            if let told = failure ?? sheet.map({ "a question: \($0)" })
                ?? (ending.mustBeRead ? ending.notice : nil)
            {
                noteLaneMessageToRead(told)
            }
            // A watcher event that landed after the lane's reload began was dropped; the state
            // on screen may be behind by it, so it gets the reload it was denied.
            if missedWatcherEvent { scheduleRefresh() }
            if let rejected = ending.rejected { setRejectedPush(rejected) }
            if let notice = ending.notice, !notice.isEmpty { showNotice(notice) }
            // Quitting: a pull's merge or a write's follow-up fetch would only be cut short. Kept,
            // though, in case the quit is called off (`endTerminating`).
            guard !isTerminating else {
                if let then = ending.then { holdFollowUpForQuit(then) }
                return
            }
            ending.then?()
        }
    }

    /// The lane's one reload. Clears `watcherEventDuringLane` as it begins: everything the
    /// watcher dropped until now, this reload reads; anything it drops from here on sets the
    /// flag again, and `runOnLane` reloads once more for it.
    ///
    /// Does nothing for a lane `open()` has left behind. Its task was cancelled, but a
    /// cancelled task still runs to its end, and without this guard it reloaded the **new**
    /// repository and cleared the new repository's flag — an event the new repository's own
    /// lane had dropped would then never get its reload.
    ///
    /// Nor for a lane a user's action has taken over (`isCurrentLane`): an automatic fetch that
    /// was pre-empted just as its git finished returns "fetched", and its reload would run beside
    /// the user's action, which reloads itself (Task 11's review).
    // internal (not private): used by +RemoteSheets.swift
    func laneRefresh(_ lane: RemoteLane) async {
        guard isCurrentLane(lane) else { return }
        setWatcherEventDuringLane(false)
        await refresh()
    }

    // internal (not private): used by +RemoteSheets.swift
    static func isCancellation(_ error: Error) -> Bool {
        error is CancellationError || Task.isCancelled
    }
}

/// What the push button does for the current branch. The view and the menu read this, never
/// the title string, to decide what to draw beside it.
enum PushKind: Equatable {
    /// An ordinary push to the target `PushTarget.resolve` names (also when that target is
    /// refused: the button is then disabled with the refusal as its reason).
    case push
    /// No push remote yet: the branch goes to a remote the user names.
    case publish
    /// The upstream was deleted on the remote; the push recreates it.
    case republish
}

/// What one piece of lane work came to: what to say, what to open, and what to start once the
/// lane (and the slot) are free again.
struct LaneEnding {
    var notice: String?
    var failure: String?
    var sheet: BranchSheet?
    var rejected: RejectedPush?
    /// The work reloaded the snapshot itself (a pull decides on the tracking after its fetch),
    /// so `runOnLane` does not reload a second time.
    var alreadyRefreshed = false
    /// The notice is a success with a warning in it ("pushed, but the upstream could not be
    /// set"): like a banner, something a held quit is called off for (`QuitGuard`). A plain
    /// "it worked" is not.
    var mustBeRead = false
    /// Runs on the main actor straight after the lane is freed, with no suspension in between:
    /// a pull's merge claims the mutation slot here, and a write's follow-up fetch claims the
    /// lane again.
    var then: (@MainActor () -> Void)?

    init(
        notice: String? = nil, failure: String? = nil, sheet: BranchSheet? = nil,
        rejected: RejectedPush? = nil, alreadyRefreshed: Bool = false, mustBeRead: Bool = false,
        then: (@MainActor () -> Void)? = nil
    ) {
        self.notice = notice
        self.failure = failure
        self.sheet = sheet
        self.rejected = rejected
        self.alreadyRefreshed = alreadyRefreshed
        self.mustBeRead = mustBeRead
        self.then = then
    }
}

/// A banner sentence already written by `RemoteWording`, handed to `finishMutation` — which
/// describes an `Error` — without being described a second time.
struct RemoteBannerText: LocalizedError {
    let text: String
    init(_ text: String) { self.text = text }
    var errorDescription: String? { text }
}
