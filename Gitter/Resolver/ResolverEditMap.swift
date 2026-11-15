import Foundation

/// The Result column's text as shown, mapped to the document's (`ResolverDocument.resultText`).
/// Pure: no view, no store.
///
/// The shown text is one paragraph per row (`ResolverAttributes`): a line of the Result, or a
/// filler, a slot or a Show Base row the document does not have; and every break is one `\n`
/// where the file may have `\r\n`. So every offset the text view gives goes through here, and
/// every caret it is given comes back through here.
///
/// **The caret rule.** A waiting slot is an empty chunk: its offset is also the start of the line
/// after it, where the document's `replace` would type into the slot. The slot has rows of its
/// own here, so the caret says which one is meant: on a slot row it is at the slot
/// (`intoEmptyChunk`), anywhere on the next line it is on that line, and typing goes there.
struct ResolverEditMap: Sendable {
    /// What a typed range becomes in the document.
    struct Edit: Hashable, Sendable {
        let range: NSRange
        /// The caret is at an empty conflict's slot: typing goes into the conflict.
        let intoEmptyChunk: Bool
    }

    private enum Row: Sendable {
        /// A line of the Result: where it starts in the document and its length without its break.
        case text(start: Int, length: Int)
        /// A slot row; `at` is the empty conflict's offset.
        case slot(at: Int)
        /// A filler or Show Base row; `at` is the start of the document's next line.
        case other(at: Int)
    }

    private let rows: [Row]
    /// Each row's first offset in the shown text; the shown text's length last.
    private let starts: [Int]
    /// The document's length, in UTF-16.
    private let documentLength: Int

    init(rows layout: [LayoutRow], document: ResolverDocument) {
        // Where each of the document's lines starts, and its length without its break.
        var lines: [(start: Int, length: Int)] = []
        var lineStart = 0
        var index = 0
        var previous: UInt16 = 0
        for chunk in document.chunks {
            for unit in chunk.text.utf16 {
                if unit == 0x0A {
                    let end = index > lineStart && previous == 0x0D ? index - 1 : index
                    lines.append((lineStart, end - lineStart))
                    lineStart = index + 1
                }
                previous = unit
                index += 1
            }
        }
        let total = index
        if lineStart < total { lines.append((lineStart, total - lineStart)) }

        var rows: [Row] = []
        var starts: [Int] = []
        var shown = 0
        // The document offset after the last line seen, with its break: where the next line starts.
        var next = 0
        for row in layout {
            starts.append(shown)
            let cell = row.result
            if !row.isBaseStrip, !row.isSlot, cell.text != nil, let number = cell.lineNumber, number >= 1,
                number <= lines.count
            {
                let line = lines[number - 1]
                rows.append(.text(start: line.start, length: line.length))
                next = number < lines.count ? lines[number].start : total
                shown += line.length + 1
            } else if row.isSlot, !row.isBaseStrip {
                rows.append(.slot(at: next))
                shown += 1
            } else {
                rows.append(.other(at: next))
                // A Show Base row shows its base line (or the no-base sentence), never typed into.
                shown += (cell.text.map(ResolverAttributes.shown) ?? (row.isBaseStrip ? ConflictWording.noBaseStrip : ""))
                    .utf16.count + 1
            }
        }
        starts.append(shown)
        self.rows = rows
        self.starts = starts
        documentLength = total
    }

    var rowCount: Int { rows.count }

    /// The row's first offset in the shown text.
    func displayStart(ofRow row: Int) -> Int { starts[min(max(row, 0), starts.count - 1)] }

    /// The row holding a shown offset (the last row for the very end).
    func row(at display: Int) -> Int {
        guard !rows.isEmpty else { return 0 }
        var low = 0, high = rows.count - 1
        while low < high {
            let middle = (low + high + 1) / 2
            if starts[middle] <= display { low = middle } else { high = middle - 1 }
        }
        return low
    }

    /// Whether the row is a line the user can type in, or a slot.
    func isEditable(row: Int) -> Bool {
        guard rows.indices.contains(row) else { return false }
        if case .other = rows[row] { return false }
        return true
    }

    func isSlot(row: Int) -> Bool {
        guard rows.indices.contains(row), case .slot = rows[row] else { return false }
        return true
    }

