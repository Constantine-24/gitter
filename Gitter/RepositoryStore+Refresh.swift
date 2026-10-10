import Foundation
import GitCore

/// Debounced, coalesced reloading of the repository snapshot.
extension RepositoryStore {

    // MARK: - Debounced refresh

    // internal (not private): used by RepositoryStore.swift's `open()`, which schedules this
    // from the file-system watcher's callback
    func scheduleRefresh(changed paths: [String] = []) {
        // A closed window's store reloads nothing (RF3): its watcher is stopped, and an event
        // already on its way is dropped here.
        guard !isClosed else { return }
        // While the network lane is busy a fetch rewrites `FETCH_HEAD` and refs continuously,
        // and every write would schedule a reload. They are dropped here; the lane's own work
        // reloads exactly once, while it still holds the lane, before it frees it (see
        // `runOnLane`). A mutation during a fetch is unaffected: `mutate` reloads directly.
        // What was dropped is remembered, so an event that lands after the lane's reload began
        // still gets one (`watcherEventDuringLane`) — unless it is only the lane's own writes,
        // which its reload is about to read or has just read.
        if let remoteActivity {
            if paths.isEmpty
                || !paths.allSatisfy({ Self.isLaneOwnWrite($0, during: remoteActivity.kind) })
            {
                setWatcherEventDuringLane(true)
            }
            return
        }
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    /// Whether `path` is one of the files the lane's own kind of work writes in `.git`, so that
    /// a watcher event for it, arriving late, is not taken for somebody else's change. Anything
    /// else during the lane — the index, `refs/heads`, `HEAD`, the worktree, and for most kinds
    /// `config` and `packed-refs` — came from something else, and is what
    /// `watcherEventDuringLane` exists to catch. (Loose objects and `*.lock` files never get
    /// here: `RepositoryWatcher` drops them.)
    ///
    /// | lane kind | its own writes |
    /// |---|---|
    /// | every kind | `FETCH_HEAD`, `refs/remotes/…`, `logs/refs/remotes/…`, `refs/tags/…` |
    /// | publish | and `config` (`push -u` writes `branch.<b>.remote`/`.merge`) |
    /// | delete on a remote, prune | and `packed-refs` (deleting a packed tracking ref rewrites it) |
    ///
    /// Why the first row is every kind's: each of them can fetch on the lane — a fetch and a
    /// pull outright (the force push and delete warnings are fetch lanes too), and a push,
    /// force push or delete the server refused, to show what it has now — and a fetch writes
    /// `FETCH_HEAD`, the remote-tracking refs with their reflogs, and any new tags (tags keep
    /// no reflog by default). A push that lands updates the tracking ref it pushed.
    ///
    /// What is deliberately **not** anyone's:
    /// - `config` outside Publish. Only `-u` writes it; a user's `git branch --unset-upstream`
    ///   during a fetch's reload writes it too, and ignoring that left stale tracking on
    ///   screen with no reload to correct it (found in Task 8's re-review).
    /// - `packed-refs` outside a delete. The fetches here pass `--no-prune`, so they never
    ///   delete a ref, and a created or updated ref is written loose. The one lane-made
    ///   rewrite left is `git maintenance run --auto` packing refs after a fetch — rare, and
    ///   what it costs is one extra reload, never a missed one.
    /// - A pull's merge or rebase (`ORIG_HEAD`, `HEAD`, `refs/heads/<b>`, the index, the
    ///   worktree). It does not run on the lane: the fast-forward runs in the lane's `then`
    ///   and Merge or Rebase from the sheet, both after the lane is free and through
    ///   `mutate`, which reloads by itself. While a pull holds the lane it only fetches.
    ///
    /// A linked worktree's fetch writes its `FETCH_HEAD` in its own git directory,
    /// `.git/worktrees/<id>/FETCH_HEAD` (B3, R28), which the watcher sees once it watches that
    /// directory: it is the lane's own write too.
    static func isLaneOwnWrite(_ path: String, during kind: RemoteActivity.Kind) -> Bool {
        guard let range = path.range(of: "/.git/") else { return false }
        let inGit = path[range.upperBound...]
        let perWorktree = inGit.split(separator: "/", omittingEmptySubsequences: false)
        if perWorktree.count == 3, perWorktree[0] == "worktrees", perWorktree[2] == "FETCH_HEAD" { return true }
        if inGit == "FETCH_HEAD" || inGit.hasPrefix("refs/remotes/")
            || inGit.hasPrefix("logs/refs/remotes/") || inGit.hasPrefix("refs/tags/")
        {
            return true
        }
        switch kind {
        case .publish: return inGit == "config"
        // A prune's compare-and-deletes rewrite `packed-refs` for a packed tracking ref. Its kept
        // branches (`refs/heads/…`) are left to cost one more reload, like a fast-forward's move.
        case .deleteRemoteBranch, .prune: return inGit == "packed-refs"
        // A remote's rename and removal rewrite the configuration (its section, and every
        // `branch.*` setting naming it) and `packed-refs` (its packed tracking refs). A removal's
        // kept branches cost one more reload, as a prune's do.
        case .renameRemote, .removeRemote: return inGit == "config" || inGit == "packed-refs"
        // A tag's push or remote delete writes nothing here: `refs/tags/…` is already in the
        // first row, and neither updates a remote-tracking ref.
        case .fetch, .autoFetch, .pull, .push, .forcePush, .pushTag, .deleteRemoteTag, .fastForward:
            return false
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
        // Nor does a closed one (RF3): a write it lets finish frees its lane without one.
        guard root != nil, !isClosed else { return }
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
            // The stop of the operation it shows, if any, read before either is written: the bar
            // and the file list must describe the same moment.
            let stop = await Self.readOperationStop(newSnapshot.status, backend: backend, root: root)
            // With no operation, a range git halted part-way (`sequencer/` left behind). A failed
            // read shows nothing rather than failing the snapshot.
            let halted =
                newSnapshot.status.operationInProgress == nil ? (try? await backend.haltedSequence(at: root)) ?? nil : nil
            // The repository may have been switched (via `open`) while this snapshot was in
            // flight; a snapshot from before that must never overwrite the new state.
            guard generation == capturedGeneration else { return }
            setSnapshot(newSnapshot)
            // The worktrees after the snapshot, in their own read, never awaited here (B3 final
            // review, I2): the state before stays until it lands. Never a failure (Task 3).
            scheduleWorktreeStateRead()
            setOperationStop(stop, halted: halted)
            syncDraftWithOperation()
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
