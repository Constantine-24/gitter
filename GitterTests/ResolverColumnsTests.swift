import AppKit
import Foundation
import GitCore
import Testing

@testable import Gitter

/// The three columns' text (`ResolverAttributes`): one paragraph per row in every column, so the
/// rows line up; fillers and the waiting slot as empty paragraphs; tints and word marks as
/// attributes the text views draw. And the Result's map between its shown text and the document
/// (`ResolverEditMap`), which carries typing, the caret and the slot rule.
@MainActor @Suite struct ResolverColumnsTests {

    static func paragraphs(_ text: NSAttributedString) -> [NSRange] {
        var ranges: [NSRange] = []
        let string = text.string as NSString
        var start = 0
        while start < string.length {
            let newline = string.range(of: "\n", range: NSRange(location: start, length: string.length - start))
            let end = newline.location == NSNotFound ? string.length : newline.location
            ranges.append(NSRange(location: start, length: end - start))
            start = end + 1
        }
        return ranges
    }

    static func style(_ text: NSAttributedString, at location: Int) -> ResolverRowStyle? {
        text.attribute(.resolverRow, at: location, effectiveRange: nil) as? ResolverRowStyle
    }

    /// The UTF-16 offsets of `text` that carry a word mark.
    static func marked(_ text: NSAttributedString, in range: NSRange) -> [Int] {
        (range.location..<NSMaxRange(range)).filter { text.attribute(.resolverMark, at: $0, effectiveRange: nil) != nil }
    }

    // MARK: - The attributes

    @Test func attributesCarryTintsAndMarks() throws {
        let rows = ResolverLayout.rows(try ResolverLayoutTests.mockup(), sides: ResolverLayoutTests.unitsSides, showBase: false)
        let palette = ResolverPalette.standard
        let ours = ResolverAttributes.text(for: rows, column: .ours, palette: palette)
        let theirs = ResolverAttributes.text(for: rows, column: .theirs, palette: palette)
        let result = ResolverAttributes.text(for: rows, column: .result, palette: palette)

        // Row 6, Ours: "pint", its side's tint, the mark on the line's text without its indent.
        let pint = Self.paragraphs(ours)[6]
        #expect(Self.style(ours, at: pint.location)?.tint == .oursChanged)
        let pintText = try #require(rows[6].ours.text)
        let expected = ResolverLayoutTests.utf16Range(of: "\"pint\": 473.2,", in: pintText)
        #expect(Self.marked(ours, in: pint) == Array(expected).map { pint.location + $0 })
        // The tint covers the whole paragraph and its break, so the row is tinted edge to edge.
        #expect(Self.style(ours, at: NSMaxRange(pint))?.tint == .oursChanged)

        // Row 25, Theirs: only " if value < 100 else 0" is marked.
        let row25 = Self.paragraphs(theirs)[25]
        let theirsText = try #require(rows[25].theirs.text)
        let marks = ResolverLayoutTests.utf16Range(of: " if value < 100 else 0", in: theirsText)
        #expect(Self.marked(theirs, in: row25) == Array(marks).map { row25.location + $0 })
        #expect(Self.style(theirs, at: row25.location)?.tint == .theirsChanged)

        // The Result: row 0 from theirs, rows 6–8 taken, row 25 edited, row 1 untinted.
        let resultRows = Self.paragraphs(result)
        #expect(Self.style(result, at: resultRows[0].location)?.tint == .fromTheirs)
        #expect([6, 7, 8].map { Self.style(result, at: resultRows[$0].location)?.tint } == [.taken, .taken, .taken])
        #expect(Self.style(result, at: resultRows[25].location)?.tint == .edited)
        #expect(Self.style(result, at: resultRows[1].location)?.tint == RowTint.none)
        #expect(Self.marked(ours, in: Self.paragraphs(ours)[1]).isEmpty)

        // The code is in the monospaced system font.
        let font = try #require(ours.attribute(.font, at: pint.location, effectiveRange: nil) as? NSFont)
        #expect(font.isFixedPitch)
    }

    @Test func fillersAreEmptyParagraphs() throws {
        let rows = ResolverLayout.rows(try ResolverLayoutTests.mockup(), sides: ResolverLayoutTests.unitsSides, showBase: false)
        for column in [ResolverColumn.ours, .result, .theirs] {
            let text = ResolverAttributes.text(for: rows, column: column, palette: .standard)
            // One paragraph per row, each ending in a break: the columns line up row for row.
            #expect(text.string.filter { $0 == "\n" }.count == rows.count, "\(column)")
            let paragraphs = Self.paragraphs(text)
            #expect(paragraphs.count == rows.count, "\(column)")
            for (index, row) in rows.enumerated() {
                let cell = column == .ours ? row.ours : column == .theirs ? row.theirs : row.result
                let shown = (text.string as NSString).substring(with: paragraphs[index])
                #expect(shown == (cell.text ?? ""), "\(column) row \(index)")
                if cell.text == nil, !row.isSlot || column != .result {
                    #expect(Self.style(text, at: paragraphs[index].location)?.kind == .filler, "\(column) row \(index)")
                    #expect(Self.style(text, at: paragraphs[index].location)?.tint == .filler, "\(column) row \(index)")
                }
            }
        }
        // Rows 7 and 8 are Ours' fillers; row 8 is Theirs' — empty paragraphs.
        let ours = ResolverAttributes.text(for: rows, column: .ours, palette: .standard)
        #expect(Self.paragraphs(ours)[7].length == 0 && Self.paragraphs(ours)[8].length == 0)
        #expect(Self.style(ours, at: Self.paragraphs(ours)[6].location)?.kind == .text)
    }

    @Test func theSlotRowsAreMarked() throws {
        let rows = ResolverLayout.rows(try ResolverLayoutTests.mockup(), sides: ResolverLayoutTests.unitsSides, showBase: false)
        let result = ResolverAttributes.text(for: rows, column: .result, palette: .standard)
        let paragraphs = Self.paragraphs(result)
        let slots = paragraphs.indices.filter { Self.style(result, at: paragraphs[$0].location)?.kind == .slot }
        #expect(slots == [14, 15])
        #expect(slots.allSatisfy { paragraphs[$0].length == 0 })
        // The sides show their lines there, not a slot.
        let theirs = ResolverAttributes.text(for: rows, column: .theirs, palette: .standard)
        #expect(Self.style(theirs, at: Self.paragraphs(theirs)[14].location)?.kind == .text)
    }

    /// A lone `\r`, or a Unicode line or paragraph separator inside a line, would start a new
    /// paragraph in the text view and break the rows' alignment: each is shown as a symbol of the
    /// same length, so offsets within the line stay the document's.
    @Test func lineBreaksInsideALineKeepTheRowsAndTheirLength() {
        let text = "a\rb\u{2028}c\u{2029}d\u{85}e\u{0B}f\u{0C}g"
        let cell = LayoutCell(lineNumber: 1, text: text, tint: .none, marks: [])
        let row = LayoutRow(ours: cell, result: cell, theirs: cell, chunk: 0, isSlot: false, badge: nil)
        let shown = ResolverAttributes.text(for: [row, row], column: .result, palette: .standard)
        #expect(Self.paragraphs(shown).count == 2)
        #expect((shown.string as NSString).length == 2 * (text.utf16.count + 1))
        var paragraphCount = 0
        (shown.string as NSString).enumerateSubstrings(
            in: NSRange(location: 0, length: (shown.string as NSString).length), options: .byParagraphs
        ) { _, _, _, _ in paragraphCount += 1 }
        #expect(paragraphCount == 2)
    }

