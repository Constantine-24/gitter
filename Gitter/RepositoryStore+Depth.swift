import Foundation
import GitCore

/// History's depth (H1): the list loads older commits a page at a time as its end row scrolls in
/// (`loadOlderCommits`), and a commit that isn't loaded — a sidebar click on an old branch, Done
/// on a comparison — is selected at once and loaded down to (`reveal`), with `pendingReveal` left
/// for the table's scroll.
///
/// Both go through the chained `refresh()`, so they keep its rules: loads never overlap, a closed
/// store loads nothing, and a load from before an `open()` is dropped by its generation.
extension RepositoryStore {

    // MARK: - Load more

    /// One page more: the depth rises by `HistoryDepth.page` (to `HistoryDepth.cap` at most) and
    /// the snapshot reloads. Nothing with no repository or a closed store, while the history is
    /// complete or no snapshot says otherwise yet, at the cap, or while a load-more is already
    /// queued or running. A failed load shows the usual banner and leaves the depth raised, so
    /// the next scroll retries.
    func loadOlderCommits() {
        guard root != nil, !isClosed, !isLoadingOlderCommits, let snapshot, !snapshot.historyIsComplete,
            historyDepth < HistoryDepth.cap
        else { return }
        setLoadingOlderCommits(true)
        setHistoryDepth(min(historyDepth + HistoryDepth.page, HistoryDepth.cap))
        let capturedGeneration = generation
        // Queued now, not from inside the task: a refresh between this call and the task's start
        // then shares this load instead of running one at the old depth's moment.
        let load = chainedRefresh()
        Task {
            await load.value
            guard generation == capturedGeneration else { return }
            setLoadingOlderCommits(false)
        }
    }

    // MARK: - Reveal

    /// Selects `sha` (a full commit id) and, when its row isn't loaded, loads down to it: the
    /// selection is at once, so the detail loads straight away, and `pendingReveal` is set for the
    /// table to scroll to once the row is in (`revealHandled`). A loaded commit is selected as
    /// before, with no read.
    ///
    /// Otherwise `historyRow(of:)` says where it is: the depth rises to cover that row and the
    /// snapshot reloads. A commit no branch, tag or HEAD reaches (a stash's) gets the not-in-history
    /// notice; one `HistoryDepth.cap` rows back or more, the cap's notice. Either stays selected.
    /// The answer is dropped when the selection or the repository changed meanwhile (a second
    /// reveal wins).
    func reveal(_ sha: String) {
        // The selection first, so its `didSet` — which ends any other reveal — has run.
        select(.commit(sha))
        guard selection == .commit(sha) else { return }
        setPendingReveal(sha)
        revealTask?.cancel()
        revealTask = nil
        guard let root, !isClosed, !historyRows.shas.contains(.commit(sha)) else { return }
        let capturedGeneration = generation
        revealTask = Task {
            let row: Int?
            do {
                row = try await backend.historyRow(of: sha, at: root)
            } catch {
                guard isRevealing(sha, generation: capturedGeneration) else { return }
                setPendingReveal(nil)
                setError(Self.describe(error))
                clearSticky()
                return
            }
            guard isRevealing(sha, generation: capturedGeneration) else { return }
            let shortSha = String(sha.prefix(7))
            guard let row else {
                // Nothing will ever scroll to it: the reveal ends here.
                setPendingReveal(nil)
                showNotice(HistoryWording.notInHistory(shortSha: shortSha))
                return
            }
            guard row < HistoryDepth.cap else {
                setPendingReveal(nil)
                showNotice(HistoryWording.beyondCap(shortSha: shortSha))
                return
            }
            let depth = HistoryDepth.depth(forRow: row)
            if depth > historyDepth { setHistoryDepth(depth) }
            await refresh()
        }
    }

    /// The table has scrolled to `sha`'s row: the reveal is over — unless another has begun.
    func revealHandled(_ sha: String) {
        if pendingReveal == sha { setPendingReveal(nil) }
    }

    /// Whether the reveal of `sha` started in `generation` is still the one wanted.
    private func isRevealing(_ sha: String, generation capturedGeneration: Int) -> Bool {
        !Task.isCancelled && generation == capturedGeneration && selection == .commit(sha)
            && pendingReveal == sha
    }
}
