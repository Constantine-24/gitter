import Foundation
import GitCore

/// Comparing two branches (B3): "Compare with "<current>"" and Compare Branches…, the compare
/// mode of the commit list column, and how it ends.
///
/// A comparison is one state (the milestone's first promise): GitCore reads both tips to ids
/// once and takes the counts, the lists and the merge bases from those ids; the changes are read
/// from the same ids (`loadDetail` / `loadDiff`), so nothing on screen can mix two states. When a
/// refresh shows a tip somewhere else, the bar says so (`comparisonStaleness`) — the comparison
/// itself is never quietly read again. Refresh and Swap read it again, as a new state.
///
/// Read-only: nothing here writes, so nothing goes through `mutate` or the network lane.
extension RepositoryStore {

    // MARK: - State

    /// Where the comparison's tips stand in the snapshot on screen, or nil with none.
    var comparisonStaleness: CompareWording.Staleness? {
        guard let comparison, let refs = snapshot?.refs else { return nil }
        return CompareWording.staleness(comparison, refs: refs)
    }

    /// The comparison's full refs whose tip differs from the snapshot — moved or deleted — in
    /// the order A, B; empty while it is current.
    var comparisonMoved: [String] {
        comparisonStaleness?.moved ?? []
    }

    /// The branch HEAD is on as a full ref, when it has a commit.
    var currentBranchFullRef: String? {
        currentBranchRef.map { "refs/heads/" + $0.name }
    }

    /// The commit a detail header describes: from the log; for a commit only one side of the
    /// comparison has, which the loaded rows may not show, from the comparison's lists; and for a
    /// selected commit in neither — a reveal's before its deep load lands, one past the cap — from
    /// its own read (`detailCommit`, H1).
    func commitForDetail(_ sha: String) -> Commit? {
        if let commit = snapshot?.commits.first(where: { $0.sha == sha }) { return commit }
        if let comparison,
            let commit = (comparison.commitsOnlyB + comparison.commitsOnlyA).first(where: { $0.sha == sha })
        {
            return commit
        }
        return detailCommit?.sha == sha ? detailCommit : nil
    }

    // MARK: - Menu reasons

    /// Why "Compare with "<current>"" is off on the row of the branch `ref` (full), or nil.
    func compareWithCurrentBlockedReason(_ ref: String) -> String? {
        CompareWording.compareWithBlocked(
            ref, current: currentBranch, currentHasCommits: currentBranchRef != nil, isDetached: isDetached)
    }

    /// Why Compare Branches… is off, or nil.
    var compareBranchesBlockedReason: String? {
        CompareWording.compareBranchesBlocked(branchCount: localBranches.count + remoteBranches.count)
    }

    // MARK: - Entering

    /// "Compare with "<current>"": the current branch as A, `ref` (full) as B — the changes
    /// `ref` would bring.
    func compareWithCurrent(_ ref: String) {
        guard compareWithCurrentBlockedReason(ref) == nil, let current = currentBranchFullRef else { return }
        compare(current, ref)
    }

    /// Compare Branches…: the sheet with its two pickers, A preset to `a` or the current branch,
    /// B to `b` — unless that is A again.
    func requestCompareBranches(a: String?, b: String?) {
        guard root != nil, compareBranchesBlockedReason == nil else { return }
        let first = a ?? currentBranchFullRef
        activeSheet = .compareBranches(a: first, b: b == first ? nil : b)
    }

    /// The sheet's Compare: closes it and compares.
    func confirmCompareBranches(_ a: String, _ b: String) {
        guard case .compareBranches = activeSheet else { return }
        activeSheet = nil
        compare(a, b)
    }

    /// Reads `a` against `b` (full refs) off the main actor, then shows it: the commit list
    /// column switches to compare mode with the changes row selected. A refusal — not a branch,
    /// gone, the same twice — is a sticky banner, and whatever was on screen stays; the next
    /// comparison read takes that banner down.
    func compare(_ a: String, _ b: String) {
        guard let root else { return }
        compareTask?.cancel()
        let capturedGeneration = generation
        compareTask = Task {
            let result: Result<Comparison, Error>
            do {
                result = .success(try await backend.compare(a, b, at: root))
            } catch {
                result = .failure(error)
            }
            guard !Task.isCancelled, generation == capturedGeneration else { return }
            switch result {
            case .success(let comparison):
                clearCompareFailure()
                setComparison(comparison)
                select(.comparisonChanges)
            case .failure(let error):
                showCompareFailure(CompareWording.failure(error) ?? Self.describe(error))
            }
        }
    }

    // MARK: - In compare mode

    /// Swap: the same two branches read again the other way round — a new state. Not with a
    /// branch gone.
    func swapComparison() {
        guard let comparison, comparisonStaleness?.offersSwap != false else { return }
        compare(comparison.b.ref, comparison.a.ref)
    }

    /// Refresh: the same two branches read again, as they are now.
    func refreshComparison() {
        guard let comparison else { return }
        compare(comparison.a.ref, comparison.b.ref)
    }

    /// Done, Esc: back to the history. The changes row's selection goes back to the working
    /// copy; a commit clicked in the comparison stays selected, as any commit does — and when the
    /// history hasn't loaded it, it is revealed (H1): loaded down to, and scrolled to.
    func endComparison() {
        leaveComparison(revealingSelection: true)
    }

    /// A click on a sidebar row: it ends compare mode, then selects as before — a commit (a
    /// branch's, a tag's, a deleted tag's receipt's) through `reveal`, so one that isn't loaded is
    /// loaded down to (H1). The comparison's own selection is not revealed first: the click
    /// replaces it.
    func selectFromSidebar(_ newSelection: Selection) {
        leaveComparison(revealingSelection: false)
        if case .commit(let sha) = newSelection {
            reveal(sha)
        } else {
            select(newSelection)
        }
    }

    private func leaveComparison(revealingSelection: Bool) {
        compareTask?.cancel()
        compareTask = nil
        guard comparison != nil else { return }
        setComparison(nil)
        if selection == .comparisonChanges {
            select(.workingCopy)
        } else if revealingSelection, case .commit(let sha) = selection, !historyRows.shas.contains(.commit(sha)) {
            reveal(sha)
        }
    }
}
