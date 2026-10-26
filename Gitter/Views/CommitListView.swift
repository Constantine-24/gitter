import GitCore
import SwiftUI

struct CommitListView: View {
    @Environment(RepositoryStore.self) private var store
    /// Makes the table claim keyboard focus when it is clicked, so its selection draws in the
    /// system highlight colour rather than the unemphasized grey. Defensive and undiagnosed,
    /// exactly as in `WorkingCopyFileList.isFocused` — see the reasoning there.
    @FocusState private var isFocused: Bool
    /// The comparison list's, drawn over the history in compare mode (`CompareListView`).
    @FocusState private var isCompareFocused: Bool

    /// The last selection the table itself made, so the scroll below can skip it.
    ///
    /// Scrolling is for a selection made *elsewhere* — clicking a branch in the sidebar, or
    /// landing back on the working copy after a commit — which can be anywhere in 500 rows. A
    /// row the user just clicked is under the pointer by definition, and re-centring it yanks
    /// the table out from under them.
    @State private var selectedInTable: Selection?

    var body: some View {
        // Compare mode (B3): the comparison is drawn over the history until it ends (Done, Esc,
        // a sidebar click, another repository). Over it, not instead of it: swapping the history
        // out made the `HSplitView` lay this pane out afresh at its minimum, so every Compare
        // threw the commit list / detail divider to 360 pt, and its autosave kept it there
        // (measured: 900 → 601, still 601 after Done and after a relaunch; final review I1).
        // Underneath, the history is inert: no clicks, nothing for VoiceOver, and no keyboard
        // (see `.onChange(of: isFocused)` below).
        let comparing = store.comparison != nil
        history
            .disabled(comparing)
            .allowsHitTesting(!comparing)
            .accessibilityHidden(comparing)
            .overlay {
                if comparing {
                    CompareListView(isFocused: $isCompareFocused)
                        .background(.background)
                }
            }
    }

