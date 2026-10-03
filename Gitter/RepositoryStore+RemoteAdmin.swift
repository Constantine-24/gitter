import Foundation
import GitCore

/// B2's housekeeping, the app half (Task 4): Prune <remote>…, Clean Up Gone Branches…, Push and
/// Fast-Forward of a branch that is not checked out, and Set / Change / Unset Upstream.
///
/// The same pattern as `+RemoteSheets`: every `confirm…` first requires its sheet on screen and
/// carries what the sheet showed into GitCore, which compares it again before it writes — a
/// prune's ids (compare-and-delete), a clean-up's tips and counts, a fast-forward's tip
/// (compare-and-set). Every sentence is `RemoteAdminWording`'s.
///
/// | action | runs | holds |
/// |---|---|---|
/// | prune's list | on the lane (`.prune`): a dry-run fetch contacts the remote | the lane |
/// | prune | on the lane (`.prune`) | the lane and the mutation slot |
/// | fast-forward | on the lane (`.fastForward`): Gitter's fetch, then the compare-and-set | the lane and the mutation slot |
/// | push / publish of another branch | the existing push (`send`) | the lane and the mutation slot |
/// | clean-up's list and deletes, set / unset upstream | `mutate` | the mutation slot |
extension RepositoryStore {

    // MARK: - Why a menu item is off

    /// A local branch by name, as the snapshot on screen has it.
    func localBranch(_ name: String) -> Branch? {
        localBranches.first { $0.name == name }
    }

    func pushBranchBlockedReason(_ name: String) -> String? {
        guard let branch = localBranch(name) else { return RemoteAdminWording.noSuchBranch(name) }
        return RemoteAdminWording.pushBranchBlocked(branch, gate: remoteGate)
    }

    func fastForwardBlockedReason(_ name: String) -> String? {
        guard let branch = localBranch(name) else { return RemoteAdminWording.noSuchBranch(name) }
        return RemoteAdminWording.fastForwardBlocked(branch, gate: remoteGate)
    }

    var upstreamBlockedReason: String? { RemoteAdminWording.upstreamBlocked(remoteGate) }

    func unsetUpstreamBlockedReason(_ name: String) -> String? {
        guard let branch = localBranch(name) else { return RemoteAdminWording.noSuchBranch(name) }
        return RemoteAdminWording.unsetUpstreamBlocked(branch, gate: remoteGate)
    }

    func pruneBlockedReason(_ remote: Remote) -> String? {
        RemoteAdminWording.pruneBlocked(remote, gate: remoteGate)
    }

    var pruneMenuBlockedReason: String? { RemoteAdminWording.pruneMenuBlocked(remoteGate) }
    var cleanUpBlockedReason: String? { RemoteAdminWording.cleanUpBlocked(remoteGate) }

    // MARK: - Prune

    /// Opens "Prune <remote>…": GitCore's list — a dry-run fetch, on the lane — and, after the
    /// one reload (the listing downloads objects and may re-create `<remote>/HEAD`, R26), the
    /// sheet. Nothing to prune is a notice, not an empty sheet.
    func requestPrune(_ remote: String) {
        guard let entry = snapshot?.refs.remotes.first(where: { $0.name == remote }) else {
            showStickyError(RemoteAdminWording.remoteGone(remote))
            return
        }
        if let reason = pruneBlockedReason(entry) {
            showStickyError(reason)
            return
        }
        runOnLane(.prune, remote: remote, holdingMutation: false) { [self] backend, root, lane, _ in
            let plan: PrunePlan
            do {
                plan = try await backend.prunePlan(remote, at: root)
            } catch where Self.isCancellation(error) {
                return LaneEnding(notice: RemoteAdminWording.pruneListStopped)
            } catch {
                return LaneEnding(failure: RemoteAdminWording.pruneListFailure(error, remote: remote))
            }
            await laneRefresh(lane)
            if Task.isCancelled {
                return LaneEnding(notice: RemoteAdminWording.pruneListStopped, alreadyRefreshed: true)
            }
            guard !plan.refs.isEmpty else {
                return LaneEnding(notice: RemoteAdminWording.nothingToPrune(remote), alreadyRefreshed: true)
            }
            return LaneEnding(sheet: .prune(plan), alreadyRefreshed: true)
        }
    }

