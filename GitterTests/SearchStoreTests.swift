import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// Commit search in the store (F1 Task 2): one debounced, cancellable search per window whose
/// results take over the History column, how it ends (Esc, Stop, a failure, a sidebar click,
/// Compare, Show in History, a close, another repository), how its results stand in for History's
/// rows (the detail header, the merge check), and what a refresh does to it. On real scratch
/// repositories, with `TestBackend` where a search has to be held, failed or counted, and
/// `searchDebounce` at zero.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct SearchStoreTests {

    // MARK: - Helpers

    static func sha(_ repo: ScratchRepo, _ rev: String = "HEAD") throws -> String {
        try repo.git("rev-parse", rev).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// first, "fix the parser", "unrelated", "Fix the lexer" on `main`, newest last.
    static func fixes() throws -> (repo: ScratchRepo, parser: String, lexer: String) {
        let repo = try ScratchRepo()
        do {
            try repo.commit("a.txt", "one\n", "first")
            try repo.commit("b.txt", "parser\n", "fix the parser")
            let parser = try sha(repo)
            try repo.commit("c.txt", "other\n", "unrelated")
            try repo.commit("d.txt", "lexer\n", "Fix the lexer")
            return (repo, parser, try sha(repo))
        } catch {
            repo.remove()
            throw error
        }
    }

    /// A store on `repo`, opened and idle, searching with no debounce.
    static func opened(
        _ repo: ScratchRepo, backend: TestBackend, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> (RepositoryStore, cleanup: () -> Void) {
        let (store, cleanup) = await openedTestStore(repo, backend: backend, sourceLocation: sourceLocation)
        store.searchDebounce = .zero
        return (store, cleanup)
    }

    /// Opens search, picks `mode`, types `query` and waits for the search to land.
    static func search(
        _ store: RepositoryStore, _ query: String, mode: CommitSearchMode = .messageAuthorOrID,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async {
        store.openSearch()
        store.setSearchMode(mode)
        store.setSearchQuery(query)
        await waitUntilIdle(store, sourceLocation: sourceLocation)
    }

    static func rows(_ store: RepositoryStore) -> [String]? {
        store.commitSearch?.result?.commits.map(\.sha)
    }

    static func searchCalls(_ backend: TestBackend) -> Int {
        backend.calls.filter { $0 == .searchCommits }.count
    }

    /// Returns once `task` has ended: a search let go after it was cancelled, which has then had
    /// every chance to land.
    static func finish(_ task: Task<Void, Never>?, sourceLocation: SourceLocation = #_sourceLocation) async {
        guard let task else {
            Issue.record("no search task to finish", sourceLocation: sourceLocation)
            return
        }
        let call = CallUnderTest { () -> Bool in
            await task.value
            return true
        }
        if await call.value("the search task ending", sourceLocation: sourceLocation) == nil { call.cancel() }
    }

    // MARK: - Typing and selecting

    @Test(.timeLimit(.minutes(10))) func typingSearchesAndSelectingShowsDetail() async throws {
        let (repo, parser, lexer) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }

        await Self.search(store, "fix")
        #expect(Self.rows(store) == [lexer, parser])
        #expect(store.commitSearch?.status == .done)
        #expect(store.commitSearch?.query == "fix")
        #expect(Self.searchCalls(backend) == 1)

        let shown = (Self.rows(store) ?? []).map(Selection.commit)
        store.selectRows([.commit(parser)], shown: shown)
        #expect(store.selection == .commit(parser))
        #expect(await waitUntil("the result's detail") { store.detailFiles.map(\.path) == ["b.txt"] })
        #expect(store.commitForDetail(parser)?.summary == "fix the parser")
        // Selecting reads nothing more: the search still stands.
        #expect(Self.rows(store) == [lexer, parser])
    }

    /// A query that differs only in blanks around it is the same search: nothing runs. An empty
    /// one shows no list and runs nothing either.
    @Test(.timeLimit(.minutes(10))) func anUnchangedOrEmptyQueryRunsNothing() async throws {
        let (repo, parser, lexer) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }

        store.openSearch()
        #expect(store.commitSearch?.query == "")
        #expect(store.commitSearch?.status == .idle)
        store.setSearchQuery("   ")
        await waitUntilIdle(store)
        #expect(Self.searchCalls(backend) == 0)
        #expect(store.commitSearch?.result == nil)
        #expect(store.commitSearch?.status == .idle)

        store.setSearchQuery("fix")
        await waitUntilIdle(store)
        #expect(Self.searchCalls(backend) == 1)
        store.setSearchQuery("fix ")
        await waitUntilIdle(store)
        #expect(Self.searchCalls(backend) == 1)
        #expect(store.commitSearch?.query == "fix ")
        #expect(Self.rows(store) == [lexer, parser])

        store.setSearchQuery("")
        await waitUntilIdle(store)
        #expect(Self.searchCalls(backend) == 1)
        #expect(store.commitSearch?.result == nil)
        #expect(store.commitSearch?.status == .idle)
        // Search is still open, with an empty field.
        #expect(store.commitSearch != nil)
    }

    /// Opening search again keeps the search that is open.
    @Test(.timeLimit(.minutes(10))) func openSearchKeepsTheOpenOne() async throws {
        let (repo, parser, lexer) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "fix", mode: .messageAuthorOrID)
        store.openSearch()
        #expect(store.commitSearch?.query == "fix")
        #expect(Self.rows(store) == [lexer, parser])
    }

    /// A mode change searches again with the same text.
    @Test(.timeLimit(.minutes(10))) func aModeChangeSearchesAgain() async throws {
        let (repo, parser, _) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "b.txt", mode: .messageAuthorOrID)
        #expect(Self.rows(store) == [])
        #expect(store.commitSearch?.status == .done)

        store.setSearchMode(.file)
        await waitUntilIdle(store)
        #expect(store.commitSearch?.mode == .file)
        #expect(Self.rows(store) == [parser])
        #expect(Self.searchCalls(backend) == 2)
    }

    @Test(.timeLimit(.minutes(10))) func aNewQueryKeepsOldRowsUntilItLands() async throws {
        let (repo, parser, lexer) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        defer { await releaseAndSettle([backend], [store]) }
        await Self.search(store, "fix")
        #expect(Self.rows(store) == [lexer, parser])

        let gate = backend.hold(.searchCommits)
        store.setSearchQuery("lexer")
        #expect(await waitUntil("the second search parked") { gate.waiting })
        #expect(store.commitSearch?.query == "lexer")
        #expect(store.commitSearch?.status == .searching)
        #expect(Self.rows(store) == [lexer, parser])

        gate.release()
        await waitUntilIdle(store)
        #expect(Self.rows(store) == [lexer])
        #expect(store.commitSearch?.status == .done)
    }

    // MARK: - Stop and failure

    @Test(.timeLimit(.minutes(10))) func stopClearsRows() async throws {
        let (repo, parser, lexer) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        defer { await releaseAndSettle([backend], [store]) }
        await Self.search(store, "fix")
        #expect(Self.rows(store) == [lexer, parser])

        let gate = backend.hold(.searchCommits)
        store.setSearchQuery("lexer")
        #expect(await waitUntil("the search parked") { gate.waiting })
        let running = store.searchTask
        store.stopSearch()
        #expect(store.commitSearch?.result == nil)
        #expect(store.commitSearch?.status == .stopped)
        #expect(store.commitSearch?.query == "lexer")

        // The stopped search, let go, lands nothing.
        gate.release()
        await Self.finish(running)
        #expect(store.commitSearch?.result == nil)
        #expect(store.commitSearch?.status == .stopped)

        // Editing the query searches again.
        store.setSearchQuery("parser")
        await waitUntilIdle(store)
        #expect(Self.rows(store) == [parser])
        #expect(store.commitSearch?.status == .done)
    }

    @Test(.timeLimit(.minutes(10))) func aFailureClearsRowsAndShowsGitsWords() async throws {
        let (repo, parser, lexer) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "fix")
        #expect(Self.rows(store) == [lexer, parser])

        let failure = GitError.commandFailed(exitCode: 128, stderr: "fatal: injected by the test\n")
        backend.fail(.searchCommits, with: failure)
        store.setSearchQuery("lexer")
        await waitUntilIdle(store)
        #expect(store.commitSearch?.result == nil)
        #expect(store.commitSearch?.status == .failed(RepositoryStore.describe(failure)))
        #expect(SearchWording.statusLine(try #require(store.commitSearch)) == "fatal: injected by the test\n")
        // The status line says it: no banner.
        #expect(store.lastError == nil)
        #expect(store.commitSearch != nil)

        // Choosing a mode searches again.
        store.setSearchMode(.file)
        await waitUntilIdle(store)
        #expect(store.commitSearch?.status == .done)
        #expect(Self.rows(store) == [])
    }

    /// A deep result held as the selected commit, then a new search without it: the header reads
    /// the commit on its own (`detailCommit`) instead of falling back to a bare id.
    @Test(.timeLimit(.minutes(10))) func aDeepSelectionKeepsItsHeaderWhenTheRowsGo() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(fixture.repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "o1")
        #expect(Self.rows(store) == [fixture.oldTip])
        store.selectRows([.commit(fixture.oldTip)], shown: [.commit(fixture.oldTip)])
        #expect(await waitUntil("the result's detail") { store.detailFiles.map(\.path) == ["old.txt"] })
        // The header came from the result: no commit read of its own.
        #expect(!backend.calls.contains(.commitByID))

        store.stopSearch()
        #expect(store.commitSearch?.result == nil)
        #expect(await waitUntil("the header's own read") { store.commitForDetail(fixture.oldTip)?.summary == "o1" })
        #expect(backend.calls.contains(.commitByID))
        #expect(store.selection == .commit(fixture.oldTip))
    }

    // MARK: - Leaving

    @Test(.timeLimit(.minutes(10))) func escapeWhileSearchingCancelsAndNothingLandsLater() async throws {
        let (repo, parser, _) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        defer { await releaseAndSettle([backend], [store]) }
        store.select(.commit(parser))
        await waitUntilIdle(store)

        let gate = backend.hold(.searchCommits)
        store.openSearch()
        store.setSearchQuery("fix")
        #expect(await waitUntil("the search parked") { gate.waiting })
        let running = store.searchTask
        store.leaveSearch()
        #expect(store.commitSearch == nil)

        gate.release()
        await Self.finish(running)
        #expect(store.commitSearch == nil)
        #expect(store.selection == .commit(parser))
        #expect(store.pendingReveal == nil)
        #expect(Self.searchCalls(backend) == 1)
    }

    /// P3: a window closed while a search runs — nothing lands, nothing reopens it.
    @Test(.timeLimit(.minutes(10))) func closingTheWindowCancelsTheSearch() async throws {
        let (repo, _, _) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        defer { await releaseAndSettle([backend], [store]) }

        let gate = backend.hold(.searchCommits)
        store.openSearch()
        store.setSearchQuery("fix")
        #expect(await waitUntil("the search parked") { gate.waiting })
        let running = store.searchTask
        store.close()
        #expect(store.commitSearch == nil)

        gate.release()
        await Self.finish(running)
        #expect(store.commitSearch == nil)
        // A closed window opens no search again.
        store.openSearch()
        #expect(store.commitSearch == nil)
    }

    /// Another repository: the search was of the one being left.
    @Test(.timeLimit(.minutes(10))) func openingAnotherRepositoryEndsSearch() async throws {
        let (repo, _, _) = try Self.fixes()
        defer { repo.remove() }
        let other = try ScratchRepo("other")
        defer { other.remove() }
        try other.commit("a.txt", "one\n", "fix elsewhere")
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "fix")
        #expect(store.commitSearch != nil)

        await open(store, other.url)
        #expect(store.commitSearch == nil)
    }

    @Test(.timeLimit(.minutes(10))) func showInHistoryLeavesAndReveals() async throws {
        let (repo, parser, _) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "fix")

        store.showInHistory(parser)
        #expect(store.commitSearch == nil)
        #expect(store.selection == .commit(parser))
        #expect(store.pendingReveal == parser)
    }

    @Test(.timeLimit(.minutes(10))) func aDeepResultHasDetailAndMergeCheck() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(fixture.repo, backend: backend)
        defer { cleanup() }
        #expect(store.snapshot?.commits.contains { $0.sha == fixture.oldTip } == false)
        #expect(store.snapshot?.commits.contains { $0.sha == fixture.deepMerge } == false)
        // Controls: with no search, neither is known.
        #expect(store.commitForDetail(fixture.oldTip) == nil)
        #expect(store.historyBlockedReason(for: [fixture.deepMerge]) == nil)

        await Self.search(store, "o1")
        #expect(Self.rows(store) == [fixture.oldTip])
        #expect(store.detailCommit == nil)
        #expect(store.commitForDetail(fixture.oldTip)?.summary == "o1")
        store.selectRows([.commit(fixture.oldTip)], shown: [.commit(fixture.oldTip)])
        #expect(await waitUntil("the result's detail") { store.detailFiles.map(\.path) == ["old.txt"] })
        #expect(store.historyBlockedReason(for: [fixture.oldTip]) == nil)

        store.setSearchQuery("m160")
        await waitUntilIdle(store)
        #expect(Self.rows(store) == [fixture.deepMerge])
        #expect(store.detailCommit?.sha != fixture.deepMerge)
        #expect(store.historyBlockedReason(for: [fixture.deepMerge]) == HistoryWording.mergesInSelection)
        #expect(store.historyBlockedReason(for: [fixture.oldTip, fixture.deepMerge]) == HistoryWording.mergesInSelection)
    }

    @Test(.timeLimit(.minutes(10))) func leavingWithADeepResultRevealsIt() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(fixture.repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "o1")
        store.selectRows([.commit(fixture.oldTip)], shown: [.commit(fixture.oldTip)])
        await waitUntilIdle(store)

        store.leaveSearch()
        #expect(store.commitSearch == nil)
        #expect(store.selection == .commit(fixture.oldTip))
        #expect(store.pendingReveal == fixture.oldTip)
        await waitUntilIdle(store)
        #expect(store.historyRows.shas.contains(.commit(fixture.oldTip)))
        #expect(store.commitForDetail(fixture.oldTip)?.summary == "o1")
    }

    /// Control for the reveal: a result History has loaded is selected as it is, with no reveal.
    @Test(.timeLimit(.minutes(10))) func leavingWithALoadedResultDoesNotReveal() async throws {
        let (repo, parser, _) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "fix")
        store.selectRows([.commit(parser)], shown: (Self.rows(store) ?? []).map(Selection.commit))
        store.leaveSearch()
        #expect(store.commitSearch == nil)
        #expect(store.selection == .commit(parser))
        #expect(store.pendingReveal == nil)
    }

    // MARK: - Compare and the sidebar

    @Test(.timeLimit(.minutes(10))) func compareAndSearchAreExclusive() async throws {
        let (repo, _, _) = try Self.fixes()
        defer { repo.remove() }
        try repo.git("switch", "-q", "-c", "feature")
        try repo.commit("e.txt", "e\n", "fix on feature")
        try repo.git("switch", "-q", "main")
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }

        await Self.search(store, "fix")
        // A refused comparison leaves the screen as it was: search stays.
        store.compare("refs/heads/main", "refs/heads/nope")
        #expect(await waitUntil("the refusal") { store.lastError != nil })
        #expect(store.comparison == nil)
        #expect(store.commitSearch?.query == "fix")

        store.compare("refs/heads/main", "refs/heads/feature")
        #expect(await waitUntil("the comparison") { store.comparison != nil })
        #expect(store.commitSearch == nil)

        store.openSearch()
        #expect(store.comparison == nil)
        #expect(store.commitSearch?.query == "")
    }

    @Test(.timeLimit(.minutes(10))) func aSidebarClickEndsSearch() async throws {
        let (repo, _, lexer) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "parser")

        store.selectFromSidebar(.commit(lexer))
        #expect(store.commitSearch == nil)
        #expect(store.selection == .commit(lexer))
        #expect(store.pendingReveal == lexer)
    }

    // MARK: - Refresh

    @Test(.timeLimit(.minutes(10))) func aRefChangeRerunsMessageSearchKeepingSelection() async throws {
        let (repo, parser, lexer) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "fix")
        store.selectRows([.commit(parser)], shown: (Self.rows(store) ?? []).map(Selection.commit))
        await waitUntilIdle(store)
        let calls = Self.searchCalls(backend)

        try repo.commit("e.txt", "printer\n", "fix the printer")
        let printer = try Self.sha(repo)
        await store.refresh()
        await waitUntilIdle(store)
        #expect(Self.searchCalls(backend) == calls + 1)
        #expect(Self.rows(store) == [printer, lexer, parser])
        #expect(store.commitSearch?.status == .done)
        #expect(store.selection == .commit(parser))
    }

    /// A commit on a detached HEAD moves no branch or tag, yet History (`--all` takes HEAD) gains
    /// it: the search runs again too.
    @Test(.timeLimit(.minutes(10))) func aCommitOnADetachedHeadRerunsTheSearch() async throws {
        let (repo, parser, lexer) = try Self.fixes()
        defer { repo.remove() }
        try repo.git("switch", "-q", "--detach")
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "fix")
        let calls = Self.searchCalls(backend)
        let refs = store.snapshot?.refs

        try repo.commit("e.txt", "printer\n", "fix the printer")
        let printer = try Self.sha(repo)
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.snapshot?.refs == refs)
        #expect(Self.searchCalls(backend) == calls + 1)
        #expect(Self.rows(store) == [printer, lexer, parser])
    }

    @Test(.timeLimit(.minutes(10))) func aRefChangeMarksCodeSearchStale() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.commit("b.txt", "a needle here\n", "add it")
        let added = try Self.sha(repo)
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "needle", mode: .code)
        #expect(Self.rows(store) == [added])
        #expect(store.commitSearch?.isStale == false)
        let calls = Self.searchCalls(backend)
        let loads = store.snapshotLoadCount

        try repo.commit("c.txt", "another needle\n", "add another")
        let another = try Self.sha(repo)
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.snapshotLoadCount > loads)
        #expect(store.commitSearch?.isStale == true)
        #expect(Self.rows(store) == [added])
        #expect(store.commitSearch?.status == .done)
        #expect(Self.searchCalls(backend) == calls)
        #expect(SearchWording.staleLine(try #require(store.commitSearch)) == SearchWording.stale)

        store.searchAgain()
        await waitUntilIdle(store)
        #expect(store.commitSearch?.isStale == false)
        #expect(Self.rows(store) == [another, added])
        #expect(Self.searchCalls(backend) == calls + 1)
    }

    @Test(.timeLimit(.minutes(10))) func aRefreshWithoutRefChangeRunsNothing() async throws {
        let (repo, _, _) = try Self.fixes()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        await Self.search(store, "fix")
        let calls = Self.searchCalls(backend)
        let loads = store.snapshotLoadCount

        try repo.write("a.txt", "edited\n")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.snapshotLoadCount > loads)
        #expect(store.snapshot?.status.files.map(\.path) == ["a.txt"])
        #expect(Self.searchCalls(backend) == calls)

        // Control: a commit, which moves `main`, does run it.
        try repo.git("commit", "-qam", "fix the edit")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(Self.searchCalls(backend) == calls + 1)
        #expect(Self.rows(store)?.count == 3)
    }

    // MARK: - When it is off

    @Test(.timeLimit(.minutes(10))) func searchIsOffUnderASheetAndInFocusMode() async throws {
        // No repository.
        let (bare, _, bareCleanup) = makeTestStore()
        defer { bareCleanup() }
        #expect(bare.searchBlockedReason == SearchWording.noRepository)

        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await Self.opened(repo, backend: backend)
        defer { cleanup() }
        #expect(store.searchBlockedReason == nil)

        store.activeSheet = .rename("main")
        #expect(store.searchBlockedReason == SearchWording.blockedBySheet)
        store.openSearch()
        #expect(store.commitSearch == nil)
        store.activeSheet = nil
        #expect(store.searchBlockedReason == nil)

        _ = try #require(await ResolverStoreTests.openDraft(store))
        #expect(store.resolverFocus != nil)
        #expect(store.searchBlockedReason == SearchWording.blockedInFocusMode)
        store.openSearch()
        #expect(store.commitSearch == nil)
    }
}
