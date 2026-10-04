import Foundation
import GitCore

/// Every sentence B2's housekeeping puts on screen — prune, clean-up of gone branches, another
/// branch's push and fast-forward, upstream — and every decision about whether one of those
/// menu items is available, as pure functions over plain values (tested in
/// `RemoteAdminWordingTests` and `RemoteAdminMenuTests`).
///
/// `RemoteWording`'s two rules hold here too: text that came from git or a server goes through
/// `RemoteWording.plain`, and **a cancelled or failed write never says "nothing changed"** —
/// GitCore reports those as `RemoteAdminPartial`, `PruneResult.outcomeUnknown` / `.notTried`,
/// and each gets words of its own (carried note 6).
enum RemoteAdminWording {

    // MARK: - Menu titles

    static func pruneTitle(_ remote: String) -> String { "Prune \"\(remote)\"…" }
    static let cleanUpTitle = "Clean Up Gone Branches…"
    static func fastForwardTitle(_ branch: String) -> String { "Fast-Forward \"\(branch)\"" }
    static let unsetUpstreamTitle = "Unset Upstream"

    static func upstreamTitle(_ branch: Branch) -> String {
        branch.upstream == nil ? "Set Upstream…" : "Change Upstream…"
    }

    /// Push, Publish… or Re-publish, decided as the toolbar decides it (`RemoteWording.pushKind`,
    /// on `PushTarget.resolve`). Publish has an ellipsis: from a menu it always opens the sheet
    /// that names the remote.
    static func pushBranchTitle(_ branch: Branch, remotes: [Remote]) -> String {
        switch RemoteWording.pushKind(branch: branch, remotes: remotes) {
        case .push: "Push \"\(branch.name)\""
        case .publish: "Publish \"\(branch.name)\"…"
        case .republish: "Re-publish \"\(branch.name)\""
        }
    }

    // MARK: - Why an item is off

    /// Push or Publish of `branch` from its own menu. The branch HEAD is on keeps the toolbar's
    /// reasons (`RemoteWording.pushBlocked`); any other branch is pushed by name and HEAD is not
    /// touched, so neither an operation in progress nor a detached HEAD stops it — only the
    /// lane, the mutation slot and where `PushTarget.resolve` says it goes.
    static func pushBranchBlocked(_ branch: Branch, gate: RemoteWording.Gate) -> String? {
        if branch.name == gate.branch?.name { return RemoteWording.pushBlocked(gate) }
        guard gate.hasRepository else { return RemoteWording.noRepository }
        if let activity = gate.activity { return RemoteWording.laneBusy(activity) }
        if gate.isMutating { return RemoteWording.mutationBusy }
        switch PushTarget.resolve(branch, remotes: gate.remotes) {
        case .push: return nil
        case .unpublished:
            if gate.remotes.isEmpty { return RemoteWording.noRemotes }
            return gate.remotes.contains(where: \.canPush) ? nil : RemoteWording.noRemoteToPushTo
        case .refused(let refusal): return RemoteWording.refused(refusal, branch: branch.name)
        }
    }

    /// Fast-Forward `branch`: off for the branch HEAD is on (it keeps Pull), and whenever the
    /// tracking already on screen says nothing could move — no upstream, a gone one, commits of
    /// its own. Behind or level is on: the fetch first may bring more. GitCore decides again
    /// after that fetch, and refuses a branch another worktree uses (R15).
    static func fastForwardBlocked(_ branch: Branch, gate: RemoteWording.Gate) -> String? {
        guard gate.hasRepository else { return RemoteWording.noRepository }
        if branch.name == gate.branch?.name { return fastForwardCurrent(branch.name) }
        if let activity = gate.activity { return RemoteWording.laneBusy(activity) }
        if gate.isMutating { return RemoteWording.mutationBusy }
        guard let upstream = branch.upstream else { return fastForwardNoUpstream(branch.name) }
        if let remote = branch.upstreamRemote,
            let reason = RemoteWording.fetchURLBlocked(gate.remotes.first { $0.name == remote })
        {
            return reason
        }
        switch branch.tracking {
        case .gone: return fastForwardUpstreamGone(branch.name, upstream: upstream)
        case .counts(let ahead, let behind) where ahead > 0:
            return behind > 0
                ? fastForwardDiverged(branch.name, upstream: upstream, ahead: ahead, behind: behind)
                : fastForwardAhead(branch.name, upstream: upstream, ahead: ahead)
        case .counts, .none: return nil
        }
    }

