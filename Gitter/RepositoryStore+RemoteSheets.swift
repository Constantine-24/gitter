import Foundation
import GitCore

/// The four remote sheets: opening them, and answering them.
///
/// The same pattern as `+BranchSheets`: every `confirm…` method first requires the matching
/// sheet to be on screen — with nothing to answer, a stale call, a mis-wired button or a debug
/// step reaching straight for the destructive half stops there — and carries what the sheet
/// showed into the operation. For the two that can lose commits on the server, what it carries
/// is a **full sha handed to git as a lease**, so a remote branch that moved while the sheet
/// was up is refused by the server itself (`[rejected] (stale info)`), not by a re-read here
/// that could be overtaken in turn.
extension RepositoryStore {

    // MARK: - Pull

    /// Answers the pull sheet. Merge is the existing `merge(.alwaysMergeCommit)`; Rebase is
    /// `rebase(onto:)` with the upstream spelled as the full remote-tracking ref. Either way the
    /// remembered pull mode is written only after it ran.
    ///
    /// Refused if the branch no longer tracks the upstream the sheet asked about: the counts on
    /// it are about that pair, and a terminal can switch branches while it is up.
    func confirmPull(_ mode: PullMode) {
        guard case .pullDiverged(_, _, let upstream) = activeSheet else { return }
        // `mutate` drops a call silently while the slot is held; the answer to a question must
        // not vanish like that. Checked **before** the sheet is taken down: the question is
        // still the right one, and leaving it up is what lets the user answer it again once
        // the other change has finished.
        guard !isMutating else {
            showStickyError(RemoteWording.pullAnswerSlotBusy)
            return
        }
        activeSheet = nil
        guard let branch = currentBranchRef, branch.upstream == upstream else {
            showStickyError(RemoteWording.pullSheetStale)
            return
        }
        switch mode {
        case .merge:
            integratePull(upstream: upstream, mode: .alwaysMergeCommit)
        case .rebase:
            rebase(branch, onto: upstream)
        }
    }

    /// The Rebase answer. Refused first while an operation is in progress, like every action
    /// that moves HEAD; then `GitRemoteBackend.rebase` refuses a dirty tree before git runs
    /// (`.treeNotClean`, the existing sentence). A rebase that stops is `.conflicts`: the
    /// existing operation note and Abort sheet take over, and nothing more is said here.
    private func rebase(_ branch: Branch, onto upstream: String) {
        if let reason = branchSwitchingBlockedReason {
            mutate { _, _ in throw BranchActionBlocked(reason: reason) }
            return
        }
        let target = Self.fullUpstreamRef(of: branch) ?? upstream
        let name = branch.name
        mutate(result: { backend, root in
            do {
                return try await Self.reporting(.rebaseOnto, upstream) {
                    try await backend.rebase(onto: target, at: root)
                }
            } catch {
                // A dirty tree: Stash and Continue runs the pull again (`retry`). The mode is
                // the diverged sheet's; a retried pull asks again rather than reading it.
                throw StashAndContinue.offering(
                    error, for: .pull(upstream: upstream, mode: .alwaysMergeCommit))
            }
        }, onSuccess: { [self] outcome in
            Self.rememberPullMode(.rebase)
            select(.workingCopy)
            if let notice = RemoteWording.rebaseNotice(outcome, branch: name, upstream: upstream) {
                showNotice(notice)
            }
        })
    }

    /// The upstream as a full ref name — `refs/remotes/origin/main`, or `refs/heads/main` for a
    /// local upstream — built from `%(upstream:short)`, which git prints as the shortest
    /// *unambiguous* spelling: `origin/main` normally, `remotes/origin/main` when a local branch
    /// or tag of that name would shadow it.
    static func fullUpstreamRef(of branch: Branch) -> String? {
        guard let upstream = branch.upstream else { return nil }
        if upstream.hasPrefix("refs/") { return upstream }
        if upstream.hasPrefix("remotes/") || upstream.hasPrefix("heads/") {
            return "refs/" + upstream
        }
        return branch.upstreamRemote == nil ? "refs/heads/" + upstream : "refs/remotes/" + upstream
    }

    // MARK: - Publish

