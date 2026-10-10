import Foundation
import Testing

@testable import Gitter

/// Returns once `store` has nothing in flight: no mutation, no network lane, no worktree read, no
/// queued reload, and the last scheduled reload (`refreshTask`) has ended. Polls every 20 ms, with
/// no bound of its own: a hang is the test's `.timeLimit`, ending the wait through
/// `CallUnderTest`, which records `neverCameBack` (E1 pattern).
///
/// A change made outside the store (the test's own `git`) is followed by `await store.refresh()`
/// and then this; the watcher's 300 ms debounce is not waited for.
@MainActor
func waitUntilIdle(_ store: RepositoryStore, sourceLocation: SourceLocation = #_sourceLocation) async {
    let call = CallUnderTest { @MainActor () -> Bool in
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
            if !store.isMutating, store.remoteActivity == nil, !store.isReadingWorktreeState, !store.refreshIsQueued {
                // The reload the watcher scheduled, sleeping out its debounce or running.
                if let task = store.refreshTask { await task.value }
                if !store.isMutating, store.remoteActivity == nil, !store.isReadingWorktreeState, !store.refreshIsQueued {
                    return true
                }
            }
        }
        return false
    }
    if await call.value("the store going idle", sourceLocation: sourceLocation) == nil {
        // The wait was cancelled: stop the poll it left behind.
        call.cancel()
    }
}

/// A store on `repo`, opened and idle, with the first snapshot in. `cleanup` removes its scratch
/// defaults (the repository is `repo.remove()`'s).
@MainActor
func openedTestStore(_ repo: ScratchRepo) async -> (RepositoryStore, cleanup: () -> Void) {
    let (store, _, cleanup) = makeTestStore()
    store.open(repo.url)
    // `open` starts its first load in a task of its own; it is idle only once a snapshot is in.
    let first = CallUnderTest { @MainActor () -> Bool in
        while store.snapshot == nil, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(20)) }
        return store.snapshot != nil
    }
    if await first.value("the first snapshot") == nil { first.cancel() }
    await waitUntilIdle(store)
    return (store, cleanup)
}
