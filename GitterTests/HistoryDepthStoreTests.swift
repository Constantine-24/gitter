import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// History's depth in the store (H1 Task 2): a load-more raises it a page at a time and every
/// refresh keeps it, `open()` puts it back to one page, and a reveal — a sidebar click, Done on a
/// comparison — selects a commit that isn't loaded at once, then loads down to its row and leaves
/// `pendingReveal` for the table's scroll. On real scratch repositories (`DeepHistory`), with
/// `TestBackend` where a call has to be held, counted or answered.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct HistoryDepthStoreTests {

    // MARK: - Depth

    @Test(.timeLimit(.minutes(10))) func loadMoreRaisesAndRefreshKeepsDepth() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let (store, cleanup) = await openedTestStore(fixture.repo)
        defer { cleanup() }
        #expect(store.historyDepth == HistoryDepth.page)
        #expect(store.snapshot?.commits.count == 500)

        store.loadOlderCommits()
        #expect(store.isLoadingOlderCommits)
        await waitUntilIdle(store)
        #expect(!store.isLoadingOlderCommits)
        #expect(store.historyDepth == 1000)
        #expect(store.snapshot?.commits.count == 1000)
        #expect(store.historyRows.rows.last == .end(.loading))

        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.historyDepth == 1000)
        #expect(store.snapshot?.commits.count == 1000)
    }

    /// RF3: another repository opens at one page, with no reveal left from the one before — also
    /// when a reveal was still reading where its commit is.
    @Test(.timeLimit(.minutes(10))) func openResetsDepth() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let other = try ScratchRepo()
        defer { other.remove() }
        try other.commit("a.txt", "one\n", "first")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(fixture.repo, backend: backend)
        defer { cleanup() }
        defer { backend.releaseAll() }
        store.loadOlderCommits()
        await waitUntilIdle(store)
        #expect(store.historyDepth == 1000)

        // The root is past row 1000: its reveal reads its row, held here, as `open()` runs.
        let gate = backend.hold(.historyRow)
        store.reveal(fixture.root)
        #expect(await waitUntil("the row read parked") { gate.waiting })
        #expect(store.pendingReveal == fixture.root)

        await open(store, other.url)
        #expect(store.pendingReveal == nil)
        gate.release()
        await waitUntilIdle(store)
        #expect(store.historyDepth == HistoryDepth.page)
        #expect(store.snapshot?.historyDepth == HistoryDepth.page)
        #expect(store.pendingReveal == nil)
        #expect(store.notice == nil)
        #expect(store.selection == .workingCopy)
    }

    @Test(.timeLimit(.minutes(10))) func completeHistoryStopsLoading() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.fastImport(DeepHistory.linear(600))
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        #expect(store.snapshot?.historyIsComplete == false)
        #expect(store.historyRows.rows.last == .end(.loading))

        store.loadOlderCommits()
        await waitUntilIdle(store)
        #expect(store.snapshot?.historyIsComplete == true)
        #expect(store.snapshot?.commits.count == 600)
        #expect(store.historyRows.rows.last == .end(.complete))

        let loads = store.snapshotLoadCount
        store.loadOlderCommits()
        #expect(!store.isLoadingOlderCommits)
        await waitUntilIdle(store)
        #expect(store.snapshotLoadCount == loads)
        #expect(store.historyDepth == 1000)
    }

    @Test(.timeLimit(.minutes(10))) func queuedLoadMoreIsNotDoubled() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let (store, cleanup) = await openedTestStore(fixture.repo)
        defer { cleanup() }
        store.loadOlderCommits()
        store.loadOlderCommits()
        await waitUntilIdle(store)
        #expect(store.historyDepth == 1000)
        #expect(store.snapshot?.historyDepth == 1000)
    }

    /// RF2: a refresh (a watcher event) lands while a load-more is queued: one deeper list, never
    /// a depth that went back, and at most two loads.
    @Test(.timeLimit(.minutes(10))) func refreshDuringLoadMore() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let (store, cleanup) = await openedTestStore(fixture.repo)
        defer { cleanup() }
        let loads = store.snapshotLoadCount
        store.loadOlderCommits()
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.historyDepth == 1000)
        #expect(store.snapshot?.commits.count == 1000)
        #expect(store.snapshotLoadCount - loads <= 2)
        #expect(store.snapshotLoadCount - loads >= 1)
    }

    // MARK: - Reveal

    @Test(.timeLimit(.minutes(10))) func revealSelectsAtOnceThenLoadsToTheRow() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let (store, cleanup) = await openedTestStore(fixture.repo)
        defer { cleanup() }
        #expect(!store.historyRows.shas.contains(.commit(fixture.oldTip)))

        store.reveal(fixture.oldTip)
        #expect(store.selection == .commit(fixture.oldTip))
        #expect(store.pendingReveal == fixture.oldTip)

        await waitUntilIdle(store)
        #expect(store.historyDepth == 1000)
        #expect(store.historyRows.shas.contains(.commit(fixture.oldTip)))
        #expect(store.selection == .commit(fixture.oldTip))
        #expect(store.pendingReveal == fixture.oldTip)

        // The view scrolled: it says so, and the reveal is over.
        store.revealHandled("0000000000000000000000000000000000000000")
        #expect(store.pendingReveal == fixture.oldTip)
        store.revealHandled(fixture.oldTip)
        #expect(store.pendingReveal == nil)
    }

    /// A sidebar click is a reveal (`selectFromSidebar`).
    @Test(.timeLimit(.minutes(10))) func sidebarClickReveals() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let (store, cleanup) = await openedTestStore(fixture.repo)
        defer { cleanup() }
        store.selectFromSidebar(.commit(fixture.oldTip))
        #expect(store.pendingReveal == fixture.oldTip)
        await waitUntilIdle(store)
        #expect(store.historyRows.shas.contains(.commit(fixture.oldTip)))
        #expect(store.pendingReveal == fixture.oldTip)
    }

    @Test(.timeLimit(.minutes(10))) func selectionElsewhereClearsReveal() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let (store, cleanup) = await openedTestStore(fixture.repo)
        defer { cleanup() }
        store.reveal(fixture.oldTip)
        #expect(store.pendingReveal == fixture.oldTip)
        store.select(.workingCopy)
        #expect(store.pendingReveal == nil)
        await waitUntilIdle(store)
        #expect(store.pendingReveal == nil)
        #expect(store.selection == .workingCopy)
    }

    /// RF4: a commit already loaded is selected as today — no reload, no row read.
    @Test(.timeLimit(.minutes(10))) func revealOfALoadedCommitDoesNotReload() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(fixture.repo, backend: backend)
        defer { cleanup() }
        let loaded = try #require(store.snapshot?.commits[400].sha)
        let loads = store.snapshotLoadCount

        store.reveal(loaded)
        await waitUntilIdle(store)
        #expect(store.selection == .commit(loaded))
        #expect(store.snapshotLoadCount == loads)
        #expect(!backend.calls.contains(.historyRow))
        #expect(store.historyDepth == HistoryDepth.page)
    }

    /// RF5: a second old commit clicked while the first's reveal runs wins.
    @Test(.timeLimit(.minutes(10))) func secondRevealWins() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let (store, cleanup) = await openedTestStore(fixture.repo)
        defer { cleanup() }
        store.reveal(fixture.oldTip)
        store.reveal(fixture.root)
        await waitUntilIdle(store)
        #expect(store.selection == .commit(fixture.root))
        #expect(store.pendingReveal == fixture.root)
        #expect(store.historyRows.shas.contains(.commit(fixture.root)))
        #expect(store.notice == nil)
    }

    @Test(.timeLimit(.minutes(10))) func stashOnlyCommitGivesNotice() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.commit("a.txt", "two\n", "second")
        try repo.write("a.txt", "three\n")
        try repo.git("stash")
        let stash = try repo.git("rev-parse", "refs/stash").trimmingCharacters(in: .whitespacesAndNewlines)
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.reveal(stash)
        await waitUntilIdle(store)
        #expect(store.notice?.text == HistoryWording.notInHistory(shortSha: String(stash.prefix(7))))
        #expect(store.selection == .commit(stash))
        // Nothing will ever scroll to it.
        #expect(store.pendingReveal == nil)
        #expect(store.historyDepth == HistoryDepth.page)
    }

    @Test(.timeLimit(.minutes(10))) func beyondCapGivesNotice() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(fixture.repo, backend: backend)
        defer { cleanup() }
        backend.replaceHistoryRow { _, _, _ in 60_000 }
        let loads = store.snapshotLoadCount

        store.reveal(fixture.oldTip)
        await waitUntilIdle(store)
        #expect(backend.calls.contains(.historyRow))
        #expect(store.notice?.text == HistoryWording.beyondCap(shortSha: String(fixture.oldTip.prefix(7))))
        #expect(store.historyDepth == HistoryDepth.page)
        #expect(store.snapshotLoadCount == loads)
        #expect(store.selection == .commit(fixture.oldTip))
        #expect(store.pendingReveal == nil)
    }

    /// The header of a commit that isn't loaded comes from the one-commit read, as soon as the
    /// detail lands — not when the deep load does (held here).
    @Test(.timeLimit(.minutes(10))) func unloadedCommitHeaderReadsTheCommit() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(fixture.repo, backend: backend)
        defer { cleanup() }
        defer { backend.releaseAll() }
        #expect(store.commitForDetail(fixture.oldTip) == nil)

        let gate = backend.hold(.snapshot)
        store.reveal(fixture.oldTip)
        #expect(await waitUntil("the header's commit read") { store.commitForDetail(fixture.oldTip) != nil })
        #expect(gate.waiting)
        #expect(store.snapshot?.commits.contains { $0.sha == fixture.oldTip } == false)
        #expect(store.commitForDetail(fixture.oldTip)?.summary == "o1")
        #expect(backend.calls.contains(.commitByID))

        gate.release()
        await waitUntilIdle(store)
        #expect(store.historyRows.shas.contains(.commit(fixture.oldTip)))
        #expect(store.commitForDetail(fixture.oldTip)?.summary == "o1")
    }

    /// BACKLOG 1074: Done on a comparison whose selected commit isn't in the history loads down to
    /// it.
    @Test(.timeLimit(.minutes(10))) func doneRevealsACompareSelection() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let (store, cleanup) = await openedTestStore(fixture.repo)
        defer { cleanup() }
        store.compare("refs/heads/main", "refs/heads/old")
        #expect(await waitUntil("the comparison") { store.comparison != nil })
        #expect(store.comparison?.commitsOnlyB.map(\.sha) == [fixture.oldTip])
        store.select(.commit(fixture.oldTip))
        await waitUntilIdle(store)
        #expect(!store.historyRows.shas.contains(.commit(fixture.oldTip)))

        store.endComparison()
        #expect(store.comparison == nil)
        #expect(store.selection == .commit(fixture.oldTip))
        #expect(store.pendingReveal == fixture.oldTip)
        await waitUntilIdle(store)
        #expect(store.historyDepth >= 1000)
        #expect(store.historyRows.shas.contains(.commit(fixture.oldTip)))
        #expect(store.pendingReveal == fixture.oldTip)
    }

    /// `historyBlockedReason`'s merge test reads the selected commits themselves, so a merge that
    /// isn't loaded yet — a reveal's deep load still running, held here — is still found.
    @Test(.timeLimit(.minutes(10))) func mergeTestReadsAnUnloadedSelection() async throws {
        let fixture = try DeepHistory.make()
        defer { fixture.repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(fixture.repo, backend: backend)
        defer { cleanup() }
        defer { backend.releaseAll() }
        #expect(store.snapshot?.commits.contains { $0.sha == fixture.deepMerge } == false)

        let gate = backend.hold(.snapshot)
        store.reveal(fixture.deepMerge)
        #expect(await waitUntil("the header's commit read") { store.commitForDetail(fixture.deepMerge) != nil })
        #expect(gate.waiting)
        #expect(store.historyBlockedReason(for: [fixture.deepMerge]) == HistoryWording.mergesInSelection)

        gate.release()
        await waitUntilIdle(store)
        #expect(store.historyBlockedReason(for: [fixture.deepMerge]) == HistoryWording.mergesInSelection)
    }
}

