import GitCore
import SwiftUI

/// The commit list column in compare mode (B3), while `store.comparison` is set: a bar reading
/// `A ⇄ B` with Swap and Done, the "Changes B brings (N files)" row — selected on entry — and the
/// commits only on B, then only on A, each group with its exact count and "…and N more not
/// listed" past `Comparison.listLimit`. No graph lanes: the two lists are not one history. A
/// commit row shows that commit in the detail as usual; its only menu item is Copy Commit ID —
/// comparing is read-only, and the history keeps the actions.
///
/// After a refresh that finds a tip elsewhere the bar says "<b> has moved since this
/// comparison" with Refresh; a branch deleted since leaves only Done.
struct CompareListView: View {
    @Environment(RepositoryStore.self) private var store
    /// Draws the selection in the system highlight colour once the list is clicked, as
    /// `CommitListView` does. `CommitListView`'s, so that a Tab landing on the history hidden under
    /// this list can hand the focus here (final fix wave, I1).
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        if let comparison = store.comparison {
            VStack(spacing: 0) {
                CompareBar(comparison: comparison, staleness: store.comparisonStaleness)
                Divider()
                list(comparison)
            }
        }
    }

    private func list(_ c: Comparison) -> some View {
        List(selection: selectionBinding(c)) {
            Section {
                if let title = CompareWording.changesRow(c, fileCount: store.comparisonFiles?.count) {
                    Label(title, systemImage: "doc.on.doc")
                        .fontWeight(.medium)
                        .tag(Selection.comparisonChanges)
                } else {
                    Text(CompareWording.noHistoryRow(c))
                        .foregroundStyle(.secondary)
                        .selectionDisabled()
                }
            }
            group(c.b.ref, count: c.onlyB, commits: c.commitsOnlyB)
            group(c.a.ref, count: c.onlyA, commits: c.commitsOnlyA)
        }
        .listStyle(.inset)
        .focused(isFocused)
        .simultaneousGesture(TapGesture().onEnded { isFocused.wrappedValue = true })
        .contextMenu(forSelectionType: Selection.self) { ids in
            if ids.count == 1, case .commit(let sha)? = ids.first {
                Button(CompareWording.copyCommitIDTitle) { Clipboard.copy(sha) }
            }
        }
    }

    @ViewBuilder
    private func group(_ ref: String, count: Int, commits: [Commit]) -> some View {
        Section(CompareWording.onlyOn(ref, count: count)) {
            if commits.isEmpty {
                Text(CompareWording.noCommits)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
            ForEach(commits) { commit in
                CompareCommitRow(commit: commit)
                    .tag(Selection.commit(commit.sha))
            }
            if let more = CompareWording.notListed(total: count, listed: commits.count) {
                Text(more)
                    .foregroundStyle(.secondary)
                    .selectionDisabled()
            }
        }
    }

    /// The changes row, or one of the comparison's commits; anything else — the history's own
    /// selection from before — shows as nothing selected here.
    private func selectionBinding(_ c: Comparison) -> Binding<Selection?> {
        Binding(
            get: {
                switch store.selection {
                case .comparisonChanges:
                    return .comparisonChanges
                case .commit(let sha)
                where c.commitsOnlyB.contains(where: { $0.sha == sha })
                    || c.commitsOnlyA.contains(where: { $0.sha == sha }):
                    return store.selection
                default:
                    return nil
                }
            },
            set: { newValue in
                guard let newValue, newValue != store.selection else { return }
                store.select(newValue)
            })
    }
}

/// One commit only one side has: its subject, author, date and short id, as the history shows
/// them, without the graph or the pills.
private struct CompareCommitRow: View {
    let commit: Commit

    var body: some View {
        HStack(spacing: 8) {
            Text(commit.summary)
                .lineLimit(1)
            Spacer(minLength: 8)
            Text(commit.authorName)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(commit.authorDate.formatted(.relative(presentation: .named)))
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(commit.shortSha)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }
}

/// `A ⇄ B` with Swap and Done (Esc), and — once a refresh finds a tip elsewhere — the line that
/// says so, with Refresh unless a branch is gone.
private struct CompareBar: View {
    let comparison: Comparison
    let staleness: CompareWording.Staleness?

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right")
                    .foregroundStyle(.secondary)
                Text(CompareWording.barTitle(comparison))
                    .font(.headline)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(CompareWording.barHelp(comparison))
                Spacer(minLength: 8)
                if staleness?.offersSwap != false {
                    Button(CompareWording.swapTitle) { store.swapComparison() }
                        .help(CompareWording.swapHelp(comparison))
                }
                Button(CompareWording.doneTitle) { store.endComparison() }
                    .keyboardShortcut(.cancelAction)
                    .help(CompareWording.doneHelp)
            }
            if let staleness, let line = CompareWording.staleLine(staleness) {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(line)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 8)
                    if staleness.offersRefresh {
                        Button(CompareWording.refreshTitle) { store.refreshComparison() }
                            .help(CompareWording.refreshHelp)
                    }
                }
                .accessibilityElement(children: .contain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