    static func fastForwardCurrent(_ branch: String) -> String {
        "\"\(branch)\" is the branch you are on: Pull brings it up to date."
    }

    static func fastForwardNoUpstream(_ branch: String) -> String {
        "\"\(branch)\" has no upstream to fast-forward to."
    }

    static func fastForwardUpstreamGone(_ branch: String, upstream: String) -> String {
        "\"\(upstream)\", the upstream of \"\(branch)\", no longer exists."
    }

    static func fastForwardAhead(_ branch: String, upstream: String, ahead: Int) -> String {
        "\"\(branch)\" has \(commits(ahead)) \"\(upstream)\" doesn't, so it can't be fast-forwarded."
    }

    static func fastForwardDiverged(_ branch: String, upstream: String, ahead: Int, behind: Int) -> String {
        "\"\(branch)\" and \"\(upstream)\" have both moved on (\(RemoteWording.pullCounts(ahead: ahead, behind: behind))), "
            + "so only a merge or a rebase could combine them."
    }

    /// Unset Upstream: only a branch with one. A config write, through `mutate`.
    static func unsetUpstreamBlocked(_ branch: Branch, gate: RemoteWording.Gate) -> String? {
        if let reason = upstreamBlocked(gate) { return reason }
        return branch.upstream == nil ? noUpstreamToUnset(branch.name) : nil
    }

    static func noUpstreamToUnset(_ branch: String) -> String { "\"\(branch)\" has no upstream." }

    /// Set / Change Upstream…: a config write, through `mutate`, which would drop the answer
    /// silently while another change runs.
    static func upstreamBlocked(_ gate: RemoteWording.Gate) -> String? {
        guard gate.hasRepository else { return RemoteWording.noRepository }
        return gate.isMutating ? RemoteWording.mutationBusy : nil
    }

    /// Prune <remote>…: its list is a dry-run fetch on the lane, so a remote with no fetch URL is
    /// off (Task 3's `fetchURLBlocked`, carried note 4), and so is a busy lane. The sheet's own
    /// button waits for a running change.
    static func pruneBlocked(_ remote: Remote?, gate: RemoteWording.Gate) -> String? {
        guard gate.hasRepository else { return RemoteWording.noRepository }
        if let activity = gate.activity { return RemoteWording.laneBusy(activity) }
        return RemoteWording.fetchURLBlocked(remote)
    }

    /// The remotes the Remotes menu offers a prune for: the ones with a fetch URL, in order.
    static func prunableRemotes(_ remotes: [Remote]) -> [String] {
        remotes.filter(\.canFetch).map(\.name)
    }

    /// Why the Remotes menu's Prune is off as a whole.
    static func pruneMenuBlocked(_ gate: RemoteWording.Gate) -> String? {
        guard gate.hasRepository else { return RemoteWording.noRepository }
        if let activity = gate.activity { return RemoteWording.laneBusy(activity) }
        if gate.remotes.isEmpty { return RemoteWording.noRemotes }
        return prunableRemotes(gate.remotes).isEmpty ? RemoteWording.noRemoteToFetchFrom : nil
    }

    /// Clean Up Gone Branches…: reads, then deletes through `mutate`.
    static func cleanUpBlocked(_ gate: RemoteWording.Gate) -> String? {
        upstreamBlocked(gate)
    }

    // MARK: - The prune sheet

    static func pruneSheetTitle(_ remote: String) -> String { "Prune \"\(remote)\"" }

    static func pruneSheetIntro(_ plan: PrunePlan) -> String {
        let remote = "\"\(plan.remote)\""
        if plan.refs.count == 1 {
            return "This remote-tracking branch is no longer on \(remote). Pruning deletes it here; "
                + "nothing on the server changes."
        }
        return "These \(plan.refs.count) remote-tracking branches are no longer on \(remote). Pruning "
            + "deletes them here; nothing on the server changes."
    }

    static func nothingToPrune(_ remote: String) -> String {
        "Nothing to prune: every remote-tracking branch of \"\(remote)\" is still on the server."
    }

