import GitCore
import SwiftUI

/// One line of the commit table: either the synthetic working-copy row or a commit.
enum CommitRow: Identifiable, Hashable {
    case workingCopy(changeCount: Int)
    case commit(Commit, GraphRow?, hasIncomingEdge: Bool)

    var id: Selection {
        switch self {
        case .workingCopy: .workingCopy
        case .commit(let commit, _, _): .commit(commit.sha)
        }
    }
}

struct CommitListView: View {
    @Environment(RepositoryStore.self) private var store
    /// Makes the table claim keyboard focus when it is clicked, so its selection draws in the
    /// system highlight colour rather than the unemphasized grey. Defensive and undiagnosed,
    /// exactly as in `WorkingCopyFileList.isFocused` — see the reasoning there.
    @FocusState private var isFocused: Bool

    /// The last selection the table itself made, so the scroll below can skip it.
    ///
    /// Scrolling is for a selection made *elsewhere* — clicking a branch in the sidebar, or
    /// landing back on the working copy after a commit — which can be anywhere in 500 rows. A
    /// row the user just clicked is under the pointer by definition, and re-centring it yanks
    /// the table out from under them.
    @State private var selectedInTable: Selection?

    var body: some View {
        let rows = rows()
        ScrollViewReader { proxy in
            table(rows)
                .onChange(of: store.selection) { _, newValue in
                    // Cleared whichever branch is taken, so the flag can only ever suppress
                    // the one scroll it was set for. Left standing, a selection the table made
                    // and then lost (a reload that drops the row, a repository swap) would go
                    // on matching and silently swallow a later jump to the same commit.
                    let clickedInTable = newValue == selectedInTable
                    selectedInTable = nil
                    guard !clickedInTable else { return }
                    // `x: 0` rather than `.center`: the columns are wider than the pane, and
                    // centring on both axes pushed the Summary column off to the left until
                    // only Author was readable. This keeps the leading edge where it is and
                    // moves only vertically. (Near either end of the log the row lands as
                    // close to the middle as the content allows, which is not the middle.)
                    //
                    // `anchor: nil` — minimal scroll to make visible — was tried instead, to
                    // get the "already visible row does not move" case for free and drop the
                    // flag above. It does not work here: clicking a branch 44 commits back
                    // scrolled the table part of the way and stopped two rows short of the
                    // selected commit, which stayed off screen. Screenshotted, twice, with the
                    // animation given 20 s to settle.
                    withAnimation { proxy.scrollTo(newValue, anchor: UnitPoint(x: 0, y: 0.5)) }
                }
        }
    }

    @ViewBuilder
    private func table(_ rows: [CommitRow]) -> some View {
        Table(rows, selection: selectionBinding(rows)) {
            TableColumn("") { row in
                switch row {
                case .workingCopy:
                    CommitGraphCell(row: nil, isMerge: false, width: graphWidth)
                case .commit(let commit, let graphRow, let hasIncomingEdge):
                    CommitGraphCell(
                        row: graphRow,
                        isMerge: commit.isMerge,
                        hasIncomingEdge: hasIncomingEdge,
                        width: graphWidth
                    )
                }
            }
            .width(graphWidth + CommitGraphCell.cellHorizontalPadding)

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
                case .commit(let commit, _, _):
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
                if case .commit(let commit, _, _) = row {
                    Text(commit.authorName).lineLimit(1)
                }
            }
            .width(min: 90, ideal: 120)

            TableColumn("Date") { row in
                if case .commit(let commit, _, _) = row {
                    Text(commit.authorDate.formatted(.relative(presentation: .named)))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .width(min: 90, ideal: 130)

            TableColumn("SHA") { row in
                if case .commit(let commit, _, _) = row {
                    Text(commit.shortSha)
                        .font(.system(.body, design: .monospaced))
                        .foregroundStyle(.secondary)
                }
            }
            .width(min: 64, ideal: 74)
        }
        .tableStyle(.inset)
        .focused($isFocused)
        .simultaneousGesture(TapGesture().onEnded { isFocused = true })
        // `forSelectionType:` rather than a `.contextMenu` inside the row views: this is the
        // form `Table` knows about, and it is what makes a right-click select the row it lands
        // on before building the menu. The working-copy row and a right-click on empty space
        // both arrive here with nothing to offer a menu about, and get none.
        //
        // `ids` is the whole selection when the click lands inside it and the clicked row
        // alone when it does not; the commits among them go to the menu in the order shown.
        .contextMenu(forSelectionType: CommitRow.ID.self) { ids in
            let shas = rows.compactMap { row -> String? in
                guard case .commit(let commit, _, _) = row, ids.contains(row.id) else { return nil }
                return commit.sha
            }
            if !shas.isEmpty {
                CommitMenu(shas: shas)
            }
        }
    }

    private var graphWidth: CGFloat {
        CommitGraphCell.contentWidth(for: store.snapshot?.graph ?? [])
    }

    /// Commits as a set (⌘-click, ⇧-click), the working copy alone — `CommitSelection` decides,
    /// through the store. The table is handed the set the store keeps, so it can never draw a
    /// selection the detail pane is not about.
    private func selectionBinding(_ rows: [CommitRow]) -> Binding<Set<Selection>> {
        Binding(
            get: { CommitSelection.table(selection: store.selection, commits: store.selectedCommits) },
            set: { newValue in
                let before = store.selection
                store.selectRows(newValue, shown: rows.map(\.id))
                if store.selection != before { selectedInTable = store.selection }
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
        var previous: GraphRow?
        for commit in snapshot.commits {
            let graphRow = graphBySha[commit.sha]
            let hasIncomingEdge = if let graphRow, let previous {
                previous.edges.contains { !$0.fromAbove && $0.toLane == graphRow.lane }
            } else {
                false
            }
            result.append(.commit(commit, graphRow, hasIncomingEdge: hasIncomingEdge))
            previous = graphRow
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