    @Test func theBaseStripIsMarkedAndSaysWhenThereIsNoBase() throws {
        let rows = ResolverLayout.rows(try ResolverLayoutTests.mockup(), sides: ResolverLayoutTests.unitsSides, showBase: true)
        let result = ResolverAttributes.text(for: rows, column: .result, palette: .standard)
        let paragraphs = Self.paragraphs(result)
        let strips = rows.indices.filter { rows[$0].isBaseStrip }
        #expect(!strips.isEmpty)
        for index in strips {
            #expect(Self.style(result, at: paragraphs[index].location)?.kind == .baseStrip)
        }
        // Conflicts 1 and 2 have no base: their one strip row says so.
        let noBase = strips.filter { rows[$0].result.text == nil }
        #expect(noBase.count == 2)
        #expect(noBase.allSatisfy { (result.string as NSString).substring(with: paragraphs[$0]) == ConflictWording.noBaseStrip })
    }

    // MARK: - The Result's map

    static func map(_ document: ResolverDocument, showBase: Bool = false) -> (ResolverEditMap, [LayoutRow]) {
        let rows = ResolverLayout.rows(document, sides: ResolverLayoutTests.unitsSides, showBase: showBase)
        return (ResolverEditMap(rows: rows, document: document), rows)
    }

    /// The caret rule: a caret on a slot row types into the waiting conflict; one at the start of
    /// the line after it — the same document offset — types into that line, and the conflict
    /// stays waiting.
    @Test func aCaretAtTheSlotTypesIntoItAndOneOnTheNextLineDoesNot() throws {
        let document = try ResolverLayoutTests.mockup()
        let (map, _) = Self.map(document)
        let slotAt = document.range(ofChunk: 3).location

        for row in [14, 15] {
            let edit = try #require(map.edit(for: NSRange(location: map.displayStart(ofRow: row), length: 0)))
            #expect(edit.range == NSRange(location: slotAt, length: 0))
            #expect(edit.intoEmptyChunk)
        }
        let next = try #require(map.edit(for: NSRange(location: map.displayStart(ofRow: 16), length: 0)))
        #expect(next.range == NSRange(location: slotAt, length: 0))
        #expect(!next.intoEmptyChunk)

        var typedAtTheSlot = document
        typedAtTheSlot.replace(NSRange(location: slotAt, length: 0), with: "q", intoEmptyChunk: true)
        #expect(typedAtTheSlot.chunks.first { $0.id == 3 }?.state == .edited)
        var typedOnTheNextLine = document
        typedOnTheNextLine.replace(next.range, with: "q", intoEmptyChunk: next.intoEmptyChunk)
        #expect(typedOnTheNextLine.chunks.first { $0.id == 3 }?.state == .waiting)
        #expect(typedOnTheNextLine.chunks.first { $0.id == 4 }?.text.hasPrefix("q}") == true)

        // Back from the document: the slot's offset is the slot row when the caret is at the slot,
        // else the next line's start.
        #expect(map.displayOffset(forDocument: slotAt, atSlot: true) == map.displayStart(ofRow: 14))
        #expect(map.displayOffset(forDocument: slotAt, atSlot: false) == map.displayStart(ofRow: 16))
    }

    /// Every caret position on a text row maps to the document and back to itself.
    /// The view's own gestures on the line just above a waiting slot, through the map: a
    /// triple-click selects the line with its break, which ends at the slot row's start; typing
    /// over it keeps the slot waiting and the new text on its own line (Ruling 50). So does a
    /// deletion from inside the line to the slot. Undo brings each back.
    @Test func replacingTheLineAboveASlotThroughTheMapKeepsItWaiting() throws {
        let fresh = try ResolverLayoutTests.mockup()
        let (map, rows) = Self.map(fresh)
        let slotRow = try #require(rows.firstIndex { $0.isSlot && $0.chunk == 3 })
        let above = slotRow - 1
        let lineStart = map.displayStart(ofRow: above), slotStart = map.displayStart(ofRow: slotRow)
        let slotAt = fresh.range(ofChunk: 3).location

        // Triple-click, then typing.
        let line = try #require(map.edit(for: NSRange(location: lineStart, length: slotStart - lineStart)))
        #expect(NSMaxRange(line.range) == slotAt)
        var document = fresh
        var history = ResolverHistory()
        history.record(document, coalescingTypingIn: nil, at: ResolverDocumentTests.t0)
        #expect(document.replace(line.range, with: "x", intoEmptyChunk: line.intoEmptyChunk) != nil)
        #expect(document.chunks.first { $0.id == 3 }?.state == .waiting)
        #expect(document.waitingCount == fresh.waitingCount)
        #expect(document.chunks.map(\.id) == fresh.chunks.map(\.id))
        let chunk2 = try #require(document.chunks.first { $0.id == 2 })
        #expect(chunk2.text.hasSuffix("\nx\n") || chunk2.text == "x\n")
        let typed = document
        let undone = try ResolverDocumentTests.undo(&history, document)
        #expect(undone == fresh)
        #expect(try ResolverDocumentTests.redo(&history, undone) == typed)

        // A deletion from the line's second character to the slot.
        let tail = try #require(map.edit(for: NSRange(location: lineStart + 1, length: slotStart - lineStart - 1), deleting: true))
        var deleted = fresh
        var deletions = ResolverHistory()
        deletions.record(deleted, coalescingTypingIn: nil, at: ResolverDocumentTests.t0)
        #expect(deleted.replace(tail.range, with: "", intoEmptyChunk: tail.intoEmptyChunk) != nil)
        #expect(deleted.chunks.first { $0.id == 3 }?.state == .waiting)
        #expect(deleted.chunks.map(\.id) == fresh.chunks.map(\.id))
        #expect(deleted.chunks.first { $0.id == 2 }?.text.hasSuffix("\n") == true)
        let afterDeletion = deleted
        let back = try ResolverDocumentTests.undo(&deletions, deleted)
        #expect(back == fresh)
        #expect(try ResolverDocumentTests.redo(&deletions, back) == afterDeletion)
    }

