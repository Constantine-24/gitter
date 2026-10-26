import CoreGraphics
import GitCore

/// One line of the commit table: the synthetic working-copy row, a commit, or the end row after
/// the last commit (H1) — "Loading older commits…" while there may be more, "Start of history"
/// once there is none.
enum CommitRow: Identifiable, Hashable {
    case workingCopy(changeCount: Int)
    case commit(Commit, GraphRow?, hasIncomingEdge: Bool)
    case end(complete: Bool)

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
            rows.append(.end(complete: snapshot.historyIsComplete))
        }
        return HistoryRows(rows: rows, graphWidth: width, shas: shas, loaded: loaded, merges: merges)
    }
}
