import Foundation
import Testing

@testable import Gitter

/// Returns once `store` has nothing in flight: no mutation, no network lane, no worktree read, no
/// queued reload, and the last scheduled reload (`refreshTask`) has ended — the very task seen
/// before waiting, not one that replaced it meanwhile (`scheduleRefresh` replaces it, and a wait on
/// the old task returns at once). Polls every 20 ms, with no bound of its own: a hang is the
/// test's `.timeLimit`, ending the wait through `CallUnderTest`, which records `neverCameBack`
/// (E1 pattern); that includes the wait on `refreshTask`, which nothing else can end.
///
/// A change made outside the store (the test's own `git`) is followed by `await store.refresh()`
/// and then this; the watcher's 300 ms debounce is not waited for.
@MainActor
func waitUntilIdle(_ store: RepositoryStore, sourceLocation: SourceLocation = #_sourceLocation) async {
    @MainActor func quiet() -> Bool {
        !store.isMutating && store.remoteActivity == nil && !store.isReadingWorktreeState && !store.refreshIsQueued
    }
    let call = CallUnderTest { @MainActor () -> Bool in
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
            guard quiet() else { continue }
            // The reload the watcher scheduled, sleeping out its debounce or running.
            let seen = store.refreshTask
            if let seen { await seen.value }
            if quiet(), store.refreshTask == seen { return true }
        }
        return false
    }
    if await call.value("the store going idle", sourceLocation: sourceLocation) == nil {
        // The wait was cancelled: stop the poll it left behind.
        call.cancel()
    }
}

/// A store on `repo`, opened and idle, with the first snapshot in. `cleanup` removes its scratch
/// defaults (the repository is `repo.remove()`'s). If `open` fails (`lastError`), that is recorded
/// as an issue at the caller's `sourceLocation` and the wait ends at once.
@MainActor
func openedTestStore(
    _ repo: ScratchRepo, sourceLocation: SourceLocation = #_sourceLocation
) async -> (RepositoryStore, cleanup: () -> Void) {
    let (store, _, cleanup) = makeTestStore()
    store.open(repo.url)
    // `open` starts its first load in a task of its own; it is idle only once a snapshot is in.
    let first = CallUnderTest { @MainActor () -> Bool in
        while store.snapshot == nil, store.lastError == nil, !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return store.snapshot != nil
    }
    let opened = await first.value("the first snapshot", sourceLocation: sourceLocation)
    if opened == nil { first.cancel() }
    if let error = store.lastError {
        Issue.record("open failed: \(error)", sourceLocation: sourceLocation)
        return (store, cleanup)
    }
    await waitUntilIdle(store, sourceLocation: sourceLocation)
    return (store, cleanup)
}
