import AppKit
import GitCore

/// The three columns and the two strips between them, as one AppKit view: Ours | → | Result | ← |
/// Theirs on the headers' grid (`ResolverGrid`), scrolled as one.
///
/// **Rendering.** Each render lays the draft out (`ResolverLayout.rows`, reusing the sides' part,
/// `ResolverLayout.Sides`, held here per draft and rebuilt only when it no longer fits — Rulings
/// 10 and 13), then patches each column's text only where its rows changed: the rows before and
/// after the change are compared, and the paragraphs between are rebuilt
/// (`ResolverAttributes`). Line numbers are drawn from the rows, never part of the text, so a
/// typed line break does not rebuild every row below it.
///
/// **Typing.** The Result's text view never edits its own text. Each change it asks for is mapped
/// to the document (`ResolverEditMap`, which also carries the slot rule), given to the store
/// (`resolverReplace`), and the text is patched from the model at once; the caret lands after the
/// typed text. An input method's composition is shown as AppKit types it and given to the store
/// when it is final.
///
/// **The caret** follows the current conflict (`ResolverFocus.currentChunk`) whenever it moves or
/// the Result changes other than by typing (a take, undo, redo): it goes to the conflict's first
/// row, its slot when it waits, and the conflict is scrolled into view when it moved.
///
/// **Undo.** ⌘Z and ⇧⌘Z reach `undo:` and `redo:` here, or in a column's text view, and go to the
/// store's history; the text views' own undo is off.
final class ResolverColumnsHost: NSView, NSTextViewDelegate, NSUserInterfaceValidations {
    let ours = ResolverTextColumn(column: .ours)
    let result = ResolverTextColumn(column: .result)
    let theirs = ResolverTextColumn(column: .theirs)
    let left = ResolverGutterView(side: .ours)
    let right = ResolverGutterView(side: .theirs)

    weak var store: RepositoryStore?
    private(set) var path = ""
    var palette = ResolverPalette.standard

    private var sidesCache: (snapshot: ConflictSnapshot, sides: ResolverLayout.Sides)?
    /// The last build's rows per chunk, for the same draft (Ruling 32).
    private var rowCache = ResolverLayout.RowCache()
    private var snapshot: ConflictSnapshot?
    private var document: ResolverDocument?
    private var rows: [LayoutRow] = []
    private var showBase = false
    private var current: Int?
    private var canTake = false
    private var editable = false
    private(set) var resultMap: ResolverEditMap?
    private(set) var model = ResolverColumnsModel()
    /// The widest line of the three, in points, so the three scroll sideways together.
    private var codeWidth: CGFloat = 0
    private var syncing = false
    private var focusedOnce = false
    /// A render came while an input method was composing: done once it commits.
    private var renderPending = false

    #if DEBUG
        /// The host on screen last, for the harness's `resolver:type:` step.
        static weak var debugLatest: ResolverColumnsHost?
    #endif

    private var columns: [ResolverTextColumn] { [ours, result, theirs] }

