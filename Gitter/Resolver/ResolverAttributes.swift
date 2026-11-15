import AppKit
import Foundation

/// One of the three columns.
enum ResolverColumn: Hashable, Sendable { case ours, result, theirs }

/// What a row's paragraph is in a column.
enum ResolverRowKind: Hashable, Sendable {
    /// A line of the column's text.
    case text
    /// A grey filler: the other columns have a line here.
    case filler
    /// The waiting slot, in the Result.
    case slot
    /// A Show Base row above a conflict, in the Result: read-only.
    case baseStrip
}

/// A row paragraph's style, as the attribute `.resolverRow` carries it over the whole paragraph
/// and its break: what the row is and its tint. The text view draws the tint from it.
final class ResolverRowStyle: NSObject, Sendable {
    let kind: ResolverRowKind
    let tint: RowTint

    init(kind: ResolverRowKind, tint: RowTint) {
        self.kind = kind
        self.tint = tint
    }

    override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? ResolverRowStyle else { return false }
        return other.kind == kind && other.tint == tint
    }

    override var hash: Int {
        var hasher = Hasher()
        hasher.combine(kind)
        hasher.combine(tint)
        return hasher.finalize()
    }
}

extension NSAttributedString.Key {
    /// A `ResolverRowStyle`, over each row's paragraph and its break.
    static let resolverRow = NSAttributedString.Key("dev.penzin.Gitter.resolverRow")
    /// The stronger word mark: `true` over the marked characters.
    static let resolverMark = NSAttributedString.Key("dev.penzin.Gitter.resolverMark")
}

/// The columns' text, built from the layout's rows. Pure: no view, no store.
///
/// Every row is one paragraph in every column, ending in `\n`, so the three columns line up row
/// for row at the same height. A cell's text is its line (never its line ending); a filler, the
/// waiting slot and a cell with no text are empty paragraphs. Tints and word marks are attributes
/// (`.resolverRow`, `.resolverMark`) the text view draws behind the text; line numbers, bars,
/// badges, the slot and the outline are drawn from the rows themselves.
@MainActor enum ResolverAttributes {
    /// Every row's height: the mockup's.
    nonisolated static let rowHeight: CGFloat = 20
    static let codeFont = NSFont.monospacedSystemFont(ofSize: 12, weight: .regular)
    static let interfaceFont = NSFont.systemFont(ofSize: 11)

    /// One fixed height per row, whatever the characters: the alignment depends on it. The line
    /// is `rowHeight - belowLine` tall with its glyphs at its foot, and the paragraph spacing
    /// below it makes up the row, so the code sits in the row's middle. (A `.baselineOffset`
    /// would shorten TextKit 2's line instead: measured, 18 pt rows for 20.)
    static let paragraphStyle: NSParagraphStyle = {
        let style = NSMutableParagraphStyle()
        style.minimumLineHeight = rowHeight - belowLine
        style.maximumLineHeight = rowHeight - belowLine
        style.paragraphSpacing = belowLine
        style.lineBreakMode = .byClipping
        style.tabStops = []
        let space = (" " as NSString).size(withAttributes: [.font: codeFont]).width
        style.defaultTabInterval = space * 4
        return style
    }()

    /// The code font's advance: every character but the widest.
    static let characterWidth: CGFloat = ("0" as NSString).size(withAttributes: [.font: codeFont]).width

    /// The space under a line that centres the code font in its row.
    static let belowLine: CGFloat = {
        let font = codeFont
        return ((rowHeight - (font.ascender - font.descender)) / 2).rounded()
    }()

    static func text(for rows: [LayoutRow], column: ResolverColumn, palette: ResolverPalette) -> NSAttributedString {
        let result = NSMutableAttributedString()
        result.beginEditing()
        let code: [NSAttributedString.Key: Any] = [
            .font: codeFont, .paragraphStyle: paragraphStyle, .foregroundColor: palette.text,
        ]
        for row in rows {
            let cell = cell(row, column)
            let kind: ResolverRowKind
            var attributes = code
            let shown: String
            if column == .result, row.isBaseStrip {
                kind = .baseStrip
                shown = cell.text.map(Self.shown) ?? ConflictWording.noBaseStrip
                attributes[.foregroundColor] = palette.secondaryText
                if cell.text == nil { attributes[.font] = interfaceFont }
            } else if column == .result, row.isSlot {
                kind = .slot
                shown = ""
            } else if let text = cell.text {
                kind = .text
                shown = Self.shown(text)
            } else {
                kind = .filler
                shown = ""
            }
            let tint: RowTint = kind == .filler ? .filler : cell.tint
            attributes[.resolverRow] = ResolverRowStyle(kind: kind, tint: tint)
            let start = result.length
            result.append(NSAttributedString(string: shown + "\n", attributes: attributes))
            if kind == .text {
                let length = (shown as NSString).length
                for mark in cell.marks where mark.lowerBound >= 0 && mark.upperBound <= length && !mark.isEmpty {
                    result.addAttribute(
                        .resolverMark, value: true,
                        range: NSRange(location: start + mark.lowerBound, length: mark.count))
                }
            }
        }
        result.endEditing()
        return result
    }

    nonisolated static func cell(_ row: LayoutRow, _ column: ResolverColumn) -> LayoutCell {
        switch column {
        case .ours: row.ours
        case .result: row.result
        case .theirs: row.theirs
        }
    }

    /// A line as the text view shows it: a character that would start a new line or paragraph
    /// there (a lone `\r`, NEL, a vertical tab, a form feed, a line or paragraph separator) is
    /// shown as a symbol of the same UTF-16 length, so the row stays one paragraph and every
    /// offset within it stays the line's.
    nonisolated static func shown(_ line: String) -> String {
        guard line.unicodeScalars.contains(where: { breaks.keys.contains($0) }) else { return line }
        var scalars = String.UnicodeScalarView()
        for scalar in line.unicodeScalars { scalars.append(breaks[scalar] ?? scalar) }
        return String(scalars)
    }

    nonisolated private static let breaks: [Unicode.Scalar: Unicode.Scalar] = [
        "\r": "\u{240D}", "\u{0B}": "\u{240B}", "\u{0C}": "\u{240C}", "\u{85}": "\u{2424}",
        "\u{2028}": "\u{2424}", "\u{2029}": "\u{00B6}",
    ]
}
