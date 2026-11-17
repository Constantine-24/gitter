import Foundation
import GitterSyntax
import Testing

@testable import Gitter

/// The columns' rows mapped to their source lines' syntax tokens (`ResolverSyntax`): a text row
/// gets its line's tokens only while its text is that line; fillers, slots and base strips are
/// plain; and the lines are split exactly as `SyntaxHighlighter.lineTokens` splits them.
@Suite struct ResolverSyntaxTests {

    static func cell(_ number: Int?, _ text: String?) -> LayoutCell {
        LayoutCell(lineNumber: number, text: text, tint: .none, marks: [])
    }

    static func row(
        ours: LayoutCell = cell(nil, nil), result: LayoutCell = cell(nil, nil), theirs: LayoutCell = cell(nil, nil),
        isSlot: Bool = false, isBaseStrip: Bool = false
    ) -> LayoutRow {
        LayoutRow(ours: ours, result: result, theirs: theirs, chunk: 0, isSlot: isSlot, badge: nil, isBaseStrip: isBaseStrip)
    }

    static let keyword = SyntaxToken(range: 0..<3, kind: .keyword)
    static let number = SyntaxToken(range: 8..<9, kind: .number)

    @Test func textRowsGetTheirLinesTokens() {
        let source = "let a = 1\nlet b = 2\n"
        let sourceLines = ResolverSyntax.sourceLines(source)
        let lines: [[SyntaxToken]] = [[Self.keyword], [Self.keyword, Self.number], []]
        // Row 0 shows line 2, row 1 is a filler, row 2 shows line 1: by number, not by row.
        let rows = [
            Self.row(ours: Self.cell(2, "let b = 2"), result: Self.cell(2, "let b = 2"), theirs: Self.cell(2, "let b = 2")),
            Self.row(),
            Self.row(ours: Self.cell(1, "let a = 1"), result: Self.cell(1, "let a = 1"), theirs: Self.cell(1, "let a = 1")),
        ]
        for column in [ResolverColumn.ours, .result, .theirs] {
            let tokens = ResolverSyntax.rowTokens(rows: rows, column: column, lines: lines, sourceLines: sourceLines)
            #expect(tokens == [0: [Self.keyword, Self.number], 2: [Self.keyword]], "\(column)")
        }
    }

    @Test func fillersSlotsAndBaseStripsArePlain() {
        let sourceLines = ResolverSyntax.sourceLines("let a = 1\n")
        let lines: [[SyntaxToken]] = [[Self.keyword], []]
        let line = Self.cell(1, "let a = 1")
        let rows = [
            // A filler in every column.
            Self.row(),
            // A slot row: its Result cell is never coloured, even were it to carry the line.
            Self.row(ours: line, result: line, theirs: line, isSlot: true),
            // A Show Base row whose base line reads like the source line.
            Self.row(result: line, isBaseStrip: true),
            // A line number past the text.
            Self.row(ours: Self.cell(5, "let a = 1"), result: Self.cell(5, "let a = 1"), theirs: Self.cell(5, "let a = 1")),
        ]
        #expect(ResolverSyntax.rowTokens(rows: rows, column: .result, lines: lines, sourceLines: sourceLines).isEmpty)
        // The sides of the slot row are their own lines, coloured; the rest stays plain.
        #expect(ResolverSyntax.rowTokens(rows: rows, column: .ours, lines: lines, sourceLines: sourceLines) == [1: [Self.keyword]])
        #expect(ResolverSyntax.rowTokens(rows: rows, column: .theirs, lines: lines, sourceLines: sourceLines) == [1: [Self.keyword]])
    }

    @Test func editedRowStaysPlainUntilReparse() {
        let sourceLines = ResolverSyntax.sourceLines("let a = 1\nlet b = 2\n")
        let lines: [[SyntaxToken]] = [[Self.keyword], [Self.keyword, Self.number], []]
        let rows = [
            Self.row(result: Self.cell(1, "let a = 1")),
            // Typed into since the parse: the text is not line 2's any more.
            Self.row(result: Self.cell(2, "let b = 2x")),
        ]
        #expect(ResolverSyntax.rowTokens(rows: rows, column: .result, lines: lines, sourceLines: sourceLines) == [0: [Self.keyword]])
        // Canonically equal but other code units: still not the line.
        let composed = ResolverSyntax.sourceLines("let \u{E9} = 1\n")
        let decomposed = [Self.row(result: Self.cell(1, "let e\u{301} = 1"))]
        #expect(ResolverSyntax.rowTokens(rows: decomposed, column: .result, lines: [[Self.keyword], []], sourceLines: composed).isEmpty)
    }

    @Test func shownSymbolsKeepOffsets() throws {
        // A lone `\r` inside line 1: the text view shows it as `␍`, one UTF-16 unit as well.
        let source = "let a = 1\r// note\nlet b = 2\n"
        let lines = SyntaxHighlighter.lineTokens(SyntaxHighlighter.tokens(in: source, language: .swift), in: source)
        let sourceLines = ResolverSyntax.sourceLines(source)
        let text = String(try #require(sourceLines.first))
        #expect(text == "let a = 1\r// note")
        let rows = [Self.row(ours: Self.cell(1, text))]
        let tokens = try #require(ResolverSyntax.rowTokens(rows: rows, column: .ours, lines: lines, sourceLines: sourceLines)[0])
        let shown = ResolverAttributes.shown(text)
        #expect(shown != text)
        #expect(shown.utf16.count == text.utf16.count)
        #expect(tokens.allSatisfy { $0.range.upperBound <= shown.utf16.count })
        let units = Array(shown.utf16)
        func word(_ token: SyntaxToken) -> String { String(decoding: units[token.range], as: UTF16.self) }
        #expect(tokens.contains { $0.kind == .keyword && word($0) == "let" })
        #expect(tokens.contains { $0.kind == .comment && word($0) == "// note" })
    }

    /// The same lines, counted and indexed as `lineTokens` counts them: CRLF's `\r` belongs to
    /// the terminator, a lone `\r` to the line, and a final `\n` leaves an empty last line.
    @Test func sourceLinesSplitAsLineTokens() {
        let cases: [(String, [String])] = [
            ("a\r\nb\rc\n", ["a", "b\rc", ""]),
            ("a\r\r\nb", ["a\r", "b"]),
            ("\r\n\n", ["", "", ""]),
            ("", [""]),
            ("x", ["x"]),
            ("é\u{301}\r\n🙂\n", ["é\u{301}", "🙂", ""]),
        ]
        for (text, expected) in cases {
            let lines = ResolverSyntax.sourceLines(text)
            #expect(lines.map(String.init) == expected, "\(text.debugDescription)")
            // One token over each whole line: lineTokens cuts it at the same line ends.
            var tokens: [SyntaxToken] = []
            var start = 0
            for line in lines {
                let length = line.utf16.count
                if length > 0 { tokens.append(SyntaxToken(range: start..<(start + length), kind: .string)) }
                start += length + (start + length < text.utf16.count ? (Array(text.utf16)[start + length] == 0x0D ? 2 : 1) : 0)
            }
            let split = SyntaxHighlighter.lineTokens(tokens, in: text)
            #expect(split.count == lines.count, "\(text.debugDescription)")
            for (index, line) in lines.enumerated() where index < split.count {
                let expectedTokens = line.isEmpty ? [] : [SyntaxToken(range: 0..<line.utf16.count, kind: .string)]
                #expect(split[index] == expectedTokens, "\(text.debugDescription) line \(index)")
            }
        }
    }
}
