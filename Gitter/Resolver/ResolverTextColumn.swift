import AppKit
import GitCore
import GitterSyntax

/// What the columns' views draw from, rebuilt with every render of the rows
/// (`ResolverColumnsHost`): the rows, and per conflict its rows and whether it can be taken.
struct ResolverColumnsModel {
    var rows: [LayoutRow] = []
    /// The conflicts (chunks holding a block), in order.
    var conflicts: [Int] = []
    /// Per chunk id, its rows (Show Base rows included) and its first row below them.
    var chunkRows: [Int: Range<Int>] = [:]
    var firstRow: [Int: Int] = [:]
    /// Conflicts still waiting.
    var waiting: Set<Int> = []
    /// Conflicts a take can act on: not merged by an edit.
    var takeable: Set<Int> = []
    /// The current conflict (`ResolverFocus.currentChunk`).
    var current: Int?
    /// Takes, typing, undo and redo: the draft is editable.
    var canTake = false

    init() {}

    init(rows: [LayoutRow], document: ResolverDocument, current: Int?, canTake: Bool) {
        self.rows = rows
        self.current = current
        self.canTake = canTake
        for chunk in document.chunks where !chunk.blocks.isEmpty {
            conflicts.append(chunk.id)
            if chunk.state == .waiting { waiting.insert(chunk.id) }
            if !chunk.isMerged { takeable.insert(chunk.id) }
        }
        var start = 0
        while start < rows.count {
            let id = rows[start].chunk
            var end = start
            while end < rows.count, rows[end].chunk == id { end += 1 }
            chunkRows[id] = start..<end
            firstRow[id] = (start..<end).first { !rows[$0].isBaseStrip } ?? start
            start = end
        }
    }

    /// The same conflicts, rows, states and current conflict: the strips, chips and outlines
    /// need no new layout.
    func sameLayout(as other: ResolverColumnsModel) -> Bool {
        rows.count == other.rows.count && current == other.current && canTake == other.canTake
            && conflicts == other.conflicts && waiting == other.waiting && takeable == other.takeable
            && chunkRows == other.chunkRows
    }

    /// "Conflict N" of the conflicts, for VoiceOver.
    func conflictIndex(_ id: Int) -> Int? { conflicts.firstIndex(of: id) }
}

/// The columns' shared geometry: every row `rowHeight` tall, from `top`.
@MainActor enum ResolverGeometry {
    static let rowHeight = ResolverAttributes.rowHeight
    static let top: CGFloat = 8
    /// Space between the line numbers and the code.
    static let codeGap: CGFloat = 10

    static func y(ofRow row: Int) -> CGFloat { top + CGFloat(row) * rowHeight }

    /// The rows a vertical span shows.
    static func rows(in rect: NSRect, count: Int) -> Range<Int> {
        guard count > 0 else { return 0..<0 }
        let first = max(0, Int(((rect.minY - top) / rowHeight).rounded(.down)))
        let last = min(count, Int(((rect.maxY - top) / rowHeight).rounded(.up)) + 1)
        return first < last ? first..<last : 0..<0
    }

    /// The width of the line-number gutter for numbers up to `lines`.
    static func numberWidth(lines: Int) -> CGFloat {
        let digits = max(2, String(max(lines, 1)).count)
        return CGFloat(digits) * numberDigit + 22
    }

    private static let numberDigit = ("0" as NSString).size(withAttributes: [.font: ResolverColumnOverlay.numberFont]).width
}

/// A column's text view (TextKit 2): Ours and Theirs read-only, the Result editable when the
/// draft is. Behind the text it draws each row's tint, the grey fillers and the word marks, all
/// from the text's attributes (`ResolverAttributes`). The Result's typing never edits this text
/// directly: `ResolverColumnsHost` maps it to the document, and the text is rebuilt from the
/// model. Its own undo is off; ⌘Z and ⇧⌘Z go to the store.
final class ResolverTextView: NSTextView {
    private(set) var column: ResolverColumn = .result
    weak var host: ResolverColumnsHost?
    var palette = ResolverPalette.standard
    /// The text's offset of each row, and the text's length last (`ResolverColumnsHost`).
    var starts: [Int] = [0]
    /// How many rows from the top TextKit has laid out (`layOut(throughRow:)`). Every change to
    /// the text, whoever makes it — the host's patches and row restores, AppKit's own marked text
    /// — lowers it to the row the change starts in (`storageEdited`).
    private(set) var laidOutRows = 0
    /// Where the composition of an input method started (dead keys, Japanese and the like): the
    /// selection then, in this text. The marked text is shown as AppKit types it and committed to
    /// the document only when it is final.
    private(set) var compositionStart: NSRange?
    /// The composition is being made plain text before it is committed.
    private var committing = false

