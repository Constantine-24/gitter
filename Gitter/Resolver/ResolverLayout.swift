import Foundation
import GitCore

/// A cell's background: a side's change, the Result's state, or a grey filler.
enum RowTint: Hashable, Sendable { case none, oursChanged, theirsChanged, taken, edited, fromOurs, fromTheirs, filler }

/// The small badge at the right edge of a Result row.
enum ResultBadge: Hashable, Sendable { case ours, theirs, oursThenTheirs, theirsThenOurs, editedByYou, fromOurs, fromTheirs }

/// One column's part of a row.
struct LayoutCell: Hashable, Sendable {
    let lineNumber: Int?  // nil for a filler or the waiting slot
    let text: String?  // nil for a filler or the waiting slot; never a line ending
    let tint: RowTint
    let marks: [Range<Int>]  // UTF-16 offsets within `text`, the stronger word marks
}

/// One row of Ours | Result | Theirs.
struct LayoutRow: Hashable, Sendable {
    let ours: LayoutCell, result: LayoutCell, theirs: LayoutCell
    let chunk: Int  // ResolverChunk.id
    let isSlot: Bool  // a waiting chunk's slot row in the Result
    /// A conflict's first row, or (in common text) the first row of each run of lines from one
    /// side or edited (the spec's rule). Below the base strip when it shows.
    let badge: ResultBadge?
    /// A Show Base row above a conflict: fillers on the sides, the base line in the Result
    /// (tinted `.filler`), or nil text for the one row that says there is no base.
    var isBaseStrip: Bool = false
}

/// Aligns the three columns into rows. Pure: no AppKit, no git.
///
/// - **Lines** are split on `\n`, a `\r` before it dropped, so `\r\n` is one terminator; no cell
///   text holds one. Lines compare by UTF-8 bytes.
/// - **Each column's lines** are its own: Ours is stage 2, Theirs stage 3 (in worktree form),
///   the Result the document's chunks. Line numbers count them, skipping fillers and the slot.
/// - **Where a chunk sits in a stage.** A conflict's side is in the stage line for line, so each
///   block's side is found there in order, as an exact match of lines; among several places the
///   one whose neighbouring lines match the common text around the block (`commonOriginal`, git's,
///   never the typed text) wins, then the one nearest the common text's length. Common text
///   takes the stage lines between its blocks; a merged chunk takes the gap between its
///   neighbours, so the chunks tile each stage.
/// - **Side tints.** A side line that differs from the base gets its side's tint and word marks
///   against the base line it replaces, whole when it replaces none: a block's lines against the
///   block's base, the other lines against stage 1. Without stage 1 only blocks are tinted.
/// - **Per chunk:**
///   - a waiting conflict: `max(ours, theirs, 1)` rows, the slot in the Result on every one;
///   - a taken or edited chunk: `max(result, ours, theirs)` rows, fillers below the shorter
///     columns, the badge on its first row;
///   - common text: the Result's lines aligned with each side's through line diffs. A line only
///     one side has is `fromOurs`/`fromTheirs`, marked against the other side's line it
///     replaces; a line not in git's text is `edited`. A line the Result lacks is a filler there.
///
/// It reruns on every change, so its cost is near-linear in the lines plus the line diffs.
enum ResolverLayout {
    static func rows(_ document: ResolverDocument, sides: ConflictSides, showBase: Bool) -> [LayoutRow] {
        let chunks = document.chunks
        let base = sides.base.map { lines(of: $0) }
        let ours = Column(stage: sides.ours, side: .ours, chunks: chunks, base: base)
        let theirs = Column(stage: sides.theirs, side: .theirs, chunks: chunks, base: base)

        var rows: [LayoutRow] = []
        var nextNumber = 1
        // The last chunk's text ended inside a line, which this chunk's first line continues.
        var continues = false
        for (index, chunk) in chunks.enumerated() {
            var result: [NumberedLine] = []
            for (offset, line) in lines(of: chunk.text).enumerated() {
                if offset == 0, continues {
                    result.append(NumberedLine(line: line, number: nextNumber - 1))
                } else {
                    result.append(NumberedLine(line: line, number: nextNumber))
                    nextNumber += 1
                }
            }
            if !chunk.text.isEmpty { continues = chunk.text.unicodeScalars.last != "\n" }

            let spans = (ours: ours.spans[index], theirs: theirs.spans[index])
            if chunk.blocks.isEmpty {
                rows += commonRows(chunk, result: result, ours: ours, theirs: theirs, spans: spans)
            } else {
                if showBase {
                    let strip: [String?] = baseStrip(of: chunk) ?? [nil]
                    for line in strip {
                        rows.append(
                            LayoutRow(
                                ours: filler, result: LayoutCell(lineNumber: nil, text: line, tint: .filler, marks: []),
                                theirs: filler, chunk: chunk.id, isSlot: false, badge: nil, isBaseStrip: true))
                    }
                }
                rows += conflictRows(chunk, result: result, ours: ours, theirs: theirs, spans: spans)
            }
        }
        return rows
    }

