import AppKit
import GitCore
import SwiftUI

/// One hunk: the `@@` header with its stage/unstage buttons, then the hunk's lines.
///
/// Deliberately *not* wrapped in a stack of its own — the header and the `ForEach` over the
/// lines go straight into the enclosing `LazyVStack`, so a long hunk's rows are still built as
/// they scroll into view.
struct DiffHunkView: View {
    let file: FileDiff
    let hunk: Hunk
    /// Whether this file's diff can be staged piece by piece. False for commit diffs, for
    /// untracked, binary and renamed files: then the hunk renders as the read-only diff it was
    /// before — no buttons, no gutter clicks, no hover.
    let canStage: Bool
    /// How wide the diff pane is, so the header can be held to it. See `header`.
    let viewportWidth: CGFloat
    @Binding var selection: DiffLineSelection

    @Environment(RepositoryStore.self) private var store

    static let numberWidth: CGFloat = 44

    var body: some View {
        // Read once per hunk rather than once per line: `ids(for:)` is a dictionary lookup.
        let ids = canStage ? selection.ids(for: hunk) : []

        header(selectedCount: ids.count)

        // Identified by the whole line, not by `DiffLine.id`. That id is a running index
        // within one parse, so after a reload index 7 usually names a *different* line —
        // and the lazy stack, seeing an id it already has, keeps the row it drew before and
        // never asks it to redraw. (Reproduced on the pre-Task-8 code too: staging anything
        // left the rows below it showing the previous diff's text and numbers.) Hashing the
        // text of each line costs one pass per reload and nothing while scrolling.
        ForEach(hunk.lines, id: \.self) { line in
            DiffLineRow(
                line: line,
                isSelected: ids.contains(line.id),
                isSelectable: canStage && (line.kind == .added || line.kind == .removed)
            ) { extending in
                if extending {
                    selection.extend(to: line, in: hunk)
                } else {
                    selection.toggle(line, in: hunk)
                }
            }
        }
    }

    // MARK: - Header

    /// The `@@` line, with the buttons at the trailing edge of the *viewport*.
    ///
    /// Clamped to the pane's width rather than filling whatever the lazy stack turns out to be,
    /// so the buttons cannot be pushed out of sight by a long line in the file. See the note on
    /// `pinnedToViewport`.
    private func header(selectedCount: Int) -> some View {
        HStack(spacing: 8) {
            Text(hunk.header)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if canStage {
                Spacer(minLength: 12)
                buttons(selectedCount: selectedCount)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 2)
        .pinnedToViewport(viewportWidth, background: .quinary)
    }

    private func buttons(selectedCount: Int) -> some View {
        HStack(spacing: 6) {
            if selectedCount == 0 {
                Button(store.stagedView ? "Unstage Hunk" : "Stage Hunk") {
                    store.applyHunk(hunk, in: file)
                }
                // Mutations are serialized in the store; the disabled state is what says so.
                .disabled(store.isMutating)
            } else {
                Button(lineButtonTitle(selectedCount)) {
                    store.applyLines(selection.ids(for: hunk), of: hunk, in: file)
                }
                .disabled(store.isMutating)
                // Clearing writes nothing to git, so a mutation in flight is no reason to
                // refuse it — dropping a selection is exactly what a user does while waiting.
                Button("Clear") { selection.clear(hunk) }
                    .buttonStyle(.borderless)
            }
        }
    }

    private func lineButtonTitle(_ count: Int) -> String {
        let verb = store.stagedView ? "Unstage" : "Stage"
        return "\(verb) \(count) \(count == 1 ? "Line" : "Lines")"
    }
}

/// One diff line: a clickable gutter (numbers, selection bar, +/- marker) and the text.
private struct DiffLineRow: View {
    let line: DiffLine
    let isSelected: Bool
    let isSelectable: Bool
    /// Called with `true` for a shift-click, which extends the range instead of toggling.
    let onTap: (Bool) -> Void

    /// The only per-row state there is; a hover flag costs one `Bool` and no measuring.
    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 0) {
            gutter
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.body, design: .monospaced))
                .italic(line.kind == .noNewline)
                .foregroundStyle(
                    line.kind == .noNewline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary)
                )
                // Stays selectable: the click gesture is on the gutter only, so dragging over
                // the text still selects it for copying.
                .textSelection(.enabled)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 6)
                .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    /// The part that takes clicks. `NSEvent.modifierFlags` is the only way to see the shift
    /// key here: SwiftUI's tap gesture carries no modifier information, and the class property
    /// reports the flags as they are right now, which inside the handler is the click's own.
    @ViewBuilder
    private var gutter: some View {
        let content = HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Rectangle()
                .fill(isSelected ? Color.accentColor : Color.clear)
                .frame(width: 3)
                .padding(.leading, 4)
            Text(marker)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: 10)
        }
        .frame(maxHeight: .infinity)

        if isSelectable {
            content
                .background(isHovering ? Color.accentColor.opacity(0.18) : Color.clear)
                .contentShape(.rect)
                .onTapGesture { onTap(NSEvent.modifierFlags.contains(.shift)) }
                .onHover { isHovering = $0 }
        } else {
            content
        }
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(.caption, design: .monospaced).monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: DiffHunkView.numberWidth, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var marker: String {
        switch line.kind {
        case .added: "+"
        case .removed: "-"
        case .context: " "
        case .noNewline: "\\"
        }
    }

    private var background: Color {
        switch line.kind {
        case .added: Color.green.opacity(isSelected ? 0.30 : 0.15)
        case .removed: Color.red.opacity(isSelected ? 0.30 : 0.15)
        case .context, .noNewline: Color.clear
        }
    }
}
