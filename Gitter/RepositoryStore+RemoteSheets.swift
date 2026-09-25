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
            try await Self.reporting(.rebaseOnto, upstream) {
                try await backend.rebase(onto: target, at: root)
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
        guard snapshot?.refs.remotes.contains(where: { $0.name == remote }) == true else {
            showStickyError(RemoteWording.noSuchRemote(remote))
            return
        }
        send(branch, to: remote, remoteRef: "refs/heads/" + branch.name, publishing: true)
    }

    // MARK: - Force push

    /// Opens the force push confirmation — and is reachable **only** from the banner of a push
    /// the server refused for having commits this branch lacks (`rejectedPush`).
    ///
    /// Fetches that remote first, so the sheet counts what the server has *now*, then reads the
    /// remote-tracking ref's **full** sha — the lease `confirmForcePush` will hand to git — and
    /// the commits it holds that the local branch does not: the first 20, and how many in all.
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

        runOnLane(.fetch, remote: remote, holdingMutation: false) { [self] backend, root, progress in
            do {
                try await backend.fetch(remote: remote, at: root, progress: progress)
            } catch where Self.isCancellation(error) {
                return LaneEnding(notice: RemoteWording.fetchStopped(from: remote))
            } catch {
                return LaneEnding(
                    failure: RemoteWording.failure(
                        error, attempt: "fetch from \"\(remote)\"", isWrite: false))
            }
            await refresh()
            // From the snapshot just read, after the fetch: `%(objectname)`, the full sha.
            guard let tip = remoteBranches.first(where: { $0.name == trackingName })?.sha else {
                return LaneEnding(
                    failure: RemoteWording.noRemoteTrackingRef(trackingName),
                    alreadyRefreshed: true)
            }
            let local = "refs/heads/" + branchName
            do {
                let total = try await backend.commitCount(in: tip, notIn: local, at: root)
                guard total > 0 else {
                    return LaneEnding(
                        notice: RemoteWording.nothingToForce(trackingName, branch: branchName),
                        alreadyRefreshed: true)
                }
                let discarded = try await backend.commits(
                    in: tip, notIn: local, limit: 20, at: root)
                return LaneEnding(
                    sheet: .forcePush(
                        branch: branchName, remote: remote, remoteRef: rejected.remoteRef,
                        remoteTip: tip, discarded: discarded, total: total),
                    alreadyRefreshed: true)
            } catch {
                return LaneEnding(
                    failure: RemoteWording.failure(
                        error, attempt: "count what a force push would replace",
                        isWrite: false),
                    alreadyRefreshed: true)
            }
        }
    }

    /// The force push, leased on the sheet's own `remoteTip`: if the server's branch is not
    /// exactly there any more, git answers `[rejected] (stale info)` and changes nothing.
    func confirmForcePush() {
        guard case .forcePush(let branch, let remote, let remoteRef, let remoteTip, _, _) =
            activeSheet
        else { return }
        activeSheet = nil
        guard currentBranch == branch else {
            showStickyError(RemoteWording.forcePushSheetStale)
            return
        }
        runOnLane(.forcePush, remote: remote, holdingMutation: true) {
            [self] backend, root, progress in
            let result: PushResult
            do {
                result = try await backend.forcePush(
                    branch, to: remote, remoteRef: remoteRef, expectedRemoteTip: remoteTip,
                    at: root, progress: progress)
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
            var notice = RemoteWording.pushed(
                result.outcome, branch: branch, remote: remote, remoteRef: remoteRef,
                publishing: false, wasGone: false) ?? ""
            let links = RemoteWording.pullRequestLinks(result.remoteMessages)
            if !links.isEmpty { notice += "\n" + links.joined(separator: "\n") }
            return LaneEnding(notice: notice)
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
        let remoteName = remote.name
        let branch = String(remoteBranch.dropFirst(remoteName.count + 1))

        runOnLane(.fetch, remote: remoteName, holdingMutation: false) {
            [self] backend, root, progress in
            do {
                try await backend.fetch(remote: remoteName, at: root, progress: progress)
            } catch where Self.isCancellation(error) {
                return LaneEnding(notice: RemoteWording.fetchStopped(from: remoteName))
            } catch {
                return LaneEnding(
                    failure: RemoteWording.failure(
                        error, attempt: "fetch from \"\(remoteName)\"", isWrite: false))
            }
            await refresh()
            guard let tip = remoteBranches.first(where: { $0.name == remoteBranch })?.sha else {
                return LaneEnding(
                    notice: RemoteWording.alreadyGone(branch, on: remoteName),
                    alreadyRefreshed: true)
            }
            do {
                let onlyThere = try await backend.commitsOnlyOnRemoteBranch(
                    remoteBranch, at: root)
                return LaneEnding(
                    sheet: .deleteRemoteBranch(
                        remote: remoteName, branch: branch, tip: tip, onlyThere: onlyThere),
                    alreadyRefreshed: true)
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
    func confirmDeleteRemoteBranch() {
        guard case .deleteRemoteBranch(let remote, let branch, let tip, _) = activeSheet else {
            return
        }
        activeSheet = nil
        runOnLane(.deleteRemoteBranch, remote: remote, holdingMutation: true) {
            [self] backend, root, progress in
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