    /// The document range a shown range replaces, or nil where nothing can be typed: a caret on
    /// a filler or a Show Base row.
    ///
    /// Each end maps on its own: on a line, to the same place in it; on any other row, to the
    /// start of the document's next line, which is also a slot's offset. A deletion that maps to
    /// nothing because it only spans rows the document lacks — a backspace at the start of a line
    /// below fillers (`deleting`) — deletes the line break before them, as it would with none
    /// shown (a one-character deletion: a Cut of rows the document lacks takes nothing); text
    /// typed over such a range is inserted there instead.
    func edit(for range: NSRange, deleting: Bool = false) -> Edit? {
        guard !rows.isEmpty, range.location >= 0, NSMaxRange(range) <= starts[rows.count] else { return nil }
        let first = row(at: range.location)
        if range.length == 0 {
            switch rows[first] {
            case .text(let start, let length):
                return Edit(range: NSRange(location: start + min(range.location - starts[first], length), length: 0), intoEmptyChunk: false)
            case .slot(let at):
                return Edit(range: NSRange(location: at, length: 0), intoEmptyChunk: true)
            case .other:
                return nil
            }
        }
        let low = position(range.location), high = position(NSMaxRange(range))
        if high > low {
            return Edit(range: NSRange(location: low, length: high - low), intoEmptyChunk: false)
        }
        // Nothing of the document's between the ends: the break before the line the range ends at.
        let last = row(at: NSMaxRange(range))
        guard deleting, range.length == 1, NSMaxRange(range) == starts[last], case .text(let start, _) = rows[last],
            let previous = rows[..<last].lastIndex(where: { if case .text = $0 { true } else { false } }),
            case .text(let before, let length) = rows[previous]
        else { return Edit(range: NSRange(location: low, length: 0), intoEmptyChunk: isSlot(row: first)) }
        let end = before + length
        return Edit(range: NSRange(location: end, length: start - end), intoEmptyChunk: false)
    }

    /// Where a caret moving from `old` to `display` rests: on a line as it is; on a filler or Show
    /// Base row, on in the direction it moved — the next line's start or the slot going down, the
    /// previous line's end going up; on a slot, its first row — or, moved by a key (`byKey`) from
    /// the slot down into its lower rows, past it, so arrowing down leaves a slot. A click anywhere
    /// in a slot is at the slot.
    func caret(_ display: Int, from old: Int, byKey: Bool) -> Int {
        guard !rows.isEmpty else { return display }
        let target = row(at: display), was = row(at: old)
        let down = display >= old
        switch rows[target] {
        case .text:
            return display
        case .slot:
            let run = slotRun(target)
            if byKey, run.contains(was), target != run.lowerBound {
                // Already at the slot: going down leaves it.
                return down ? (landing(from: run.upperBound, down: true) ?? starts[run.lowerBound]) : starts[run.lowerBound]
            }
            return starts[run.lowerBound]
        case .other:
            return landing(from: target, down: down) ?? landing(from: target, down: !down) ?? display
        }
    }

    /// The rows of the slot that holds `row`.
    private func slotRun(_ row: Int) -> Range<Int> {
        var low = row, high = row + 1
        while low > 0, isSlot(row: low - 1) { low -= 1 }
        while high < rows.count, isSlot(row: high) { high += 1 }
        return low..<high
    }

    /// The first place a caret can rest from `row` on, going down (a line's start, a slot's first
    /// row) or up (a line's end, a slot's first row).
    private func landing(from row: Int, down: Bool) -> Int? {
        let order = down ? Array(row..<rows.count) : Array((0..<min(row, rows.count)).reversed())
        for index in order {
            switch rows[index] {
            case .text(_, let length): return down ? starts[index] : starts[index] + length
            case .slot: return starts[slotRun(index).lowerBound]
            case .other: continue
            }
        }
        return nil
    }

    /// The document's range for a shown range, each end mapped as `edit(for:)` maps it: what Copy
    /// and Cut take — the document's own text, never a filler, a slot's rows or Show Base's text.
    func documentRange(for range: NSRange) -> NSRange {
        guard !rows.isEmpty, range.location >= 0, range.location != NSNotFound else { return NSRange(location: 0, length: 0) }
        let end = min(NSMaxRange(range), starts[rows.count])
        let low = position(min(range.location, end)), high = position(end)
        return NSRange(location: low, length: max(0, high - low))
    }

    /// The document offset of a shown offset; the shown text's very end is the document's.
    private func position(_ display: Int) -> Int {
        if display >= starts[rows.count] { return documentLength }
        let index = row(at: display)
        switch rows[index] {
        case .text(let start, let length): return start + min(display - starts[index], length)
        case .slot(let at), .other(let at): return at
        }
    }

    /// The shown offset of a document offset: at the slot that starts there when `atSlot`, else
    /// on the line that holds it (a CRLF's middle is the line's end).
    func displayOffset(forDocument offset: Int, atSlot: Bool) -> Int {
        if atSlot, let slot = rows.indices.first(where: { if case .slot(let at) = rows[$0] { at == offset } else { false } }) {
            return starts[slot]
        }
        var fallback: Int?
        for (index, row) in rows.enumerated() {
            guard case .text(let start, let length) = row else { continue }
            if offset < start { return fallback ?? starts[index] }
            if offset <= start + length { return starts[index] + (offset - start) }
            fallback = starts[index] + length
        }
        if let fallback { return fallback }
        return rows.indices.first { isSlot(row: $0) }.map { starts[$0] } ?? 0
    }

    /// How long `typed` is in the document, its line breaks made `lineEnding` as `replace` makes them.
    static func typedLength(_ typed: String, lineEnding: String) -> Int {
        var length = 0
        var scalars = typed.unicodeScalars[...]
        while let scalar = scalars.popFirst() {
            switch scalar {
            case "\r":
                if scalars.first == "\n" { scalars.removeFirst() }
                length += lineEnding.utf16.count
            case "\n":
                length += lineEnding.utf16.count
            default:
                length += String(scalar).utf16.count
            }
        }
        return length
    }
}