    @ViewBuilder
    private var history: some View {
        // Built once per snapshot by the store (H1, `HistoryRows`), not per body.
        let historyRows = store.historyRows
        // Once per body, not per row: the pills of 500 rows look up one dictionary.
        let tags = TagWording.tagsByCommit(store.snapshot?.refs.tags ?? [])
        // The same for other worktrees' detached HEADs (B3): `log --all` lists their commits.
        let worktreeHeads = store.detachedWorktreeHeads
        ScrollViewReader { proxy in
            table(historyRows, tags: tags, worktreeHeads: worktreeHeads)
                .onChange(of: store.selection) { _, newValue in
                    // Cleared whichever branch is taken, so the flag can only ever suppress
                    // the one scroll it was set for. Left standing, a selection the table made
                    // and then lost (a reload that drops the row, a repository swap) would go
                    // on matching and silently swallow a later jump to the same commit.
                    let clickedInTable = newValue == selectedInTable
                    selectedInTable = nil
                    guard !clickedInTable else { return }
                    // A reveal's commit is scrolled to by the reveal's own path below, once its
                    // row is in (Ruling 6): scrolling here too would scroll twice — or, for a
                    // commit not loaded yet, to a row that isn't there.
                    guard HistoryRows.selectionScrolls(to: newValue, pendingReveal: store.pendingReveal) else {
                        return
                    }
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
                // A reveal (`RepositoryStore.reveal`, a sidebar click or Done): the selection
                // was made before its row was loaded, so the scroll waits for the row — the deep
                // load landing, or at once for a commit already loaded — and only then is the
                // reveal handled. Handled earlier, the store would drop the load (Ruling 6).
                .onChange(of: store.historyRows) { scrollToReveal(proxy) }
                .onChange(of: store.pendingReveal) { scrollToReveal(proxy) }
        }
    }

    private func scrollToReveal(_ proxy: ScrollViewProxy) {
        guard let pending = store.pendingReveal, let row = store.historyRows.revealTarget(pending) else { return }
        // The same anchor as the selection's scroll above, for the same reasons.
        withAnimation { proxy.scrollTo(row, anchor: UnitPoint(x: 0, y: 0.5)) }
        store.revealHandled(pending)
    }

    @ViewBuilder
    private func table(
        _ historyRows: HistoryRows, tags: [String: [Tag]], worktreeHeads: [String: [Worktree]]
    ) -> some View {
        let rows = historyRows.rows
        let graphWidth = historyRows.graphWidth
        Table(rows, selection: selectionBinding(historyRows.shas)) {
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
                case .end:
                    EmptyView()
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
                        // The log's branch decorations, then the commit's tags from the tag
                        // list: `%D`'s tag entries change with `log.decorate=full` and vanish
                        // under `log.excludeDecoration` (B18), the tag list does not.
                        ForEach(
                            Array(TagWording.branchDecorations(commit.refs).enumerated()),
                            id: \.offset
                        ) { _, ref in
                            RefCapsule(ref: ref)
                        }
                        ForEach(tags[commit.sha] ?? []) { tag in
                            TagCapsule(tag: tag)
                        }
                        ForEach(worktreeHeads[commit.sha] ?? []) { worktree in
                            WorktreeCapsule(worktree: worktree)
                        }
                        Text(commit.summary).lineLimit(1)
                    }
                case .end(let end):
                    EndRowCell(end: end) { store.loadOlderCommits() }
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
        // Under the comparison the table is hidden but still in the key loop (`.disabled` does
        // not take it out, and `.focusable` either puts a stop of its own in front of the table,
        // which took the click's focus from it, or rebuilds the table, which throws the divider
        // again — measured): when Tab lands on it while comparing, the focus goes on to the
        // comparison's list. (Handed to nothing, the next Tab came back here.) Its selection
        // writes are dropped meanwhile (`RepositoryStore.selectRows`).
        .onChange(of: isFocused) { _, focused in
            guard focused, store.comparison != nil else { return }
            isFocused = false
            isCompareFocused = true
        }
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

    /// Commits as a set (⌘-click, ⇧-click), the working copy alone — `CommitSelection` decides,
    /// through the store. The table is handed the set the store keeps, so it can never draw a
    /// selection the detail pane is not about.
    private func selectionBinding(_ shown: [Selection]) -> Binding<Set<Selection>> {
        Binding(
            get: { CommitSelection.table(selection: store.selection, commits: store.selectedCommits) },
            set: { newValue in
                let before = store.selection
                store.selectRows(newValue, shown: shown)
                if store.selection != before { selectedInTable = store.selection }
            }
        )
    }
}

/// The row after the last commit (H1): "Loading older commits…" with a small spinner while older
/// commits may exist, and its appearing — scrolled to, or reached with ↓ / Page Down / End — loads
/// the next page (`loadOlderCommits`, which runs one load at a time and nothing while complete or
/// at the cap). "Start of history", or at the cap the line saying the list stops there, in
/// secondary text and loading nothing. Not a selection, and with no menu: the table's
/// `forSelectionType` menu takes commits only.
///
/// The load is handed in, not read from the environment: a `Table` cell does not always get the
/// window's environment objects — `@Environment(RepositoryStore.self)` here trapped ("No
/// Observable object of type RepositoryStore found") the first time the row scrolled in, in the
/// real app (H1 Task 3).
private struct EndRowCell: View {
    let end: CommitRow.End
    let loadOlder: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            if end.loadsMore {
                ProgressView().controlSize(.small)
            }
            Text(end.text).foregroundStyle(.secondary)
        }
        .onAppear {
            #if DEBUG
                DebugLaunchHooks.endRowAppearances += 1
            #endif
            if end.loadsMore { loadOlder() }
        }
        #if DEBUG
            .onDisappear { DebugLaunchHooks.endRowDisappearances += 1 }
        #endif
    }
}

/// A small tinted capsule for one of git's `%D` branch decorations (tags are `TagCapsule`).
private struct RefCapsule: View {
    let ref: String

    var body: some View {
        let isHead = ref.hasPrefix("HEAD")
        Text(ref)
            .font(.caption2)
            .fontWeight(isHead ? .bold : .regular)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.accentColor.opacity(0.2), in: Capsule())
            .foregroundStyle(Color.accentColor)
    }
}

/// "worktree: <folder>" on the commit another worktree's detached HEAD is at (B3, R27): `log
/// --all` shows that commit, and nothing else on its row would say why. Its own style — teal,
/// with a window icon — so it is not read as a branch or a tag.
private struct WorktreeCapsule: View {
    let worktree: Worktree

    var body: some View {
        Label(WorktreeWording.pillText(worktree), systemImage: "macwindow")
            .labelStyle(TagPillLabelStyle())
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.teal.opacity(0.2), in: Capsule())
            .foregroundStyle(Color.teal)
            .help(WorktreeWording.pillHelp(worktree))
    }
}

/// A tag's pill on its commit's row, from the tag list — the same icon and tooltip as its
/// sidebar row. The icon tells it from a branch's pill whatever the accent colour is (with an
/// orange system accent the two tints are the same).
private struct TagCapsule: View {
    let tag: Tag

    var body: some View {
        Label(tag.name, systemImage: TagWording.rowIcon(tag))
            .labelStyle(TagPillLabelStyle())
            .font(.caption2)
            .lineLimit(1)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(Color.orange.opacity(0.2), in: Capsule())
            .foregroundStyle(Color.orange)
            .help(TagWording.rowHelp(tag))
            .accessibilityLabel(TagWording.rowAccessibility(tag))
    }
}

/// Icon and title close together, sized for a pill.
private struct TagPillLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 2) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

