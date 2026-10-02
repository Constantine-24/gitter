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
        if store.selectedFileIsUnmerged {
            // A conflicted file: git describes it with `diff --cc`, which the parser does not
            // match, and what the user needs is the resolver anyway.
            ConflictResolverView()
        } else {
            VStack(spacing: 0) {
                if let path = store.reopenablePath, path == store.selectedPath { reopenOffer(path) }
                diffOrPlaceholder
            }
        }
    }

    /// A resolved conflict that can still be reopened (`GitConflictBackend.canReopen`).
    private func reopenOffer(_ path: String) -> some View {
        let blocked = store.conflictActionBlockedReason
        return HStack(spacing: 8) {
            Text(ConflictWording.reopenOffer(path))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button(ConflictWording.reopenMenuItem) { store.requestReopen(path) }
                .disabled(blocked != nil, help: blocked)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .headerRow(background: .quaternary.opacity(0.5))
    }

    @ViewBuilder
    private var diffOrPlaceholder: some View {
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

    /// A conflicted file never gets here: it has the resolver (`ConflictResolverView`).
    private var placeholder: some View {
        ContentUnavailableView(
            hasSelection ? "No Changes" : "No File Selected", systemImage: "doc.text.magnifyingglass"
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
    /// `.help(text)` when there is text, and nothing at all when there is not.
    ///
    /// `.help("")` is not the same as no tooltip: it replaces whatever an enclosing view or
    /// the control itself would otherwise say with an empty one.
    @ViewBuilder
    func helpIfPresent(_ text: String?) -> some View {
        if let text { help(text) } else { self }
    }

    /// Disables the control but keeps its tooltip.
    ///
    /// A disabled `NSControl` does not track the mouse, so a `.help` attached directly to a
    /// disabled control never shows. The wrapper here stays enabled and hit-testable and
    /// carries the tooltip instead; the (possibly disabled) control just sits inside it.
    /// `HStack(spacing: 0)` around a single child adds no size or padding of its own, so this
    /// changes nothing about layout, and it adds no gesture of its own, so a click still reaches
    /// the control underneath when it is enabled.
    func disabled(_ isDisabled: Bool, help text: String?) -> some View {
        HStack(spacing: 0) { self.disabled(isDisabled) }
            .contentShape(.rect)
            .helpIfPresent(text)
    }

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