/// The deep-history fixture, one `fast-import` stream into a `ScratchRepo` (H1 Task 2): `main`
/// m1…m1100 a minute apart; `old`, one commit o1 forked from m200 and never merged (about row 900
/// of the history); and s1, forked from m150 and merged into main at m160 (a merge about row 940).
/// 1,102 commits.
struct DeepHistory {
    let repo: ScratchRepo
    /// o1, the tip of `old`.
    let oldTip: String
    /// m160, the merge of s1.
    let deepMerge: String
    /// m1, the root: the last row.
    let root: String

    static func time(_ n: Int) -> Int { 1_700_000_000 + n * 60 }

    static func commit(_ branch: String, mark: Int, time: Int, message: String, from: Int?, merge: Int? = nil) -> String {
        var text = "commit refs/heads/\(branch)\nmark :\(mark)\n"
        text += "author Tester <t@t> \(time) +0000\ncommitter Tester <t@t> \(time) +0000\n"
        text += "data \(message.utf8.count)\n\(message)\n"
        if let from { text += "from :\(from)\n" }
        if let merge { text += "merge :\(merge)\n" }
        let blob = "\(mark)\n"
        text += "M 100644 inline \(branch).txt\ndata \(blob.utf8.count)\n\(blob)\n"
        return text
    }

