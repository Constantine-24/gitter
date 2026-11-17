import Foundation
import GitterSyntax

/// The columns' rows mapped to syntax tokens (syntax colours, spec "Resolve Conflicts"). Pure:
/// no view, no store, any thread.
///
/// Tokens come per source line (`SyntaxHighlighter.lineTokens`): the stage's text for Ours and
/// Theirs, the Result's text as last parsed. A row takes its line's tokens through its cell's
/// line number, and only while its text is still that line, unit for unit: a Result row typed
/// into since the parse, or one that shares its line with the chunk before it, stays plain until
/// the next parse. Fillers, the waiting slot, Show Base rows and rows longer than
/// `SyntaxHighlighter.maxLineLength` stay plain too. A row's text is
/// shown with the same UTF-16 length (`ResolverAttributes.shown`), so the line's offsets are the
/// row's.
enum ResolverSyntax {
    /// Each coloured row's tokens, by row index, with ranges relative to the row's text. Rows
    /// with no tokens have no entry.
    static func rowTokens(rows: [LayoutRow], column: ResolverColumn, lines: [[SyntaxToken]], sourceLines: [Substring])
        -> [Int: [SyntaxToken]]
    {
        var result: [Int: [SyntaxToken]] = [:]
        for (index, row) in rows.enumerated() {
            if let tokens = tokens(of: row, column: column, lines: lines, sourceLines: sourceLines) {
                result[index] = tokens
            }
        }
        return result
    }

    /// One row's tokens, or nil when it stays plain.
    static func tokens(of row: LayoutRow, column: ResolverColumn, lines: [[SyntaxToken]], sourceLines: [Substring])
        -> [SyntaxToken]?
    {
        if column == .result, row.isSlot || row.isBaseStrip { return nil }
        let cell = ResolverAttributes.cell(row, column)
        guard let number = cell.lineNumber, let text = cell.text else { return nil }
        // The colours go on the row's text on the main actor, token by token.
        let length = text.utf16.count
        guard length <= SyntaxHighlighter.maxLineLength else { return nil }
        let index = number - 1
        guard lines.indices.contains(index), sourceLines.indices.contains(index),
            text.utf16.elementsEqual(sourceLines[index].utf16)
        else { return nil }
        let tokens = lines[index]
        guard !tokens.isEmpty else { return nil }
        // `lineTokens` never reaches past the line; kept to the text all the same.
        return tokens.allSatisfy({ $0.range.upperBound <= length }) ? tokens : tokens.filter { $0.range.upperBound <= length }
    }

    /// `text`'s lines without their terminators, split as `SyntaxHighlighter.lineTokens` splits:
    /// at each `\n`, a `\r` just before it part of the terminator (a lone `\r` stays in its
    /// line), on UTF-16 units because `"\r\n"` is one `Character`. One line per `\n` plus one, so
    /// a final `\n` leaves an empty last line.
    static func sourceLines(_ text: String) -> [Substring] {
        let utf16 = text.utf16
        var lines: [Substring] = []
        var lineStart = utf16.startIndex
        var previous: (unit: UInt16, index: String.Index)?
        var index = utf16.startIndex
        while index != utf16.endIndex {
            let unit = utf16[index]
            if unit == 0x0A {
                // Every end is a `Character` boundary: before `\r\n`, a lone `\r` or a `\n`.
                var end = index
                if let previous, previous.unit == 0x0D, previous.index >= lineStart { end = previous.index }
                lines.append(text[lineStart..<end])
                lineStart = utf16.index(after: index)
            }
            previous = (unit, index)
            index = utf16.index(after: index)
        }
        lines.append(text[lineStart..<utf16.endIndex])
        return lines
    }
}