    /// The base text of a conflict, one string per line, for the Show Base strip; nil for common
    /// text, an unknown id, and a conflict whose base is missing or empty (both sides only added
    /// lines there). A merged chunk's blocks' base lines, in order.
    static func baseStrip(_ document: ResolverDocument, chunk id: Int) -> [String]? {
        guard let chunk = document.chunks.first(where: { $0.id == id }) else { return nil }
        return baseStrip(of: chunk)
    }

    private static func baseStrip(of chunk: ResolverChunk) -> [String]? {
        let lines = chunk.blocks.flatMap { block in Self.lines(of: block.base ?? Data()).map(\.text) }
        return lines.isEmpty ? nil : lines
    }

    // MARK: - Chunks

    private static let filler = LayoutCell(lineNumber: nil, text: nil, tint: .filler, marks: [])
    private static let slot = LayoutCell(lineNumber: nil, text: nil, tint: .none, marks: [])

    private struct NumberedLine {
        let line: Line
        let number: Int
    }

    private typealias Spans = (ours: Range<Int>, theirs: Range<Int>)

    private static func conflictRows(
        _ chunk: ResolverChunk, result: [NumberedLine], ours: Column, theirs: Column, spans: Spans
    ) -> [LayoutRow] {
        let tint: RowTint, badge: ResultBadge?
        switch chunk.state {
        case .waiting: (tint, badge) = (.none, nil)
        case .taken(let choice): (tint, badge) = (.taken, Self.badge(for: choice))
        case .edited, .common: (tint, badge) = (.edited, .editedByYou)
        }
        let waiting = chunk.state == .waiting
        let count =
            waiting
            ? max(spans.ours.count, spans.theirs.count, 1)
            : max(result.count, spans.ours.count, spans.theirs.count)
        return (0..<count).map { row in
            let resultCell =
                waiting
                ? slot
                : row < result.count
                    ? LayoutCell(lineNumber: result[row].number, text: result[row].line.text, tint: tint, marks: [])
                    : filler
            return LayoutRow(
                ours: row < spans.ours.count ? ours.cell(spans.ours.lowerBound + row) : filler,
                result: resultCell,
                theirs: row < spans.theirs.count ? theirs.cell(spans.theirs.lowerBound + row) : filler,
                chunk: chunk.id, isSlot: waiting, badge: row == 0 ? badge : nil)
        }
    }

    private static func badge(for choice: BlockChoice) -> ResultBadge {
        switch choice {
        case .ours: .ours
        case .theirs: .theirs
        case .oursThenTheirs: .oursThenTheirs
        case .theirsThenOurs: .theirsThenOurs
        }
    }

