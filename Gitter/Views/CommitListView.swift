import GitCore
import SwiftUI

/// One line of the commit table: either the synthetic working-copy row or a commit.
enum CommitRow: Identifiable, Hashable {
    case workingCopy(changeCount: Int)
    case commit(Commit, GraphRow?)

    var id: Selection {
        switch self {
        case .workingCopy: .workingCopy
        case .commit(let commit, _): .commit(commit.sha)
        }
    }
}

struct CommitListView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let rows = rows()
        Table(rows, selection: selectionBinding) {
            TableColumn("") { row in
                switch row {
                case .workingCopy:
                    CommitGraphCell(row: nil, isMerge: false)
                case .commit(let commit, let graphRow):
                    CommitGraphCell(row: graphRow, isMerge: commit.isMerge)
                }
            }
            .width(graphWidth)

            TableColumn("Summary") { row in
                switch row {
                case .workingCopy(let count):
                    HStack(spacing: 6) {
                        Text("Working Copy").fontWeight(.medium)
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .padding(.horizontal, 5)
                                .padding(.vertical, 1)
                                .background(.quaternary, in: Capsule())
                        }
                    }
                case .commit(let commit, _):
                    HStack(spacing: 4) {
                        ForEach(Array(commit.refs.enumerated()), id: \.offset) { _, ref in
                            RefCapsule(ref: ref)
                        }
                        Text(commit.summary).lineLimit(1)
                    }
                }
            }
            .width(min: 180, ideal: 420)

            TableColumn("Author") { row in
                if case .commit(let commit, _) = row {
                    Text(commit.authorName).lineLimit(1)
                }
            }
            .width(min: 90, ideal: 120)

            TableColumn("Date") { row in
                if case .commit(let commit, _) = row {
                    Text(commit.authorDate.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 90, ideal: 130)

            TableColumn("SHA") { row in
                if case .commit(let commit, _) = row {
                    Text(commit.shortSha)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 64, ideal: 74)
        }
        .tableStyle(.inset)
    }

    private var graphWidth: CGFloat {
        CommitGraphCell.columnWidth(for: store.snapshot?.graph ?? [])
    }

    private var selectionBinding: Binding<Selection?> {
        Binding(
            get: { store.selection },
            set: { newValue in
                guard let newValue, newValue != store.selection else { return }
                store.select(newValue)
            }
        )
    }

    private func rows() -> [CommitRow] {
        guard let snapshot = store.snapshot else { return [] }
        var result: [CommitRow] = []
        let changed = snapshot.status.files.count
        if changed > 0 {
            result.append(.workingCopy(changeCount: changed))
        }
        var graphBySha: [String: GraphRow] = [:]
        for row in snapshot.graph { graphBySha[row.sha] = row }
        for commit in snapshot.commits {
            result.append(.commit(commit, graphBySha[commit.sha]))
        }
        return result
    }
}

/// A small tinted capsule for one of git's `%D` decorations.
private struct RefCapsule: View {
    let ref: String

    var body: some View {
        let isTag = ref.hasPrefix("tag: ")
        let isHead = ref.hasPrefix("HEAD")
        Text(isTag ? String(ref.dropFirst(5)) : ref)
            .font(.caption2)
            .fontWeight(isHead ? .bold : .regular)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                (isTag ? Color.orange : Color.accentColor).opacity(0.2),
                in: Capsule()
            )
            .foregroundStyle(isTag ? Color.orange : Color.accentColor)
    }
}