    /// Publishes the current branch to `remote` from the publish sheet: `push -u`, onto the
    /// branch's own name there.
    func confirmPublish(to remote: String) {
        guard case .publish(let name) = activeSheet else { return }
        activeSheet = nil
        guard let branch = currentBranchRef, branch.name == name else {
            showStickyError(RemoteWording.publishSheetStale)
            return
        }
        guard snapshot?.refs.remotes.contains(where: { $0.name == remote && $0.canPush }) == true else {
            showStickyError(RemoteWording.noSuchRemote(remote))
            return
        }
        send(branch, to: remote, remoteRef: "refs/heads/" + branch.name, publishing: true)
    }

    // MARK: - Force push

    /// Opens the force push confirmation — and is reachable **only** from the banner of a push
    /// the server refused for having commits this branch lacks (`rejectedPush`).
    ///
    /// Fetches that remote first, so the sheet counts what the server has *now*, then reads two
    /// **full** shas from the snapshot taken after it: the remote-tracking ref's — the lease
    /// `confirmForcePush` hands to git — and the local branch's — the commit it pushes. The
    /// commits the first holds that the second lacks are counted against the *sha*, not the
    /// branch name, so what the sheet lists is exactly what that push would take off.
    ///
    /// Stop during the counting reads "stopped", like Stop anywhere else: the counting is part
    /// of what the user asked for, and "Couldn't count" would describe a failure that did not
    /// happen.
    func requestForcePush() {
        guard let rejected = rejectedPush, rejected.branch == currentBranch else {
            showStickyError(RemoteWording.forcePushNotOffered)
            return
        }
        let remote = rejected.remote
        let branchName = rejected.branch
        let remoteName = rejected.remoteRef.hasPrefix("refs/heads/")
            ? String(rejected.remoteRef.dropFirst("refs/heads/".count)) : rejected.remoteRef
        let trackingName = "\(remote)/\(remoteName)"

        runOnLane(.fetch, remote: remote, holdingMutation: false) { [self] backend, root, lane, progress in
            do {
                try await backend.fetch(remote: remote, at: root, progress: progress)
            } catch where Self.isCancellation(error) {
                return LaneEnding(notice: RemoteWording.fetchStopped(from: remote))
            } catch {
                return LaneEnding(
                    failure: RemoteWording.failure(
                        error, attempt: "fetch from \"\(remote)\"", isWrite: false))
            }
            await laneRefresh(lane)
            // Stop pressed during the reload: it ran to the end (a reload is not cancellable),
            // and nothing after it should.
            if Task.isCancelled {
                return LaneEnding(
                    notice: RemoteWording.forcePushWarningStopped, alreadyRefreshed: true)
            }
            // From the snapshot just read, after the fetch: `%(objectname)`, the full sha.
            guard let tip = remoteBranches.first(where: { $0.name == trackingName })?.sha else {
                return LaneEnding(
                    failure: RemoteWording.noRemoteTrackingRef(trackingName),
                    alreadyRefreshed: true)
            }
            guard let localTip = localBranches.first(where: { $0.name == branchName })?.sha else {
                return LaneEnding(
                    failure: RemoteWording.forcePushBranchGone(branchName),
                    alreadyRefreshed: true)
            }
            do {
                let total = try await backend.commitCount(in: tip, notIn: localTip, at: root)
                try Task.checkCancellation()
                guard total > 0 else {
                    return LaneEnding(
                        notice: RemoteWording.nothingToForce(trackingName, branch: branchName),
                        alreadyRefreshed: true)
                }
                let discarded = try await backend.commits(
                    in: tip, notIn: localTip, limit: 20, at: root)
                try Task.checkCancellation()
                return LaneEnding(
                    sheet: .forcePush(
                        branch: branchName, localTip: localTip, remote: remote,
                        remoteRef: rejected.remoteRef, remoteTip: tip, discarded: discarded,
                        total: total),
                    alreadyRefreshed: true)
            } catch where Self.isCancellation(error) {
                return LaneEnding(
                    notice: RemoteWording.forcePushWarningStopped, alreadyRefreshed: true)
            } catch {
                return LaneEnding(
                    failure: RemoteWording.failure(
                        error, attempt: "count what a force push would replace",
                        isWrite: false),
                    alreadyRefreshed: true)
            }
        }
    }

