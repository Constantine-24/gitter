import AppKit
import GitCore
import SwiftUI

/// Focus mode's three columns for the draft of `path`: Ours | Result | Theirs, aligned row for row
/// and scrolled as one, on the grid the column headers use (`ResolverGrid`). The drawing, typing,
/// takes and keys are `ResolverColumnsHost`'s; this hands it the store's state.
struct ResolverColumnsView: View {
    let path: String

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let focus = store.resolverFocus
        ResolverColumnsRepresentable(
            store: store, path: path, draft: store.resolverDrafts[path],
            current: focus?.path == path ? focus?.currentChunk : nil, showsBase: store.showsBase,
            labels: store.conflictSides)
    }
}

/// `ResolverColumnsHost` in SwiftUI.
private struct ResolverColumnsRepresentable: NSViewRepresentable {
    let store: RepositoryStore
    let path: String
    let draft: ResolverDraft?
    let current: Int?
    let showsBase: Bool
    let labels: SideLabels

    func makeNSView(context: Context) -> ResolverColumnsHost { ResolverColumnsHost() }

    func updateNSView(_ host: ResolverColumnsHost, context: Context) {
        host.update(store: store, path: path, draft: draft, current: current, showBase: showsBase, labels: labels)
    }
}

/// The columns' grid, shared by the headers and the columns: three equal columns with a strip
/// between each two.
enum ResolverGrid {
    static let gutterWidth: CGFloat = 24

    static var gutter: some View {
        ResolverColor.sidebar.frame(width: gutterWidth)
    }
}

/// A whole-file kind's side column (Ruling 23): the side's text when it is text, read-only and
/// numbered; else a centred description ("Binary file, 2.8 MB", "Symlink to …", "Deleted on
/// this side").
struct ResolverWholeFileSide: View {
    let content: WholeFileSideContent
    let side: ConflictSide

    var body: some View {
        switch content {
        case .text(let text):
            ResolverPlainText(text: text, side: side)
        case .description(let words):
            Text(words)
                .font(.callout)
                .foregroundStyle(ResolverColor.secondaryText)
                .multilineTextAlignment(.center)
                .padding(16)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }
}

/// A side's whole text, read-only, numbered, in the columns' font and rows.
private struct ResolverPlainText: NSViewRepresentable {
    let text: String
    let side: ConflictSide

    func makeNSView(context: Context) -> ResolverTextColumn {
        // Its side's column: VoiceOver names it so.
        let column = ResolverTextColumn(column: side == .ours ? .ours : .theirs)
        column.scrollView.hasVerticalScroller = true
        return column
    }

    func updateNSView(_ column: ResolverTextColumn, context: Context) {
        let lines = ResolverLayout.lines(of: text)
        let rows = lines.enumerated().map { index, line in
            let cell = LayoutCell(lineNumber: index + 1, text: line.text, tint: .none, marks: [])
            return LayoutRow(ours: cell, result: cell, theirs: cell, chunk: 0, isSlot: false, badge: nil)
        }
        guard column.overlay.model.rows != rows else { return }
        let view = column.textView
        view.textStorage?.setAttributedString(ResolverAttributes.text(for: rows, column: .ours, palette: .standard))
        var starts = [0]
        for line in lines { starts.append((starts.last ?? 0) + ResolverAttributes.shown(line.text).utf16.count + 1) }
        view.starts = starts
        let numberWidth = ResolverGeometry.numberWidth(lines: rows.count)
        view.codeInset = numberWidth + ResolverGeometry.codeGap
        let digit = ("0" as NSString).size(withAttributes: [.font: ResolverAttributes.codeFont]).width
        let widest = CGFloat(lines.map { $0.text.utf16.count }.max() ?? 0) * digit
        view.setFrameSize(NSSize(width: max(400, view.codeInset + widest + 40), height: ResolverGeometry.y(ofRow: rows.count + 1)))
        column.overlay.numberWidth = numberWidth
        var model = ResolverColumnsModel()
        model.rows = rows
        column.overlay.model = model
        column.overlay.needsDisplay = true
    }
}