    /// Prunes exactly `plan` — the sheet's, and only while it is the one on screen — creating
    /// the branches in `keeping` (plan ref → new branch name) first. GitCore counts the stranded
    /// commits again, creates the kept branches, and deletes each ref only while it holds the id
    /// the sheet showed.
    ///
    /// The notice is **sticky**: a pruned remote-tracking ref has no reflog (R7), so the ids it
    /// names are the only way back. `<remote>/HEAD`'s target is read just before, so the notice
    /// can say when it was pruned out from under it (carried note 1).
    func confirmPrune(_ plan: PrunePlan, keeping: [String: String]) {
        guard case .prune(let shown) = activeSheet, shown == plan else { return }
        // Before the sheet closes, so a refusal leaves it up to answer again.
        if let refusal = laneClaimRefusal(.prune, holdingMutation: true) {
            showStickyError(refusal)
            return
        }
        activeSheet = nil
        let remote = plan.remote
        runOnLane(.prune, remote: remote, holdingMutation: true) { backend, root, _, _ in
            let headTarget = (try? await backend.remoteHEADTarget(of: remote, at: root)) ?? nil
            let result: PruneResult
            do {
                result = try await backend.prune(plan, keeping: keeping, at: root)
            } catch {
                return LaneEnding(failure: RemoteAdminWording.pruneFailure(error, remote: remote))
            }
            return LaneEnding(
                notice: Notice(text: RemoteAdminWording.pruned(result, remote: remote, headTarget: headTarget)),
                mustBeRead: RemoteAdminWording.prunedNeedsReading(result), sticky: true)
        }
    }

    /// The prune sheet's keep boxes: a suggested name for every holder (Ruling 1: its own name,
    /// or `-kept` when a branch, tag or remote has it, and no two alike) and the holders ticked by
    /// default — those whose commits no other holder already keeps (carried note 2), decided by
    /// asking git whether one holder's tip is in another's history (`commitCount … == 0`).
    /// With more than `keepComparisonLimit` holders the pairs are not asked and every holder is
    /// ticked: more branches than needed, never fewer.
    func pruneKeepDefaults(_ plan: PrunePlan) async -> (names: [String: String], ticked: Set<String>) {
        let holders = plan.stranded.holders.compactMap { ref in plan.refs.first { $0.ref == ref } }
        var contained: Set<[String]> = []
        if let root, holders.count <= Self.keepComparisonLimit {
            for outer in holders {
                for inner in holders where inner.ref != outer.ref {
                    if (try? await backend.commitCount(in: inner.id, notIn: outer.id, at: root)) == 0 {
                        contained.insert([outer.ref, inner.ref])
                    }
                }
            }
        }
        let ticked = RemoteAdminWording.defaultKeeps(holders) { contained.contains([$0.ref, $1.ref]) }
        let refs = snapshot?.refs
        var taken = Set(
            (refs?.localBranches.map(\.name) ?? []) + (refs?.tags.map(\.name) ?? [])
                + (refs?.remoteNames ?? []))
        var names: [String: String] = [:]
        for tip in holders {
            let name = RemoteAdminWording.suggestedKeepName(for: tip.ref, remote: plan.remote, taken: taken)
            names[tip.ref] = name
            taken.insert(name)
        }
        return (names, Set(ticked))
    }

    static let keepComparisonLimit = 16