    init() {
        super.init(frame: .zero)
        clipsToBounds = true
        for column in columns {
            addSubview(column)
            column.textView.host = self
            NotificationCenter.default.addObserver(
                self, selector: #selector(clipChanged(_:)), name: NSView.boundsDidChangeNotification,
                object: column.scrollView.contentView)
        }
        addSubview(left)
        addSubview(right)
        result.textView.delegate = self
        for gutter in [left, right] {
            gutter.take = { [weak self] choice, id in self?.store?.resolverTake(choice, chunk: id) }
        }
        result.overlay.take = { [weak self] choice, id in self?.store?.resolverTake(choice, chunk: id) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    // MARK: - Layout

    override func layout() {
        super.layout()
        let gutter = ResolverGrid.gutterWidth
        let width = max(0, (bounds.width - 2 * gutter) / 3)
        ours.frame = NSRect(x: 0, y: 0, width: width, height: bounds.height)
        left.frame = NSRect(x: width, y: 0, width: gutter, height: bounds.height)
        result.frame = NSRect(x: width + gutter, y: 0, width: width, height: bounds.height)
        right.frame = NSRect(x: 2 * width + gutter, y: 0, width: gutter, height: bounds.height)
        theirs.frame = NSRect(x: 2 * width + 2 * gutter, y: 0, width: max(0, bounds.width - 2 * width - 2 * gutter), height: bounds.height)
        for column in columns { column.layoutSubtreeIfNeeded() }
        sizeTextViews()
        followScroll(result.scrollView.contentView.bounds.origin)
        result.overlay.layoutChips()
    }

    /// Every text view as tall as the rows and as wide as the widest line of the three.
    private func sizeTextViews() {
        let numberWidth = ResolverGeometry.numberWidth(lines: rows.count)
        let inset = numberWidth + ResolverGeometry.codeGap
        let height = ResolverGeometry.y(ofRow: rows.count + 1) + ResolverGeometry.top
        for column in columns {
            let clip = column.scrollView.contentView.bounds.size
            let view = column.textView
            if view.codeInset != inset { view.codeInset = inset }
            let size = NSSize(width: max(clip.width, inset + codeWidth + 40), height: max(clip.height, height))
            if view.frame.size != size { view.setFrameSize(size) }
            column.overlay.numberWidth = numberWidth
        }
    }

    // MARK: - Rendering

    /// The draft as the store has it now. Renders only what changed since the last call.
    func update(store: RepositoryStore, path: String, draft: ResolverDraft?, current: Int?, showBase: Bool, labels: SideLabels) {
        self.store = store
        #if DEBUG
            Self.debugLatest = self
        #endif
        for gutter in [left, right] { gutter.labels = labels }
        result.overlay.labels = labels
        guard let draft else {
            self.path = path
            clear()
            return
        }
        if result.textView.hasMarkedText() {
            renderPending = true
            return
        }
        let samePath = path == self.path && draft.snapshot == snapshot
        self.path = path
        let changed = !samePath || document.map { !Self.sameText($0, draft.document) } ?? true
        let canTake = draft.isEditable
        let editable = canTake && draft.document.notEditable == nil
        let moved = current != self.current || !samePath
        let rerender = changed || showBase != self.showBase || canTake != self.canTake
        // The caret, as a place in the document, kept across a render that is not typing.
        let caret = rerender && !moved ? captureCaret() : nil
        let before = document
        if rerender {
            render(draft, showBase: showBase, current: current, reset: !samePath)
        }
        if editable != self.editable {
            self.editable = editable
            result.textView.isEditable = editable
        }
        // A render has pushed the current conflict already.
        if current != model.current || (moved && !rerender) {
            self.current = current
            model.current = current
            pushModel(redraw: [.ours, .result, .theirs], layout: true)
        }
        if moved || Self.justTaken(current, before: before, after: draft.document) {
            // The current conflict moved, or was just taken: the caret follows it.
            caretToCurrent(scroll: moved)
        } else if changed, samePath, let before, let at = Self.firstDifference(before, draft.document) {
            // Undo, redo: the caret where the text changed — at the slot when the change is a
            // conflict waiting again, else on the line (a slot and the next line share an offset).
            let slot = draft.document.chunks.contains { chunk in
                chunk.state == .waiting && draft.document.range(ofChunk: chunk.id).location == at
                    && before.chunks.first { $0.id == chunk.id }?.state != .waiting
            }
            restoreCaret(Caret(offset: at, atSlot: slot))
        } else if rerender {
            // Show Base and the like: the caret stays where it was in the document.
            restoreCaret(caret)
        }
        if !focusedOnce, window != nil {
            focusedOnce = true
            // After SwiftUI's update: the keys go to the Result (or, read-only, to the columns).
            DispatchQueue.main.async { [weak self] in
                guard let self, let window = self.window else { return }
                window.makeFirstResponder(self.editable ? self.result.textView : self)
            }
        }
    }

    private func clear() {
        guard document != nil || !rows.isEmpty else { return }
        document = nil
        snapshot = nil
        sidesCache = nil
        rowCache = ResolverLayout.RowCache()
        rows = []
        resultMap = nil
        model = ResolverColumnsModel()
        for column in columns {
            column.textView.textStorage?.setAttributedString(NSAttributedString())
            column.textView.starts = [0]
        }
        pushModel(redraw: [.ours, .result, .theirs], layout: true)
    }

    /// Lays the draft out and patches each column's text where its rows changed.
    private func render(_ draft: ResolverDraft, showBase: Bool, current: Int?, reset: Bool) {
        let document = draft.document
        let sides: ResolverLayout.Sides
        if let cache = sidesCache, cache.snapshot == draft.snapshot {
            // Chunks merged or split (an edit across an edge, its undo): placed again, keeping
            // the stages' tints (Ruling 28).
            sides = cache.sides.refitted(to: document)
        } else {
            sides = ResolverLayout.Sides(draft.sides, document: document)
            rowCache = ResolverLayout.RowCache()
        }
        sidesCache = (draft.snapshot, sides)
        // Only the chunks an edit changed are laid out again.
        let newRows = ResolverLayout.rows(document, using: sides, showBase: showBase, reusing: &rowCache)
        let old = reset ? [] : rows
        var widest: CGFloat = reset ? 0 : codeWidth
        var redraw: Set<ResolverColumn> = []
        for column in columns {
            let patched = patch(column, old: old, new: newRows)
            if patched.changed { redraw.insert(column.column) }
            widest = max(widest, patched.width)
        }
        codeWidth = widest
        rows = newRows
        self.document = document
        self.snapshot = draft.snapshot
        self.showBase = showBase
        self.canTake = draft.isEditable
        self.current = current
        resultMap = ResolverEditMap(rows: newRows, document: document)
        let previous = model
        model = ResolverColumnsModel(rows: newRows, document: document, current: current, canTake: draft.isEditable)
        sizeTextViews()
        pushModel(redraw: redraw, layout: reset || !model.sameLayout(as: previous))
    }

    /// Gives the overlays and strips the model; redraws the columns in `redraw`, and everything
    /// when the conflicts' rows, states or the current conflict moved (`layout`).
    private func pushModel(redraw: Set<ResolverColumn>, layout: Bool) {
        for column in columns {
            column.overlay.model = model
            if layout || redraw.contains(column.column) { column.overlay.needsDisplay = true }
        }
        for gutter in [left, right] { gutter.model = model }
        guard layout else { return }
        result.overlay.layoutChips()
        for gutter in [left, right] { gutter.layoutButtons() }
    }

    /// Replaces the paragraphs of the rows that changed in one column; the widest line among them.
    private func patch(_ column: ResolverTextColumn, old: [LayoutRow], new: [LayoutRow]) -> (changed: Bool, width: CGFloat) {
        let view = column.textView
        guard let storage = view.textStorage else { return (false, 0) }
        let kind = column.column
        var prefix = 0
        let limit = min(old.count, new.count)
        while prefix < limit, Self.sameShown(old[prefix], new[prefix], kind) { prefix += 1 }
        var suffix = 0
        while suffix < limit - prefix, Self.sameShown(old[old.count - 1 - suffix], new[new.count - 1 - suffix], kind) {
            suffix += 1
        }
        // Text that is not the old rows' (never, but cheap to be sure of) is replaced whole.
        if !old.isEmpty, view.starts.count != old.count + 1 || view.starts.last != storage.length {
            return patch(column, old: [], new: new)
        }
        let changed = Array(new[prefix..<(new.count - suffix)])
        let starts = view.starts
        let replaced = NSRange(location: starts[prefix], length: starts[old.count - suffix] - starts[prefix])
        let text = ResolverAttributes.text(for: changed, column: kind, palette: palette)
        if old.isEmpty {
            storage.setAttributedString(text)
        } else if replaced.length > 0 || text.length > 0 {
            storage.beginEditing()
            storage.replaceCharacters(in: replaced, with: text)
            storage.endEditing()
        } else {
            return (false, 0)
        }
        // The new starts: kept before the change, counted through it, shifted after it.
        var newStarts = old.isEmpty ? [0] : Array(starts[...prefix])
        let string = text.string as NSString
        let first = newStarts[prefix]
        for index in 0..<string.length where string.character(at: index) == 0x0A {
            newStarts.append(first + index + 1)
        }
        let delta = text.length - replaced.length
        if suffix > 0 {
            for index in (old.count - suffix + 1)...old.count { newStarts.append(starts[index] + delta) }
        }
        view.starts = newStarts
        view.needsDisplay = true
        let digit = ResolverAttributes.characterWidth
        let longest = changed.lazy.map { ResolverAttributes.cell($0, kind).text.map(Self.columns) ?? 0 }.max() ?? 0
        return (true, CGFloat(longest) * digit)
    }

    /// A line's width in character columns, a tab as the next stop of four.
    static func columns(_ line: String) -> Int {
        var count = 0
        for unit in line.utf16 { count = unit == 0x09 ? (count / 4 + 1) * 4 : count + 1 }
        return count
    }

    /// Whether a row shows the same in a column: its text, tint, marks and kind. Line numbers are
    /// drawn apart, so a row that only moved down is the same.
    static func sameShown(_ a: LayoutRow, _ b: LayoutRow, _ column: ResolverColumn) -> Bool {
        let x = ResolverAttributes.cell(a, column), y = ResolverAttributes.cell(b, column)
        guard x.tint == y.tint, x.marks == y.marks, a.isBaseStrip == b.isBaseStrip else { return false }
        if column == .result, a.isSlot != b.isSlot { return false }
        switch (x.text, y.text) {
        case (nil, nil): return true
        // `==` is a byte compare for most text; text it calls equal with other bytes (canonically
        // equivalent) almost always has another length, and a row shown with the same length
        // keeps every offset right.
        case (let p?, let q?): return p.utf16.count == q.utf16.count && p == q
        default: return false
        }
    }

    /// The same chunks, states and bytes (never `==`, which calls canonically equal text equal).
    static func sameText(_ a: ResolverDocument, _ b: ResolverDocument) -> Bool {
        a.chunks.count == b.chunks.count
            && zip(a.chunks, b.chunks).allSatisfy { x, y in
                x.id == y.id && x.state == y.state && x.blocks.count == y.blocks.count && x.text.utf8.elementsEqual(y.text.utf8)
            }
    }

    // MARK: - The caret

    /// A caret as a place in the document: an offset, and whether it is at a slot there.
    private struct Caret {
        let offset: Int
        let atSlot: Bool
    }

    private func captureCaret() -> Caret? {
        guard let map = resultMap else { return nil }
        let selection = result.textView.selectedRange()
        guard selection.location != NSNotFound, selection.location <= (result.textView.textStorage?.length ?? 0),
            let edit = map.edit(for: NSRange(location: selection.location, length: 0))
        else { return nil }
        return Caret(offset: edit.range.location, atSlot: edit.intoEmptyChunk)
    }

    /// The caret back at its place in the document as it is now; at the current conflict when
    /// it had none.
    private func restoreCaret(_ caret: Caret?) {
        guard let caret, let map = resultMap else {
            caretToCurrent(scroll: false)
            return
        }
        let display = map.displayOffset(forDocument: caret.offset, atSlot: caret.atSlot)
        guard display <= (result.textView.textStorage?.length ?? 0) else { return }
        result.textView.setSelectedRange(NSRange(location: display, length: 0))
    }

    /// The first UTF-16 offset where two Results differ; nil when they are the same text.
    static func firstDifference(_ a: ResolverDocument, _ b: ResolverDocument) -> Int? {
        var x = a.resultText.utf16.makeIterator(), y = b.resultText.utf16.makeIterator()
        var offset = 0
        while true {
            let p = x.next(), q = y.next()
            if p == nil, q == nil { return nil }
            if p != q { return offset }
            offset += 1
        }
    }

    /// Whether the current conflict was taken by this change: its state became a take.
    static func justTaken(_ current: Int?, before: ResolverDocument?, after: ResolverDocument) -> Bool {
        guard let current, let new = after.chunks.first(where: { $0.id == current }), case .taken = new.state else {
            return false
        }
        guard let old = before?.chunks.first(where: { $0.id == current }) else { return true }
        return old.state != new.state || !old.text.utf8.elementsEqual(new.text.utf8)
    }

    /// The caret to the current conflict's first row (its slot while it waits); scrolled into
    /// view when it moved there.
    private func caretToCurrent(scroll: Bool) {
        guard let current, let row = model.firstRow[current], let map = resultMap else { return }
        let display = map.displayStart(ofRow: row)
        let view = result.textView
        if display <= (view.textStorage?.length ?? 0) {
            view.setSelectedRange(NSRange(location: display, length: 0))
        }
        if scroll, let range = model.chunkRows[current] { scrollToRows(range) }
    }

    /// Brings rows into view, a third of the way down, unless they are already in view.
    private func scrollToRows(_ range: Range<Int>) {
        let clip = result.scrollView.contentView
        let visible = clip.bounds
        let top = ResolverGeometry.y(ofRow: range.lowerBound), bottom = ResolverGeometry.y(ofRow: range.upperBound)
        // The caret is at the row's start: back to the lines' starts too.
        guard top < visible.minY || bottom > visible.maxY || visible.minX > 0 else { return }
        let maxY = max(0, result.textView.frame.height - visible.height)
        let y = top < visible.minY || bottom > visible.maxY ? min(max(0, top - visible.height / 3), maxY) : visible.minY
        clip.scroll(to: NSPoint(x: 0, y: y))
        result.scrollView.reflectScrolledClipView(clip)
    }

    // MARK: - Typing

    /// A change the Result's text view asked for: mapped, given to the store, shown from the model.
    func typed(_ range: NSRange, _ text: String) {
        guard let store, let map = resultMap, let document, editable,
            let edit = map.edit(for: range, deleting: text.isEmpty)
        else { return }
        store.resolverReplace(edit.range, with: text, intoEmptyChunk: edit.intoEmptyChunk)
        guard let draft = store.resolverDrafts[path], !Self.sameText(draft.document, document) else { return }
        let caret = edit.range.location + ResolverEditMap.typedLength(text, lineEnding: document.lineEnding)
        let current = store.resolverFocus?.path == path ? store.resolverFocus?.currentChunk : self.current
        render(draft, showBase: showBase, current: current, reset: false)
        guard let map = resultMap else { return }
        let display = map.displayOffset(forDocument: caret, atSlot: false)
        result.textView.setSelectedRange(NSRange(location: display, length: 0))
        result.textView.scrollRangeToVisible(NSRange(location: display, length: 0))
    }

    /// The document's text for shown ranges, in order: what Copy and Cut put on the pasteboard.
    func documentText(for ranges: [NSRange]) -> String? {
        guard let map = resultMap, let document else { return nil }
        let text = document.resultText as NSString
        return ranges.map { text.substring(with: map.documentRange(for: $0)) }.joined()
    }

    /// Puts a row's paragraph back as the model has it (after an input method's composition).
    func restoreRow(_ row: Int, in view: ResolverTextView) {
        guard let storage = view.textStorage, rows.indices.contains(row), view.starts.count == rows.count + 1 else { return }
        let start = view.starts[row]
        let paragraph = (storage.string as NSString).paragraphRange(for: NSRange(location: min(start, storage.length), length: 0))
        storage.replaceCharacters(in: paragraph, with: ResolverAttributes.text(for: [rows[row]], column: .result, palette: palette))
        if renderPending {
            renderPending = false
            if let store { refresh(from: store) }
        }
    }

    /// A render from the store as it is now (after a deferred one).
    private func refresh(from store: RepositoryStore) {
        let focus = store.resolverFocus
        update(
            store: store, path: path, draft: store.resolverDrafts[path], current: focus?.path == path ? focus?.currentChunk : nil,
            showBase: store.showsBase, labels: store.conflictSides)
    }

    func textView(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
        // An input method's marked text is shown as typed; it reaches the store when committed.
        if textView.hasMarkedText() || (textView as? ResolverTextView)?.compositionStart != nil { return true }
        if let replacementString { typed(range, replacementString) }
        return false
    }

    /// A caret is never left on a filler or a Show Base row, nor inside a slot's lower rows: it
    /// moves on in the direction it was going.
    func textView(
        _ textView: NSTextView, willChangeSelectionFromCharacterRange old: NSRange, toCharacterRange new: NSRange
    ) -> NSRange {
        guard new.length == 0, let map = resultMap, !textView.hasMarkedText() else { return new }
        // Only a key leaves a slot by moving down into its lower rows; a click there stays at it.
        let byKey = NSApp.currentEvent?.type == .keyDown
        return NSRange(location: map.caret(new.location, from: old.location, byKey: byKey), length: 0)
    }

    // MARK: - Undo and redo

    private var draft: ResolverDraft? { store?.resolverDrafts[path] }
    var canUndo: Bool { draft.map { $0.isEditable && $0.history.canUndo } ?? false }
    var canRedo: Bool { draft.map { $0.isEditable && $0.history.canRedo } ?? false }

    func undo() { store?.resolverUndo() }
    func redo() { store?.resolverRedo() }

    @objc func undo(_ sender: Any?) { undo() }
    @objc func redo(_ sender: Any?) { redo() }

    func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if item.action == #selector(undo(_:)) { return canUndo }
        if item.action == #selector(redo(_:)) { return canRedo }
        return false
    }

    // MARK: - Scrolling as one

    @objc private func clipChanged(_ notification: Notification) {
        guard !syncing, let clip = notification.object as? NSClipView else { return }
        syncing = true
        defer { syncing = false }
        let origin = clip.bounds.origin
        for column in columns where column.scrollView.contentView !== clip {
            let other = column.scrollView.contentView
            if other.bounds.origin != origin {
                other.scroll(to: origin)
                column.scrollView.reflectScrolledClipView(other)
            }
        }
        followScroll(origin)
    }

    /// The overlays and strips follow the text vertically; the overlays learn the sideways offset.
    private func followScroll(_ origin: NSPoint) {
        for column in columns {
            if column.overlay.bounds.origin.y != origin.y { column.overlay.setBoundsOrigin(NSPoint(x: 0, y: origin.y)) }
            if column.overlay.horizontalOffset != origin.x {
                column.overlay.horizontalOffset = origin.x
                column.overlay.needsDisplay = true
            }
        }
        for gutter in [left, right] where gutter.bounds.origin.y != origin.y {
            gutter.setBoundsOrigin(NSPoint(x: 0, y: origin.y))
            gutter.needsDisplay = true
        }
        result.overlay.updateAccessibility()
    }

    // MARK: - The harness

    #if DEBUG
        /// Types `text` into the Result at the current conflict, through the text view's own path.
        func debugType(_ text: String) -> Bool {
            caretToCurrent(scroll: true)
            guard editable else { return false }
            result.textView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
            return true
        }

        /// Backspace at the start of the line after the current conflict, through the text
        /// view's own `deleteBackward`: an edit across the conflict's edge, which joins the line
        /// to the conflict's last line.
        func debugBackspaceAfterCurrent() -> Bool {
            guard editable, let current, let range = model.chunkRows[current], let map = resultMap else { return false }
            let display = map.displayStart(ofRow: range.upperBound)
            guard display <= (result.textView.textStorage?.length ?? 0) else { return false }
            result.textView.setSelectedRange(NSRange(location: display, length: 0))
            result.textView.deleteBackward(nil)
            return true
        }

        /// The columns as drawn, for the harness's log: rows, the selection, the scroll offset and
        /// whether each column's text is its rows.
        func debugDescribe() -> String {
            let selection = result.textView.selectedRange()
            let row = resultMap?.row(at: selection.location) ?? -1
            let aligned = columns.allSatisfy { column in
                let paragraphs = (column.textView.string as NSString).components(separatedBy: "\n").count - 1
                return paragraphs == rows.count && column.textView.starts.count == rows.count + 1
                    && column.textView.starts.last == column.textView.textStorage?.length
            }
            let heights = Set(columns.map(\.textView.frame.height))
            return "rows: \(rows.count) | aligned: \(aligned) | heights: \(heights.sorted()) | caret: \(selection.location) row \(row) "
                + "| scroll: \(result.scrollView.contentView.bounds.origin.y) | editable: \(result.textView.isEditable) "
                + "| first responder: \(window?.firstResponder === result.textView)"
        }
    #endif
}
