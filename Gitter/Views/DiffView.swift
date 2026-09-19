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
            // Vertical only: a long line now wraps to the row's width and grows the row taller
            // instead of running past the pane's edge, so there is nothing left to scroll
            // sideways to. That also means the stack never needs a width wider than the pane
            // itself — no GeometryReader is needed to measure and pin it.
            ScrollView(.vertical) {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(diffs) { diff in
                        fileSection(diff)
                    }
                }
            }
            .background(Color(nsColor: .textBackgroundColor))
            // Every reload renumbers the lines, so a selection made against the previous parse
            // would now point at whatever happens to sit at those indices.
            .onChange(of: diffs, initial: true) { resetSelection() }
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
            .headerRow(background: .quaternary)

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

extension View {
    /// Fills a header row to the width of the diff pane, so whatever sits at its trailing edge
    /// — the stage buttons — has the full pane to lay out in.
    ///
    /// Used to be clamped to a measured viewport width, back when the pane could scroll
    /// sideways and a header's natural width could run wider than the pane. Now that long
    /// lines wrap instead, the pane is never wider than its container, so a plain `.infinity`
    /// frame does the same job without measuring anything.
    func headerRow(background: some ShapeStyle) -> some View {
        frame(maxWidth: .infinity, alignment: .leading)
            .background(background)
    }
}
