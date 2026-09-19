import GitCore
import SwiftUI

/// Renders the parsed diff of the selected file: hunk headers followed by their
/// lines, with old/new line numbers in fixed-width gutters.
///
/// Owns the line selection, because it is the one view that sees the whole loaded diff.
/// `DiffLine.id` is an index handed out by the parser, so a selection means nothing once the
/// diff is parsed again — which is every mutation, every path change and every side change.
struct DiffView: View {
    let diffs: [FileDiff]
    let hasSelection: Bool

    @Environment(RepositoryStore.self) private var store
    @State private var selection = DiffLineSelection()

    var body: some View {
        if diffs.isEmpty {
            placeholder
        } else {
            // The stack's width is driven by the viewport rather than by measuring every line,
            // so rows stay lazy; individual long lines still overflow and scroll horizontally.
            GeometryReader { proxy in
                ScrollView([.vertical, .horizontal]) {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(diffs) { diff in
                            fileSection(diff)
                        }
                    }
                    .frame(minWidth: proxy.size.width, alignment: .leading)
                }
                .background(Color(nsColor: .textBackgroundColor))
            }
            // Every reload renumbers the lines, so a selection made against the previous parse
            // would now point at whatever happens to sit at those indices.
            .onChange(of: diffs, initial: true) { resetSelection() }
            .onExitCommand { selection.clearAll() }
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            hasSelection ? "No Changes" : "No File Selected",
            systemImage: "doc.text.magnifyingglass"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resetSelection() {
        selection.clearAll()
        #if DEBUG
            DebugLaunchHooks.preselectLines(in: diffs, selection: &selection)
        #endif
    }

    @ViewBuilder
    private func fileSection(_ diff: FileDiff) -> some View {
        Text(diff.displayPath)
            .font(.system(.caption, design: .monospaced).weight(.semibold))
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(.quaternary)

        if diff.isBinary {
            Text("Binary file")
                .font(.callout)
                .italic()
                .foregroundStyle(.secondary)
                .padding(8)
        } else if diff.hunks.isEmpty {
            Text("No changes")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(8)
        } else {
            // Asked once per file: it depends on the file and on the store's selection, not on
            // the hunk, and it is what decides whether this diff is interactive at all.
            let canStage = store.canPartiallyStage(diff)
            ForEach(diff.hunks) { hunk in
                DiffHunkView(file: diff, hunk: hunk, canStage: canStage, selection: $selection)
            }
        }
    }
}
