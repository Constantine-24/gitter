import GitCore
import SwiftUI

/// Renders the parsed diff of the selected file: hunk headers followed by their
/// lines, with old/new line numbers in fixed-width gutters.
struct DiffView: View {
    let diffs: [FileDiff]
    let hasSelection: Bool

    private static let numberWidth: CGFloat = 44

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
        }
    }

    private var placeholder: some View {
        ContentUnavailableView(
            hasSelection ? "No Changes" : "No File Selected",
            systemImage: "doc.text.magnifyingglass"
        )
        .frame(maxWidth: .infinity, maxHeight: .infinity)
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
            ForEach(diff.hunks) { hunk in
                Text(hunk.header)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.quinary)

                ForEach(hunk.lines) { line in
                    DiffLineRow(line: line, numberWidth: Self.numberWidth)
                }
            }
        }
    }
}

private struct DiffLineRow: View {
    let line: DiffLine
    let numberWidth: CGFloat

    var body: some View {
        HStack(spacing: 0) {
            number(line.oldNumber)
            number(line.newNumber)
            Text(line.text.isEmpty ? " " : line.text)
                .font(.system(.body, design: .monospaced))
                .italic(line.kind == .noNewline)
                .foregroundStyle(line.kind == .noNewline ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                .textSelection(.enabled)
                .lineLimit(1)
                .fixedSize(horizontal: true, vertical: false)
                .padding(.leading, 6)
                .padding(.trailing, 12)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(background)
    }

    private func number(_ value: Int?) -> some View {
        Text(value.map(String.init) ?? "")
            .font(.system(.caption, design: .monospaced).monospacedDigit())
            .foregroundStyle(.tertiary)
            .frame(width: numberWidth, alignment: .trailing)
            .padding(.trailing, 4)
    }

    private var background: Color {
        switch line.kind {
        case .added: Color.green.opacity(0.15)
        case .removed: Color.red.opacity(0.15)
        case .context, .noNewline: Color.clear
        }
    }
}
