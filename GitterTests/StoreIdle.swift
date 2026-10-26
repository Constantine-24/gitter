import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// Returns once `store` has nothing in flight: no mutation, no network lane, no worktree read, no
/// queued reload, no load-more (`isLoadingOlderCommits`) and no reveal (`revealTask`, H1 Task 2:
/// its row read runs before any reload is queued), and the last scheduled reload (`refreshTask`)
/// has ended — the very task seen before waiting, not one that replaced it meanwhile
/// (`scheduleRefresh` replaces it, and a wait on the old task returns at once). Polls every 20 ms, with no bound of its own: a hang is the
/// test's `.timeLimit`, ending the wait through `CallUnderTest`, which records `neverCameBack`
/// (E1 pattern); that includes the wait on `refreshTask`, which nothing else can end.
///
/// A change made outside the store (the test's own `git`) is followed by `await store.refresh()`
/// and then this; the watcher's 300 ms debounce is not waited for.
@MainActor
func waitUntilIdle(_ store: RepositoryStore, sourceLocation: SourceLocation = #_sourceLocation) async {
    @MainActor func quiet() -> Bool {
        !store.isMutating && store.remoteActivity == nil && !store.isReadingWorktreeState && !store.refreshIsQueued
            && !store.isLoadingOlderCommits
    }
    let call = CallUnderTest { @MainActor () -> Bool in
        while !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
            // A reveal reads its row, then reloads: both inside its task.
            if let reveal = store.revealTask { await reveal.value }
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
/// as an issue at the caller's `sourceLocation` and the wait ends at once. `backend` is real git
/// unless the test hands in its own (a `TestBackend`, E3 Task 3).
@MainActor
func openedTestStore(
    _ repo: ScratchRepo, backend: RepositoryStore.Backend = CLIGitBackend(),
    sourceLocation: SourceLocation = #_sourceLocation
) async -> (RepositoryStore, cleanup: () -> Void) {
    let (store, _, cleanup) = makeTestStore(backend: backend)
    await open(store, repo.url, sourceLocation: sourceLocation)
    return (store, cleanup)
}

/// Opens `url` in `store` and returns once the first snapshot is in and the store is idle — or at
/// once, with an issue at `sourceLocation`, if `open` fails (`lastError`). What `openedTestStore`
/// does for its own store, for a store made elsewhere (a `WindowRegistry`'s, E2 Task 3).
@MainActor
func open(_ store: RepositoryStore, _ url: URL, sourceLocation: SourceLocation = #_sourceLocation) async {
    store.open(url)
    // `open` starts its first load in a task of its own; it is idle only once a snapshot is in.
    await waitUntil("the first snapshot", sourceLocation: sourceLocation) {
        store.snapshot != nil || store.lastError != nil
    }
    if let error = store.lastError {
        Issue.record("open failed: \(error)", sourceLocation: sourceLocation)
        return
    }
    await waitUntilIdle(store, sourceLocation: sourceLocation)
}

/// Returns once `condition` holds, polled every 20 ms on the main actor, and says whether it does.
/// No bound of its own: a condition that never comes is the test's `.timeLimit`, ending the wait
/// through `CallUnderTest`, which records `neverCameBack` with `what` in it (E1 pattern). The one
/// poll the waits below are made of.
@MainActor
@discardableResult
func waitUntil(
    _ what: String, sourceLocation: SourceLocation = #_sourceLocation,
    _ condition: @escaping @MainActor () -> Bool
) async -> Bool {
    let call = CallUnderTest { @MainActor () -> Bool in
        while !condition(), !Task.isCancelled {
            try? await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }
    guard let met = await call.value(what, sourceLocation: sourceLocation) else {
        // The wait was cancelled: stop the poll it left behind.
        call.cancel()
        return false
    }
    return met
}

/// Returns once `store` has no git write left running: its lane free and its change ended — or,
/// for a closed store, its lane free (a closed store's change ends unseen, B3.1). A test's
/// teardown waits on this (`releaseAndSettle`), so that a released write does not race the
/// removal of its repository and bare remote (final review M2, as Ruling 10 did in Task 6).
@MainActor
func waitUntilSettled(_ store: RepositoryStore, sourceLocation: SourceLocation = #_sourceLocation) async {
    await waitUntil("the store's git work ending", sourceLocation: sourceLocation) {
        store.remoteActivity == nil && (!store.isMutating || store.isClosed)
    }
}

/// A test's teardown with `TestBackend` holds: releases every hold of `backends`
/// (`TestBackend.releaseAll`) and returns once each of `stores` has settled (`waitUntilSettled`).
/// Declared as `defer { await releaseAndSettle(…) }` after the repository's and the registry's
/// own `defer`s, so that it runs before them — and after a `defer` that ends a store's
/// terminating, whose held follow-up fetch it then waits for too.
@MainActor
func releaseAndSettle(
    _ backends: [TestBackend], _ stores: [RepositoryStore], sourceLocation: SourceLocation = #_sourceLocation
) async {
    for backend in backends { backend.releaseAll() }
    for store in stores { await waitUntilSettled(store, sourceLocation: sourceLocation) }
}

/// Returns once `store`'s network lane is free (E2 Task 3).
@MainActor
func waitUntilLaneFree(_ store: RepositoryStore, sourceLocation: SourceLocation = #_sourceLocation) async {
    await waitUntil("the lane freeing", sourceLocation: sourceLocation) { store.remoteActivity == nil }
}

/// Returns once `store` has left `registry.stores` (E2 Task 3).
@MainActor
func waitUntilGone(
    _ store: RepositoryStore, from registry: WindowRegistry, sourceLocation: SourceLocation = #_sourceLocation
) async {
    await waitUntil("the closed store leaving the registry", sourceLocation: sourceLocation) {
        !registry.stores.contains { $0 === store }
    }
}