    @Test func textPositionsRoundTrip() throws {
        let document = try ResolverLayoutTests.mockup()
        let (map, rows) = Self.map(document)
        let text = document.resultText as NSString
        for (index, row) in rows.enumerated() {
            guard let line = row.result.text else { continue }
            for column in 0...line.utf16.count {
                let display = map.displayStart(ofRow: index) + column
                let edit = try #require(map.edit(for: NSRange(location: display, length: 0)), "row \(index)")
                #expect(!edit.intoEmptyChunk)
                #expect(map.displayOffset(forDocument: edit.range.location, atSlot: false) == display, "row \(index)")
                if column < line.utf16.count {
                    #expect(text.substring(with: NSRange(location: edit.range.location, length: 1)) == (line as NSString).substring(with: NSRange(location: column, length: 1)))
                }
            }
        }
    }

    @Test func fillersAndTheBaseStripTakeNoTyping() throws {
        var document = try ResolverLayoutTests.mockup()
        document.take(.ours, chunk: 1)  // one line in the Result, two in Theirs: a Result filler
        let (map, rows) = Self.map(document, showBase: true)
        let filler = try #require(rows.indices.first { rows[$0].result == ResolverLayoutTests.filler && !rows[$0].isBaseStrip })
        #expect(map.edit(for: NSRange(location: map.displayStart(ofRow: filler), length: 0)) == nil)
        let strip = try #require(rows.indices.first { rows[$0].isBaseStrip })
        #expect(map.edit(for: NSRange(location: map.displayStart(ofRow: strip), length: 0)) == nil)
    }

    /// Backspace at the start of a line below Result fillers deletes the line break before them,
    /// as it would with no fillers shown: the break after "pint".
    @Test func backspaceBelowFillersDeletesTheBreakBeforeThem() throws {
        var document = try ResolverLayoutTests.mockup()
        document.take(.ours, chunk: 1)
        let (map, rows) = Self.map(document)
        let brace = try #require(rows.indices.first { rows[$0].result.text == "}" })
        #expect(rows[brace - 1].result == ResolverLayoutTests.filler)
        let backspace = NSRange(location: map.displayStart(ofRow: brace) - 1, length: 1)
        let edit = try #require(map.edit(for: backspace, deleting: true))
        let pintEnd = NSMaxRange((document.resultText as NSString).range(of: "\"pint\": 473.2,"))
        #expect(edit.range == NSRange(location: pintEnd, length: 1))
        // Text typed over the filler's break is inserted at the next line's start, deleting nothing.
        let braceStart = (document.resultText as NSString).range(of: "}\n\nWEIGHT").location
        #expect(map.edit(for: backspace)?.range == NSRange(location: braceStart, length: 0))
    }

    /// A selection across rows maps each end on its own; a CRLF break is two document units but
    /// one shown, and a selection from a line's end to the next line's start covers both.
    @Test func crlfLinesMapByTheirOwnLength() throws {
        let sides = ResolverLayoutTests.sides(ours: "a\r\nO\r\nz\r\n", base: "a\r\nB\r\nz\r\n", theirs: "a\r\nT\r\nz\r\n")
        var document = try ResolverLayoutTests.document(
            [ResolverLayoutTests.common("ab\r\n"), ResolverLayoutTests.block("O\r\n", "B\r\n", "T\r\n"),
             ResolverLayoutTests.common("z\r\n")], sides: sides)
        document.take(.ours, chunk: 1)
        let rows = ResolverLayout.rows(document, sides: sides, showBase: false)
        let map = ResolverEditMap(rows: rows, document: document)
        // "ab|" to "|O": the CRLF.
        let edit = try #require(map.edit(for: NSRange(location: 2, length: 1)))
        #expect(edit.range == NSRange(location: 2, length: 2))
        #expect(map.edit(for: NSRange(location: map.displayStart(ofRow: 2), length: 0))?.range.location == 7)
        #expect(map.displayOffset(forDocument: 7, atSlot: false) == map.displayStart(ofRow: 2))
    }

    /// Keys move a caret over rows the document lacks in the direction they go, and out of a slot
    /// downwards from its first row; a click anywhere in a slot lands at its first row (I3).
    @Test func theCaretRestsOnLinesAndAtTheSlotsFirstRow() throws {
        var document = try ResolverLayoutTests.mockup()
        document.take(.ours, chunk: 1)  // conflict 1: one Result line over two of Theirs, a filler
        let (map, rows) = Self.map(document, showBase: true)
        let start = { map.displayStart(ofRow: $0) }
        let slot = try #require(rows.indices.first { rows[$0].isSlot })
        #expect(rows[slot + 1].isSlot)  // conflict 2's slot is two rows
        let after = slot + 2
        #expect(rows[after].result.text == "}")

        // A click on either slot row, from anywhere: the slot's first row.
        for from in [start(slot), start(slot + 1), start(0), start(after)] {
            #expect(map.caret(start(slot + 1), from: from, byKey: false) == start(slot))
            #expect(map.caret(start(slot), from: from, byKey: false) == start(slot))
        }
        // Keys: down from the slot's first row leaves it for the line after; down into it from
        // above lands on its first row; up from the line after lands on its first row.
        #expect(map.caret(start(slot + 1), from: start(slot), byKey: true) == start(after))
        #expect(map.caret(start(slot + 1), from: start(slot - 1), byKey: true) == start(slot))
        #expect(map.caret(start(slot + 1), from: start(after), byKey: true) == start(slot))

        // The filler under conflict 1's Result line: down to the next line, up to the line's end.
        let filler = try #require(rows.indices.first { rows[$0].result == ResolverLayoutTests.filler && !rows[$0].isBaseStrip })
        let above = filler - 1, below = filler + 1
        let aboveLength = try #require(rows[above].result.text).utf16.count
        #expect(map.caret(start(filler), from: start(above), byKey: true) == start(below))
        #expect(map.caret(start(filler), from: start(below), byKey: true) == start(above) + aboveLength)
        // A Show Base row: down to the conflict's first line.
        let strip = try #require(rows.indices.first { rows[$0].isBaseStrip && rows[$0].chunk == 5 })
        #expect(map.caret(start(strip), from: start(strip - 1), byKey: true) == start(strip + 1))
        // A line is a line, by key or click.
        #expect(map.caret(start(above) + 2, from: 0, byKey: false) == start(above) + 2)
    }