    /// `count` commits on `main`, m1 to m<count>.
    static func linear(_ count: Int) -> String {
        (1...count).map { commit("main", mark: $0, time: time($0), message: "m\($0)", from: $0 == 1 ? nil : $0 - 1) }
            .joined()
    }

    static func make() throws -> DeepHistory {
        let repo = try ScratchRepo()
        var stream = ""
        for n in 1...1100 {
            if n == 151 {
                stream += commit("s", mark: 5_002, time: time(150) + 30, message: "s1", from: 150)
            }
            if n == 201 {
                stream += commit("old", mark: 5_001, time: time(200) + 30, message: "o1", from: 200)
            }
            stream += commit(
                "main", mark: n, time: time(n), message: "m\(n)", from: n == 1 ? nil : n - 1,
                merge: n == 160 ? 5_002 : nil)
        }
        do {
            try repo.fastImport(stream)
            // s1 is reached through the merge alone.
            try repo.git("update-ref", "-d", "refs/heads/s")
            func sha(_ rev: String) throws -> String {
                try repo.git("rev-parse", rev).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            return DeepHistory(
                repo: repo, oldTip: try sha("refs/heads/old"), deepMerge: try sha("refs/heads/main~940"),
                root: try sha("refs/heads/main~1099"))
        } catch {
            repo.remove()
            throw error
        }
    }
}
