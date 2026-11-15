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