    /// What Copy and Cut take: the document's own text for the shown selection — no filler or slot
    /// lines, no Show Base text, CRLF as it is (I5).
    @Test func aSelectionCopiesTheDocumentsText() throws {
        let sides = ResolverLayoutTests.sides(
            ours: "a\r\nO\r\nz\r\nw\r\n", base: "a\r\nB\r\nz\r\nC\r\nw\r\n", theirs: "a\r\nT\r\nT2\r\nz\r\nU\r\nU2\r\nw\r\n")
        var document = try ResolverLayoutTests.document(
            [ResolverLayoutTests.common("a\r\n"), ResolverLayoutTests.block("O\r\n", "B\r\n", "T\r\nT2\r\n"),
             ResolverLayoutTests.common("z\r\n"), ResolverLayoutTests.block("", "C\r\n", "U\r\nU2\r\n"),
             ResolverLayoutTests.common("w\r\n")], sides: sides)
        document.take(.ours, chunk: 1)  // "O" over a filler
        let rows = ResolverLayout.rows(document, sides: sides, showBase: true)
        #expect(rows.contains { $0.isBaseStrip } && rows.contains { $0.isSlot })
        #expect(rows.contains { $0.result == ResolverLayoutTests.filler && !$0.isBaseStrip })
        let map = ResolverEditMap(rows: rows, document: document)
        let all = NSRange(location: 0, length: map.displayStart(ofRow: rows.count))
        #expect(map.documentRange(for: all) == NSRange(location: 0, length: document.resultText.utf16.count))
        #expect((document.resultText as NSString).substring(with: map.documentRange(for: all)) == "a\r\nO\r\nz\r\nw\r\n")
        // From inside "O" to inside "w": the bytes between, whatever is shown between.
        let o = try #require(rows.firstIndex { $0.result.text == "O" })
        let w = try #require(rows.firstIndex { $0.result.text == "w" })
        let part = map.documentRange(for: NSRange(location: map.displayStart(ofRow: o) + 1, length: map.displayStart(ofRow: w) - map.displayStart(ofRow: o)))
        #expect((document.resultText as NSString).substring(with: part) == "\r\nz\r\nw")
    }

    @Test func typedTextIsCountedInTheFilesLineEnding() {
        #expect(ResolverEditMap.typedLength("a\nb", lineEnding: "\r\n") == 4)
        #expect(ResolverEditMap.typedLength("a\r\nb\rc", lineEnding: "\n") == 5)
        #expect(ResolverEditMap.typedLength("é", lineEnding: "\n") == 1)
    }
}

