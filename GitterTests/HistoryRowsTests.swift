import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// The commit table's rows (H1 Task 2, `HistoryRows`): built once per snapshot in `setSnapshot`,
/// with the end row after the last commit — none with no commits — and a graph width that never
/// shrinks while the repository stays open. The end row is never a selection.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct HistoryRowsTests {
    static let a = "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d"
    static let b = "2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e"

    static func commit(_ sha: String, parents: [String] = []) -> Commit {
        Commit(
            sha: sha, parents: parents, authorName: "Tester", authorEmail: "t@t",
            authorDate: Date(timeIntervalSince1970: 0), summary: "c", refs: [])
    }

    static func snapshot(
        commits: [Commit], graph: [GraphRow] = [], files: [FileStatus] = [], complete: Bool = true
    ) -> RepoSnapshot {
        RepoSnapshot(
            root: URL(fileURLWithPath: "/nonexistent"),
            status: WorkingCopyStatus(
                headSha: commits.first?.sha, branch: "main", upstream: nil, ahead: 0, behind: 0, files: files),
            refs: RefCollection(localBranches: [], remoteBranches: [], tags: []),
            commits: commits, graph: graph, historyIsComplete: complete)
    }

    // MARK: - Pure

    /// RF1: an empty repository has no end row (the empty state, as today); a history that ends
    /// says so after its last commit, and one that may go on says it is loading.
    @Test func emptySnapshotHasNoEndRow() {
        #expect(HistoryRows.build(nil, previousWidth: nil).rows.isEmpty)
        #expect(HistoryRows.build(Self.snapshot(commits: []), previousWidth: nil).rows.isEmpty)

        let complete = HistoryRows.build(Self.snapshot(commits: [Self.commit(Self.a)]), previousWidth: nil)
        #expect(complete.rows.count == 2)
        #expect(complete.rows.last == .end(complete: true))
        #expect(complete.shas == [.commit(Self.a)])

        let more = HistoryRows.build(
            Self.snapshot(commits: [Self.commit(Self.a)], complete: false), previousWidth: nil)
        #expect(more.rows.last == .end(complete: false))
        #expect(more.rows.last?.id == .historyEnd)
    }

    /// The working-copy row, the commits with their graph rows, the end row; `shas` is every
    /// selectable row's id in order, which the end row's is not.
    @Test func rowsAreTheWorkingCopyTheCommitsAndTheEnd() {
        let graph = [
            GraphRow(sha: Self.a, lane: 0, edges: [GraphEdge(fromLane: 0, toLane: 0, fromAbove: false)], laneCount: 1),
            GraphRow(sha: Self.b, lane: 0, edges: [], laneCount: 1),
        ]
        let file = FileStatus(path: "f.txt", originalPath: nil, staged: nil, unstaged: .modified)
        let rows = HistoryRows.build(
            Self.snapshot(commits: [Self.commit(Self.a, parents: [Self.b]), Self.commit(Self.b)], graph: graph, files: [file]),
            previousWidth: nil)
        #expect(rows.rows.count == 4)
        #expect(rows.rows.first == .workingCopy(changeCount: 1))
        #expect(rows.shas == [.workingCopy, .commit(Self.a), .commit(Self.b)])
        guard case .commit(let second, let row, let incoming) = rows.rows[2] else {
            Issue.record("row 2 is \(rows.rows[2])")
            return
        }
        #expect(second.sha == Self.b)
        #expect(row == graph[1])
        #expect(incoming)
        #expect(rows.graphWidth == CommitGraphCell.contentWidth(for: graph))
    }

    @Test func widthNeverShrinksAtTheSameDepth() {
        let wide = [GraphRow(sha: Self.a, lane: 0, edges: [], laneCount: 4)]
        let narrow = [GraphRow(sha: Self.a, lane: 0, edges: [], laneCount: 1)]
        let commits = [Self.commit(Self.a)]
        let first = HistoryRows.build(Self.snapshot(commits: commits, graph: wide), previousWidth: nil)
        let fresh = HistoryRows.build(Self.snapshot(commits: commits, graph: narrow), previousWidth: nil)
        #expect(fresh.graphWidth < first.graphWidth)
        let kept = HistoryRows.build(Self.snapshot(commits: commits, graph: narrow), previousWidth: first.graphWidth)
        #expect(kept.graphWidth == first.graphWidth)
        let wider = HistoryRows.build(Self.snapshot(commits: commits, graph: wide), previousWidth: fresh.graphWidth)
        #expect(wider.graphWidth == first.graphWidth)
    }

    @Test func endRowIsNeverResolvedAsASelection() {
        #expect(CommitSelection.resolve([.historyEnd], previous: [.workingCopy], shown: [.workingCopy]) == nil)
        let both = CommitSelection.resolve(
            [.historyEnd, .commit(Self.a)], previous: [.workingCopy], shown: [.workingCopy, .commit(Self.a)])
        #expect(both == CommitSelection.Resolved(detail: .commit(Self.a), commits: [Self.a]))
        #expect(CommitSelection.table(selection: .historyEnd, commits: []).isEmpty)
    }

    // MARK: - In the store

    /// One build per snapshot set — not per selection, notice or read of the rows.
    @Test(.timeLimit(.minutes(10))) func rowsBuiltOncePerSnapshot() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.commit("a.txt", "two\n", "second")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let builds = store.historyRowsBuilds
        let loads = store.snapshotLoadCount
        #expect(builds >= 1)
        let rows = store.historyRows

        let sha = try #require(store.snapshot?.commits.first?.sha)
        store.select(.commit(sha))
        store.select(.workingCopy)
        store.showNotice("hello")
        await waitUntilIdle(store)
        _ = store.historyRows
        #expect(store.historyRowsBuilds == builds + (store.snapshotLoadCount - loads))
        #expect(store.historyRows == rows)

        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.historyRowsBuilds == builds + (store.snapshotLoadCount - loads))
        #expect(store.historyRowsBuilds > builds)
    }

    /// RF1 in the store: an empty repository shows no rows at all.
    @Test(.timeLimit(.minutes(10))) func anEmptyRepositoryHasNoRows() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        #expect(store.snapshot?.commits.isEmpty == true)
        #expect(store.historyRows.rows.isEmpty)
    }

    /// The column keeps its width when a refresh needs fewer lanes, and `open()` resets it.
    @Test(.timeLimit(.minutes(10))) func widthNeverShrinksInTheStoreUntilOpen() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        for name in ["b1", "b2", "b3"] {
            try repo.git("switch", "-q", "-c", name, "main")
            try repo.commit("\(name).txt", "x\n", name)
        }
        try repo.git("switch", "-q", "main")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let wide = store.historyRows.graphWidth

        for name in ["b1", "b2", "b3"] { try repo.git("branch", "-q", "-D", name) }
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.snapshot?.commits.count == 1)
        #expect(CommitGraphCell.contentWidth(for: store.snapshot?.graph ?? []) < wide)
        #expect(store.historyRows.graphWidth == wide)

        await open(store, repo.url)
        #expect(store.historyRows.graphWidth < wide)
    }

    /// The table handing the end row in changes nothing.
    @Test(.timeLimit(.minutes(10))) func endRowIsNotSelectable() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        try repo.commit("a.txt", "two\n", "second")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let sha = try #require(store.snapshot?.commits.first?.sha)
        let shown = store.historyRows.rows.map(\.id)
        #expect(shown.last == .historyEnd)
        store.selectRows([.commit(sha)], shown: shown)
        #expect(store.selection == .commit(sha))

        store.selectRows([.historyEnd], shown: shown)
        #expect(store.selection == .commit(sha))
        #expect(store.selectedCommits == [sha])
        store.select(.historyEnd)
        #expect(store.selection == .commit(sha))
    }
}
