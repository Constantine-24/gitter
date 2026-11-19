import GitCore
import SwiftUI

/// The results of commit search (F1), drawn over the history like `CompareListView` once the
/// query is not empty (`historyIsCovered`): a table with History's columns, less the graph. A row
/// shows its commit in the detail as usual and has History's menu, then Show in History. The bar
/// above it is `SearchBar`.
struct SearchListView: View {
    @Environment(RepositoryStore.self) private var store
    /// Draws the selection in the system highlight colour once the list is clicked, as
    /// `CommitListView` does. `CommitListView`'s, so that a Tab landing on the history hidden under
    /// this list can hand the focus here.
    var isFocused: FocusState<Bool>.Binding

    var body: some View {
        if let state = store.commitSearch {
            list(state)
        }
    }

    // MARK: - Results

    @ViewBuilder
    private func list(_ state: CommitSearchState) -> some View {
        let commits = state.result?.commits ?? []
        // Once per body, not per row: every row's pills look up these two dictionaries.
        let tags = TagWording.tagsByCommit(store.snapshot?.refs.tags ?? [])
        let worktreeHeads = store.detachedWorktreeHeads
        Table(commits, selection: selectionBinding(commits)) {
            TableColumn("Summary") { commit in
                HStack(spacing: 4) {
                    ForEach(Array(TagWording.branchDecorations(commit.refs).enumerated()), id: \.offset) { _, ref in
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
            }
            .width(min: 180, ideal: 420)

            TableColumn("Author") { commit in
                Text(commit.authorName).lineLimit(1)
            }
            .width(min: 90, ideal: 120)

            TableColumn("Date") { commit in
                Text(commit.authorDate.formatted(.relative(presentation: .named)))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .width(min: 90, ideal: 130)

            TableColumn("SHA") { commit in
                Text(commit.shortSha)
                    .font(.system(.body, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .width(min: 64, ideal: 74)
        }
        .tableStyle(.inset)
        .focused(isFocused)
        .simultaneousGesture(TapGesture().onEnded { isFocused.wrappedValue = true })
        .contextMenu(forSelectionType: String.self) { ids in
            let shas = commits.map(\.sha).filter(ids.contains)
            if !shas.isEmpty {
                CommitMenu(shas: shas)
                if let sha = shas.first, shas.count == 1 {
                    Divider()
                    Button(SearchWording.showInHistory) { store.showInHistory(sha) }
                }
            }
        }
    }

    /// The commits among the store's selection, and the table's writes through `selectRows`, as
    /// History's table does.
    private func selectionBinding(_ commits: [Commit]) -> Binding<Set<String>> {
        Binding(
            get: {
                Set(
                    CommitSelection.table(selection: store.selection, commits: store.selectedCommits)
                        .compactMap { selection -> String? in
                            if case .commit(let sha) = selection { sha } else { nil }
                        })
            },
            set: { newValue in
                store.selectRows(Set(newValue.map(Selection.commit)), shown: commits.map { .commit($0.sha) })
            }
        )
    }
}

/// The search bar (F1): the field, the mode menu, Close Search and the status line with Stop and
/// Search Again. An inset at the top of the commit list column while search is open
/// (`CommitListView`), over History or over the results.
struct SearchBar: View {
    @Environment(RepositoryStore.self) private var store
    @Environment(\.findCommitsFocusRequest) private var focusRequest
    @FocusState private var fieldFocused: Bool

    var body: some View {
        if let state = store.commitSearch {
            bar(state)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(SearchWording.barAccessibility)
            // Opened by the menu: the field is there the moment the bar is, and ⌥⌘F again, with
            // the bar open, asks for it once more.
            .onAppear { Task { @MainActor in fieldFocused = true } }
            .onChange(of: focusRequest) { fieldFocused = true }
        }
    }

    // MARK: - Bar

    private func bar(_ state: CommitSearchState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                TextField(
                    SearchWording.barAccessibility, text: queryBinding,
                    prompt: Text(SearchWording.prompt(state.mode))
                )
                .textFieldStyle(.plain)
                .focused($fieldFocused)
                Picker(SearchWording.modeAccessibility, selection: modeBinding) {
                    ForEach(CommitSearchMode.allCases, id: \.self) { mode in
                        Text(SearchWording.name(mode)).tag(mode)
                    }
                }
                .pickerStyle(.menu)
                .labelsHidden()
                .fixedSize()
                Button {
                    store.leaveSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                // Esc, from anywhere in the window — the field, a result, History — as Done does
                // for a comparison; a cancel-action button also fires from inside a text field.
                .keyboardShortcut(.cancelAction)
                .help(SearchWording.closeSearch)
                .accessibilityLabel(SearchWording.closeSearch)
            }
            statusRow(state)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }

    @ViewBuilder
    private func statusRow(_ state: CommitSearchState) -> some View {
        if case .failed(let words) = state.status {
            failure(words)
        } else {
            progressRow(state)
        }
    }

    /// A failure in the store's error style (`ErrorBanner`): the warning glyph and the whole
    /// message — git's often runs to several lines, the cause last — selectable, scrolling past
    /// the banner's own line cap.
    private func failure(_ words: String) -> some View {
        let baseline = Banner.firstBaseline
        return HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            ScrollView {
                Text(words)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollBounceBehavior(.basedOnSize)
            .frame(maxHeight: Banner.capHeight(for: words))
            .fixedSize(horizontal: false, vertical: true)
            // A scroll view has no baseline of its own: give it its first line's, as `Banner` does.
            .alignmentGuide(.firstTextBaseline) { dimensions in dimensions[.top] + baseline }
        }
        .padding(8)
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(.background)
                .overlay(RoundedRectangle(cornerRadius: 6).fill(Color.yellow.opacity(0.25)))
        }
        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.yellow.opacity(0.6)))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SearchWording.failedAccessibility(words))
    }

    @ViewBuilder
    private func progressRow(_ state: CommitSearchState) -> some View {
        let status = SearchWording.statusLine(state)
        let stale = SearchWording.staleLine(state)
        if status != nil || stale != nil {
            HStack(spacing: 8) {
                if state.status == .searching {
                    ProgressView().controlSize(.small)
                }
                if let status {
                    Text(status)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                // Only while a search runs: Stop also clears a landed result.
                if state.status == .searching {
                    Button(SearchWording.stop) { store.stopSearch() }
                }
                if let stale {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(stale).font(.callout).lineLimit(1)
                    Button(SearchWording.searchAgain) { store.searchAgain() }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .contain)
        }
    }

    private var queryBinding: Binding<String> {
        Binding(get: { store.commitSearch?.query ?? "" }, set: { store.setSearchQuery($0) })
    }

    private var modeBinding: Binding<CommitSearchMode> {
        Binding(get: { store.commitSearch?.mode ?? .messageAuthorOrID }, set: { store.setSearchMode($0) })
    }

}

extension EnvironmentValues {
    /// Counts each time Find Commits asks for the field while search is open (`MainWindow`).
    @Entry var findCommitsFocusRequest: Int = 0
}