/// The columns on a real store, in an offscreen window: typing reaches the store through the
/// Result's text view and its map, ⌘Z goes to the store, Escape leaves the text, an input
/// method's composition is committed once, and the caret stays where it was across renders
/// that are not typing.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct ResolverColumnsHostTests {

    /// Focus mode on `a.txt` (chunks 0…4: top, conflict, mid, conflict, end) and the columns
    /// showing it.
    static func columns(_ repo: ScratchRepo) async throws
        -> (store: RepositoryStore, host: ResolverColumnsHost, window: NSWindow, cleanup: () -> Void)
    {
        let (store, cleanup) = await openedTestStore(repo)
        _ = try #require(await ResolverStoreTests.openDraft(store, "a.txt"))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = ResolverColumnsHost()
        host.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(host)
        refresh(store, host)
        host.layoutSubtreeIfNeeded()
        return (store, host, window, cleanup)
    }

    static func refresh(_ store: RepositoryStore, _ host: ResolverColumnsHost) {
        let focus = store.resolverFocus
        host.update(
            store: store, path: "a.txt", draft: store.resolverDrafts["a.txt"], current: focus?.currentChunk,
            showBase: store.showsBase, labels: store.conflictSides)
    }

    static func chunk(_ id: Int, _ store: RepositoryStore) -> ResolverChunk? {
        store.resolverDrafts["a.txt"]?.document.chunks.first { $0.id == id }
    }

    /// The shown offset of the start of the Result row whose text is `line`.
    static func rowStart(_ line: String, _ host: ResolverColumnsHost) throws -> Int {
        let row = try #require(host.model.rows.firstIndex { $0.result.text == line })
        return try #require(host.resultMap).displayStart(ofRow: row)
    }

    @Test(.timeLimit(.minutes(10))) func typingInTheResultReachesTheStoreAndShowsAtOnce() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo)
        defer { cleanup(); window.close() }
        let view = host.result.textView
        // The caret starts at the current conflict's slot.
        #expect(store.resolverFocus?.currentChunk == 1)
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(Self.chunk(1, store)?.text == "x\n")
        #expect(Self.chunk(1, store)?.state == .edited)
        // Shown at once, the caret after it, no SwiftUI pass needed.
        let row = try Self.rowStart("x", host)
        #expect((view.string as NSString).substring(with: NSRange(location: row, length: 2)) == "x\n")
        #expect(view.selectedRange() == NSRange(location: row + 1, length: 0))
        // The rows are the model's, every column one paragraph per row.
        #expect(host.model.rows == ResolverLayout.rows(try #require(store.resolverDrafts["a.txt"]).document, sides: try #require(store.resolverDrafts["a.txt"]).sides, showBase: false))
        for column in [host.ours, host.result, host.theirs] {
            #expect(column.textView.string.filter { $0 == "\n" }.count == host.model.rows.count)
        }
    }

    /// The sides' part of the layout is kept per file (Ruling 51): going back to a file shown a
    /// moment ago builds nothing again, and typing refits rather than rebuilds.
    @Test(.timeLimit(.minutes(10))) func goingBackToAFileReusesItsSides() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo)
        defer { cleanup(); window.close() }
        #expect(host.sidesBuilt == 1)
        let b = try #require(await ResolverStoreTests.openDraft(store, "b.txt"))
        host.update(store: store, path: "b.txt", draft: b, current: nil, showBase: false, labels: store.conflictSides)
        #expect(host.sidesBuilt == 2)
        let a = try #require(store.resolverDrafts["a.txt"])
        host.update(store: store, path: "a.txt", draft: a, current: nil, showBase: false, labels: store.conflictSides)
        #expect(host.sidesBuilt == 2)
        host.update(store: store, path: "b.txt", draft: b, current: nil, showBase: false, labels: store.conflictSides)
        #expect(host.sidesBuilt == 2)
        // The rows are still the fresh build's.
        #expect(host.model.rows == ResolverLayout.rows(b.document, sides: b.sides, showBase: false))
    }

    /// The caret rule in the view: on the line after a waiting slot, typing goes into that line.
    @Test(.timeLimit(.minutes(10))) func aCaretOnTheLineAfterASlotTypesIntoThatLine() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo)
        defer { cleanup(); window.close() }
        let view = host.result.textView
        view.setSelectedRange(NSRange(location: try Self.rowStart("mid", host), length: 0))
        view.insertText("q", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(Self.chunk(1, store)?.state == .waiting)
        #expect(Self.chunk(2, store)?.text == "qmid\n")
        #expect(view.selectedRange() == NSRange(location: try Self.rowStart("qmid", host) + 1, length: 0))
    }

    @Test(.timeLimit(.minutes(10))) func undoAndRedoGoToTheStoreNotTheTextView() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo)
        defer { cleanup(); window.close() }
        let view = host.result.textView
        let undo = NSMenuItem(title: "Undo", action: #selector(ResolverTextView.undo(_:)), keyEquivalent: "z")
        let redo = NSMenuItem(title: "Redo", action: #selector(ResolverTextView.redo(_:)), keyEquivalent: "Z")
        #expect(!view.validateUserInterfaceItem(undo))
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.validateUserInterfaceItem(undo))
        #expect(view.undoManager?.canUndo != true)  // the text view's own undo is off

        #expect(view.tryToPerform(#selector(ResolverTextView.undo(_:)), with: nil))
        #expect(store.resolverDrafts["a.txt"]?.hasUserChanges == false)
        #expect(view.validateUserInterfaceItem(redo))
        // The columns host answers too, for when a side column has the keys.
        #expect(host.tryToPerform(#selector(ResolverColumnsHost.redo(_:)), with: nil))
        #expect(Self.chunk(1, store)?.text == "x\n")
    }

    /// A render that is not typing — undo, Show Base — leaves the caret where it was in the
    /// document, not at the current conflict.
    @Test(.timeLimit(.minutes(10))) func theCaretStaysPutAcrossUndoAndShowBase() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo)
        defer { cleanup(); window.close() }
        let view = host.result.textView
        view.setSelectedRange(NSRange(location: try Self.rowStart("end", host), length: 0))
        view.insertText("q", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(Self.chunk(4, store)?.text == "qend\n")
        let caret = view.selectedRange()

        // Typing paused; the caret moves on the same line, then undo.
        view.setSelectedRange(NSRange(location: caret.location - 1, length: 0))
        store.resolverUndo()
        Self.refresh(store, host)
        #expect(Self.chunk(4, store)?.text == "end\n")
        #expect(view.selectedRange() == NSRange(location: try Self.rowStart("end", host), length: 0))

        // Show Base adds rows above each conflict; the caret stays on "end".
        store.showsBase = true
        defer { store.showsBase = false }
        Self.refresh(store, host)
        #expect(host.model.rows.contains { $0.isBaseStrip })
        #expect(view.selectedRange() == NSRange(location: try Self.rowStart("end", host), length: 0))

        // A take moves it to the conflict taken.
        store.resolverTake(.theirs, chunk: 3)
        Self.refresh(store, host)
        let taken = try #require(host.model.firstRow[3])
        #expect(view.selectedRange() == NSRange(location: try #require(host.resultMap).displayStart(ofRow: taken), length: 0))
    }

    /// Undoing what was typed into a slot puts the caret back at the slot, not on the line after.
    @Test(.timeLimit(.minutes(10))) func undoingSlotTypingPutsTheCaretAtTheSlot() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo)
        defer { cleanup(); window.close() }
        let view = host.result.textView
        view.insertText("x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(Self.chunk(1, store)?.state == .edited)
        store.resolverUndo()
        Self.refresh(store, host)
        #expect(Self.chunk(1, store)?.state == .waiting)
        let slot = try #require(host.model.firstRow[1])
        #expect(host.model.rows[slot].isSlot)
        #expect(view.selectedRange() == NSRange(location: try #require(host.resultMap).displayStart(ofRow: slot), length: 0))
    }

    /// The strips' buttons take their own side, the chips theirs (Both: ours first; its menu:
    /// theirs first), and the overlay lets clicks through to the text except on a chip.
    @Test(.timeLimit(.minutes(10))) func theTakeButtonsAndChipsTakeTheirSide() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo)
        defer { cleanup(); window.close() }
        func buttons(_ gutter: ResolverGutterView) -> [ResolverTakeButton] {
            gutter.subviews.compactMap { $0 as? ResolverTakeButton }.sorted { $0.frame.minY < $1.frame.minY }
        }
        func chips() -> [ResolverChip] {
            host.result.overlay.subviews.compactMap { $0 as? ResolverChip }.sorted {
                ($0.frame.minY, $0.frame.minX) < ($1.frame.minY, $1.frame.minX)
            }
        }
        // One button per conflict in each strip, labelled with the conflict and the side.
        #expect(buttons(host.left).count == 2 && buttons(host.right).count == 2)
        #expect(buttons(host.left)[0].accessibilityLabel() == "Take Ours for conflict 1 of 2")
        #expect(buttons(host.right)[1].accessibilityLabel() == "Take Theirs for conflict 2 of 2")

        #expect(buttons(host.left)[0].accessibilityPerformPress())
        #expect(Self.chunk(1, store)?.state == .taken(.ours))
        #expect(buttons(host.right)[1].accessibilityPerformPress())
        #expect(Self.chunk(3, store)?.state == .taken(.theirs))

        // The chips of a waiting slot: ← Ours, Both, Theirs →.
        store.resolverUndo()
        Self.refresh(store, host)
        #expect(Self.chunk(3, store)?.state == .waiting)
        let slot = chips()
        #expect(slot.map(\.title) == [ConflictWording.slotOurs, ConflictWording.slotBoth, ConflictWording.slotTheirs])
        #expect(slot[1].accessibilityLabel() == "Take Both, Ours First for conflict 2 of 2")
        slot[2].performClick(nil)
        #expect(Self.chunk(3, store)?.state == .taken(.theirs))
        store.resolverUndo()
        Self.refresh(store, host)
        chips()[1].performClick(nil)
        #expect(Self.chunk(3, store)?.state == .taken(.oursThenTheirs))
        store.resolverUndo()
        Self.refresh(store, host)
        let both = chips()[1]
        let theirsFirst = try #require(both.menu?.items.first { $0.title == ConflictWording.bothTheirsFirst })
        both.menu?.performActionForItem(at: try #require(both.menu?.index(of: theirsFirst)))
        #expect(Self.chunk(3, store)?.state == .taken(.theirsThenOurs))
        store.resolverUndo()
        Self.refresh(store, host)
        chips()[0].performClick(nil)
        #expect(Self.chunk(3, store)?.state == .taken(.ours))

        // Clicks go through the overlay to the text, but not past a chip.
        store.resolverUndo()
        Self.refresh(store, host)
        let overlay = host.result.overlay
        let chip = chips()[0]
        let onChip = overlay.convert(NSPoint(x: chip.frame.midX, y: chip.frame.midY), to: overlay.superview)
        #expect(overlay.hitTest(onChip) is ResolverChip)
        let onText = overlay.convert(NSPoint(x: overlay.bounds.midX, y: overlay.bounds.minY + 12), to: overlay.superview)
        #expect(overlay.hitTest(onText) == nil)
    }

    /// Focus mode fills the columns before their first layout, while the strips are still zero
    /// wide: the take buttons are placed again once the strips have their width, centred in them
    /// rather than half outside their left edge until the next take.
    @Test(.timeLimit(.minutes(10))) func theTakeButtonsSitInTheMiddleOfTheirStrips() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let (_, host, window, cleanup) = try await Self.columns(repo)
        defer { cleanup(); window.close() }
        for gutter in [host.left, host.right] {
            #expect(gutter.bounds.width == ResolverGrid.gutterWidth)
            let buttons = gutter.subviews.compactMap { $0 as? ResolverTakeButton }
            #expect(buttons.count == 2)
            for button in buttons {
                #expect(abs(button.frame.midX - gutter.bounds.midX) < 0.5, "\(gutter.side) button at \(button.frame)")
                #expect(gutter.bounds.contains(button.frame))
            }
        }
    }

    /// A merge whose `b.txt` has one conflict two rows tall in the Result's slot (Theirs has two
    /// lines), between "top" and "end".
    static func twoRowMerge() throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.write("b.txt", "top\nx\nend\n")
        try repo.git("add", ".")
        try repo.git("commit", "-m", "base")
        try repo.git("switch", "-c", "topic")
        try repo.write("b.txt", "top\ntopic x\ntopic y\nend\n")
        try repo.git("commit", "-qam", "topic")
        try repo.git("switch", "-q", "main")
        try repo.write("b.txt", "top\nmain x\nend\n")
        try repo.git("commit", "-qam", "main")
        try repo.gitExpectingFailure("merge", "topic")
        return repo
    }

    static func columns(_ repo: ScratchRepo, path: String) async throws
        -> (store: RepositoryStore, host: ResolverColumnsHost, window: NSWindow, cleanup: () -> Void)
    {
        let (store, cleanup) = await openedTestStore(repo)
        _ = try #require(await ResolverStoreTests.openDraft(store, path))
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1200, height: 600), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = ResolverColumnsHost()
        host.frame = window.contentView?.bounds ?? .zero
        window.contentView?.addSubview(host)
        let focus = store.resolverFocus
        host.update(
            store: store, path: path, draft: store.resolverDrafts[path], current: focus?.currentChunk,
            showBase: store.showsBase, labels: store.conflictSides)
        host.layoutSubtreeIfNeeded()
        return (store, host, window, cleanup)
    }

    /// The first lines TextKit 2 has laid out in view, in each column, against their rows' places:
    /// where it drew them is where the line numbers, tints, outline and take buttons are.
    static func expectTextOnRows(_ host: ResolverColumnsHost, _ what: String) throws {
        for column in [host.ours, host.result, host.theirs] {
            let view = column.textView
            let manager = try #require(view.textLayoutManager)
            let content = try #require(manager.textContentManager)
            manager.textViewportLayoutController.layoutViewport()
            let viewport = try #require(manager.textViewportLayoutController.viewportRange)
            var checked = 0
            manager.enumerateTextLayoutFragments(from: viewport.location, options: []) { fragment in
                let offset = content.offset(from: content.documentRange.location, to: fragment.rangeInElement.location)
                guard let row = view.starts.firstIndex(of: offset) else { return true }
                let y = fragment.layoutFragmentFrame.minY + view.textContainerOrigin.y
                #expect(abs(y - ResolverGeometry.y(ofRow: row)) < 0.5, "\(what): \(column.column) row \(row) laid out at \(y)")
                checked += 1
                return checked < 5
            }
            #expect(checked > 0, "\(what): \(column.column) has no line in view")
        }
    }

    /// Lets the run loop turn until the columns have caught up with a long jump (at most 5 s).
    static func settleLayout(_ host: ResolverColumnsHost) async throws {
        for _ in 0..<500 where host.layoutPending {
            // As on screen, each turn is drawn.
            host.window?.displayIfNeeded()
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(!host.layoutPending)
        host.layoutSubtreeIfNeeded()
        host.window?.displayIfNeeded()
    }

    /// The columns scrolled to near the end of the file, as a user's scroll does.
    static func scrollDeep(_ host: ResolverColumnsHost) {
        let clip = host.result.scrollView.contentView
        let y = max(0, host.result.textView.frame.height - clip.bounds.height - 200)
        clip.scroll(to: NSPoint(x: 0, y: y))
        host.result.scrollView.reflectScrolledClipView(clip)
        host.layoutSubtreeIfNeeded()
    }

    /// A merge whose `long.txt` has 300 lines above its one conflict, so focus mode opens
    /// scrolled far down it; with `twice`, 300 more lines and a second conflict below the first.
    static func longMerge(twice: Bool = false) throws -> ScratchRepo {
        let repo = try ScratchRepo()
        let above = (1...300).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let below = twice ? (301...600).map { "line \($0)" }.joined(separator: "\n") + "\n" : ""
        func file(_ side: String) -> String {
            above + "\(side) x\n" + below + (twice ? "\(side) y\n" : "") + "end\n"
        }
        try repo.write("long.txt", file("base"))
        try repo.git("add", ".")
        try repo.git("commit", "-m", "base")
        try repo.git("switch", "-c", "topic")
        try repo.write("long.txt", file("topic"))
        try repo.git("commit", "-qam", "topic")
        try repo.git("switch", "-q", "main")
        try repo.write("long.txt", file("main"))
        try repo.git("commit", "-qam", "main")
        try repo.gitExpectingFailure("merge", "topic")
        return repo
    }

    /// The line numbers, tints, outline and take buttons are drawn at the rows, so TextKit 2 must
    /// lay the text out on them too: also when the columns jump far down a file whose lines above
    /// were never laid out, where TextKit places the lines it shows by an estimate of the ones
    /// above (seen 490 pt high at row 222).
    @Test(.timeLimit(.minutes(10))) func theTextSitsOnItsRowsAfterAJumpDownTheFile() async throws {
        let repo = try Self.longMerge()
        defer { repo.remove() }
        let (_, host, window, cleanup) = try await Self.columns(repo, path: "long.txt")
        defer { cleanup(); window.close() }
        #expect(host.result.scrollView.contentView.bounds.minY > 3000)
        try await Self.settleLayout(host)
        try Self.expectTextOnRows(host, "after the jump")
    }

    /// While the lines above a long jump are laid out, TextKit keeps the lines it shows where it
    /// first drew them, which moves the view by its estimate's error (443 pt in the real app);
    /// once they are laid out the view is where the jump aimed it: the next conflict a third of
    /// the way down, on screen.
    @Test(.timeLimit(.minutes(10))) func aLongJumpEndsWhereItAimed() async throws {
        let repo = try Self.longMerge(twice: true)
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo, path: "long.txt")
        defer { cleanup(); window.close() }
        try await Self.settleLayout(host)
        let clip = host.result.scrollView.contentView
        store.resolverNextConflict()
        host.update(
            store: store, path: "long.txt", draft: store.resolverDrafts["long.txt"],
            current: store.resolverFocus?.currentChunk, showBase: store.showsBase, labels: store.conflictSides)
        #expect(host.layoutPending)
        let conflict = try #require(host.model.chunkRows[store.resolverFocus?.currentChunk ?? -1])
        let top = ResolverGeometry.y(ofRow: conflict.lowerBound)
        let aimed = min(max(0, top - clip.bounds.height / 3), host.result.textView.frame.height - clip.bounds.height)
        try await Self.settleLayout(host)
        try Self.expectTextOnRows(host, "after the jump to the next conflict")
        #expect(clip.bounds.minY == aimed)
        #expect(clip.bounds.minY <= top && ResolverGeometry.y(ofRow: conflict.upperBound) <= clip.bounds.maxY)
    }

    /// A jump further down than one turn's layout budget lays the rows above the view out over
    /// several turns of the run loop, a budget's worth at a time, never all at once; when the last
    /// part is done the text is on its rows.
    @Test(.timeLimit(.minutes(10))) func aLongJumpIsLaidOutOverSeveralTurns() async throws {
        let repo = try Self.longMerge(twice: true)
        defer { repo.remove() }
        let (_, host, window, cleanup) = try await Self.columns(repo, path: "long.txt")
        defer { cleanup(); window.close() }
        let view = host.result.textView
        try await Self.settleLayout(host)
        let before = view.laidOutRows
        host.layoutBudget = 50
        host.catchUpBudget = 50
        Self.scrollDeep(host)
        let first = ResolverGeometry.rows(in: host.result.scrollView.contentView.bounds, count: host.model.rows.count).lowerBound
        #expect(first - before > 150)
        #expect(view.laidOutRows == before + 50)
        #expect(host.layoutPending)
        try await Self.settleLayout(host)
        #expect(view.laidOutRows >= first)
        try Self.expectTextOnRows(host, "after the turns")
    }

    /// A merge with two long files: `long.txt` as `longMerge(twice: true)` has it, and `top.txt`,
    /// its one conflict on its second row and 600 lines after it.
    static func twoLongFiles() throws -> ScratchRepo {
        let repo = try ScratchRepo()
        let above = (1...300).map { "line \($0)" }.joined(separator: "\n") + "\n"
        let below = (301...600).map { "line \($0)" }.joined(separator: "\n") + "\n"
        func write(_ side: String) throws {
            try repo.write("long.txt", above + "\(side) x\n" + below + "\(side) y\nend\n")
            try repo.write("top.txt", "first\n\(side) z\n" + above + below)
        }
        try write("base")
        try repo.git("add", ".")
        try repo.git("commit", "-m", "base")
        try repo.git("switch", "-c", "topic")
        try write("topic")
        try repo.git("commit", "-qam", "topic")
        try repo.git("switch", "-q", "main")
        try write("main")
        try repo.git("commit", "-qam", "main")
        try repo.gitExpectingFailure("merge", "topic")
        return repo
    }

    /// Another file shown while a long jump in the last one is still being laid out starts at its
    /// top, where its first conflict is: not where the last file's jump aimed.
    @Test(.timeLimit(.minutes(10))) func aFileSwitchDuringACatchUpKeepsTheNewFileAtItsTop() async throws {
        let repo = try Self.twoLongFiles()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo, path: "long.txt")
        defer { cleanup(); window.close() }
        try await Self.settleLayout(host)
        _ = try #require(await ResolverStoreTests.openDraft(store, "top.txt"))
        let long = try #require(store.resolverDrafts["long.txt"]), top = try #require(store.resolverDrafts["top.txt"])
        let second = long.document.chunks.last { !$0.blocks.isEmpty }?.id
        host.update(store: store, path: "long.txt", draft: long, current: second, showBase: false, labels: store.conflictSides)
        #expect(host.layoutPending)
        #expect(host.result.scrollView.contentView.bounds.minY > 5000)
        let first = top.document.chunks.first { !$0.blocks.isEmpty }?.id
        host.update(store: store, path: "top.txt", draft: top, current: first, showBase: false, labels: store.conflictSides)
        try await Self.settleLayout(host)
        #expect(host.result.scrollView.contentView.bounds.minY == 0)
        try Self.expectTextOnRows(host, "top.txt after the switch")
    }

    /// A scroll of the user's own while a long jump is still being laid out — a wheel, a trackpad,
    /// the scroller, all of which AppKit announces as a live scroll — is where the view stays:
    /// the jump's aim is not put back over it.
    @Test(.timeLimit(.minutes(10))) func aUserScrollDuringACatchUpIsNotUndone() async throws {
        let repo = try Self.longMerge(twice: true)
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo, path: "long.txt")
        defer { cleanup(); window.close() }
        try await Self.settleLayout(host)
        store.resolverNextConflict()
        host.update(
            store: store, path: "long.txt", draft: store.resolverDrafts["long.txt"],
            current: store.resolverFocus?.currentChunk, showBase: store.showsBase, labels: store.conflictSides)
        #expect(host.layoutPending)
        let scroll = host.result.scrollView, clip = scroll.contentView
        let aimed = clip.bounds.minY
        // Back up 200 rows, into the lines laid out before the jump.
        let mine = aimed - 4000
        NotificationCenter.default.post(name: NSScrollView.willStartLiveScrollNotification, object: scroll)
        clip.scroll(to: NSPoint(x: 0, y: mine))
        scroll.reflectScrolledClipView(clip)
        NotificationCenter.default.post(name: NSScrollView.didEndLiveScrollNotification, object: scroll)
        try await Self.settleLayout(host)
        #expect(abs(clip.bounds.minY - mine) < 100, "the user scrolled to \(mine), the jump aimed at \(aimed); the view is at \(clip.bounds.minY)")
        try Self.expectTextOnRows(host, "after the user's scroll")
    }

    /// Once the columns are laid out deep down the file, an edit far above the rows in view —
    /// typing, an input method's commit, an undo, Show Base turned on — changes the rows above
    /// them, so what was laid out from there on must be laid out again: the text stays on its
    /// rows, whichever path changed it.
    @Test(.timeLimit(.minutes(10))) func theTextStaysOnItsRowsAfterAnEditAboveTheView() async throws {
        let repo = try Self.longMerge(twice: true)
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo, path: "long.txt")
        defer { cleanup(); window.close() }
        func refresh() {
            host.update(
                store: store, path: "long.txt", draft: store.resolverDrafts["long.txt"],
                current: store.resolverFocus?.currentChunk, showBase: store.showsBase, labels: store.conflictSides)
            host.layoutSubtreeIfNeeded()
        }
        let view = host.result.textView
        try await Self.settleLayout(host)
        Self.scrollDeep(host)
        try await Self.settleLayout(host)
        try Self.expectTextOnRows(host, "deep")

        // Typing three lines near the top (the text view scrolls up to the caret), then back down.
        view.setSelectedRange(NSRange(location: try Self.rowStart("line 5", host), length: 0))
        view.insertText("typed\ntyped\ntyped\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        refresh()
        #expect(store.resolverDrafts["long.txt"]?.hasUserChanges == true)
        try await Self.settleLayout(host)
        Self.scrollDeep(host)
        try await Self.settleLayout(host)
        try Self.expectTextOnRows(host, "after typing above")

        // An input method's composition, committed near the top, then back down.
        view.setSelectedRange(NSRange(location: try Self.rowStart("line 9", host), length: 0))
        view.setMarkedText("k", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.insertText("\u{304B}\n", replacementRange: NSRange(location: NSNotFound, length: 0))
        refresh()
        try await Self.settleLayout(host)
        Self.scrollDeep(host)
        try await Self.settleLayout(host)
        try Self.expectTextOnRows(host, "after an input method's commit above")

        // Undo while deep: the rows above change under the view, which does not scroll.
        let before = host.result.scrollView.contentView.bounds.minY
        store.resolverUndo()
        store.resolverUndo()
        refresh()
        #expect(host.result.scrollView.contentView.bounds.minY == before)
        try await Self.settleLayout(host)
        try Self.expectTextOnRows(host, "after undo while deep")

        // Show Base turned on while deep: base strips appear above the view.
        store.showsBase = true
        refresh()
        try await Self.settleLayout(host)
        try Self.expectTextOnRows(host, "after Show Base while deep")
    }

    /// A click on the slot's lower row (the caret already at the slot, where it starts) stays in
    /// the slot, and typing goes into the conflict (I3).
    @Test(.timeLimit(.minutes(10))) func aClickOnASlotsLowerRowStaysInTheSlot() async throws {
        let repo = try Self.twoRowMerge()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo, path: "b.txt")
        defer { cleanup(); window.close() }
        let view = host.result.textView
        let map = try #require(host.resultMap)
        let slot = try #require(host.model.firstRow[1])
        #expect(host.model.rows[slot].isSlot && host.model.rows[slot + 1].isSlot)
        #expect(view.selectedRange() == NSRange(location: map.displayStart(ofRow: slot), length: 0))
        // No key event is current: the selection change is a click's.
        view.setSelectedRange(NSRange(location: map.displayStart(ofRow: slot + 1), length: 0))
        #expect(view.selectedRange() == NSRange(location: map.displayStart(ofRow: slot), length: 0))
        view.insertText("q", replacementRange: NSRange(location: NSNotFound, length: 0))
        let chunks = try #require(store.resolverDrafts["b.txt"]).document.chunks
        #expect(chunks.first { $0.id == 1 }?.state == .edited)
        #expect(chunks.first { $0.id == 1 }?.text == "q\n")
        #expect(chunks.first { $0.id == 2 }?.text == "end\n")
    }

    /// An input method that cancels its composition (empty marked text) hands the text back to the
    /// store: a Backspace after it reaches the store, and the shown text is the model's (I4).
    @Test(.timeLimit(.minutes(10))) func aCancelledCompositionLeavesTheStoreInCharge() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo)
        defer { cleanup(); window.close() }
        let view = host.result.textView
        let start = try Self.rowStart("mid", host)
        view.setSelectedRange(NSRange(location: start + 2, length: 0))
        view.setMarkedText("\u{B4}", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        view.setMarkedText("", selectedRange: NSRange(location: 0, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        #expect(view.compositionStart == nil)
        #expect(store.resolverDrafts["a.txt"]?.hasUserChanges == false)
        view.deleteBackward(nil)
        #expect(Self.chunk(2, store)?.text == "md\n")
        view.insertText("i", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(Self.chunk(2, store)?.text == "mid\n")
        // The shown text is a fresh build of the rows.
        let fresh = ResolverAttributes.text(for: host.model.rows, column: .result, palette: .standard)
        #expect(view.string == fresh.string)
    }

    /// Copy and Cut put the document's text for the selection on the pasteboard — never a filler,
    /// a slot's blank rows or Show Base's text (I5).
    @Test(.timeLimit(.minutes(10))) func copyTakesTheDocumentsTextNotTheShownOne() async throws {
        let repo = try Self.twoRowMerge()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo, path: "b.txt")
        defer { cleanup(); window.close() }
        store.showsBase = true
        defer { store.showsBase = false }
        let refresh = {
            let focus = store.resolverFocus
            host.update(
                store: store, path: "b.txt", draft: store.resolverDrafts["b.txt"], current: focus?.currentChunk,
                showBase: store.showsBase, labels: store.conflictSides)
        }
        refresh()
        let view = host.result.textView
        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.copy-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        #expect(view.writablePasteboardTypes == [.string])

        // Waiting: the slot's rows and the strip are shown, the document has neither.
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "top\nend\n")

        // Taken Ours: one line over Theirs' two, a Result filler below it.
        store.resolverTake(.ours, chunk: 1)
        refresh()
        #expect(host.model.rows.contains { $0.result == ResolverLayoutTests.filler && !$0.isBaseStrip })
        view.setSelectedRange(NSRange(location: 0, length: (view.string as NSString).length))
        #expect(view.writeSelection(to: pasteboard, types: [.string]))
        #expect(pasteboard.string(forType: .string) == "top\nmain x\nend\n")
        #expect(pasteboard.string(forType: .string) == store.resolverDrafts["b.txt"]?.document.resultText)
    }

    /// ⌘Z with the sidebar's list holding the keys reaches the store through focus mode's key
    /// monitor; in a sheet's text field it is the field's (I2).
    @Test(.timeLimit(.minutes(10))) func undoKeysReachTheStoreWhereverTheKeysAre() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo)
        defer { cleanup(); window.close() }
        let monitor = ResolverKeyMonitor.MonitorView(
            done: {}, undo: { store.resolverUndo() }, redo: { store.resolverRedo() })
        window.contentView?.addSubview(monitor)
        let list = NSTableView(frame: NSRect(x: 0, y: 0, width: 100, height: 100))
        window.contentView?.addSubview(list)
        func key(_ characters: String, _ flags: NSEvent.ModifierFlags) throws -> NSEvent {
            try #require(
                NSEvent.keyEvent(
                    with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: window.windowNumber,
                    context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false,
                    keyCode: 6))
        }
        store.resolverTake(.ours, chunk: 1)
        #expect(window.makeFirstResponder(list))
        #expect(monitor.handle(try key("z", .command)))
        #expect(Self.chunk(1, store)?.state == .waiting)
        #expect(monitor.handle(try key("Z", [.command, .shift])))
        #expect(Self.chunk(1, store)?.state == .taken(.ours))
        // The Result too.
        #expect(window.makeFirstResponder(host.result.textView))
        #expect(monitor.handle(try key("z", .command)))
        #expect(Self.chunk(1, store)?.state == .waiting)
        // A text field being edited keeps its own undo.
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        window.contentView?.addSubview(field)
        #expect(window.makeFirstResponder(field))
        #expect(!monitor.handle(try key("z", .command)))
    }

    /// Escape in the editable Result leaves the text, so the next Escape is Done.
    @Test(.timeLimit(.minutes(10))) func escapeInTheResultLeavesTheText() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let (_, host, window, cleanup) = try await Self.columns(repo)
        defer { cleanup(); window.close() }
        #expect(window.makeFirstResponder(host.result.textView))
        host.result.textView.cancelOperation(nil)
        #expect(window.firstResponder === host)
    }

    /// A dead key: the marked accent shows as typed and reaches the store once, as "é".
    @Test(.timeLimit(.minutes(10))) func aCompositionIsCommittedOnce() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let (store, host, window, cleanup) = try await Self.columns(repo)
        defer { cleanup(); window.close() }
        let view = host.result.textView
        let start = try Self.rowStart("mid", host)
        view.setSelectedRange(NSRange(location: start, length: 0))
        view.setMarkedText("\u{B4}", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.hasMarkedText())
        #expect(store.resolverDrafts["a.txt"]?.hasUserChanges == false)
        view.insertText("\u{E9}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!view.hasMarkedText())
        #expect(Self.chunk(2, store)?.text == "\u{E9}mid\n")
        #expect((view.string as NSString).substring(with: NSRange(location: start, length: 5)) == "\u{E9}mid\n")
        #expect(view.string.filter { $0 == "\n" }.count == host.model.rows.count)
        store.resolverUndo()
        #expect(store.resolverDrafts["a.txt"]?.hasUserChanges == false)
    }
}