    /// `refs/remotes/origin/x` → `origin/x`, as the sidebar names it.
    static func shortRef(_ ref: String) -> String {
        ref.hasPrefix("refs/remotes/") ? String(ref.dropFirst("refs/remotes/".count)) : ref
    }

    /// The union count (R5), worded as exactly what was counted — never "unreachable": a reflog
    /// can still reach them.
    static func stranded(_ stranded: StrandedCommits) -> String {
        switch stranded.count {
        case 0: "Every commit on them is also on a branch, tag or another remote."
        case 1: "1 commit would be on no branch, tag or other remote Gitter can see:"
        default: "\(stranded.count) commits would be on no branch, tag or other remote Gitter can see:"
        }
    }

    /// How many of them the list leaves out (it shows `StrandedCommits.displayLimit`).
    static func strandedMore(_ stranded: StrandedCommits) -> String? {
        let more = stranded.count - stranded.commits.count
        return more > 0 ? RemoteWording.andMore(more) : nil
    }

    static let keepNameEmpty = "Enter a branch name."

    static let keepHeading = "Keep a local branch at each of these, so their commits stay on a branch:"
    static func keepLabel(_ ref: String) -> String { "Keep \"\(shortRef(ref))\" as" }

    /// Carried note 1: pruning `<remote>/HEAD`'s target leaves it dangling and a later fetch
    /// does **not** repair it (measured in Task 1), so this never says that it does.
    static func danglingHEAD(remote: String, target: String) -> String {
        "\"\(remote)/HEAD\" points at \"\(shortRef(target))\", which this prunes: it will point at "
            + "nothing, and a fetch does not repair it."
    }

    static func prunesHEADTarget(target: String?, refs: [RefTip]) -> Bool {
        guard let target else { return false }
        return refs.contains { $0.ref == target }
    }

    /// The keep field's live verdict (`keepBranchNameProblem`, and two ticked names alike).
    static func keepNameProblem(_ refusal: RemoteAdminRefusal?, duplicate: Bool) -> String? {
        if duplicate { return "Another kept branch has this name." }
        switch refusal {
        case nil: return nil
        case .branchExists(let name): return "A branch, tag or remote named \"\(name)\" already exists."
        default: return "That is not a valid branch name."
        }
    }

    /// Refs of the plan whose tip on screen is no longer the one the list read: the prune leaves
    /// them alone (the compare-and-delete), and the sheet says so before the click.
    static func pruneSheetStale(changed: Int) -> String {
        changed == 1
            ? "1 of these changed since the list was read; the prune will leave it alone."
            : "\(changed) of these changed since the list was read; the prune will leave them alone."
    }

    static let pruneButton = "Prune"

    // MARK: - Keep boxes (carried note 2, Ruling 1)

    /// The holders ticked by default: every holder whose commits no other holder already keeps.
    /// `contains(outer, inner)` is true when `outer` reaches `inner`'s tip — then everything only
    /// `inner` holds, `outer` holds too. Of two holders at one commit the first is kept. In
    /// holder order.
    static func defaultKeeps(_ holders: [RefTip], contains: (RefTip, RefTip) -> Bool) -> [String] {
        holders.enumerated().compactMap { index, inner in
            let covered = holders.enumerated().contains { other, outer in
                guard other != index, contains(outer, inner) else { return false }
                // Mutual containment is one commit: the earlier of the two stays.
                return !contains(inner, outer) || other < index
            }
            return covered ? nil : inner.ref
        }
    }

    // Keep All / Keep None (Ruling 12): in a squash-merge repository every pruned ref is a
    // holder, all ticked by default (promise 2), and unticking twenty-four boxes one by one is not
    // a choice anybody can make.

    static let keepAllTitle = "Keep All"
    static let keepNoneTitle = "Keep None"

    /// Every box in `refs` ticked (`all`) or unticked.
    static func ticking(_ refs: [String], all: Bool) -> [String: Bool] {
        Dictionary(uniqueKeysWithValues: refs.map { ($0, all) })
    }

    /// Whether Keep All and Keep None would change anything: Keep All while a box is unticked,
    /// Keep None while one is ticked.
    static func keepAllOffers(_ refs: [String], ticked: [String: Bool]) -> (all: Bool, none: Bool) {
        (refs.contains { ticked[$0] != true }, refs.contains { ticked[$0] == true })
    }

