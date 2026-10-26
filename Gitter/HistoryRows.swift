import CoreGraphics
import GitCore

/// One line of the commit table: the synthetic working-copy row, a commit, or the end row after
/// the last commit (H1, `End`).
enum CommitRow: Identifiable, Hashable {
    case workingCopy(changeCount: Int)
    case commit(Commit, GraphRow?, hasIncomingEdge: Bool)
    case end(End)

    /// What the end row says, and whether its appearing loads the next page.
    enum End: Hashable {
        /// Older commits may exist: "Loading older commits…", and the next page loads as it shows.
        case loading
        /// git has nothing older: "Start of history".
        case complete
        /// The list is at `HistoryDepth.cap` with older commits left (Ruling 5): the store loads
        /// no further, so the row says so instead of "Loading…" forever, and loads nothing.
        case capped

        var loadsMore: Bool { self == .loading }

        var text: String {
            switch self {
            case .loading: HistoryWording.loadingOlder
            case .complete: HistoryWording.startOfHistory
            case .capped: HistoryWording.capReached
            }
        }
    }

    var id: Selection {
        switch self {
        case .workingCopy: .workingCopy
        case .commit(let commit, _, _): .commit(commit.sha)
        // Never a selection: `CommitSelection.resolve` drops it and `select` refuses it.
        case .end: .historyEnd
        }
    }
}

/// The commit table's rows for one snapshot (H1 Task 2), built once when the snapshot is set
/// (`RepositoryStore.setSnapshot`), not on every evaluation of the table's body: at a depth of
/// thousands, rebuilding the rows and their graph lookup per body was the cost.
struct HistoryRows: Equatable {
    /// The working-copy row (with changes), the commits with their graph rows, then the end row —
    /// none of them with no commits (the empty state, as before H1).
    let rows: [CommitRow]
    /// The graph column's width: what the snapshot's lanes need, and never less than the width
    /// before it (`previousWidth`), so a refresh needing fewer lanes does not narrow the column.
    let graphWidth: CGFloat
    /// The selectable rows' ids in the order shown — the working copy and the commits, not the end
    /// row: the `shown` order `CommitSelection` takes, and what "is this commit loaded" asks.
    let shas: [Selection]
    /// The loaded commits' shas, for "is this commit loaded" in O(1) (`isLoaded`).
    let loaded: Set<String>
    /// The loaded merge commits' shas: the menus' merge test (`historyBlockedReason`).
    let merges: Set<String>

    /// Whether `sha` is one of the loaded commits.
    func isLoaded(_ sha: String) -> Bool { loaded.contains(sha) }

    /// No snapshot: no rows.
    static let empty = HistoryRows.build(nil, previousWidth: nil)

    static func build(_ snapshot: RepoSnapshot?, previousWidth: CGFloat?) -> HistoryRows {
        let lanesWidth = CommitGraphCell.contentWidth(for: snapshot?.graph ?? [])
        let width = max(lanesWidth, previousWidth ?? 0)
        guard let snapshot else {
            return HistoryRows(rows: [], graphWidth: width, shas: [], loaded: [], merges: [])
        }
        var rows: [CommitRow] = []
        rows.reserveCapacity(snapshot.commits.count + 2)
        let changed = snapshot.status.files.count
        if changed > 0 {
            rows.append(.workingCopy(changeCount: changed))
        }
        var graphBySha: [String: GraphRow] = [:]
        graphBySha.reserveCapacity(snapshot.graph.count)
        for row in snapshot.graph { graphBySha[row.sha] = row }
        var previous: GraphRow?
        var loaded = Set<String>(minimumCapacity: snapshot.commits.count)
        var merges = Set<String>()
        for commit in snapshot.commits {
            loaded.insert(commit.sha)
            if commit.isMerge { merges.insert(commit.sha) }
            let graphRow = graphBySha[commit.sha]
            let hasIncomingEdge =
                if let graphRow, let previous {
                    previous.edges.contains { !$0.fromAbove && $0.toLane == graphRow.lane }
                } else {
                    false
                }
            rows.append(.commit(commit, graphRow, hasIncomingEdge: hasIncomingEdge))
            previous = graphRow
        }
        let shas = rows.map(\.id)
        if !snapshot.commits.isEmpty {
            rows.append(.end(end(of: snapshot)))
        }
        return HistoryRows(rows: rows, graphWidth: width, shas: shas, loaded: loaded, merges: merges)
    }


    /// The end row's state for `snapshot`: complete when git had nothing older, capped when the
    /// depth is at `HistoryDepth.cap` with older commits left, loading otherwise.
    private static func end(of snapshot: RepoSnapshot) -> CommitRow.End {
        if snapshot.historyIsComplete { return .complete }
        return snapshot.historyDepth >= HistoryDepth.cap ? .capped : .loading
    }

    // MARK: - The table's scrolls (Ruling 6)

    /// The row a pending reveal (`RepositoryStore.pendingReveal`) scrolls to: its commit's, once
    /// that is loaded — nil before, so the reveal is not handled while its deep load still runs.
    func revealTarget(_ pendingReveal: String?) -> Selection? {
        guard let pendingReveal, isLoaded(pendingReveal) else { return nil }
        return .commit(pendingReveal)
    }

    /// Whether a new selection scrolls the table through the selection's own path: not for the
    /// commit a reveal is pending for, which the reveal's path scrolls to (`revealTarget`), so a
    /// reveal never scrolls twice.
    static func selectionScrolls(to selection: Selection, pendingReveal: String?) -> Bool {
        guard let pendingReveal else { return true }
        return selection != .commit(pendingReveal)
    }
}