    private static func commonRows(
        _ chunk: ResolverChunk, result: [NumberedLine], ours: Column, theirs: Column, spans: Spans
    ) -> [LayoutRow] {
        let keys = result.map(\.line.key)
        let left = Spine(old: ours.lines[spans.ours].map(\.key), new: keys)
        let right = Spine(old: theirs.lines[spans.theirs].map(\.key), new: keys)
        var edited = Set<Int>()
        if let original = chunk.commonOriginal, !chunk.text.utf8.elementsEqual(original.utf8) {
            let git = Spine(old: lines(of: original).map(\.key), new: keys)
            edited = Set(keys.indices.filter { git.partner[$0]?.exact != true })
        } else if chunk.commonOriginal == nil {
            edited = Set(keys.indices)
        }

        var rows: [LayoutRow] = []
        var previous = RowTint.filler
        func gapRows(_ oursGap: [Int], _ theirsGap: [Int]) {
            for row in 0..<max(oursGap.count, theirsGap.count) {
                rows.append(
                    LayoutRow(
                        ours: row < oursGap.count ? ours.cell(spans.ours.lowerBound + oursGap[row]) : filler,
                        result: filler,
                        theirs: row < theirsGap.count ? theirs.cell(spans.theirs.lowerBound + theirsGap[row]) : filler,
                        chunk: chunk.id, isSlot: false, badge: nil))
                previous = .filler
            }
        }
        for (index, numbered) in result.enumerated() {
            gapRows(left.gaps[index], right.gaps[index])
            let oursPartner = left.partner[index], theirsPartner = right.partner[index]
            let text = numbered.line.text
            let tint: RowTint, marks: [Range<Int>]
            if edited.contains(index) {
                (tint, marks) = (.edited, [])
            } else if oursPartner?.exact != true, theirsPartner?.exact == true {
                tint = .fromTheirs
                marks = oursPartner.map { lineMarks(old: ours.lines[spans.ours.lowerBound + $0.index].text, new: text) }
                    ?? wholeLine(text)
            } else if oursPartner?.exact == true, theirsPartner?.exact != true {
                tint = .fromOurs
                marks = theirsPartner.map { lineMarks(old: theirs.lines[spans.theirs.lowerBound + $0.index].text, new: text) }
                    ?? wholeLine(text)
            } else {
                (tint, marks) = (.none, [])
            }
            let badge = tint == previous ? nil : runBadge(tint)
            previous = tint
            rows.append(
                LayoutRow(
                    ours: oursPartner.map { ours.cell(spans.ours.lowerBound + $0.index) } ?? filler,
                    result: LayoutCell(lineNumber: numbered.number, text: text, tint: tint, marks: marks),
                    theirs: theirsPartner.map { theirs.cell(spans.theirs.lowerBound + $0.index) } ?? filler,
                    chunk: chunk.id, isSlot: false, badge: badge))
        }
        gapRows(left.tail, right.tail)
        return rows
    }

    /// The badge that starts a run of common lines with `tint`.
    private static func runBadge(_ tint: RowTint) -> ResultBadge? {
        switch tint {
        case .fromOurs: .fromOurs
        case .fromTheirs: .fromTheirs
        case .edited: .editedByYou
        default: nil
        }
    }

    // MARK: - Lines

    struct Line {
        let text: String
        let key: [UInt8]
    }

    /// `text`'s lines without their `\n` or `\r\n`; none for empty text, and a last line without
    /// a terminator counts.
    static func lines(of text: String) -> [Line] {
        guard !text.isEmpty else { return [] }
        var parts = text.unicodeScalars.split(separator: "\n", omittingEmptySubsequences: false)
        if text.unicodeScalars.last == "\n" { parts.removeLast() }
        return parts.map { part in
            let scalars = part.last == "\r" ? part.dropLast() : part
            let line = String(Substring(scalars))
            return Line(text: line, key: Array(line.utf8))
        }
    }

    static func lines(of data: Data) -> [Line] {
        lines(of: String(validating: data, as: UTF8.self) ?? String(decoding: data, as: UTF8.self))
    }

    /// `WordDiff`'s marks, the whole-line fallback trimmed to the line's text (no indentation).
    static func lineMarks(old: String, new: String) -> [Range<Int>] {
        let marks = WordDiff.marks(old: old, new: new)
        return marks == [0..<new.utf16.count] ? wholeLine(new) : marks
    }

    /// The line from its first to its last character that is not whitespace; none for a blank line.
    static func wholeLine(_ text: String) -> [Range<Int>] {
        var offset = 0, first: Int?, last = 0
        for character in text {
            let length = character.utf16.count
            if !character.isWhitespace {
                if first == nil { first = offset }
                last = offset + length
            }
            offset += length
        }
        return first.map { [$0..<last] } ?? []
    }

    // MARK: - Line diffs

    private enum Pair {
        case matched(Int, Int), paired(Int, Int), old(Int), new(Int)
    }

    /// `old` against `new` through `CollectionDifference`: equal lines matched, and in each hunk
    /// the k-th removed line paired with the k-th inserted one; the rest one-sided.
    private static func pairs(_ old: [[UInt8]], _ new: [[UInt8]]) -> [Pair] {
        var removed = Set<Int>(), inserted = Set<Int>()
        for change in new.difference(from: old) {
            switch change {
            case .remove(let offset, _, _): removed.insert(offset)
            case .insert(let offset, _, _): inserted.insert(offset)
            }
        }
        var pairs: [Pair] = []
        var i = 0, j = 0
        while i < old.count || j < new.count {
            var gone: [Int] = [], added: [Int] = []
            while i < old.count, removed.contains(i) {
                gone.append(i)
                i += 1
            }
            while j < new.count, inserted.contains(j) {
                added.append(j)
                j += 1
            }
            if gone.isEmpty, added.isEmpty {
                guard i < old.count, j < new.count else { break }
                pairs.append(.matched(i, j))
                i += 1
                j += 1
                continue
            }
            let paired = min(gone.count, added.count)
            for k in 0..<paired { pairs.append(.paired(gone[k], added[k])) }
            pairs += gone.dropFirst(paired).map { .old($0) }
            pairs += added.dropFirst(paired).map { .new($0) }
        }
        return pairs
    }