    /// The force push, pinned on **both** sides to what the sheet showed: leased on its
    /// `remoteTip` — if the server's branch is not exactly there any more, git answers
    /// `[rejected] (stale info)` and changes nothing — and sending its `localTip` by sha, so git
    /// pushes that commit whatever the branch points at now.
    ///
    /// **Refused, not pushed, when the branch has moved since the sheet was drawn.** Sending
    /// `localTip` anyway would be safe for the server — it is exactly what the sheet counted —
    /// but the sheet described it as "your branch", and it no longer is: the user may have reset
    /// away from it on purpose. The re-read is a fresh snapshot taken inside the lane, holding
    /// the mutation slot, so nothing in Gitter can move the branch after it; a terminal that
    /// does in the instant before git runs still gets the sha the sheet showed pushed, never
    /// anything else.
    func confirmForcePush() {
        guard
            case .forcePush(let branch, let localTip, let remote, let remoteRef, let remoteTip, _, _) =
                activeSheet
        else { return }
        activeSheet = nil
        guard currentBranch == branch else {
            showStickyError(RemoteWording.forcePushSheetStale)
            return
        }
        runOnLane(.forcePush, remote: remote, holdingMutation: true) {
            [self] backend, root, lane, progress in
            let branchNow: String?
            do {
                let fresh = try await backend.snapshot(at: root)
                branchNow = fresh.refs.localBranches.first { $0.name == branch }?.sha
            } catch where Self.isCancellation(error) {
                return LaneEnding(notice: RemoteWording.forcePushStoppedBeforeSending)
            } catch {
                return LaneEnding(
                    failure: RemoteWording.failure(
                        error, attempt: "check \"\(branch)\" before force pushing",
                        isWrite: false) + " Nothing was pushed.")
            }
            guard branchNow == localTip else {
                return LaneEnding(failure: RemoteWording.forcePushBranchMoved(branch))
            }
            let result: PushResult
            do {
                result = try await backend.forcePush(
                    branch, to: remote, remoteRef: remoteRef, expectedRemoteTip: remoteTip,
                    expectedLocalTip: localTip, at: root, progress: progress)
            } catch {
                return writeFailed(
                    error, kind: .forcePush, branch: branch, remote: remote,
                    attempt: "force push \"\(branch)\" to \"\(remote)\"")
            }
            if let banner = RemoteWording.rejected(
                result.outcome, branch: branch, remote: remote,
                remoteMessages: result.remoteMessages)
            {
                // Stale lease: the server changed nothing, and a fetch shows what it has now.
                try? await backend.fetch(remote: remote, at: root, progress: progress)
                return LaneEnding(failure: banner)
            }
            var text = RemoteWording.pushed(
                result.outcome, branch: branch, remote: remote, remoteRef: remoteRef,
                publishing: false, wasGone: false) ?? ""
            let hostLines = RemoteWording.pullRequestLines(result.remoteMessages)
            if !hostLines.isEmpty { text += "\n" + hostLines.joined(separator: "\n") }
            return LaneEnding(
                notice: Notice.linked(
                    text: text,
                    links: NoticeLinks.extract(fromRemoteLines: result.remoteMessages)))
        }
    }

    // MARK: - Delete on a remote

    /// Opens the confirmation for deleting `remoteBranch` (`origin/topic`) on its remote.
    ///
    /// Fetches that remote first, then reads the remote-tracking ref's **full** sha — the
    /// lease — and how many of its commits are held by no branch, tag or other remote
    /// (`commitsOnlyOnRemoteBranch`). Never "unreachable": that count does not look at the
    /// stash, notes, a detached HEAD, other worktrees or the reflog.
    func requestDeleteRemoteBranch(_ remoteBranch: String) {
        if let reason = deleteRemoteBranchBlockedReason {
            showStickyError(reason)
            return
        }
        guard let refs = snapshot?.refs,
            let ref = refs.remoteBranches.first(where: { $0.name == remoteBranch }),
            let remote = refs.remote(of: ref)
        else {
            showStickyError(RemoteWording.noSuchRemoteBranch(remoteBranch))
            return
        }
        // Fetched from, then pushed to: neither with no URL (fix round 1, I1).
        if let reason = RemoteWording.deleteOnRemoteURLBlocked(remote) {
            showStickyError(reason)
            return
        }
        let remoteName = remote.name
        let branch = String(remoteBranch.dropFirst(remoteName.count + 1))

        runOnLane(.fetch, remote: remoteName, holdingMutation: false) {
            [self] backend, root, lane, progress in
            do {
                try await backend.fetch(remote: remoteName, at: root, progress: progress)
            } catch where Self.isCancellation(error) {
                return LaneEnding(notice: RemoteWording.fetchStopped(from: remoteName))
            } catch {
                return LaneEnding(
                    failure: RemoteWording.failure(
                        error, attempt: "fetch from \"\(remoteName)\"", isWrite: false))
            }
            await laneRefresh(lane)
            if Task.isCancelled {
                return LaneEnding(
                    notice: RemoteWording.deleteWarningStopped, alreadyRefreshed: true)
            }
            guard let tip = remoteBranches.first(where: { $0.name == remoteBranch })?.sha else {
                return LaneEnding(
                    notice: RemoteWording.alreadyGone(branch, on: remoteName),
                    alreadyRefreshed: true)
            }
            do {
                let onlyThere = try await backend.commitsOnlyOnRemoteBranch(
                    remoteBranch, at: root)
                try Task.checkCancellation()
                return LaneEnding(
                    sheet: .deleteRemoteBranch(
                        remote: remoteName, branch: branch, tip: tip, onlyThere: onlyThere),
                    alreadyRefreshed: true)
            } catch where Self.isCancellation(error) {
                return LaneEnding(
                    notice: RemoteWording.deleteWarningStopped, alreadyRefreshed: true)
            } catch {
                return LaneEnding(
                    failure: RemoteWording.failure(
                        error, attempt: "count the commits only on \"\(remoteBranch)\"",
                        isWrite: false),
                    alreadyRefreshed: true)
            }
        }
    }

