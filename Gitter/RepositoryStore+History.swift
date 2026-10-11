import Foundation
import GitCore

/// Cherry-pick and revert of the selected commits, and rebase onto a chosen commit or branch
/// (B1, Task 3).
///
/// Each is two steps, and only the second writes:
///
/// 1. `request…` asks GitCore for the plan (`historyPlan` / `rebasePlan` — reads only) through
///    `mutate`, so a refusal is a sticky banner like any other — tracked changes with Stash and
///    Continue beside it — and puts the plan on screen as a sheet.
/// 2. `confirm…` hands **the plan GitCore returned** back to `run` / `rebase(_:at:)`, which make
///    it again and refuse (`.headMoved`, `.planChanged`, or the plan's own refusals) on any
///    difference: what the sheet showed is what runs.
///
/// A stop — a conflict, a signing failure, an untracked file in a later commit's way — is A2's:
/// the operation bar (or the halted bar) takes over and nothing is said here.
extension RepositoryStore {

    // MARK: - Cherry-pick and revert

    /// Plans cherry-picking or reverting `shas` (the commit list's full ids, any order) and puts
    /// the plan up as `.historyAction`, or the refusal in the banner.
    func requestHistoryAction(_ action: HistoryAction, shas: [String]) {
        guard requestMayProceed() else { return }
        let pending = PendingBranchAction.history(action, shas)
        // Refused here with the operation's own sentence, before even the plan's read; GitCore
        // refuses the same (and a halted range, which only it can see).
        if let operation = operationInProgress {
            mutate { _, _ in
                throw HistoryWording.error(HistoryRefusal.operationInProgress(operation), for: pending)
            }
            return
        }
        mutate(result: { backend, root in
            do {
                return try await backend.historyPlan(action, shas: shas, at: root)
            } catch {
                throw HistoryWording.error(error, for: pending)
            }
        }, onSuccess: { [self] plan in
            activeSheet = .historyAction(plan)
        })
    }

    /// Runs the plan the sheet shows — only as the answer to that sheet.
    func confirmHistoryAction(_ plan: HistoryPlan) {
        guard case .historyAction(let shown) = activeSheet, shown == plan else { return }
        activeSheet = nil
        // What Stash and Continue would plan again: everything the user selected.
        let pending = PendingBranchAction.history(
            plan.action, plan.commits.map(\.sha) + plan.leftOut.map(\.sha))
        mutate(result: { backend, root -> HistoryOutcome in
            let outcome: HistoryOutcome
            do {
                outcome = try await backend.run(plan, at: root)
            } catch {
                throw HistoryWording.error(error, for: pending)
            }
            if case .failed(let words) = outcome {
                throw HistoryActionFailed(sentence: HistoryWording.failed(plan.action, gitsWords: words))
            }
            return outcome
        }, onSuccess: { [self] outcome in
            // What the user needs to look at next is the working copy: the bar after a stop,
            // the staged revert, or simply the new commits on top of the list.
            select(.workingCopy)
            switch outcome {
            case .applied(let count, let dropped):
                showNotice(HistoryWording.applied(plan, count: count, dropped: dropped))
            case .alreadyReverted(let commit):
                showNotice(HistoryWording.alreadyReverted(commit, plan: plan))
            case .unsignedRevertLeftStaged(let words):
                let filled = prefillRevertMessage(plan)
                showStagedRevertNotice(
                    Notice(text: HistoryWording.revertLeftStaged(gitsWords: words, messageInComposer: filled)))
            case .stopped, .failed:
                // A stop is the operation bar's to say; a failure was thrown above.
                break
            }
        })
    }

    /// Puts git's own revert message into an empty draft, so Commit makes the commit git could
    /// not. Returns whether the draft holds it now — a draft the user had written is theirs.
    private func prefillRevertMessage(_ plan: HistoryPlan) -> Bool {
        guard plan.action == .revert, plan.commits.count == 1, let commit = plan.commits.first else {
            return false
        }
        let message = HistoryWording.revertMessage(commit)
        draft.prefill(from: message)
        return draft.message == message
    }

    // MARK: - Rebase onto

    /// Plans rebasing HEAD onto `target` — a full object id or a branch's full ref name
    /// (`refs/heads/x`, `refs/remotes/o/x`) — and puts the plan up as `.rebaseOnto`, or the
    /// refusal in the banner.
    func requestRebaseOnto(_ target: String) {
        guard requestMayProceed() else { return }
        let pending = PendingBranchAction.rebaseOnto(target)
        if let operation = operationInProgress {
            mutate { _, _ in
                throw HistoryWording.error(HistoryRefusal.operationInProgress(operation), for: pending)
            }
            return
        }
        mutate(result: { backend, root in
            do {
                return try await backend.rebasePlan(onto: target, at: root)
            } catch {
                throw HistoryWording.error(error, for: pending)
            }
        }, onSuccess: { [self] plan in
            activeSheet = .rebaseOnto(plan)
        })
    }