    /// The line under the keep list while a ticked name has a problem (each row shows its own).
    static func keepProblemsSummary(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "One name to keep needs changing; it is marked in the list."
        default: "\(count) names to keep need changing; they are marked in the list."
        }
    }

    /// "Keeping 3 of 24." — beside the two buttons, so the count is seen while the list scrolls.
    static func keepCount(_ refs: [String], ticked: [String: Bool]) -> String {
        let count = refs.filter { ticked[$0] == true }.count
        return count == 0
            ? "Keeping none of \(refs.count): their commits will be on no branch."
            : "Keeping \(count) of \(refs.count)."
    }

    /// The pruned branch's own name — what follows `refs/remotes/<remote>/`, or `refs/remotes/`
    /// for a ref a custom refspec put elsewhere — or `<name>-kept` (then `-kept-2`, …) when a
    /// branch, tag or remote has it, compared ignoring case as the file system does (Ruling 1).
    static func suggestedKeepName(for ref: String, remote: String, taken: Set<String>) -> String {
        let own = "refs/remotes/" + remote + "/"
        let base = ref.hasPrefix(own) ? String(ref.dropFirst(own.count)) : shortRef(ref)
        let lowered = Set(taken.map { $0.lowercased() })
        if !lowered.contains(base.lowercased()) { return base }
        var candidate = base + "-kept"
        var n = 2
        while lowered.contains(candidate.lowercased()) {
            candidate = "\(base)-kept-\(n)"
            n += 1
        }
        return candidate
    }

    // MARK: - The prune's notice (sticky: the only record, promise 3)

    /// Every deleted ref with the id it held, the kept branches, and — each in its own words —
    /// the refs left alone, refused, of unknown outcome and not tried.
    static func pruned(_ result: PruneResult, remote: String, headTarget: String?) -> String {
        var lines: [String] = []
        let count = result.deleted.count
        if count > 0 {
            lines.append(
                (count == 1
                    ? "Pruned 1 remote-tracking branch of \"\(remote)\". This is the only record of what it held:"
                    : "Pruned \(count) remote-tracking branches of \"\(remote)\". This is the only record of what they held:"))
            lines += result.deleted.map { "\(shortRef($0.ref)) \($0.id)" }
        } else {
            lines.append("Nothing was pruned from \"\(remote)\".")
        }
        if !result.keptBranches.isEmpty {
            let names = result.keptBranches.map { "\"\($0)\"" }.joined(separator: ", ")
            lines.append((result.keptBranches.count == 1 ? "Kept as a local branch: " : "Kept as local branches: ") + names + ".")
        }
        for tip in result.skippedMoved {
            lines.append("Left alone, because it changed since the list was read: \(shortRef(tip.ref)) (was \(tip.id)).")
        }
        for failure in result.failed {
            lines.append(
                "git refused to delete \(shortRef(failure.tip.ref)) (\(failure.tip.id)): "
                    + RemoteWording.plainJoined(failure.gitsWords.split(whereSeparator: \.isNewline).map(String.init)))
        }
        for tip in result.outcomeUnknown {
            lines.append(
                "Stopped while deleting \(shortRef(tip.ref)) (\(tip.id)): whether it is gone is not known. Refresh to see.")
        }
        if !result.notTried.isEmpty {
            lines.append(
                "Not tried, because the prune was stopped: "
                    + result.notTried.map { shortRef($0.ref) }.joined(separator: ", ") + ".")
        }
        if let headTarget, result.deleted.contains(where: { $0.ref == headTarget }) {
            lines.append(
                "\"\(remote)/HEAD\" now points at nothing (it pointed at \"\(shortRef(headTarget))\"); a fetch "
                    + "does not repair it.")
        }
        if count > 0 {
            lines.append("Bring one back with: git update-ref refs/remotes/\(remote)/<branch> <id>")
        }
        return lines.joined(separator: "\n")
    }

    /// Whether a prune's notice says something went wrong — what a held quit must not carry
    /// away unread (`LaneEnding.mustBeRead`).
    static func prunedNeedsReading(_ result: PruneResult) -> Bool {
        !result.skippedMoved.isEmpty || !result.failed.isEmpty || !result.outcomeUnknown.isEmpty
            || !result.notTried.isEmpty
    }

    /// `prune` threw: every case is before any delete (GitCore's order), so each says nothing
    /// was pruned — except a cancellation, which may have come while a kept branch was being
    /// created.
    static func pruneFailure(_ error: Error, remote: String) -> String {
        switch error {
        case RemoteAdminRefusal.strandedGrew:
            return "More commits would be left on no branch, tag or remote than the sheet said — something changed "
                + "while it was open. Nothing was pruned. Prune again to see what would go now."
        case RemoteAdminRefusal.branchExists(let name):
            return "Couldn't keep \"\(name)\": a branch, tag or remote has that name now. Nothing was pruned."
        case RemoteAdminRefusal.invalidBranchName(let name):
            return "Couldn't keep \"\(name)\": that is not a valid branch name. Nothing was pruned."
        case RemoteAdminRefusal.invalidObjectID:
            return "The list held an id that is not a full commit id, so nothing was pruned. Prune again."
        case RemoteAdminPartial.keptBranchesThenStopped(let kept, let failedName, let words):
            let names = kept.map { "\"\($0)\"" }.joined(separator: ", ")
            let made = kept.count == 1 ? "the kept branch \(names)" : "the kept branches \(names)"
            return "Created \(made), then couldn't create \"\(failedName)\": \(RemoteWording.plain(words)). "
                + "Nothing was pruned; \(names) \(kept.count == 1 ? "stays" : "stay")."
        case RemoteAdminPartial.keptBranchesCancelled(let kept, let unknown):
            // Ruling 12 (m7): git was stopped while it created this branch — it may exist.
            let base = "Stopped while creating the kept branch \"\(unknown)\": it may or may not have been "
                + "created — check the branch list. Nothing was pruned"
            guard !kept.isEmpty else { return base + "." }
            let names = kept.map { "\"\($0)\"" }.joined(separator: ", ")
            return base + "; \(names) \(kept.count == 1 ? "was" : "were") created before it and stay\(kept.count == 1 ? "s" : "")."
        case _ where error is CancellationError:
            // GitCore turns a cancellation during the kept branches' creation into the case above.
            return "Stopped the prune before anything was created or deleted."
        default:
            return RemoteWording.failure(error, attempt: "prune \"\(remote)\"", isWrite: false)
                + " Nothing was pruned."
        }
    }

    /// The listing (a dry-run fetch) threw.
    static func pruneListFailure(_ error: Error, remote: String) -> String {
        switch error {
        case RemoteAdminRefusal.noSuchRemote, RemoteOperationError.noSuchRemote:
            return remoteGone(remote)
        case RemoteAdminRefusal.unsafeRefspec(let refspec):
            return "Gitter won't prune \"\(RemoteWording.plain(remote))\": its fetch refspec "
                + "\(RemoteWording.plain(refspec)) writes outside refs/remotes/, so its list would name your own "
                + "branches."
        default:
            return RemoteWording.failure(error, attempt: "list what \"\(remote)\" no longer has", isWrite: false)
        }
    }

    static let pruneListStopped = "Stopped before the prune list was ready. Nothing was pruned."

    /// Ruling 11: a remote that was configured when the menu was drawn and is not any more.
    static func remoteGone(_ remote: String) -> String {
        "\"\(RemoteWording.plain(remote))\" is no longer a configured remote — it was removed or renamed since "
            + "the last refresh. Nothing was run."
    }

    // MARK: - Clean Up Gone Branches

    static let cleanUpSheetTitle = "Clean Up Gone Branches"
    static func cleanUpIntro(_ count: Int) -> String {
        (count == 1 ? "This branch tracks an upstream" : "These \(count) branches track an upstream")
            + " that no longer exists. The ticked ones will be deleted here; their tips are named afterwards."
    }
    static let nothingGone = "No branch tracks an upstream that is gone."

    /// "tracked origin/x · merged" or "· N commits only here".
    static func goneRowDetail(_ gone: GoneBranch) -> String {
        let state = gone.uniqueCommits == 0 ? "merged" : "\(commits(gone.uniqueCommits)) only here"
        return "tracked \(shortUpstream(gone.upstream)) · \(state)"
    }

    /// Ticked when nothing is lost and git would delete it: merged, and checked out nowhere.
    static func defaultTicked(_ gone: GoneBranch) -> Bool {
        gone.uniqueCommits == 0 && gone.checkedOutAt == nil
    }

    static func checkedOut(_ gone: GoneBranch) -> String? {
        gone.checkedOutAt.map { "Checked out at \(RemoteWording.plain($0)), so git won't delete it." }
    }

    /// A1's unmerged warning (`DeleteBranchSheet`), for a ticked "N only here" row.
    static func unmergedWarning(_ gone: GoneBranch) -> String? {
        switch gone.uniqueCommits {
        case 0: nil
        case 1:
            "1 commit exists only on \"\(gone.name)\". Deleting it leaves that commit on no branch, tag or remote: "
                + "only the reflog would still reach it."
        default:
            "\(gone.uniqueCommits) commits exist only on \"\(gone.name)\". Deleting it leaves those commits on no "
                + "branch, tag or remote: only the reflog would still reach them."
        }
    }

    static func cleanUpButton(_ count: Int) -> String {
        count == 1 ? "Delete 1 Branch" : "Delete \(count) Branches"
    }

    /// What a clean-up did, branch by branch: every deleted branch with its tip (its reflog went
    /// with it), the ones whose settings git left behind (a held `config.lock`, Ruling 2), and
    /// every one not deleted with why.
    static func cleanedUp(_ report: CleanUpReport) -> String {
        var lines: [String] = []
        switch report.deleted.count {
        case 0: lines.append("No branch was deleted.")
        case 1: lines.append("Deleted 1 branch whose upstream was gone:")
        default: lines.append("Deleted \(report.deleted.count) branches whose upstream was gone:")
        }
        lines += report.deleted.map { "\($0.name) \($0.tip)" }
        for deleted in report.deleted {
            guard let left = deleted.settingsLeft else {
                lines.append(
                    "\"\(deleted.name)\" was deleted, but Gitter couldn't read back whether its settings "
                        + "(branch.\(deleted.name).*) were left behind. Check with: git config --get-regexp "
                        + "'^branch\\.\(deleted.name)\\.'")
                continue
            }
            guard !left.isEmpty else { continue }
            lines.append(
                "\"\(deleted.name)\" was deleted, but its settings were left behind "
                    + "(\(left.joined(separator: ", "))): another git process held the configuration. "
                    + "A new branch named \"\(deleted.name)\" would inherit them. Remove them with: "
                    + "git config --remove-section branch.\(deleted.name)")
        }
        if !report.notDeleted.isEmpty {
            lines.append("Not deleted:")
            for item in report.notDeleted {
                switch item.reason {
                case .moved(let now):
                    lines.append("\"\(item.name)\" changed since the list was read (it is at \(now.prefix(7))).")
                case .moreWouldGo(let was, let now):
                    lines.append("\"\(item.name)\" now has \(commits(now)) only on it — the list said \(was).")
                case .alreadyGone:
                    lines.append("\"\(item.name)\" is already gone.")
                case .checkedOut:
                    lines.append("\"\(item.name)\" is checked out in a worktree, so git won't delete it.")
                case .failed(let words):
                    lines.append("\"\(item.name)\": \(RemoteWording.plain(words))")
                }
            }
        }
        if !report.deleted.isEmpty { lines.append("Recreate one with: git branch <name> <id>") }
        return lines.joined(separator: "\n")
    }

    static func cleanUpListFailure(_ error: Error) -> String {
        RemoteWording.failure(error, attempt: "list the branches whose upstream is gone", isWrite: false)
    }

    // MARK: - Another branch's push

    /// A push of a branch that is not checked out, refused for commits it lacks: neither Pull
    /// nor Force Push is for it (both act on the branch HEAD is on), so the sentence points at
    /// Fast-Forward. Every other rejection reads as the toolbar's.
    static func pushRejected(
        _ outcome: PushOutcome, branch: String, remote: String, remoteMessages: [String]
    ) -> String? {
        guard case .rejected(let rejection) = outcome else { return nil }
        guard rejection == .fetchFirst || rejection == .nonFastForward else {
            return RemoteWording.rejected(outcome, branch: branch, remote: remote, remoteMessages: remoteMessages)
        }
        let base = "\"\(remote)\" has commits on \"\(branch)\" that this repository doesn't, so the push was refused "
            + "and nothing was pushed. Fast-forward \"\(branch)\" if it has no commits of its own; otherwise check "
            + "it out and pull."
        let server = RemoteWording.serverLines(remoteMessages)
        return server.isEmpty ? base : base + "\n" + server.joined(separator: "\n")
    }

    // MARK: - Fast-forward

    /// The destination is the outcome's own (`.fastForwarded(to:)`, carried note 3), never a
    /// re-read or the upstream's tip.
    static func fastForwarded(_ outcome: FastForwardOutcome, branch: String, upstream: String) -> String {
        switch outcome {
        case .fastForwarded(let from, let to):
            "Fast-forwarded \"\(branch)\" to \"\(upstream)\" (\(from.prefix(7))..\(to.prefix(7)))."
        case .upToDate:
            "\"\(branch)\" is already up to date with \"\(upstream)\"."
        }
    }

    static func fastForwardFailure(_ error: Error, branch: String, upstream: String) -> String {
        switch error {
        case FastForwardRefusal.checkedOut(let path):
            return "\"\(branch)\" is in use by the worktree at \(RemoteWording.plain(path)) — checked out, or being "
                + "rebased or bisected there — so it was not moved."
        case FastForwardRefusal.noUpstream:
            return "\"\(branch)\" has no upstream Gitter can fast-forward it to. Nothing was moved."
        case FastForwardRefusal.ahead(let ahead):
            return "\"\(branch)\" has \(commits(ahead)) \"\(upstream)\" doesn't and nothing new from it, so there is "
                + "nothing to fast-forward. Nothing was moved."
        case FastForwardRefusal.diverged(let ahead, let behind):
            return "\"\(branch)\" and \"\(upstream)\" have both moved on "
                + "(\(RemoteWording.pullCounts(ahead: ahead, behind: behind))), so only a merge or a rebase could "
                + "combine them. Check out \"\(branch)\" and pull. Nothing was moved."
        case FastForwardRefusal.moved:
            return "\"\(branch)\" changed since you chose Fast-Forward, so it was left where it is now. Try again."
        case RemoteAdminPartial.fastForwardOutcomeUnknown(_, let from, let to):
            return "Stopped while moving \"\(branch)\": it is at \(from.prefix(7)) or at \(to.prefix(7)), and which is "
                + "not known. Refresh to see."
        default:
            return RemoteWording.failure(error, attempt: "fast-forward \"\(branch)\"", isWrite: false)
        }
    }

    /// Stop pressed during the fetch that comes first: nothing was moved.
    static func fastForwardStopped(_ branch: String) -> String {
        "Stopped before \"\(branch)\" was fast-forwarded. Nothing was moved."
    }

    // MARK: - Upstream

    static func upstreamSheetTitle(_ branch: String, current: String?) -> String {
        (current == nil ? "Set Upstream of " : "Change Upstream of ") + "\"\(branch)\""
    }

    static func upstreamNow(_ current: String?) -> String {
        current.map { "It tracks \"\($0)\" now." } ?? "It has no upstream now."
    }

    static let upstreamExplanation =
        "Its tracking badge, Pull and Fast-Forward compare it with the upstream."
    static let upstreamButton = "Set Upstream"
    static let upstreamLocalGroup = "Local branches"
    static let noUpstreamCandidates = "There is no fetched remote branch or other local branch to track."

    /// `refs/remotes/origin/x` → `origin/x`, `refs/heads/base` → `base`.
    static func shortUpstream(_ ref: String) -> String {
        if ref.hasPrefix("refs/heads/") { return String(ref.dropFirst("refs/heads/".count)) }
        return shortRef(ref)
    }

    /// What git wrote, read back: the upstream, and the `rebase=true` `branch.autoSetupRebase`
    /// adds (R17).
    static func upstreamSet(_ branch: String, to ref: String, result: SetUpstreamResult) -> String {
        let base = "\"\(branch)\" now tracks \"\(shortUpstream(ref))\"."
        guard result.wroteRebase else { return base }
        return base + " git also set branch.\(branch).rebase=true (branch.autoSetupRebase), so pulling it rebases."
    }

    static func upstreamUnset(_ branch: String, was: String?) -> String {
        guard let was else { return "\"\(branch)\" no longer has an upstream." }
        return "\"\(branch)\" no longer has an upstream (it tracked \"\(was)\")."
    }

    /// Carried note 7: every refusal, the write git made that is not the one asked for, the
    /// half-written and the unknown.
    static func upstreamFailure(_ error: Error, branch: String, ref: String) -> String {
        switch error {
        case UpstreamRefusal.notFetched(let ref):
            return "\"\(shortUpstream(ref))\" doesn't exist here — not fetched yet, or pruned. Nothing was changed."
        case UpstreamRefusal.notABranch(let ref):
            return "\"\(shortUpstream(ref))\" is not a branch any remote fetches into, so git won't track it. "
                + "Nothing was changed."
        case UpstreamRefusal.ambiguousNamespace(let ref):
            return "Two remotes fetch into \"\(shortUpstream(ref))\", so git can't tell which remote \"\(branch)\" "
                + "would track. Nothing was changed."
        case UpstreamRefusal.ownUpstream:
            return "A branch can't track itself. Nothing was changed."
        case UpstreamRefusal.mergeMismatch(let expected, let written):
            return "git set the upstream of \"\(branch)\", but to \(RemoteWording.plain(written)) on the server, not "
                + "\(RemoteWording.plain(expected)): overlapping fetch refspecs mapped it to another branch. Change the "
                + "upstream again, or fix the refspecs in a terminal."
        case RemoteAdminPartial.upstreamChangedThenFailed(_, let remote, let merge, let words):
            let remoteNow = remote.map { "branch.\(branch).remote = \(RemoteWording.plain($0))" }
                ?? "no branch.\(branch).remote"
            let mergeNow = merge.map { "branch.\(branch).merge = \(RemoteWording.plain($0))" }
                ?? "no branch.\(branch).merge"
            return "Changing the upstream of \"\(branch)\" failed part-way: \(RemoteWording.plain(words)). Its "
                + "configuration now has \(remoteNow) and \(mergeNow). Set or unset the upstream again."
        case RemoteAdminPartial.upstreamOutcomeUnknown:
            return "Stopped while writing the upstream of \"\(branch)\": what its configuration holds now is not "
                + "known. Refresh to see."
        case BranchOperationError.noSuchBranch(let name):
            return "There is no branch named \"\(name)\" any more. Nothing was changed."
        default:
            return RemoteWording.failure(error, attempt: "change the upstream of \"\(branch)\"", isWrite: false)
        }
    }

    // MARK: - Helpers

    /// A branch named in a menu that the snapshot no longer has.
    static func noSuchBranch(_ branch: String) -> String {
        "There is no branch named \"\(branch)\" any more."
    }

    static let cleanUpSheetChanged =
        "Some of these changed since the list was read; the clean-up will leave them alone."
    static let upstreamSheetBranchGone = "This branch no longer exists. Nothing will be changed."

    private static func commits(_ count: Int) -> String {
        count == 1 ? "1 commit" : "\(count) commits"
    }
}

