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
///
/// Task 5 adds a remote's management — Add Remote…, Edit URL…, Rename…, Remove…:
///
/// | action | runs | holds |
/// |---|---|---|
/// | add (then, if asked, Gitter's fetch of it on the lane), the URLs' read and write | `mutate` | the mutation slot |
/// | the removal's impact (read as the sheet opens) | `mutate` | the mutation slot |
/// | rename, remove | on the lane (`.renameRemote`, `.removeRemote`): never beside a fetch, whose ref lock leaves either half-done (R21, R23) | the lane and the mutation slot |
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

    /// Off for a branch another worktree holds as well (B3, R14): git refuses to move it, and
    /// GitCore's own check would refuse after the fetch.
    func fastForwardBlockedReason(_ name: String) -> String? {
        guard let branch = localBranch(name) else { return RemoteAdminWording.noSuchBranch(name) }
        if branch.name != currentBranch, let reason = worktreeHeldReason(name) { return reason }
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

    /// The keep fields' live check for one `keeping` (ref → name): GitCore's
    /// `keepBranchNameProblem` for each name, and two ticked names alike (compared ignoring case).
    /// Ref → problem; refs whose name is fine are absent.
    func keepNameProblems(_ keeping: [String: String]) async -> [String: String] {
        var found: [String: String] = [:]
        for (ref, name) in keeping {
            let duplicate = keeping.contains { $0.key != ref && $0.value.lowercased() == name.lowercased() }
            if let problem = await keepNameProblem(name, duplicate: duplicate) { found[ref] = problem }
        }
        return found
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
                show(Notice(text: text, keep: true))
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
                        failure: RemoteAdminWording.fastForwardFetchFailure(error, remote: remote, branch: name))
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

    // MARK: - Remote management (B2 Task 5): menu reasons

    /// A configured remote by name, as the snapshot on screen has it — one with no URL included.
    func configuredRemote(_ name: String) -> Remote? {
        snapshot?.refs.remotes.first { $0.name == name }
    }

    var addRemoteBlockedReason: String? { RemoteAdminWording.addRemoteBlocked(remoteGate) }
    var editURLBlockedReason: String? { RemoteAdminWording.editURLBlocked(remoteGate) }
    var renameRemoteBlockedReason: String? { RemoteAdminWording.renameRemoteBlocked(remoteGate) }
    var removeRemoteBlockedReason: String? { RemoteAdminWording.removeRemoteBlocked(remoteGate) }

    /// What is wrong with `name` as a new remote's name, or nil — GitCore's `remoteNameProblem`
    /// (git's rule, a leading `-`, `HEAD`, `@`, taken or nested, case folded). Reads only, no
    /// slot, so the sheet's debounced field can ask it. A name nothing could judge (no
    /// repository, git failed) is `.invalid`: Add and Rename must not be enabled on a name nobody
    /// vouched for.
    func remoteNameProblem(_ name: String) async -> RemoteNameProblem? {
        let trimmed = BranchNameValidator.trim(name)
        guard !trimmed.isEmpty else { return .empty }
        guard let root else { return .invalid }
        do {
            return try await backend.remoteNameProblem(trimmed, at: root)
        } catch {
            return .invalid
        }
    }

    // MARK: - Add Remote

    func requestAddRemote() {
        if let reason = addRemoteBlockedReason {
            showStickyError(reason)
            return
        }
        activeSheet = .addRemote
    }

    /// Adds the remote the Add Remote sheet describes — only as the answer to that sheet.
    /// GitCore checks the name and the URL again and writes with `remote add`, never `-f` (R19);
    /// `fetchAfter` then starts Gitter's own fetch of it on the lane, once the slot's reload has
    /// put it in the snapshot. A failure that wrote part of it is worded with what is configured
    /// now (`urlsChangedThenFailed`).
    func confirmAddRemote(name: String, url: String, fetchAfter: Bool) {
        guard case .addRemote = activeSheet else { return }
        // `mutate` drops a call silently while the slot is held; the sheet stays up instead.
        guard !isMutating else {
            showStickyError(RemoteWording.mutationBusy)
            return
        }
        activeSheet = nil
        mutate({ backend, root in
            do {
                try await backend.addRemote(name, url: url, at: root)
            } catch {
                throw RemoteBannerText(RemoteAdminWording.addRemoteFailure(error, name: name))
            }
        }, onSuccess: { [self] in
            showNotice(RemoteAdminWording.remoteAdded(name, url: url))
            if fetchAfter { fetch(remote: name) }
        })
    }

    // MARK: - Edit URL

    /// Reads `remote`'s URLs as the configuration writes them (`remoteURLs`, promise 5) and opens
    /// the sheet with them. Ruling 11: a remote the snapshot no longer has is refused first.
    func requestEditURL(_ remote: String) {
        guard configuredRemote(remote) != nil else {
            showStickyError(RemoteAdminWording.remoteGone(remote))
            return
        }
        if let reason = editURLBlockedReason {
            showStickyError(reason)
            return
        }
        mutate(result: { backend, root in
            do {
                return try await backend.remoteURLs(remote, at: root)
            } catch {
                throw RemoteBannerText(
                    RemoteAdminWording.remoteReadFailure(
                        error, remote: remote, attempt: RemoteAdminWording.readURLsAttempt(remote)))
            }
        }, onSuccess: { [self] urls in
            // Never over a sheet the user opened meanwhile.
            guard activeSheet == nil else { return }
            activeSheet = .editRemoteURL(urls, remote: remote)
        })
    }

    /// Writes `fetch` and `push` (`PushURLChange`, tri-state) to `remote` — only as the answer to
    /// its Edit URL sheet, and only while the remote's URLs are still the ones the sheet showed
    /// (RF1, refused before git runs). GitCore refuses an unsafe URL and several URLs again, and
    /// reads a failed write back (`urlsChangedThenFailed`).
    func confirmEditURL(_ remote: String, fetch: String, push: PushURLChange) {
        guard case .editRemoteURL(let shown, let shownRemote) = activeSheet, shownRemote == remote else { return }
        guard !isMutating else {
            showStickyError(RemoteWording.mutationBusy)
            return
        }
        activeSheet = nil
        mutate({ backend, root in
            do {
                guard try await backend.remoteURLs(remote, at: root) == shown else {
                    throw RemoteBannerText(RemoteAdminWording.urlsChangedWhileShown(remote))
                }
                try await backend.setURLs(of: remote, fetch: fetch, push: push, at: root)
            } catch let banner as RemoteBannerText {
                throw banner
            } catch {
                throw RemoteBannerText(RemoteAdminWording.editURLFailure(error, remote: remote))
            }
        }, onSuccess: { [self] in
            showNotice(RemoteAdminWording.urlsChanged(remote, fetch: fetch, push: push))
        })
    }

    // MARK: - Rename

    func requestRenameRemote(_ remote: String) {
        guard configuredRemote(remote) != nil else {
            showStickyError(RemoteAdminWording.remoteGone(remote))
            return
        }
        if let reason = renameRemoteBlockedReason {
            showStickyError(reason)
            return
        }
        activeSheet = .renameRemote(remote)
    }

    /// Renames `old` to `new` — only as the answer to its sheet — on the lane, holding the slot:
    /// a fetch's ref lock leaves `git remote rename` half-done (R21). GitCore refuses a remote
    /// that is gone (Ruling 11) and a name with a problem, and reads a failure back
    /// (`renameHalfDone`); the banner says what git left and how to finish.
    func confirmRenameRemote(_ old: String, to new: String) {
        guard case .renameRemote(let shown) = activeSheet, shown == old else { return }
        // Before the sheet closes, so a refusal leaves it up to answer again.
        if let refusal = laneClaimRefusal(.renameRemote, holdingMutation: true) {
            showStickyError(refusal)
            return
        }
        activeSheet = nil
        runOnLane(.renameRemote, remote: old, holdingMutation: true) { backend, root, _, _ in
            do {
                try await backend.renameRemote(old, to: new, at: root)
            } catch {
                return LaneEnding(failure: RemoteAdminWording.renameRemoteFailure(error, old: old, new: new))
            }
            return LaneEnding(notice: RemoteAdminWording.remoteRenamed(old, to: new))
        }
    }

    // MARK: - Remove

    /// Reads what removing `remote` would delete, strand and change (`removalImpact`, local
    /// reads) and opens the sheet with it.
    func requestRemoveRemote(_ remote: String) {
        guard configuredRemote(remote) != nil else {
            showStickyError(RemoteAdminWording.remoteGone(remote))
            return
        }
        if let reason = removeRemoteBlockedReason {
            showStickyError(reason)
            return
        }
        mutate(result: { backend, root in
            do {
                return try await backend.removalImpact(of: remote, at: root)
            } catch {
                throw RemoteBannerText(
                    RemoteAdminWording.remoteReadFailure(
                        error, remote: remote, attempt: RemoteAdminWording.readImpactAttempt(remote)))
            }
        }, onSuccess: { [self] impact in
            guard activeSheet == nil else { return }
            activeSheet = .removeRemote(impact)
        })
    }

    /// Removes `impact.remote` — only as the answer to the sheet that showed `impact` — creating
    /// the branches in `keeping` (ref → new branch name) first, on the lane, holding the slot
    /// (R23). GitCore compares the whole impact again before anything is created or removed
    /// (`.impactChanged`), and reads a failure back (`removeHalfDone`).
    ///
    /// The notice is **sticky**: a removed remote-tracking ref has no reflog (R7), so the ids it
    /// names are the only way back, and it lists the kept branches (carried note 4).
    func confirmRemoveRemote(_ impact: RemovalImpact, keeping: [String: String]) {
        guard case .removeRemote(let shown) = activeSheet, shown == impact else { return }
        if let refusal = laneClaimRefusal(.removeRemote, holdingMutation: true) {
            showStickyError(refusal)
            return
        }
        activeSheet = nil
        let remote = impact.remote
        runOnLane(.removeRemote, remote: remote, holdingMutation: true) { backend, root, _, _ in
            do {
                try await backend.removeRemote(impact, keeping: keeping, at: root)
            } catch {
                return LaneEnding(
                    failure: RemoteAdminWording.removeRemoteFailure(error, remote: remote, refs: impact.refs))
            }
            let kept = impact.refs.compactMap { keeping[$0.ref] }
            return LaneEnding(
                notice: Notice(text: RemoteAdminWording.remoteRemoved(impact, keptBranches: kept)), sticky: true)
        }
    }

    /// The remove sheet's keep boxes: the prune sheet's rule (`pruneKeepDefaults`) over the refs
    /// the removal deletes.
    func removeKeepDefaults(_ impact: RemovalImpact) async -> (names: [String: String], ticked: Set<String>) {
        await pruneKeepDefaults(PrunePlan(remote: impact.remote, refs: impact.refs, stranded: impact.stranded))
    }
}