    static let maxLineWidth: CGFloat = 50_000

    /// The text's store: the layout manager holds it weakly.
    private let contentStorage = NSTextContentStorage()

    init(column: ResolverColumn) {
        self.column = column
        let manager = NSTextLayoutManager()
        // Wide enough for any line (each row is one line: no wrapping), but finite: a layer as
        // wide as the container must stay drawable.
        let container = NSTextContainer(size: NSSize(width: Self.maxLineWidth, height: 10_000_000))
        container.widthTracksTextView = false
        container.heightTracksTextView = false
        container.lineFragmentPadding = 0
        manager.textContainer = container
        contentStorage.addTextLayoutManager(manager)
        contentStorage.primaryTextLayoutManager = manager
        super.init(frame: .zero, textContainer: container)
        // Rich: a plain-text view lays every line out with its own default style, not the rows'
        // fixed height. Nothing typed keeps its attributes anyway (the text is the model's).
        isRichText = true
        defaultParagraphStyle = ResolverAttributes.paragraphStyle
        importsGraphics = false
        allowsUndo = false
        allowsImageEditing = false
        usesFontPanel = false
        usesRuler = false
        usesFindBar = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticTextReplacementEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticTextCompletionEnabled = false
        isContinuousSpellCheckingEnabled = false
        isGrammarCheckingEnabled = false
        smartInsertDeleteEnabled = false
        isVerticallyResizable = false
        isHorizontallyResizable = false
        isEditable = false
        isSelectable = true
        drawsBackground = true
        backgroundColor = palette.window
        textContainerInset = NSSize(width: 0, height: ResolverGeometry.top)
        typingAttributes = [
            .font: ResolverAttributes.codeFont, .paragraphStyle: ResolverAttributes.paragraphStyle,
            .foregroundColor: palette.text,
        ]
        // Moving text by dragging it would be two edits with offsets of the text before both.
        if column == .result { unregisterDraggedTypes() }
        setAccessibilityLabel(ConflictWording.columnLabel(column))
        NotificationCenter.default.addObserver(
            self, selector: #selector(storageEdited(_:)), name: NSTextStorage.didProcessEditingNotification,
            object: textStorage)
    }

