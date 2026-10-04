import Foundation
import GitCore

/// Every sentence B2's housekeeping puts on screen — prune, clean-up of gone branches, another
/// branch's push and fast-forward, upstream, and (Task 5) a remote's Add, Edit URL, Rename and
/// Remove with the URLs they show — and every decision about whether one of those menu items is
/// available, as pure functions over plain values (tested in `RemoteAdminWordingTests`,
/// `RemoteAdminMenuTests` and `RemoteManagementWordingTests`).
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
            return keptThenStopped(kept: kept, failedName: failedName, words: words, nothing: "pruned")
        case RemoteAdminPartial.keptBranchesCancelled(let kept, let unknown):
            return keptCancelled(kept: kept, unknown: unknown, nothing: "pruned")
        case _ where error is CancellationError:
            // GitCore turns a cancellation during the kept branches' creation into the case above.
            return "Stopped the prune before anything was created or deleted."
        default:
            return RemoteWording.failure(error, attempt: "prune \"\(remote)\"", isWrite: false)
                + " Nothing was pruned."
        }
    }

    /// Kept branches were created, then one could not be: nothing was `nothing` (pruned,
    /// removed) — GitCore creates every kept branch before it deletes anything.
    private static func keptThenStopped(kept: [String], failedName: String, words: String, nothing: String) -> String {
        let names = quotedList(kept)
        let made = kept.count == 1 ? "the kept branch \(names)" : "the kept branches \(names)"
        return "Created \(made), then couldn't create \"\(failedName)\": \(RemoteWording.plain(words)). "
            + "Nothing was \(nothing); \(names) \(kept.count == 1 ? "stays" : "stay")."
    }

    /// Ruling 12 (m7), carried note 6: git was stopped while it created `unknown` — it may exist.
    /// Never "couldn't create".
    private static func keptCancelled(kept: [String], unknown: String, nothing: String) -> String {
        let base = "Stopped while creating the kept branch \"\(unknown)\": it may or may not have been "
            + "created — check the branch list. Nothing was \(nothing)"
        guard !kept.isEmpty else { return base + "." }
        let names = quotedList(kept)
        return base + "; \(names) \(kept.count == 1 ? "was" : "were") created before it and stay\(kept.count == 1 ? "s" : "")."
    }

    /// `"a", "b"`.
    private static func quotedList(_ names: [String]) -> String {
        names.map { "\"\($0)\"" }.joined(separator: ", ")
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

    // MARK: - Remote management (B2 Task 5): titles and menu reasons

    static let addRemoteTitle = "Add Remote…"
    static let editURLTitle = "Edit URL…"
    static let renameRemoteTitle = "Rename…"
    static let removeRemoteTitle = "Remove…"

    static let addRemoteSheetTitle = "Add Remote"
    static func editURLSheetTitle(_ remote: String) -> String { "Edit URL of \"\(remote)\"" }
    static func renameRemoteSheetTitle(_ remote: String) -> String { "Rename Remote \"\(remote)\"" }
    static func removeRemoteSheetTitle(_ remote: String) -> String { "Remove Remote \"\(remote)\"" }

    static let addButton = "Add Remote"
    static let saveURLButton = "Save"
    static let renameButton = "Rename"
    static let removeButton = "Remove"
    static let fetchAfterAdding = "Fetch from it after adding"

    /// Add Remote…: a configuration write through `mutate`, which would drop the answer silently
    /// while another change runs. A busy lane does not stop it: it touches no remote-tracking ref,
    /// and the fetch after it, when asked for, claims the lane itself — refused with the lane's
    /// reason, the remote added all the same, if the lane is still busy then.
    static func addRemoteBlocked(_ gate: RemoteWording.Gate) -> String? {
        upstreamBlocked(gate)
    }

    /// Edit URL…: its read and its write go through `mutate`, like Add's.
    static func editURLBlocked(_ gate: RemoteWording.Gate) -> String? {
        upstreamBlocked(gate)
    }

    /// Rename…: on the lane, never beside a fetch — a fetch's ref lock leaves a rename half-done
    /// (R21) — holding the mutation slot. A remote with no URL can be renamed: nothing is
    /// contacted.
    static func renameRemoteBlocked(_ gate: RemoteWording.Gate) -> String? {
        guard gate.hasRepository else { return RemoteWording.noRepository }
        if let activity = gate.activity { return RemoteWording.laneBusy(activity) }
        return gate.isMutating ? RemoteWording.mutationBusy : nil
    }

    /// Remove…: its impact is read through `mutate`, and the removal runs on the lane, for the
    /// same reason as a rename (R23).
    static func removeRemoteBlocked(_ gate: RemoteWording.Gate) -> String? {
        renameRemoteBlocked(gate)
    }

    // MARK: - Remotes with no URL (carried note 3)

    /// Beside a remote's name in the sidebar: nil for a remote git can fetch from.
    static func remoteBadge(_ remote: Remote) -> String? {
        guard !remote.canFetch else { return nil }
        return remote.canPush ? "push URL only" : "no URL"
    }

    /// The row's tooltip, for the same remotes.
    static func remoteHelp(_ remote: Remote) -> String? {
        guard !remote.canFetch else { return nil }
        return remote.canPush
            ? "\"\(remote.name)\" has only a push URL, so nothing can be fetched from it. Give it one with Edit URL…."
            : "\"\(remote.name)\" has no URL, so nothing can be fetched from it or pushed to it. Give it one with "
                + "Edit URL…."
    }

    // MARK: - URLs on screen (carried note 1)

    /// A remote's URL as a sheet, a notice or a banner shows it: controls taken out first, then
    /// every credential redacted — but an ssh login kept (`RemoteWording.copyableURL`): it is no
    /// secret, and without it the address names another account. Display only: what is written
    /// is what the configuration holds or what the user typed.
    static func displayURL(_ url: String) -> String {
        RemoteWording.copyableURL(RemoteWording.stripped(url))
    }

    /// Whether showing `url` as written would show something `displayURL` hides — a credential.
    static func hidesCredential(_ url: String) -> Bool {
        displayURL(url) != url
    }

    /// What a URL field starts with: the configured URL as written — unless that would put a
    /// credential on screen; then it starts empty, and an empty field keeps the configured URL
    /// (`urlToWrite`).
    static func urlFieldStart(_ configured: String?) -> String {
        guard let configured, !hidesCredential(configured) else { return "" }
        return configured
    }

    /// Under a field that started empty over a credential.
    static let credentialKept = "It holds a credential, which is not shown. Leave the field empty to keep it as it is."

    /// The URL a field means: what was typed, trimmed — or, for an empty field over a configured
    /// URL that holds a credential, that URL exactly as it is.
    static func urlToWrite(field: String, configured: String?) -> String {
        let typed = field.trimmingCharacters(in: .whitespacesAndNewlines)
        if typed.isEmpty, let configured, hidesCredential(configured) { return configured }
        return typed
    }

    /// The push side of Edit URL (`PushURLChange`, tri-state): `ownPushURL` is the sheet's
    /// choice between pushing to the fetch URL and a push URL of its own. Several push URLs are
    /// shown read-only and never written (R22, `.severalURLs`).
    static func pushChange(ownPushURL: Bool, field: String, configured: [String]) -> PushURLChange {
        guard configured.count <= 1 else { return .unchanged }
        guard ownPushURL else { return configured.isEmpty ? .unchanged : .clear }
        let url = urlToWrite(field: field, configured: configured.first)
        return configured == [url] ? .unchanged : .set(url)
    }

    /// Whether Save would write anything — it is off when it would not.
    static func editURLWrites(_ urls: RemoteURLs, fetch: String, push: PushURLChange) -> Bool {
        if urls.fetch != [fetch] { return true }
        switch push {
        case .unchanged: return false
        case .set(let url): return urls.push != [url]
        case .clear: return !urls.push.isEmpty
        }
    }

    /// The form's own check of a URL, before the click: what GitCore refuses as `.unsafeURL`
    /// (GitCore stays the authority and checks again).
    static func urlProblem(_ url: String) -> String? {
        let trimmed = url.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Enter a URL." }
        if trimmed.hasPrefix("-") { return "A URL can't begin with \"-\": git would read it as an option." }
        if trimmed.lowercased().hasPrefix("ext::") { return "Gitter won't write an ext:: URL: git would run it as a command." }
        if trimmed.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) {
            return "A URL can't hold a control character."
        }
        return nil
    }

    /// R20: where git really connects, beside the configured URL, only when an `insteadOf` rule
    /// makes them differ.
    static func connectsTo(_ urls: RemoteURLs) -> String? {
        guard let effective = urls.effectiveFetch, let first = urls.fetch.first, effective != first else { return nil }
        return "git connects to \(displayURL(effective)): a url.<base>.insteadOf rule rewrites it. "
            + "Saving keeps the URL as you typed it."
    }

    /// R22: a plain `set-url` fails on several `url` values — shown as written, read-only.
    static func severalFetchURLs(_ urls: RemoteURLs, remote: String) -> String? {
        guard urls.fetch.count > 1 else { return nil }
        return "\"\(remote)\" has \(urls.fetch.count) fetch URLs; git fetches from the first. Gitter changes the URL "
            + "only of a remote with one, so they are shown as written. Change them in a terminal with git remote set-url."
    }

    static func severalPushURLs(_ urls: RemoteURLs, remote: String) -> String? {
        guard urls.push.count > 1 else { return nil }
        return "\"\(remote)\" has \(urls.push.count) push URLs, and git pushes to each. They are shown as written and "
            + "left as they are."
    }

    static let fetchURLLabel = "Fetch URL:"
    static let pushToFetchURL = "Push to the fetch URL"
    static let pushToOwnURL = "Push to its own URL:"
    static let noURLYet = "It has no URL yet."

    // MARK: - Names

    static func remoteNameProblem(_ problem: RemoteNameProblem) -> String {
        switch problem {
        case .empty: "Enter a name for the remote."
        case .invalid: "That is not a valid remote name."
        case .reserved: "\"HEAD\" and \"@\" already mean something to git. Choose another name."
        case .exists: "A remote with that name already exists (names are compared ignoring case)."
        case .nested(let other):
            "It would share a folder of remote-tracking branches with \"\(other)\": one name is inside the other."
        }
    }

    static let addRemoteIntro =
        "Adding a remote writes its name and URL to this repository's settings. Nothing is contacted until it is fetched."

    static func renameRemoteIntro(_ remote: String) -> String {
        "Renaming \"\(remote)\" moves its remote-tracking branches and rewrites the settings that name it. Nothing on "
            + "the server changes."
    }

    // MARK: - Notices

    static func remoteAdded(_ name: String, url: String) -> String {
        "Added the remote \"\(name)\" (\(displayURL(url)))."
    }

    static func urlsChanged(_ remote: String, fetch: String, push: PushURLChange) -> String {
        let base = "\"\(remote)\" now fetches from \(displayURL(fetch))"
        switch push {
        case .unchanged: return base + "."
        case .set(let url): return base + " and pushes to \(displayURL(url))."
        case .clear: return base + " and pushes to the same URL."
        }
    }

    static func remoteRenamed(_ old: String, to new: String) -> String {
        "Renamed the remote \"\(old)\" to \"\(new)\"."
    }

    // MARK: - Add and Edit URL failures

    private static let unsafeURLReason =
        "Gitter won't write that URL — it is empty, begins with \"-\", is an ext:: command, or holds a control character."

    static func addRemoteFailure(_ error: Error, name: String) -> String {
        switch error {
        case RemoteAdminRefusal.nameProblem(let problem):
            return "Couldn't add \"\(name)\": \(lowercasedFirst(remoteNameProblem(problem))) Nothing was added."
        case RemoteAdminRefusal.unsafeURL:
            return "Couldn't add \"\(name)\": \(unsafeURLReason) Nothing was added."
        case RemoteAdminPartial.urlsChangedThenFailed(let remote, let now, let words):
            let base = "Adding \"\(remote)\" failed part-way (\(gitsWords(words)))."
            guard let now else { return base + notConfigured(remote, after: "") }
            return base + " \"\(remote)\" is configured now, with \(urlsNow(now)). Remove it, or edit its URL."
        case RemoteAdminPartial.urlsOutcomeUnknown(let remote):
            return "Stopped while git was adding \"\(remote)\": whether it was added is not known. Refresh to see."
        default:
            return RemoteWording.failure(error, attempt: "add \"\(name)\"", isWrite: false)
        }
    }

    static func editURLFailure(_ error: Error, remote: String) -> String {
        switch error {
        case RemoteAdminRefusal.severalURLs:
            return "\"\(remote)\" has more than one URL of that kind now, and git can't set one of several. Nothing was "
                + "changed. Change them in a terminal with git remote set-url."
        case RemoteAdminRefusal.noSuchRemote, RemoteOperationError.noSuchRemote:
            return remoteGone(remote)
        case RemoteAdminRefusal.unsafeURL:
            return "Couldn't change the URL of \"\(remote)\": \(unsafeURLReason) Nothing was changed."
        case RemoteAdminPartial.urlsChangedThenFailed(_, let now, let words):
            let base = "Changing the URL of \"\(remote)\" failed part-way (\(gitsWords(words)))."
            guard let now else { return base + notConfigured(remote, after: " any more") }
            return base + " It has \(urlsNow(now)) now. Edit its URL again."
        case RemoteAdminPartial.urlsOutcomeUnknown:
            return "Stopped while git was changing the URL of \"\(remote)\": which URLs it has now is not known. "
                + "Refresh to see."
        default:
            return RemoteWording.failure(error, attempt: "change the URL of \"\(remote)\"", isWrite: false)
        }
    }

    /// A read before a sheet opens — the URLs, or what a removal would change — threw. Nothing
    /// was written.
    static func remoteReadFailure(_ error: Error, remote: String, attempt: String) -> String {
        switch error {
        case RemoteAdminRefusal.noSuchRemote, RemoteOperationError.noSuchRemote: remoteGone(remote)
        default: RemoteWording.failure(error, attempt: attempt, isWrite: false)
        }
    }

    static func readURLsAttempt(_ remote: String) -> String { "read the URLs of \"\(remote)\"" }
    static func readImpactAttempt(_ remote: String) -> String { "read what removing \"\(remote)\" would change" }

    /// The sheet's URLs are not the remote's any more: Save is refused before git runs.
    static func urlsChangedWhileShown(_ remote: String) -> String {
        "The URLs of \"\(remote)\" changed since you opened this — review again. Nothing was changed."
    }

    private static func notConfigured(_ remote: String, after: String) -> String {
        " Its configuration changed, but \"\(remote)\" is not a configured remote\(after). Check with: "
            + "git config --get-regexp '^remote\\.'"
    }

    /// "the fetch URL x and no push URL", every URL redacted.
    private static func urlsNow(_ urls: RemoteURLs) -> String {
        func part(_ list: [String], _ kind: String) -> String {
            switch list.count {
            case 0: "no \(kind) URL"
            case 1: "the \(kind) URL \(displayURL(list[0]))"
            default: "the \(kind) URLs " + list.map(displayURL).joined(separator: ", ")
            }
        }
        return part(urls.fetch, "fetch") + " and " + part(urls.push, "push")
    }

    // MARK: - Rename failures

    static func renameRemoteFailure(_ error: Error, old: String, new: String) -> String {
        switch error {
        case RemoteAdminRefusal.nameProblem(let problem):
            return "Couldn't rename \"\(old)\" to \"\(new)\": \(lowercasedFirst(remoteNameProblem(problem))) "
                + "Nothing was changed."
        case RemoteAdminRefusal.noSuchRemote, RemoteOperationError.noSuchRemote:
            return remoteGone(old)
        case RemoteAdminPartial.renameHalfDone(let left):
            return renameHalfDone(left)
        case RemoteAdminPartial.renameOutcomeUnknown:
            return "Stopped while git was renaming \"\(old)\" to \"\(new)\": what its settings and remote-tracking "
                + "branches hold now is not known. Refresh, and check with: git remote -v"
        case _ where error is CancellationError:
            return "Stopped before \"\(old)\" was renamed. Nothing was changed."
        default:
            return RemoteWording.failure(error, attempt: "rename \"\(old)\"", isWrite: false)
        }
    }

    /// R21: what a failed rename left, and how to finish — one line each, so the banner gives
    /// every line room (`Banner.lineLimit`). Renaming back is offered only when it is an exact
    /// undo (`RenameLeftover`'s note): the section renamed and nothing under the new name.
    private static func renameHalfDone(_ left: RenameLeftover) -> String {
        let old = left.old
        let new = left.new
        var lines = ["Renaming \"\(old)\" to \"\(new)\" stopped part-way (\(gitsWords(left.gitsWords)))."]
        switch (left.configured.contains(old), left.configured.contains(new)) {
        case (false, true): lines.append("The remote is called \"\(new)\" now.")
        case (true, false): lines.append("The remote is still called \"\(old)\".")
        case (true, true): lines.append("Both \"\(old)\" and \"\(new)\" are configured now.")
        case (false, false): lines.append("Neither \"\(old)\" nor \"\(new)\" is configured now.")
        }
        if !left.refspecsStillOld.isEmpty {
            lines.append(
                (left.refspecsStillOld.count == 1 ? "Its fetch refspec still writes" : "Its fetch refspecs still write")
                    + " under refs/remotes/\(old)/: "
                    + left.refspecsStillOld.map(RemoteWording.plain).joined(separator: ", ") + ".")
        }
        let under = { (count: Int) in count == 1 ? "1 remote-tracking branch is" : "\(count) remote-tracking branches are" }
        if !left.refsUnderOld.isEmpty { lines.append("\(under(left.refsUnderOld.count)) still under \"\(old)/\".") }
        if !left.refsUnderNew.isEmpty { lines.append("\(under(left.refsUnderNew.count)) under \"\(new)/\".") }
        if !left.configStillNamingOld.isEmpty {
            let keys = left.configStillNamingOld.joined(separator: ", ")
            lines.append(
                left.configured.contains(old)
                    ? "These settings still name \"\(old)\": \(keys)."
                    : "These settings still name \"\(old)\", which is not configured, so those branches have no "
                        + "upstream or push remote now: \(keys).")
        }
        if left.configured == [new], left.refsUnderNew.isEmpty {
            lines.append("To undo it, rename \"\(new)\" back to \"\(old)\" (\(renameRemoteTitle) on \"\(new)\"), then try again.")
        } else {
            lines.append("Finish it in a terminal; compare git remote -v and git for-each-ref refs/remotes/.")
        }
        return lines.joined(separator: "\n")
    }

    // MARK: - The remove sheet

    static func removeIntro(_ impact: RemovalImpact) -> String {
        let remote = "\"\(impact.remote)\""
        switch impact.refs.count {
        case 0:
            return "Removing \(remote) deletes its settings here. It has no remote-tracking branches; nothing on the "
                + "server changes."
        case 1:
            return "Removing \(remote) deletes its settings and this remote-tracking branch here; nothing on the "
                + "server changes."
        default:
            return "Removing \(remote) deletes its settings and these \(impact.refs.count) remote-tracking branches "
                + "here; nothing on the server changes."
        }
    }

    /// R23: their `remote` and `merge` are unset — no upstream at all, not `[gone]`.
    static func removeUpstreams(_ impact: RemovalImpact) -> String? {
        switch impact.upstreamOf.count {
        case 0: nil
        case 1: "\"\(impact.upstreamOf[0])\" tracks \"\(impact.remote)\" and will be left with no upstream."
        default:
            "These branches track \"\(impact.remote)\" and will be left with no upstream: "
                + quotedList(impact.upstreamOf) + "."
        }
    }

    /// R23: git unsets every `pushRemote` and `remote.pushDefault` naming the remote, so these
    /// branches silently push somewhere else afterwards — each said, with where.
    static func removePushRedirects(_ impact: RemovalImpact) -> [String] {
        impact.pushRedirects.map { redirect in
            let branch = "\"\(redirect.branch)\""
            let remote = "\"\(impact.remote)\""
            switch redirect.nowPushesTo {
            case nil:
                return "\(branch) pushes to \(remote) now, and will have nowhere to push: Push will offer Publish…."
            case ".":
                return "\(branch) pushes to \(remote) now, and will push into this repository (its upstream is a local "
                    + "branch)."
            case impact.remote:
                return "\(branch) pushes to \(remote) through a setting outside this repository's configuration, which "
                    + "git leaves: it will go on pushing to \(remote), which will no longer exist."
            case let other?:
                return "\(branch) pushes to \(remote) now, and will push to \"\(other)\" instead."
            }
        }
    }

    static func removeLeftBehind(_ impact: RemovalImpact) -> String? {
        guard !impact.leftBehind.isEmpty else { return nil }
        return "These are not mapped by the fetch refspecs of \"\(impact.remote)\", so git leaves them; they will show "
            + "under Other: \(impact.leftBehind.map(shortRef).joined(separator: ", "))."
    }

    // MARK: - The remove notice (sticky: the only record, promise 3)

    /// Every deleted ref with the id it held, the kept branches, and everything else the removal
    /// changed — the branches left with no upstream and the ones now pushing elsewhere.
    static func remoteRemoved(_ impact: RemovalImpact, keptBranches: [String]) -> String {
        var lines: [String] = []
        let remote = "\"\(impact.remote)\""
        switch impact.refs.count {
        case 0: lines.append("Removed the remote \(remote).")
        case 1:
            lines.append(
                "Removed the remote \(remote). This is the only record of the remote-tracking branch deleted with it:")
        default:
            lines.append(
                "Removed the remote \(remote). This is the only record of the \(impact.refs.count) remote-tracking "
                    + "branches deleted with it:")
        }
        lines += impact.refs.map { "\(shortRef($0.ref)) \($0.id)" }
        if !keptBranches.isEmpty {
            lines.append(
                (keptBranches.count == 1 ? "Kept as a local branch: " : "Kept as local branches: ")
                    + quotedList(keptBranches) + ".")
        }
        if !impact.upstreamOf.isEmpty {
            lines.append("Left with no upstream: \(quotedList(impact.upstreamOf)).")
        }
        if !impact.pushRedirects.isEmpty {
            let each = impact.pushRedirects.map { redirect -> String in
                let branch = "\"\(redirect.branch)\""
                switch redirect.nowPushesTo {
                case nil: return "\(branch) nowhere (Push will offer Publish…)"
                case ".": return "\(branch) into this repository"
                case impact.remote: return "\(branch) still to \(remote), which no longer exists"
                case let other?: return "\(branch) to \"\(other)\""
                }
            }
            lines.append("Pushing elsewhere now: " + each.joined(separator: "; ") + ".")
        }
        if !impact.leftBehind.isEmpty {
            lines.append("Left behind, under Other: \(impact.leftBehind.map(shortRef).joined(separator: ", ")).")
        }
        if !impact.refs.isEmpty { lines.append("Bring one back with: git update-ref <ref> <id>") }
        return lines.joined(separator: "\n")
    }

    // MARK: - Remove failures

    static func removeRemoteFailure(_ error: Error, remote: String) -> String {
        switch error {
        case RemoteAdminRefusal.impactChanged:
            return "What removing \"\(remote)\" would delete or change is not what the sheet showed: it changed since "
                + "you opened this — review again. Nothing was removed."
        case RemoteAdminRefusal.noSuchRemote, RemoteOperationError.noSuchRemote:
            return remoteGone(remote)
        case RemoteAdminRefusal.branchExists(let name):
            return "Couldn't keep \"\(name)\": a branch, tag or remote has that name now. Nothing was removed."
        case RemoteAdminRefusal.invalidBranchName(let name):
            return "Couldn't keep \"\(name)\": that is not a valid branch name. Nothing was removed."
        case RemoteAdminRefusal.invalidObjectID:
            return "The sheet held an id that is not a full commit id, so nothing was removed. Choose Remove… again."
        case RemoteAdminPartial.keptBranchesThenStopped(let kept, let failedName, let words):
            return keptThenStopped(kept: kept, failedName: failedName, words: words, nothing: "removed")
        case RemoteAdminPartial.keptBranchesCancelled(let kept, let unknown):
            return keptCancelled(kept: kept, unknown: unknown, nothing: "removed")
        case RemoteAdminPartial.removeHalfDone(let left):
            return removeHalfDone(left)
        case RemoteAdminPartial.removeOutcomeUnknown(_, let kept):
            let base = "Stopped while git was removing \"\(remote)\": whether the remote, its remote-tracking branches "
                + "and the branch settings naming it are still there is not known. Refresh to see."
            switch kept.count {
            case 0: return base
            case 1: return base + " The kept branch \(quotedList(kept)) was created before git ran and stays."
            default: return base + " The kept branches \(quotedList(kept)) were created before git ran and stay."
            }
        case _ where error is CancellationError:
            // GitCore turns a cancellation during a kept branch's creation or git's own run into
            // the cases above; this one came before either.
            return "Stopped the removal of \"\(remote)\" before anything was created or removed."
        default:
            return RemoteWording.failure(error, attempt: "remove \"\(remote)\"", isWrite: false)
        }
    }

    /// R23: what a failed removal left — git unsets the branch settings first — and how to finish:
    /// removing again finishes it (measured), while the remote is still configured.
    private static func removeHalfDone(_ left: RemovalLeftover) -> String {
        let remote = "\"\(left.remote)\""
        var lines = [
            "Removing \(remote) stopped part-way (\(gitsWords(left.gitsWords))). \(remote) is "
                + (left.stillConfigured ? "still configured." : "no longer configured.")
        ]
        if !left.configRemoved.isEmpty {
            lines.append(
                "git had already removed these settings: \(left.configRemoved.joined(separator: ", ")) — those "
                    + "branches have no upstream or push remote of this name now.")
        }
        if !left.refsLeft.isEmpty {
            lines.append("Still there: \(left.refsLeft.map { shortRef($0.ref) }.joined(separator: ", ")).")
        }
        if !left.refsDeleted.isEmpty {
            lines.append(
                "Deleted, the only record of what \(left.refsDeleted.count == 1 ? "it" : "they") held: "
                    + left.refsDeleted.map { "\(shortRef($0.ref)) \($0.id)" }.joined(separator: ", "))
        }
        switch left.keptBranches.count {
        case 0: break
        case 1: lines.append("Kept as a local branch before git ran: \(quotedList(left.keptBranches)). It stays.")
        default: lines.append("Kept as local branches before git ran: \(quotedList(left.keptBranches)). They stay.")
        }
        if left.stillConfigured {
            lines.append("Remove \(remote) again to finish (\(removeRemoteTitle) on \(remote)).")
        } else if !left.refsLeft.isEmpty {
            lines.append("Delete what is left in a terminal: git update-ref -d <ref> <id>")
        }
        return lines.joined(separator: "\n")
    }

    /// git's own words (already redacted by GitCore), made plain, on one line.
    private static func gitsWords(_ words: String) -> String {
        RemoteWording.plainJoined(words.split(whereSeparator: \.isNewline).map(String.init))
    }

    private static func lowercasedFirst(_ text: String) -> String {
        guard let first = text.first else { return text }
        return first.lowercased() + text.dropFirst()
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