/// What Clean Up Gone Branches did, branch by branch (`RepositoryStore.confirmCleanUp`), for
/// `RemoteAdminWording.cleanedUp`.
struct CleanUpReport: Equatable {
    /// A branch git deleted, with the tip it had — the only record once its reflog is gone — and
    /// the `branch.<name>.*` keys git left behind (a held `config.lock`, Ruling 2); nil when they
    /// could not be read back, which is said, never taken for "none".
    struct Deleted: Equatable {
        let name: String
        let tip: String
        let settingsLeft: [String]?
    }

    enum Reason: Equatable {
        /// Its tip is no longer the one the list showed (`branchMoved`): left alone.
        case moved(now: String)
        /// More commits would go with it than the list said: left alone.
        case moreWouldGo(was: Int, now: Int)
        /// Not there any more.
        case alreadyGone
        /// Checked out here or in another worktree: git refuses (R10).
        case checkedOut
        /// git refused, in its own words (a worktree holds it, a lock).
        case failed(String)
    }

    struct NotDeleted: Equatable {
        let name: String
        let reason: Reason
    }

    var deleted: [Deleted]
    var notDeleted: [NotDeleted] = []

    /// Anything the user has to read beyond "deleted": a branch not deleted, or settings left.
    var hasProblems: Bool {
        !notDeleted.isEmpty || deleted.contains { $0.settingsLeft != [] }
    }
}