    /// The deletion, leased on the sheet's own `tip`.
    ///
    /// **Refused, not sent, when more commits would go with it than the sheet said.** The lease
    /// guards the server's side; the sheet's count is about *this clone's* refs, and those can
    /// change under an open sheet without the tip moving at all. Reproduced in the final review
    /// (`frqa/sd`): the sheet said 0 — the commits were also on a local branch — a terminal
    /// `git branch -D` of that branch made it 1, and Confirm deleted the only ref left to the
    /// commit. So the count is asked again inside the lane, holding the mutation slot, and a
    /// rise is refused in the words the force push uses for its own stale sheet. A count that
    /// fell (the commits are held somewhere new) is no reason to refuse.
    func confirmDeleteRemoteBranch() {
        guard case .deleteRemoteBranch(let remote, let branch, let tip, let onlyThere) = activeSheet
        else {
            return
        }
        activeSheet = nil
        runOnLane(.deleteRemoteBranch, remote: remote, holdingMutation: true) {
            [self] backend, root, lane, progress in
            let remoteBranch = remote + "/" + branch
            do {
                let onlyThereNow = try await backend.commitsOnlyOnRemoteBranch(
                    remoteBranch, at: root)
                try Task.checkCancellation()
                guard onlyThereNow <= onlyThere else {
                    return LaneEnding(
                        failure: RemoteWording.deleteRemoteMoreWouldGo(
                            remoteBranch, was: onlyThere, now: onlyThereNow))
                }
            } catch where Self.isCancellation(error) {
                return LaneEnding(notice: RemoteWording.deleteStoppedBeforeSending)
            } catch {
                return LaneEnding(
                    failure: RemoteWording.failure(
                        error, attempt: "count the commits only on \"\(remoteBranch)\"",
                        isWrite: false) + " Nothing was deleted.")
            }
            let result: PushResult
            do {
                result = try await backend.deleteRemoteBranch(
                    branch, on: remote, expectedTip: tip, at: root)
            } catch {
                return writeFailed(
                    error, kind: .deleteRemoteBranch, branch: branch, remote: remote,
                    attempt: "delete \"\(branch)\" on \"\(remote)\"")
            }
            if let banner = RemoteWording.deleteRejected(
                result.outcome, branch: branch, remote: remote,
                remoteMessages: result.remoteMessages)
            {
                try? await backend.fetch(remote: remote, at: root, progress: progress)
                return LaneEnding(failure: banner)
            }
            return LaneEnding(notice: RemoteWording.deleted(branch: branch, remote: remote, tip: tip))
        }
    }

    #if DEBUG
        /// Puts the pull sheet up from the tracking already on screen — no fetch, no merge — so
        /// `sheet:pull` can honestly mean "open the sheet". Does nothing unless the branch has
        /// diverged, which is the only state the real flow asks in.
        func previewPullSheet() {
            guard let branch = currentBranchRef, let upstream = branch.upstream,
                case .askHowToIntegrate(let ahead, let behind) = PullPlan.decide(branch.tracking)
            else { return }
            activeSheet = .pullDiverged(ahead: ahead, behind: behind, upstream: upstream)
        }
    #endif
}