    /// `old` laid along `new`: for each line of `new` its partner in `old` (exact or a replaced
    /// line) and the lines only `old` has just before it; `tail` follows the last.
    private struct Spine {
        var partner: [(index: Int, exact: Bool)?]
        var gaps: [[Int]]
        var tail: [Int] = []

        init(old: [[UInt8]], new: [[UInt8]]) {
            partner = Array(repeating: nil, count: new.count)
            gaps = Array(repeating: [], count: new.count)
            var pending: [Int] = []
            for pair in ResolverLayout.pairs(old, new) {
                switch pair {
                case .matched(let o, let n), .paired(let o, let n):
                    gaps[n] = pending
                    pending = []
                    if case .matched = pair { partner[n] = (o, true) } else { partner[n] = (o, false) }
                case .old(let o):
                    pending.append(o)
                case .new(let n):
                    gaps[n] = pending
                    pending = []
                }
            }
            tail = pending
        }
    }

    // MARK: - A side's column

    /// One side's stage: its lines, each line's tint and marks, and each chunk's span of lines.
    private struct Column {
        let lines: [Line]
        let tints: [RowTint]
        let marks: [[Range<Int>]]
        /// Per chunk, in `chunks` order; they tile `lines`.
        let spans: [Range<Int>]

        init(stage: Data?, side: ConflictSide, chunks: [ResolverChunk], base: [Line]?) {
            func sideOf(_ block: ConflictBlock) -> Data { side == .ours ? block.ours : block.theirs }
            // A stage that is missing (never for a blocks presentation) is rebuilt from the chunks.
            let lines =
                stage.map { ResolverLayout.lines(of: $0) }
                ?? chunks.flatMap { chunk in
                    ResolverLayout.lines(of: chunk.commonOriginal ?? "")
                        + chunk.blocks.flatMap { ResolverLayout.lines(of: sideOf($0)) }
                }
            let keys = lines.map(\.key)

            var blocks: [Located] = []
            for (index, chunk) in chunks.enumerated() {
                for (position, block) in chunk.blocks.enumerated() {
                    blocks.append(
                        Located(
                            chunk: index, lines: ResolverLayout.lines(of: sideOf(block)).map(\.key),
                            base: block.base.map { ResolverLayout.lines(of: $0) },
                            before: position == 0 ? Context.before(chunks, index) : .unknown,
                            after: position == chunk.blocks.count - 1 ? Context.after(chunks, index) : .unknown))
                }
            }
            let starts = Self.locate(blocks, in: keys)

            // Spans: a lone conflict is its block; anything else runs from the previous span's end
            // to the next block's start, or to its own last block's end before common text.
            var firstBlock: [Int: Int] = [:], lastBlock: [Int: Int] = [:]
            for (q, block) in blocks.enumerated() {
                if firstBlock[block.chunk] == nil { firstBlock[block.chunk] = q }
                lastBlock[block.chunk] = q
            }
            func blockEnd(_ q: Int) -> Int { starts[q] + blocks[q].lines.count }
            var spans: [Range<Int>] = []
            var previousEnd = 0
            for (index, chunk) in chunks.enumerated() {
                let start = previousEnd
                var end: Int
                if let q = firstBlock[index], !chunk.isMerged {
                    end = blockEnd(q)
                } else if index == chunks.count - 1 {
                    end = keys.count
                } else if let next = firstBlock[index + 1] {
                    end = starts[next]
                } else {
                    end = lastBlock[index].map(blockEnd) ?? start
                }
                end = min(max(end, start), keys.count)
                spans.append(start..<end)
                previousEnd = end
            }

            // Tints: against stage 1 everywhere, then each block's lines against the block's base.
            var tints = [RowTint](repeating: .none, count: lines.count)
            var marks = [[Range<Int>]](repeating: [], count: lines.count)
            let changed: RowTint = side == .ours ? .oursChanged : .theirsChanged
            func tint(_ pairs: [Pair], old: [Line], offset: Int) {
                for pair in pairs {
                    switch pair {
                    case .matched(_, let n):
                        tints[offset + n] = .none
                        marks[offset + n] = []
                    case .paired(let o, let n):
                        tints[offset + n] = changed
                        marks[offset + n] = ResolverLayout.lineMarks(old: old[o].text, new: lines[offset + n].text)
                    case .new(let n):
                        tints[offset + n] = changed
                        marks[offset + n] = ResolverLayout.wholeLine(lines[offset + n].text)
                    case .old:
                        break
                    }
                }
            }
            if let base { tint(ResolverLayout.pairs(base.map(\.key), keys), old: base, offset: 0) }
            for (q, block) in blocks.enumerated() {
                let start = min(starts[q], keys.count), end = min(blockEnd(q), keys.count)
                let base = block.base ?? []
                tint(ResolverLayout.pairs(base.map(\.key), Array(keys[start..<end])), old: base, offset: start)
            }

            self.lines = lines
            self.tints = tints
            self.marks = marks
            self.spans = spans
        }