    /// The keep field's live check: GitCore's `keepBranchNameProblem` (the refusal `prune` would
    /// throw), and two ticked fields alike.
    func keepNameProblem(_ name: String, duplicate: Bool) async -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return RemoteAdminWording.keepNameEmpty }
        guard let root else { return nil }
        let refusal = (try? await backend.keepBranchNameProblem(trimmed, at: root)) ?? nil
        return RemoteAdminWording.keepNameProblem(refusal, duplicate: duplicate)
    }

    /// `<remote>/HEAD`'s target now, for the sheet's dangling-HEAD line.
    func remoteHEADTarget(_ remote: String) async -> String? {
        guard let root else { return nil }
        return (try? await backend.remoteHEADTarget(of: remote, at: root)) ?? nil
    }

    // MARK: - Clean Up Gone Branches

    /// Lists the branches whose upstream is gone (`goneBranches`, through `mutate` so no delete
    /// runs beside it) and opens the sheet — or says there are none.
    func requestCleanUpGoneBranches() {
        if let reason = cleanUpBlockedReason {
            showStickyError(reason)
            return
        }
        mutate(result: { backend, root in
            do {
                return try await backend.goneBranches(at: root)
            } catch {
                throw RemoteBannerText(RemoteAdminWording.cleanUpListFailure(error))
            }
        }, onSuccess: { [self] gone in
            guard !gone.isEmpty else {
                showNotice(RemoteAdminWording.nothingGone)
                return
            }
            // Never over a sheet the user opened meanwhile.
            guard activeSheet == nil else { return }
            activeSheet = .cleanUpGone(gone)
        })
    }

    /// Deletes `branches` — the ticked rows of the sheet on screen, as it read them — one by one
    /// with the existing compare-and-delete (`forceDeleteBranch` on the tip the sheet showed),
    /// each only while it strands no more commits than its row said. A branch that changed,
    /// would strand more, or that git refuses is left and named; one git deleted is read back
    /// for the `branch.<name>.*` settings a held `config.lock` leaves (Ruling 2). Nothing is
    /// thrown for one branch: the whole report is said at the end — a sticky notice naming every
    /// tip, or a banner when anything was not done.
    func confirmCleanUp(_ branches: [GoneBranch]) {
        guard case .cleanUpGone(let shown) = activeSheet, !branches.isEmpty,
            branches.allSatisfy(shown.contains)
        else { return }
        guard !isMutating else {
            showStickyError(RemoteWording.mutationBusy)
            return
        }
        activeSheet = nil
        mutate(result: { backend, root in
            var report = CleanUpReport(deleted: [])
            for gone in branches {
                let reason = await Self.deleteGoneBranch(gone, backend: backend, root: root)
                if let reason {
                    report.notDeleted.append(.init(name: gone.name, reason: reason))
                    continue
                }
                // Nil when the read-back fails: said as unknown, never taken for "nothing left".
                let left = try? await backend.branchConfigKeys(of: gone.name, at: root)
                report.deleted.append(.init(name: gone.name, tip: gone.tip, settingsLeft: left))
            }
            return report
        }, onSuccess: { [self] report in
            let text = RemoteAdminWording.cleanedUp(report)
            if report.hasProblems {
                showStickyError(text)
            } else {
                showStickyNotice(Notice(text: text))
            }
        })
    }

    /// One branch of a clean-up: nil when git deleted it, else why it was left.
    private static func deleteGoneBranch(
        _ gone: GoneBranch, backend: Backend, root: URL
    ) async -> CleanUpReport.Reason? {
        do {
            let now = try await backend.commitsOnlyOn(branch: gone.name, at: root)
            guard now <= gone.uniqueCommits else { return .moreWouldGo(was: gone.uniqueCommits, now: now) }
            try await backend.forceDeleteBranch(gone.name, expectedTip: gone.tip, at: root)
            return nil
        } catch BranchOperationError.branchMoved(_, _, let actual) {
            return .moved(now: actual)
        } catch BranchOperationError.noSuchBranch {
            return .alreadyGone
        } catch BranchOperationError.cannotDeleteCurrent {
            // GitCore's reading of git's "used by worktree at …" too (R10).
            return .checkedOut
        } catch let refusal as BranchOperationError {
            return .failed(refusal.sentence(refusing: "delete \"\(gone.name)\""))
        } catch GitError.commandFailed(let code, let stderr) {
            let words = RemoteWording.plainJoined(stderr.split(whereSeparator: \.isNewline).map(String.init))
            return .failed(words.isEmpty ? "git exited with code \(code)." : words)
        } catch {
            return .failed(error.localizedDescription)
        }
    }

    // MARK: - Push another branch

    /// Push <b> / Publish <b>… / Re-publish <b> from a branch's own menu: where
    /// `PushTarget.resolve` says, never forced (R11, R12). The branch HEAD is on gets the same
    /// push as the toolbar; any other is pushed by name and HEAD is not touched. Publish always
    /// opens its sheet, so the remote is named before anything is sent.
    func pushBranch(_ name: String) {
        if let reason = pushBranchBlockedReason(name) {
            showStickyError(reason)
            return
        }
        guard let branch = localBranch(name), let remotes = snapshot?.refs.remotes else { return }
        switch PushTarget.resolve(branch, remotes: remotes) {
        case .push(let remote, let ref):
            send(branch, to: remote, remoteRef: ref, publishing: false, checkedOut: name == currentBranch)
        case .unpublished:
            activeSheet = .publish(branch: name)
        case .refused(let refusal):
            showStickyError(RemoteWording.refused(refusal, branch: name))
        }
    }

    // MARK: - Fast-forward another branch

    /// Fast-Forward <b>: Gitter's own fetch of the upstream's remote on the lane (none for a
    /// local upstream), then GitCore's compare-and-set on the tip the menu showed — refused, with
    /// nothing moved, if the branch has commits of its own, moved meanwhile, or is in use by a
    /// worktree (R15). The notice's destination is the outcome's (carried note 3).
    func fastForwardBranch(_ name: String) {
        if let reason = fastForwardBlockedReason(name) {
            showStickyError(reason)
            return
        }
        guard let branch = localBranch(name), let upstream = branch.upstream else { return }
        let tip = branch.sha
        let remote = branch.upstreamRemote
        runOnLane(.fastForward, remote: remote, holdingMutation: true) { backend, root, _, progress in
            if let remote {
                do {
                    try await backend.fetch(remote: remote, at: root, progress: progress)
                } catch where Self.isCancellation(error) {
                    return LaneEnding(notice: RemoteAdminWording.fastForwardStopped(name))
                } catch {
                    return LaneEnding(
                        failure: RemoteWording.failure(error, attempt: "fetch from \"\(remote)\"", isWrite: false)
                            + " \"\(name)\" was not moved.")
                }
            }
            do {
                let outcome = try await backend.fastForward(name, expecting: tip, at: root)
                return LaneEnding(notice: RemoteAdminWording.fastForwarded(outcome, branch: name, upstream: upstream))
            } catch let partial as RemoteAdminPartial {
                // Stopped while the compare-and-set ran: unknown, never "nothing changed".
                return LaneEnding(
                    failure: RemoteAdminWording.fastForwardFailure(partial, branch: name, upstream: upstream))
            } catch is CancellationError {
                // GitCore turns a cancellation during the write into the case above; this one
                // came before it.
                return LaneEnding(notice: RemoteAdminWording.fastForwardStopped(name))
            } catch {
                return LaneEnding(
                    failure: RemoteAdminWording.fastForwardFailure(error, branch: name, upstream: upstream))
            }
        }
    }

    // MARK: - Upstream

    func requestSetUpstream(_ name: String) {
        if let reason = upstreamBlockedReason {
            showStickyError(reason)
            return
        }
        guard let branch = localBranch(name) else {
            showStickyError(RemoteAdminWording.noSuchBranch(name))
            return
        }
        activeSheet = .upstream(branch: name, current: branch.upstream)
    }

    /// Makes `branch` track `ref` (a full name: `refs/remotes/<r>/<b>` or `refs/heads/<x>`, R17),
    /// as the answer to its sheet. GitCore reads what git wrote back; anything other than what
    /// was asked is a banner (carried note 7), and so is a half-written or unknown write.
    func confirmSetUpstream(_ branch: String, to ref: String) {
        guard case .upstream(let shown, _) = activeSheet, shown == branch else { return }
        guard !isMutating else {
            showStickyError(RemoteWording.mutationBusy)
            return
        }
        activeSheet = nil
        mutate(result: { backend, root in
            do {
                return try await backend.setUpstream(of: branch, to: ref, at: root)
            } catch {
                throw RemoteBannerText(RemoteAdminWording.upstreamFailure(error, branch: branch, ref: ref))
            }
        }, onSuccess: { [self] result in
            showNotice(RemoteAdminWording.upstreamSet(branch, to: ref, result: result))
        })
    }

    /// `branch --unset-upstream`: `branch.<b>.rebase` and `.pushRemote` stay (R17).
    func unsetUpstream(_ name: String) {
        if let reason = unsetUpstreamBlockedReason(name) {
            showStickyError(reason)
            return
        }
        let was = localBranch(name)?.upstream
        mutate({ backend, root in
            do {
                try await backend.unsetUpstream(of: name, at: root)
            } catch {
                throw RemoteBannerText(RemoteAdminWording.upstreamFailure(error, branch: name, ref: ""))
            }
        }, onSuccess: { [self] in
            showNotice(RemoteAdminWording.upstreamUnset(name, was: was))
        })
    }
}
