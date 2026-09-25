import Foundation
import GitCore

/// Debounced, coalesced reloading of the repository snapshot.
extension RepositoryStore {

    // MARK: - Debounced refresh

    // internal (not private): used by RepositoryStore.swift's `open()`, which schedules this
    // from the file-system watcher's callback
    func scheduleRefresh() {
        // While the network lane is busy a fetch rewrites `FETCH_HEAD` and refs continuously,
        // and every write would schedule a reload. They are dropped here; the lane's own work
        // reloads exactly once, while it still holds the lane, before it frees it (see
        // `runOnLane`). A mutation during a fetch is unaffected: `mutate` reloads directly.
        guard remoteActivity == nil else { return }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: - Refresh

    /// Loads a fresh snapshot, returning only once a load that *started after this call* has
    /// finished. `mutate` depends on that: a load already in flight may have read git before
    /// the mutation landed, so sharing it could hand back a pre-mutation snapshot.
    ///
    /// Loads never overlap — each is chained behind the previous one. A load that is chained
    /// but has not begun reading git yet is shared by every further caller, which is the
    /// coalescing the file-system watcher needs (many events, one reload). The flip side of
    /// that chaining: nothing reachable from inside a chained load may `await refresh()`, as
    /// it would then be waiting on itself forever.
    func refresh() async {
        guard root != nil else { return }
        await chainedRefresh().value
    }

    private func chainedRefresh() -> Task<Void, Never> {
        if refreshIsQueued, let queued = lastRefresh { return queued }
        let previous = lastRefresh
        refreshIsQueued = true
        let run = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            // Reading git starts now, so anything that happens from here on is invisible to
            // this load and later callers have to chain behind it instead of sharing it.
            refreshIsQueued = false
            await loadSnapshot()
        }
        lastRefresh = run
        return run
    }

    private func loadSnapshot() async {
        guard let root else { return }
        let capturedGeneration = generation
        #if DEBUG
            noteSnapshotLoad()
        #endif
        setLoading(true)
        defer { setLoading(false) }

        do {
            let newSnapshot = try await backend.snapshot(at: root)
            // The repository may have been switched (via `open`) while this snapshot was in
            // flight; a snapshot from before that must never overwrite the new state.
            guard generation == capturedGeneration else { return }
            setSnapshot(newSnapshot)
            // A mutation's own failure outranks the reload it provokes. git writes inside
            // `.git` before it fails — a rejected commit has already written COMMIT_EDITMSG —
            // so the watcher fires and this successful snapshot would otherwise erase the
            // hook's output a fraction of a second after the user saw it.
            clearErrorUnlessSticky()

            // Keep a commit selection even when the commit isn't in the loaded window (the
            // log is capped): the row simply isn't highlighted. Only an empty repository has
            // no commit the selection could ever refer to. A changed root is handled by
            // `open()`, which resets the selection itself.
            if newSnapshot.commits.isEmpty {
                selection = .workingCopy
            }
        } catch {
            guard generation == capturedGeneration else { return }
            // A failed load is newer, real information about the repository, so it replaces
            // even a mutation's message — and stops being protected from the next reload.
            setError(Self.describe(error))
            clearSticky()
        }

        loadDetail()
    }
}