        func cell(_ index: Int) -> LayoutCell {
            LayoutCell(lineNumber: index + 1, text: lines[index].text, tint: tints[index], marks: marks[index])
        }

        /// What is known to sit next to a block in the stage.
        enum Context {
            /// Nothing known (a merged chunk's edges).
            case unknown
            /// Right at the previous block's end, or at the file's start.
            case adjacent
            /// The end of the file.
            case end
            /// Git's common text.
            case common([[UInt8]])

            static func before(_ chunks: [ResolverChunk], _ index: Int) -> Context {
                guard !chunks[index].isMerged else { return .unknown }
                guard index > 0 else { return .adjacent }
                let previous = chunks[index - 1]
                if previous.blocks.isEmpty { return .common(ResolverLayout.lines(of: previous.commonOriginal ?? "").map(\.key)) }
                return previous.isMerged ? .unknown : .adjacent
            }

            static func after(_ chunks: [ResolverChunk], _ index: Int) -> Context {
                guard !chunks[index].isMerged else { return .unknown }
                guard index < chunks.count - 1 else { return .end }
                let next = chunks[index + 1]
                return next.blocks.isEmpty ? .common(ResolverLayout.lines(of: next.commonOriginal ?? "").map(\.key)) : .unknown
            }
        }

        struct Located {
            let chunk: Int
            let lines: [[UInt8]]
            let base: [Line]?
            let before: Context
            let after: Context
        }

        /// Each block's first line in `stage`, in order and without overlap. Among the places
        /// where its lines match exactly, the one whose neighbours match the most of the common
        /// text around it (up to 3 lines each way) wins, then the one nearest the length of the
        /// common text before it, then the first. With no exact match, the earliest possible line.
        static func locate(_ blocks: [Located], in stage: [[UInt8]]) -> [Int] {
            var after = [Int](repeating: 0, count: blocks.count + 1)
            for q in blocks.indices.reversed() { after[q] = after[q + 1] + blocks[q].lines.count }
            var starts: [Int] = []
            var cursor = 0
            for (q, block) in blocks.enumerated() {
                let count = block.lines.count
                let latest = stage.count - count - after[q + 1]
                var start = cursor
                let searches: Bool
                if case .adjacent = block.before { searches = false } else { searches = latest > cursor }
                if searches {
                    var best: (score: Int, distance: Int)?
                    for candidate in cursor...latest
                    where stage[candidate..<(candidate + count)].elementsEqual(block.lines) {
                        let score = Self.score(block, at: candidate, cursor: cursor, in: stage)
                        let distance: Int
                        if case .common(let lines) = block.before {
                            distance = abs(candidate - cursor - lines.count)
                        } else {
                            distance = candidate - cursor
                        }
                        if let current = best, (current.score, -current.distance) >= (score, -distance) { continue }
                        best = (score, distance)
                        start = candidate
                    }
                }
                starts.append(start)
                cursor = min(start + count, stage.count)
            }
            return starts
        }

        private static func score(_ block: Located, at start: Int, cursor: Int, in stage: [[UInt8]]) -> Int {
            var score = 0
            if case .common(let lines) = block.before {
                var k = 1
                while k <= min(3, lines.count), start - k >= cursor, stage[start - k] == lines[lines.count - k] {
                    score += 1
                    k += 1
                }
            }
            let end = start + block.lines.count
            switch block.after {
            case .common(let lines):
                var k = 0
                while k < min(3, lines.count), end + k < stage.count, stage[end + k] == lines[k] {
                    score += 1
                    k += 1
                }
            case .end:
                if end == stage.count { score += 3 }
            case .unknown, .adjacent:
                break
            }
            return score
        }
    }
}