    /// The text changed: the rows from the one the change starts in are laid out again when next
    /// in view. `starts` may still be the old rows' (the host sets them after its edit, AppKit's
    /// marked text never does), but the rows above the change are the same in both.
    @objc private func storageEdited(_ notification: Notification) {
        guard let storage = notification.object as? NSTextStorage else { return }
        let location = storage.editedRange.location
        guard location != NSNotFound else { return }
        var low = 0, high = starts.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= location { low = middle } else { high = middle - 1 }
        }
        laidOutRows = min(laidOutRows, low)
    }

    override init(frame frameRect: NSRect, textContainer container: NSTextContainer?) {
        super.init(frame: frameRect, textContainer: container)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    /// The code starts after the line numbers.
    var codeInset: CGFloat = 40 {
        didSet { textContainerInset = NSSize(width: codeInset, height: ResolverGeometry.top) }
    }

    override var textContainerOrigin: NSPoint { NSPoint(x: codeInset, y: ResolverGeometry.top) }

    /// Lays out the rows down to `row` that are not laid out yet, at most `budget` of them; true
    /// once every row above `row` is. TextKit 2 places the lines it shows by an estimate of the
    /// lines above them it has not laid out, and the estimate is not a row's height (a jump 222
    /// rows down drew the text 490 pt high); with the lines above laid out, each line it shows
    /// sits on its row, where the numbers, bars and outline are drawn.
    @discardableResult
    func layOut(throughRow row: Int, budget: Int) -> Bool {
        let row = min(row, starts.count - 1)
        guard row > laidOutRows else { return true }
        let through = min(row, laidOutRows + max(1, budget))
        guard let manager = textLayoutManager, let content = manager.textContentManager,
            let from = content.location(content.documentRange.location, offsetBy: starts[laidOutRows]),
            let to = content.location(content.documentRange.location, offsetBy: starts[through]),
            let range = NSTextRange(location: from, end: to)
        else { return true }
        manager.ensureLayout(for: range)
        laidOutRows = through
        return through == row
    }

    // MARK: Syntax colours

    /// Each row's syntax tokens (`ResolverSyntax`), empty for a plain row: one per row, kept in
    /// step with `starts` by the host.
    private(set) var rowTokens: [[SyntaxToken]] = []
    /// The rows whose colours are their `rowTokens` now. Both kinds of colour move with the text
    /// when rows above change, and a replaced paragraph loses its own (measured, Task 4).
    private(set) var colouredRows = IndexSet()

    /// Every row's tokens anew, for new text (`patch` from nothing) or after `clear`: no row is
    /// coloured yet.
    func resetRowTokens(_ tokens: [[SyntaxToken]]) {
        rowTokens = tokens
        colouredRows = []
    }

    /// Every row's tokens from a new parse: a row whose tokens did not change keeps its colours.
    func updateRowTokens(_ tokens: [[SyntaxToken]]) {
        guard tokens.count == rowTokens.count else { return resetRowTokens(tokens) }
        colouredRows = colouredRows.filteredIndexSet { rowTokens[$0] == tokens[$0] }
        rowTokens = tokens
    }

    /// The host replaced the paragraphs of rows `old` with `new.count` new ones (`patch`): those
    /// carry no colour; the rows after them keep theirs, which moved with their text.
    func replaceRowTokens(_ old: Range<Int>, with new: [[SyntaxToken]]) {
        guard old.upperBound <= rowTokens.count else { return resetRowTokens(new) }
        rowTokens.replaceSubrange(old, with: new)
        colouredRows.remove(integersIn: old)
        colouredRows.shift(startingAt: old.upperBound, by: new.count - old.count)
    }

    /// A row's paragraph was put back as it was (`restoreRow`): coloured again when next asked.
    func rowReplaced(_ row: Int) {
        colouredRows.remove(row)
    }

    /// Gives the rows in `range` not coloured yet their tokens' colours; how many rows that was.
    ///
    /// - **The Result** takes them as rendering attributes of its layout manager, over each row's
    ///   paragraph (anything there before removed first): its text is the store's, edited only
    ///   through `patch`, and its storage feeds the edit map and the input method.
    /// - **Ours and Theirs** are read-only, with no undo and no edit tracking, so they take them
    ///   in the text itself (Ruling 9): `.foregroundColor` over each row's text, the plain text
    ///   colour first, in one batch of edits. TextKit lays the edited rows out again and draws
    ///   them like any text, where a rendering attribute is redrawn on every scroll (measured,
    ///   Task 4) and a line already drawn did not take one at all.
    ///
    /// Nothing while an input method composes in the Result: its text then holds the marked
    /// text, which `starts` doesn't count, so every offset after it would be off. `restoreRow`
    /// colours the rows once the composition ends.
    @discardableResult
    func colour(rows range: Range<Int>) -> Int {
        if column == .result, hasMarkedText() || compositionStart != nil { return 0 }
        let range = range.clamped(to: 0..<min(starts.count - 1, rowTokens.count))
        guard !range.isEmpty, let storage = textStorage else { return 0 }
        var missing = IndexSet(integersIn: range)
        missing.subtract(colouredRows)
        guard let first = missing.first, let last = missing.last else { return 0 }
        colouredRows.formUnion(missing)
        if column == .result {
            colourRendering(missing, length: storage.length)
            let top = ResolverGeometry.y(ofRow: first)
            redisplay(NSRect(x: 0, y: top, width: bounds.width, height: ResolverGeometry.y(ofRow: last + 1) - top))
        } else {
            colourStorage(missing, storage)
        }
        return missing.count
    }

    /// Marks `rect` for display in this view and in every view under it that covers part of it.
    ///
    /// TextKit 2 draws each line in a view of its own under the text view. Adding a rendering
    /// attribute marks none of them, and nor does the text view's own `setNeedsDisplay(_:)`: in
    /// the real app, lines drawn plain when a jump brought them back into view (⌘] then ⌘[ at
    /// 5,000 lines while the parse ran) stayed plain under their new colours. Each public route
    /// was tried there and left them plain (Ruling 14): `setNeedsDisplay(rect)` now and on the
    /// next turn, `needsDisplay = true`, `textViewportLayoutController.layoutViewport()`,
    /// `invalidateLayout(for:)` over the rows in the viewport (before or after colouring, with
    /// or without `layoutViewport()`), and a `renderingAttributesValidator` with
    /// `invalidateRenderingAttributes(for:)`, which TextKit never called again. Marking the line
    /// views is what draws them. It uses only public `NSView` calls on the views AppKit put under
    /// this one, and marks nothing when there are none.
    private func redisplay(_ rect: NSRect) {
        setNeedsDisplay(rect)
        func mark(_ view: NSView) {
            for subview in view.subviews {
                let local = subview.convert(rect, from: self).intersection(subview.bounds)
                if !local.isEmpty { subview.setNeedsDisplay(local) }
                mark(subview)
            }
        }
        mark(self)
    }

    private func colourRendering(_ rows: IndexSet, length: Int) {
        guard let manager = textLayoutManager, let content = manager.textContentManager else { return }
        let origin = content.documentRange.location
        let palette = SyntaxPalette.standard
        for row in rows {
            let start = starts[row], end = starts[row + 1]
            guard start < end, end <= length, let from = content.location(origin, offsetBy: start),
                let to = content.location(from, offsetBy: end - start), let paragraph = NSTextRange(location: from, end: to)
            else { continue }
            manager.removeRenderingAttribute(.foregroundColor, for: paragraph)
            // The paragraph's text, without its break.
            let text = end - start - 1
            for token in rowTokens[row] where !token.range.isEmpty && token.range.upperBound <= text {
                guard let lower = content.location(from, offsetBy: token.range.lowerBound),
                    let upper = content.location(lower, offsetBy: token.range.count),
                    let tokenRange = NSTextRange(location: lower, end: upper)
                else { continue }
                manager.addRenderingAttribute(.foregroundColor, value: palette.color(token.kind), for: tokenRange)
            }
        }
    }

    private func colourStorage(_ rows: IndexSet, _ storage: NSTextStorage) {
        let syntax = SyntaxPalette.standard
        storage.beginEditing()
        for row in rows {
            let start = starts[row], end = starts[row + 1]
            // The row's text, without its break; a filler has none.
            guard start < end, end <= storage.length, end - start > 1 else { continue }
            let text = end - start - 1
            storage.addAttribute(.foregroundColor, value: palette.text, range: NSRange(location: start, length: text))
            for token in rowTokens[row] where !token.range.isEmpty && token.range.upperBound <= text {
                storage.addAttribute(
                    .foregroundColor, value: syntax.color(token.kind),
                    range: NSRange(location: start + token.range.lowerBound, length: token.range.count))
            }
        }
        storage.endEditing()
    }

    // MARK: Drawing

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let storage = textStorage, starts.count > 1 else { return }
        let count = starts.count - 1
        let visible = ResolverGeometry.rows(in: rect, count: count)
        for row in visible {
            let location = starts[row]
            guard location < storage.length,
                let style = storage.attribute(.resolverRow, at: location, effectiveRange: nil) as? ResolverRowStyle
            else { continue }
            let y = ResolverGeometry.y(ofRow: row)
            let band = NSRect(x: rect.minX, y: y, width: rect.width, height: ResolverGeometry.rowHeight)
            if style.kind == .slot { continue }
            if let colour = palette.background(style.tint) {
                colour.setFill()
                band.fill()
            }
            // The stronger marks, on the sides: where each side changed a word.
            guard column != .result, style.kind == .text else { continue }
            let paragraph = NSRange(location: location, length: max(0, starts[row + 1] - location - 1))
            storage.enumerateAttribute(.resolverMark, in: paragraph) { value, range, _ in
                guard value != nil else { return }
                palette.word(column).setFill()
                for mark in rects(for: range) {
                    let box = NSRect(x: mark.minX - 1, y: y + 2, width: mark.width + 2, height: ResolverGeometry.rowHeight - 4)
                    NSBezierPath(roundedRect: box, xRadius: 3, yRadius: 3).fill()
                }
            }
        }
    }

    /// The rectangles a range of the text covers, in this view.
    func rects(for range: NSRange) -> [NSRect] {
        guard let manager = textLayoutManager, let content = manager.textContentManager,
            let start = content.location(content.documentRange.location, offsetBy: range.location),
            let end = content.location(start, offsetBy: range.length),
            let textRange = NSTextRange(location: start, end: end)
        else { return [] }
        var rects: [NSRect] = []
        manager.enumerateTextSegments(in: textRange, type: .standard, options: []) { _, frame, _, _ in
            rects.append(frame.offsetBy(dx: textContainerOrigin.x, dy: textContainerOrigin.y))
            return true
        }
        return rects
    }

    // MARK: Typing, through the host

    override func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        guard column == .result, let host else {
            super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacementRange)
            return
        }
        var replacement = replacementRange
        if !hasMarkedText() {
            // A selection the composition replaces is deleted first, as typing would.
            let selection = self.selectedRange
            if selection.length > 0 {
                host.typed(selection, "")
                replacement = NSRange(location: NSNotFound, length: 0)
            }
            compositionStart = self.selectedRange
        }
        super.setMarkedText(string, selectedRange: selectedRange, replacementRange: replacement)
        // Marked text emptied: the input method cancelled the composition (the last marked
        // character deleted, Escape in its candidates). Nothing reaches the store, and the text is
        // the store's again.
        if !committing, !hasMarkedText(), let start = compositionStart { endComposition(start, host: host) }
    }

    /// A composition that ended with nothing committed: the row as the model has it, the caret
    /// where the composition started.
    private func endComposition(_ start: NSRange, host: ResolverColumnsHost) {
        compositionStart = nil
        host.restoreRow(host.resultMap?.row(at: start.location) ?? 0, in: self)
        if start.location <= (textStorage?.length ?? 0) {
            setSelectedRange(NSRange(location: start.location, length: 0))
        }
    }

    override func insertText(_ string: Any, replacementRange: NSRange) {
        guard !committing, let start = compositionStart, let host else {
            super.insertText(string, replacementRange: replacementRange)
            return
        }
        commitComposition(start, text: (string as? NSAttributedString)?.string ?? (string as? String) ?? "", host: host)
    }

    override func unmarkText() {
        guard !committing, let start = compositionStart, let host, hasMarkedText() else {
            super.unmarkText()
            if !committing, !hasMarkedText(), let start = compositionStart, let host { endComposition(start, host: host) }
            return
        }
        let marked = (string as NSString).substring(with: markedRange())
        commitComposition(start, text: marked, host: host)
    }

    private func commitComposition(_ start: NSRange, text: String, host: ResolverColumnsHost) {
        let row = host.resultMap?.row(at: start.location) ?? 0
        // Unmarking makes the marked text plain text (AppKit may insert it to do so), an edit of
        // this text only: the row is put back from the model below, and the final text goes to
        // the store once.
        committing = true
        super.unmarkText()
        committing = false
        compositionStart = nil
        host.restoreRow(row, in: self)
        if !text.isEmpty { host.typed(NSRange(location: start.location, length: 0), text) }
    }

    // MARK: Copy and Cut, the document's text

    /// The Result copies the document's text, so a Cut and Paste writes back exactly what was
    /// there: no filler or slot rows, no Show Base text, no stand-in symbols, CRLF as in the file.
    override var writablePasteboardTypes: [NSPasteboard.PasteboardType] {
        column == .result && host != nil ? [.string] : super.writablePasteboardTypes
    }

    override func writeSelection(to pboard: NSPasteboard, type: NSPasteboard.PasteboardType) -> Bool {
        guard column == .result, let host else { return super.writeSelection(to: pboard, type: type) }
        guard type == .string, let text = host.documentText(for: selectedRanges.map(\.rangeValue)) else { return false }
        return pboard.setString(text, forType: .string)
    }

    override func writeSelection(to pboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> Bool {
        guard column == .result, host != nil else { return super.writeSelection(to: pboard, types: types) }
        guard types.contains(.string) else { return false }
        pboard.declareTypes([.string], owner: nil)
        return writeSelection(to: pboard, type: .string)
    }

    /// Escape leaves the text, so the next one is Done (`ResolverKeyMonitor`).
    override func cancelOperation(_ sender: Any?) {
        if isEditable, let host { window?.makeFirstResponder(host) } else { super.cancelOperation(sender) }
    }

    // MARK: Undo, the store's

    @objc func undo(_ sender: Any?) { host?.undo() }
    @objc func redo(_ sender: Any?) { host?.redo() }

    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return host?.canUndo ?? false }
        if item.action == #selector(redo(_:)) { return host?.canRedo ?? false }
        return super.validateUserInterfaceItem(item)
    }
}