    /// Rebases as the sheet shows — only as the answer to that sheet.
    func confirmRebaseOnto(_ plan: RebasePlan) {
        guard case .rebaseOnto(let shown) = activeSheet, shown == plan else { return }
        activeSheet = nil
        let pending = PendingBranchAction.rebaseOnto(plan.targetName)
        mutate(result: { backend, root in
            do {
                return try await backend.rebase(plan, at: root)
            } catch {
                throw HistoryWording.error(error, for: pending)
            }
        }, onSuccess: { [self] outcome in
            select(.workingCopy)
            if let notice = HistoryWording.rebaseNotice(outcome, plan: plan) { showNotice(notice) }
        })
    }

    /// How many commits `target` has that `head` lacks (both full object ids, the plan's) — the
    /// rebase sheet's "moves straight forward" line. Nil when it cannot be counted; the sheet
    /// then says less. A read, no lock.
    func commitsOnlyIn(_ target: String, notIn head: String) async -> Int? {
        guard let root else { return nil }
        return try? await backend.commitCount(in: target, notIn: head, at: root)
    }

    // MARK: - What the menus may offer

    /// Why Cherry-Pick / Revert is off for `shas`, or nil: an operation in progress, or a merge
    /// commit among them (GitCore refuses both too; this says it before the click).
    func historyBlockedReason(for shas: [String]) -> String? {
        if let reason = branchSwitchingBlockedReason ?? changeRunningBlockedReason { return reason }
        let merges = Set(snapshot?.commits.filter(\.isMerge).map(\.sha) ?? [])
        if shas.contains(where: merges.contains) { return HistoryWording.mergesInSelection }
        return nil
    }

    /// Why Rebase onto `sha` (a commit row) is off, or nil.
    func rebaseOntoCommitBlockedReason(_ shas: [String]) -> String? {
        guard shas.count == 1 else { return HistoryWording.rebaseNeedsOneCommit }
        if let reason = branchSwitchingBlockedReason { return reason }
        if shas.first == headSha { return HistoryWording.rebaseOntoHead }
        return changeRunningBlockedReason
    }

    /// Why Rebase onto the local branch `branch` is off, or nil.
    func rebaseOntoBranchBlockedReason(_ branch: String) -> String? {
        if branch == currentBranch { return Self.currentBranchReason }
        return branchSwitchingBlockedReason ?? changeRunningBlockedReason
    }
}

/// The commit list's selection rules, pure: commits form a set — ⌘-click adds or removes one,
/// ⇧-click a range — kept in the order the list shows them; the working copy and a stash are
/// only ever selected alone; the detail pane shows the first selected commit.
enum CommitSelection {

    struct Resolved: Equatable {
        /// What the detail pane shows: the first selected commit, the working copy or a stash.
        let detail: Selection
        /// The selected commits in the order shown; empty unless `detail` is a commit.
        let commits: [String]
    }

    /// The table asks for `new` where it showed `previous`. Nil for an empty set (a click on
    /// empty space): the selection stays.
    ///
    /// A working copy or stash among what was just **added** wins alone — the user clicked it.
    /// Otherwise the commits, in the order `shown`; one the list no longer shows (the log is
    /// capped) after those, so it is not lost.
    static func resolve(_ new: Set<Selection>, previous: Set<Selection>, shown: [Selection]) -> Resolved? {
        guard !new.isEmpty else { return nil }
        let added = new.subtracting(previous)
        if let single = first(nonCommitIn: added, shown: shown) {
            return Resolved(detail: single, commits: [])
        }
        let commits = ordered(new, shown: shown)
        guard let first = commits.first else {
            // Only a working copy or stash left (the commits were deselected).
            return first(nonCommitIn: new, shown: shown).map { Resolved(detail: $0, commits: []) }
        }
        return Resolved(detail: .commit(first), commits: commits)
    }

    /// What the table shows as selected for the store's state: the commit set, or the single
    /// working copy. A stash is selected in the sidebar, and a comparison's changes in compare
    /// mode's own list (B3), so the table shows nothing for either.
    static func table(selection: Selection, commits: [String]) -> Set<Selection> {
        switch selection {
        case .workingCopy: [.workingCopy]
        case .stash, .comparisonChanges: []
        case .commit(let sha): commits.isEmpty ? [.commit(sha)] : Set(commits.map(Selection.commit))
        }
    }

    private static func first(nonCommitIn set: Set<Selection>, shown: [Selection]) -> Selection? {
        let singles = set.filter { if case .commit = $0 { false } else { true } }
        guard !singles.isEmpty else { return nil }
        return shown.first(where: singles.contains)
            ?? singles.sorted { "\($0)" < "\($1)" }.first
    }

    private static func ordered(_ set: Set<Selection>, shown: [Selection]) -> [String] {
        var result: [String] = []
        for row in shown where set.contains(row) {
            if case .commit(let sha) = row { result.append(sha) }
        }
        let unshown = set.compactMap { row -> String? in
            guard case .commit(let sha) = row, !result.contains(sha) else { return nil }
            return sha
        }
        return result + unshown.sorted()
    }
}