/// One column: its text view in a scroll view, and over it the overlay with the line numbers,
/// the bars, the outline of the current conflict and, in the Result, the slot and the badges.
final class ResolverTextColumn: NSView {
    let column: ResolverColumn
    let scrollView = NSScrollView()
    let textView: ResolverTextView
    let overlay: ResolverColumnOverlay

    init(column: ResolverColumn) {
        self.column = column
        textView = ResolverTextView(column: column)
        overlay = ResolverColumnOverlay(column: column)
        super.init(frame: .zero)
        clipsToBounds = true
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = column == .theirs
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ResolverPalette.standard.window
        scrollView.contentView.postsBoundsChangedNotifications = true
        scrollView.verticalScrollElasticity = .none
        scrollView.horizontalScrollElasticity = .none
        addSubview(scrollView)
        addSubview(overlay)
        NotificationCenter.default.addObserver(
            self, selector: #selector(scrolled), name: NSView.boundsDidChangeNotification, object: scrollView.contentView)
    }

    /// The overlay follows the text down, and learns how far it is scrolled sideways.
    @objc private func scrolled() {
        let origin = scrollView.contentView.bounds.origin
        if overlay.bounds.origin.y != origin.y { overlay.setBoundsOrigin(NSPoint(x: 0, y: origin.y)) }
        if overlay.horizontalOffset != origin.x {
            overlay.horizontalOffset = origin.x
            overlay.needsDisplay = true
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scrollView.frame = bounds
        overlay.frame = bounds
        overlay.setBoundsOrigin(NSPoint(x: 0, y: scrollView.contentView.bounds.origin.y))
    }
}

/// Over a column, scrolled with it vertically but not sideways: the line numbers on their row's
/// tint, the 3 pt bars, the outline of the current conflict and, in the Result, the dashed slot
/// with its chips and the badges. Clicks go through to the text, except on a chip.
final class ResolverColumnOverlay: NSView {
    static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
    static let badgeFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    static let promptFont = NSFont.systemFont(ofSize: 11)

    let column: ResolverColumn
    var palette = ResolverPalette.standard
    var model = ResolverColumnsModel()
    var numberWidth: CGFloat = 40
    /// How far the text is scrolled sideways, for whether a line reaches its badge.
    var horizontalOffset: CGFloat = 0
    /// The chips' actions (`ResolverColumnsHost`).
    var take: ((BlockChoice, Int) -> Void)?
    var labels = SideLabels(ours: "", theirs: "")

    private var chips: [Int: [NSButton]] = [:]
    /// Where each slot's chips start, so its words stop before them.
    private var chipsMinX: [Int: CGFloat] = [:]
    private var badgeElements: [NSAccessibilityElement] = []

    init(column: ResolverColumn) {
        self.column = column
        super.init(frame: .zero)
        clipsToBounds = true
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let hit = super.hitTest(point)
        return hit === self ? nil : hit
    }

    private func cell(_ row: LayoutRow) -> LayoutCell { ResolverAttributes.cell(row, column) }

    override func draw(_ dirtyRect: NSRect) {
        let rows = model.rows
        let visible = ResolverGeometry.rows(in: dirtyRect, count: rows.count)
        let height = ResolverGeometry.rowHeight
        let numberAttributes: [NSAttributedString.Key: Any] = [.font: Self.numberFont, .foregroundColor: palette.lineNumber]
        for index in visible {
            let row = rows[index]
            let cell = cell(row)
            let y = ResolverGeometry.y(ofRow: index)
            let gutter = NSRect(x: 0, y: y, width: numberWidth, height: height)
            let slot = column == .result && row.isSlot && !row.isBaseStrip
            let tint: RowTint = slot ? .none : (cell.text == nil && !(column == .result && row.isBaseStrip) ? .filler : cell.tint)
            (palette.background(tint) ?? palette.window).setFill()
            gutter.fill()
            if let bar = palette.bar(tint) {
                bar.setFill()
                NSRect(x: 0, y: y, width: 3, height: height).fill()
            }
            if let number = cell.lineNumber {
                let text = "\(number)" as NSString
                let size = text.size(withAttributes: numberAttributes)
                text.draw(at: NSPoint(x: numberWidth - 8 - size.width, y: y + (height - size.height) / 2), withAttributes: numberAttributes)
            }
        }
        if column == .result { drawSlots(dirtyRect) }
        drawOutline()
        if column == .result { drawBadges(dirtyRect) }
    }

    // MARK: The slot

    /// Each waiting conflict's slot: its rows in the Result.
    private func slotRect(_ id: Int) -> NSRect? {
        guard let range = model.chunkRows[id] else { return nil }
        let slotRows = range.filter { model.rows[$0].isSlot && !model.rows[$0].isBaseStrip }
        guard let first = slotRows.first, let last = slotRows.last else { return nil }
        let top = ResolverGeometry.y(ofRow: first), bottom = ResolverGeometry.y(ofRow: last + 1)
        return NSRect(x: numberWidth + 6, y: top + 3, width: bounds.width - numberWidth - 14, height: bottom - top - 6)
    }

    private func drawSlots(_ dirtyRect: NSRect) {
        let prompt: [NSAttributedString.Key: Any] = [.font: Self.promptFont, .foregroundColor: palette.badgeOrange]
        for id in model.waiting {
            guard let box = slotRect(id), box.intersects(dirtyRect) else { continue }
            palette.waitingSlot.setFill()
            let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
            path.fill()
            palette.accent.setStroke()
            path.lineWidth = 1
            path.setLineDash([4, 3], count: 2, phase: 0)
            path.stroke()
            // The words, where they fit before the chips; else as many as fit.
            let text = ConflictWording.slotPrompt as NSString
            let size = text.size(withAttributes: prompt)
            let room = (chipsMinX[id] ?? box.maxX) - 8 - (box.minX + 10)
            guard room > 20 else { continue }
            text.draw(
                with: NSRect(x: box.minX + 10, y: box.midY - size.height / 2, width: room, height: size.height),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: prompt)
        }
    }

    // MARK: The outline

    private func drawOutline() {
        guard let current = model.current, let range = model.chunkRows[current], !range.isEmpty else { return }
        let top = ResolverGeometry.y(ofRow: range.lowerBound), bottom = ResolverGeometry.y(ofRow: range.upperBound)
        let box = NSRect(x: 1.5, y: top + 0.75, width: bounds.width - 3, height: bottom - top - 1.5)
        palette.accent.setStroke()
        let path = NSBezierPath(roundedRect: box, xRadius: 4, yRadius: 4)
        path.lineWidth = 1.5
        path.stroke()
    }

    // MARK: Badges

    struct Badge {
        let badge: ResultBadge
        let rect: NSRect
        let conflict: Int?
    }

    /// Each badge at the right edge of its first row — or, when that row's text reaches it, on
    /// the row below its chunk (or its run of common lines), as the mockup draws "Edited by you".
    func badges(in rect: NSRect) -> [Badge] {
        let rows = model.rows
        var result: [Badge] = []
        let codeAttributes: [NSAttributedString.Key: Any] = [.font: ResolverAttributes.codeFont]
        let height = ResolverGeometry.rowHeight
        for index in ResolverGeometry.rows(in: rect.insetBy(dx: 0, dy: -height * 40), count: rows.count) {
            guard let badge = rows[index].badge else { continue }
            let width = Self.badgeWidth(badge)
            let x = bounds.width - width - 8
            var row = index
            let text = rows[index].result.text ?? ""
            // Measured only when the line could reach it at the code font's advance.
            let estimate = CGFloat(text.utf16.count) * ResolverAttributes.characterWidth * 2
            let measured = numberWidth + ResolverGeometry.codeGap + estimate - horizontalOffset > x - 8
                ? (text as NSString).size(withAttributes: codeAttributes).width : 0
            let reach = numberWidth + ResolverGeometry.codeGap + measured - horizontalOffset
            if reach > x - 8 {
                row = runEnd(from: index)
            }
            let y = ResolverGeometry.y(ofRow: row) + (height - 15) / 2
            let isConflict = model.conflicts.contains(rows[index].chunk)
            result.append(Badge(badge: badge, rect: NSRect(x: x, y: y, width: width, height: 15), conflict: isConflict ? rows[index].chunk : nil))
        }
        return result
    }

    private static var badgeWidths: [ResultBadge: CGFloat] = [:]

    private static func badgeWidth(_ badge: ResultBadge) -> CGFloat {
        if let width = badgeWidths[badge] { return width }
        let width = (ConflictWording.badge(badge) as NSString).size(withAttributes: [.font: badgeFont]).width + 12
        badgeWidths[badge] = width
        return width
    }

    /// The row after the badge's chunk, or after its run of common lines with one tint.
    private func runEnd(from index: Int) -> Int {
        let rows = model.rows
        let chunk = rows[index].chunk
        if model.conflicts.contains(chunk) { return model.chunkRows[chunk]?.upperBound ?? index + 1 }
        var end = index + 1
        while end < rows.count, rows[end].chunk == chunk, rows[end].badge == nil, rows[end].result.tint == rows[index].result.tint {
            end += 1
        }
        return end
    }

    private func badgeColours(_ badge: ResultBadge) -> (fill: NSColor, text: NSColor) {
        switch badge {
        case .ours, .theirs, .oursThenTheirs, .theirsThenOurs: (palette.resolved.withAlphaComponent(0.16), palette.badgeGreen)
        case .editedByYou: (palette.accent.withAlphaComponent(0.18), palette.badgeOrange)
        case .fromOurs: (palette.ours.withAlphaComponent(0.16), palette.ours)
        case .fromTheirs: (palette.theirs.withAlphaComponent(0.16), palette.badgePurple)
        }
    }

    private func drawBadges(_ dirtyRect: NSRect) {
        for badge in badges(in: dirtyRect) where badge.rect.intersects(dirtyRect) {
            let colours = badgeColours(badge.badge)
            colours.fill.setFill()
            NSBezierPath(roundedRect: badge.rect, xRadius: 7.5, yRadius: 7.5).fill()
            let words = ConflictWording.badge(badge.badge) as NSString
            let attributes: [NSAttributedString.Key: Any] = [.font: Self.badgeFont, .foregroundColor: colours.text]
            let size = words.size(withAttributes: attributes)
            words.draw(at: NSPoint(x: badge.rect.midX - size.width / 2, y: badge.rect.midY - size.height / 2), withAttributes: attributes)
        }
    }

    // MARK: Chips and accessibility

    /// The chips of each waiting slot: ← Ours, Both (⌥-click or its menu: theirs first), Theirs →.
    func layoutChips() {
        guard column == .result else { return }
        let wanted = model.canTake ? model.waiting.intersection(model.takeable) : []
        for (id, buttons) in chips where !wanted.contains(id) {
            buttons.forEach { $0.removeFromSuperview() }
            chips[id] = nil
            chipsMinX[id] = nil
        }
        for id in wanted {
            guard let box = slotRect(id) else { continue }
            let buttons = chips[id] ?? makeChips(id)
            chips[id] = buttons
            var x = box.maxX - 8
            for button in buttons.reversed() {
                let width = button.cell?.cellSize.width ?? button.fittingSize.width
                let size = NSSize(width: width + 4, height: 18)
                x -= size.width
                let frame = NSRect(x: x, y: box.midY - size.height / 2, width: size.width, height: size.height)
                if button.frame != frame { button.frame = frame }
                x -= 6
            }
            chipsMinX[id] = x + 6
            if let index = model.conflictIndex(id) {
                let count = model.conflicts.count
                let label = ConflictWording.takeLabel(.ours, conflict: index, of: count)
                guard buttons[0].accessibilityLabel() != label else { continue }
                buttons[0].setAccessibilityLabel(label)
                buttons[1].setAccessibilityLabel(ConflictWording.takeLabel(.oursThenTheirs, conflict: index, of: count))
                buttons[2].setAccessibilityLabel(ConflictWording.takeLabel(.theirs, conflict: index, of: count))
            }
        }
        accessibilityStale = true
    }

    /// The badges' and slots' elements are made again when VoiceOver next asks.
    private var accessibilityStale = true

    private func makeChips(_ id: Int) -> [NSButton] {
        let titles = [ConflictWording.slotOurs, ConflictWording.slotBoth, ConflictWording.slotTheirs]
        let choices: [BlockChoice] = [.ours, .oursThenTheirs, .theirs]
        let buttons = zip(titles, choices).map { title, choice in
            let button = ResolverChip(title: title)
            button.bezelStyle = .push
            button.controlSize = .small
            button.font = NSFont.systemFont(ofSize: 11)
            button.contentTintColor = choice == .ours ? palette.ours : choice == .theirs ? palette.theirs : nil
            button.onPress = { [weak self] option in
                let picked: BlockChoice = choice == .oursThenTheirs && option ? .theirsThenOurs : choice
                self?.take?(picked, id)
            }
            button.toolTip = choice == .oursThenTheirs
                ? ConflictWording.bothOursFirst + " (\u{2325}-click: " + ConflictWording.bothTheirsFirst + ")"
                : ConflictWording.takeHelp(choice == .ours ? .ours : .theirs, labels)
            addSubview(button)
            return button
        }
        // Both's menu: theirs first.
        let menu = NSMenu()
        for (title, choice) in [(ConflictWording.bothOursFirst, BlockChoice.oursThenTheirs), (ConflictWording.bothTheirsFirst, .theirsThenOurs)] {
            let item = ResolverMenuItem(title: title) { [weak self] in self?.take?(choice, id) }
            menu.addItem(item)
        }
        buttons[1].menu = menu
        return buttons
    }

    /// The badges and the slot for VoiceOver: drawn, so given as elements of their own.
    func updateAccessibility() {
        accessibilityStale = true
    }

    private func makeAccessibilityElements() {
        accessibilityStale = false
        guard column == .result else { return }
        let count = model.conflicts.count
        var elements: [NSAccessibilityElement] = []
        let visible = NSRect(x: 0, y: bounds.minY, width: bounds.width, height: bounds.height)
        for badge in badges(in: visible) {
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.staticText)
            element.setAccessibilityLabel(
                ConflictWording.badgeLabel(badge.badge, conflict: badge.conflict.flatMap(model.conflictIndex), of: count))
            element.setAccessibilityFrameInParentSpace(badge.rect)
            element.setAccessibilityParent(self)
            elements.append(element)
        }
        for id in model.waiting.sorted() {
            guard let box = slotRect(id), let index = model.conflictIndex(id) else { continue }
            let element = NSAccessibilityElement()
            element.setAccessibilityRole(.group)
            element.setAccessibilityLabel(ConflictWording.slotLabel(conflict: index, of: count))
            element.setAccessibilityFrameInParentSpace(box)
            element.setAccessibilityParent(self)
            elements.append(element)
        }
        badgeElements = elements
    }

    override func accessibilityChildren() -> [Any]? {
        if accessibilityStale { makeAccessibilityElements() }
        return (super.accessibilityChildren() ?? []) + badgeElements
    }

    override func isAccessibilityElement() -> Bool { false }
}

/// A button that tells whether ⌥ was down when it was pressed.
final class ResolverChip: NSButton {
    var onPress: ((Bool) -> Void)?

    convenience init(title: String) {
        self.init(frame: .zero)
        self.title = title
        self.target = self
        self.action = #selector(pressed)
    }

    @objc private func pressed() {
        onPress?(NSApp.currentEvent?.modifierFlags.contains(.option) ?? false)
    }
}

/// A menu item that runs a closure.
final class ResolverMenuItem: NSMenuItem {
    private let run: () -> Void

    init(title: String, run: @escaping () -> Void) {
        self.run = run
        super.init(title: title, action: #selector(runAction), keyEquivalent: "")
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError() }

    @objc private func runAction() { run() }
}
