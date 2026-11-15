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
///   never the typed text) wins, then the one nearest the common text's length. Since the parse's
///   common text and blocks alternate, the chunk ids tell each segment's kind, which places a
///   merged chunk's blocks and, when it took in one stretch of common text, gives that text as
///   their neighbour (`Column.Segments`). Common text
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
/// **Cost.** The sides' work — splitting both stages, the whole-stage line diffs against stage 1
/// (bounded, `alignment`: linear in the lines where a side rewrote most of a file, Ruling 51),
/// the block placement and the side lines' word marks — depends only on the stages and the chunk
/// structure, never on typed text. `Sides` holds it, built once and reused while it `fits`. Each
/// `rows(_:using:showBase:)` call then splits the Result's text and runs, per common chunk, the
/// line diffs of that chunk's ours and theirs lines against its Result lines (and against git's
/// text once typed into), so a call costs the Result's length plus diffs bounded by each common
/// chunk's size and changes. `rows(_:sides:showBase:)` builds `Sides` every time: for one-off use.
enum ResolverLayout {
    /// What the layout needs from the sides that typing cannot change: both columns' lines, side
    /// tints and word marks, and each chunk's span of lines in each stage.
    ///
    /// **When it still fits** (`fits`): while the document's chunks have the same ids and each the
    /// same number of blocks as when it was built. Typing inside a chunk and takes (taking again,
    /// Use Ours/Theirs for the rest) keep that, since the columns never read a chunk's text or
    /// state. An edit that crosses a chunk's edge merges chunks and changes it, and so can undo or
    /// redo across such an edit: rebuild then. Build it from the draft's own `ConflictSides`;
    /// other stages need a new one. A `Sides` that does not fit is rebuilt by `rows` rather than
    /// misused, at the full cost.
    ///
    /// **Refitting** (`refitted(to:)`, Ruling 28): each stage's lines and its whole-stage tints and
    /// marks against stage 1 depend on the stage alone, and are kept; a refit redoes only what the
    /// chunks decide — where each block sits, the chunks' spans, and the blocks' own tints against
    /// their bases.
    struct Sides: Sendable {
        fileprivate let ours: Column, theirs: Column
        private let oursStage: Stage?, theirsStage: Stage?
        private let base: [Line]?
        private let shape: [Shape]
        /// Which stages these are: kept by a refit, new with every `init(_:document:)`. A row cache
        /// filled for other stages is not reused (`RowCache`).
        fileprivate let stagesID: UUID

        private struct Shape: Hashable, Sendable {
            let id: Int
            let blocks: Int
        }

        init(_ sides: ConflictSides, document: ResolverDocument) {
            let base = sides.base.map { ResolverLayout.lines(of: $0) }
            let oursStage = sides.ours.map { Stage($0, side: .ours, base: base) }
            let theirsStage = sides.theirs.map { Stage($0, side: .theirs, base: base) }
            self.init(ours: oursStage, theirs: theirsStage, base: base, document: document, stagesID: UUID())
        }

        private init(
            ours oursStage: Stage?, theirs theirsStage: Stage?, base: [Line]?, document: ResolverDocument, stagesID: UUID
        ) {
            let chunks = document.chunks
            ours = Column(stage: oursStage, side: .ours, chunks: chunks, base: base)
            theirs = Column(stage: theirsStage, side: .theirs, chunks: chunks, base: base)
            self.oursStage = oursStage
            self.theirsStage = theirsStage
            self.base = base
            self.stagesID = stagesID
            shape = Self.shape(of: document)
        }

        /// The document's chunks are still the ones these columns were placed for.
        func fits(_ document: ResolverDocument) -> Bool { Self.shape(of: document) == shape }

        /// Itself while it fits `document`; else placed again for its chunks, keeping the stages'
        /// lines, tints and marks (the costly part, whole-stage diffs against the base).
        func refitted(to document: ResolverDocument) -> Sides {
            fits(document)
                ? self : Sides(ours: oursStage, theirs: theirsStage, base: base, document: document, stagesID: stagesID)
        }

        fileprivate func fitted(to document: ResolverDocument) -> Sides { refitted(to: document) }

        private static func shape(of document: ResolverDocument) -> [Shape] {
            document.chunks.map { Shape(id: $0.id, blocks: $0.blocks.count) }
        }
    }

    /// The rows, building the sides' part afresh: the brief's entry point, for one-off use.
    static func rows(_ document: ResolverDocument, sides: ConflictSides, showBase: Bool) -> [LayoutRow] {
        rows(document, using: Sides(sides, document: document), showBase: showBase)
    }

    /// The rows, reusing `sides` (rebuilt here only when it does not fit `document`).
    static func rows(_ document: ResolverDocument, using sides: Sides, showBase: Bool) -> [LayoutRow] {
        var cache = RowCache()
        return rows(document, using: sides, showBase: showBase, reusing: &cache)
    }

    /// Each chunk's rows from the last build, kept to be reused (Ruling 32). A chunk's rows depend
    /// only on:
    /// - the chunk itself (its id, state, text, git's text, its blocks);
    /// - its spans of the sides' lines, and the stages those lines are from (`Sides`' stages; a
    ///   refit keeps them);
    /// - Show Base, for a conflict;
    /// - whether its first line continues the chunk before (that chunk's text ending inside a
    ///   line), which numbers that line with the line before;
    /// - its first Result line number, applied by renumbering.
    /// Every one of these but the last is the key; a keystroke rebuilds the chunk it changed and
    /// shifts the numbers of the rows after it. It prunes itself to the chunks of the last build.
    struct RowCache: Sendable {
        fileprivate var entries: [Int: Entry] = [:]
        fileprivate var stagesID: UUID?
        /// How many chunks the last build reused.
        fileprivate(set) var reused = 0

        init() {}

        fileprivate struct Entry: Sendable {
            let chunk: ResolverChunk
            let spans: Range<Int>, theirsSpan: Range<Int>
            let showBase: Bool
            /// Its first line continued the chunk before when these rows were built.
            let continuing: Bool
            /// The Result number its first new line had, and how many lines it numbered.
            var firstNumber: Int
            let lineCount: Int
            /// Whether its text ended inside a line; nil for empty text, which changes nothing.
            let endsInsideLine: Bool?
            var rows: [LayoutRow]

            func matches(_ other: ResolverChunk, ours: Range<Int>, theirs: Range<Int>, showBase: Bool, continuing: Bool)
                -> Bool
            {
                // Show Base adds rows to conflicts only.
                spans == ours && theirsSpan == theirs && (other.blocks.isEmpty || self.showBase == showBase)
                    && self.continuing == continuing
                    && chunk.id == other.id
                    && chunk.state == other.state && chunk.blocks.count == other.blocks.count
                    && ResolverLayout.sameBytes(chunk.text, other.text)
                    && ResolverLayout.sameBytes(chunk.commonOriginal, other.commonOriginal)
            }
        }
    }

    /// The rows, reusing `sides` and, for every chunk unchanged since `cache` was filled, its rows
    /// (renumbered when lines before it came or went). The same rows as a fresh build.
    static func rows(_ document: ResolverDocument, using sides: Sides, showBase: Bool, reusing cache: inout RowCache)
        -> [LayoutRow]
    {
        let chunks = document.chunks
        let sides = sides.fitted(to: document)
        let ours = sides.ours, theirs = sides.theirs

        var rows: [LayoutRow] = []
        var entries: [Int: RowCache.Entry] = [:]
        entries.reserveCapacity(chunks.count)
        var reused = 0
        // Rows built from other stages are never reused.
        if cache.stagesID != sides.stagesID { cache.entries = [:] }
        var nextNumber = 1
        // The last chunk's text ended inside a line, which this chunk's first line continues.
        var continues = false
        for (index, chunk) in chunks.enumerated() {
            let spans = (ours: ours.spans[index], theirs: theirs.spans[index])
            // A chunk that merged several (its blocks' placement inside its spans is not in the
            // key) is always built.
            if !chunk.isMerged, var entry = cache.entries[chunk.id],
                entry.matches(chunk, ours: spans.ours, theirs: spans.theirs, showBase: showBase, continuing: continues)
            {
                if entry.firstNumber != nextNumber {
                    entry.rows = renumbered(entry.rows, by: nextNumber - entry.firstNumber)
                    entry.firstNumber = nextNumber
                }
                rows += entry.rows
                nextNumber += entry.lineCount
                if let inside = entry.endsInsideLine { continues = inside }
                entries[chunk.id] = entry
                reused += 1
                continue
            }
            let firstNumber = nextNumber
            let continuing = continues
            var result: [NumberedLine] = []
            for (offset, line) in lines(of: chunk.text).enumerated() {
                if offset == 0, continues {
                    result.append(NumberedLine(line: line, number: nextNumber - 1))
                } else {
                    result.append(NumberedLine(line: line, number: nextNumber))
                    nextNumber += 1
                }
            }
            let endsInsideLine: Bool? = chunk.text.isEmpty ? nil : chunk.text.unicodeScalars.last != "\n"
            if let endsInsideLine { continues = endsInsideLine }

            var built: [LayoutRow] = []
            if chunk.blocks.isEmpty {
                // The word marks of the rows this chunk had (same stages, kept above): a keystroke
                // computes the marks of the lines it changed, not of every line beside a rewrite.
                built = commonRows(
                    chunk, result: result, ours: ours, theirs: theirs, spans: spans,
                    previous: cache.entries[chunk.id]?.rows)
            } else {
                if showBase {
                    let strip: [String?] = baseStrip(of: chunk) ?? [nil]
                    for line in strip {
                        built.append(
                            LayoutRow(
                                ours: filler, result: LayoutCell(lineNumber: nil, text: line, tint: .filler, marks: []),
                                theirs: filler, chunk: chunk.id, isSlot: false, badge: nil, isBaseStrip: true))
                    }
                }
                built += conflictRows(chunk, result: result, ours: ours, theirs: theirs, spans: spans)
            }
            rows += built
            entries[chunk.id] = RowCache.Entry(
                chunk: chunk, spans: spans.ours, theirsSpan: spans.theirs, showBase: showBase, continuing: continuing,
                firstNumber: firstNumber,
                lineCount: nextNumber - firstNumber, endsInsideLine: endsInsideLine, rows: built)
        }
        cache.entries = entries
        cache.stagesID = sides.stagesID
        cache.reused = reused
        return rows
    }

    /// `rows` with every Result line number moved by `delta`.
    private static func renumbered(_ rows: [LayoutRow], by delta: Int) -> [LayoutRow] {
        rows.map { row in
            guard let number = row.result.lineNumber else { return row }
            let cell = row.result
            return LayoutRow(
                ours: row.ours, result: LayoutCell(lineNumber: number + delta, text: cell.text, tint: cell.tint, marks: cell.marks),
                theirs: row.theirs, chunk: row.chunk, isSlot: row.isSlot, badge: row.badge, isBaseStrip: row.isBaseStrip)
        }
    }

    /// The same UTF-8 bytes (never `==`, which calls canonically equal text equal), at once when
    /// both share one storage, as an untouched chunk's text does.
    fileprivate static func sameBytes(_ a: String?, _ b: String?) -> Bool {
        guard let a, let b else { return a == nil && b == nil }
        let shared = a.utf8.withContiguousStorageIfAvailable { x in
            b.utf8.withContiguousStorageIfAvailable { y in x.count == y.count && x.baseAddress == y.baseAddress }
        }
        if shared == .some(.some(true)) { return true }
        return a.utf8.elementsEqual(b.utf8)
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
        _ chunk: ResolverChunk, result: [NumberedLine], ours: Column, theirs: Column, spans: Spans,
        previous: [LayoutRow]? = nil
    ) -> [LayoutRow] {
        // The rows this chunk had (same stages): their Result lines, in order. A line in the
        // unchanged run at either end keeps its word marks when it keeps its tint and partner —
        // `lineMarks` is a word diff a line, and a keystroke beside a rewrite would redo thousands
        // (Ruling 51).
        let before = (previous ?? []).compactMap { row in row.result.text == nil || row.isBaseStrip ? nil : row }
        var same = 0
        while same < min(before.count, result.count),
            before[same].result.text?.utf8.elementsEqual(result[same].line.key) == true
        {
            same += 1
        }
        var sameAtEnd = 0
        while sameAtEnd < min(before.count, result.count) - same,
            before[before.count - 1 - sameAtEnd].result.text?.utf8.elementsEqual(result[result.count - 1 - sameAtEnd].line.key)
                == true
        {
            sameAtEnd += 1
        }
        /// The marks the row before had for Result line `index`, when it had that tint and partner.
        func known(_ index: Int, _ tint: RowTint, partner number: Int) -> [Range<Int>]? {
            let old: Int
            if index < same {
                old = index
            } else if index >= result.count - sameAtEnd {
                old = index - result.count + before.count
            } else {
                return nil
            }
            let row = before[old]
            guard row.result.tint == tint else { return nil }
            let partner = tint == .fromTheirs ? row.ours.lineNumber : row.theirs.lineNumber
            return partner == number ? row.result.marks : nil
        }
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
                marks = oursPartner.map { partner in
                    let line = spans.ours.lowerBound + partner.index
                    return known(index, .fromTheirs, partner: line + 1) ?? lineMarks(old: ours.lines[line].text, new: text)
                } ?? wholeLine(text)
            } else if oursPartner?.exact == true, theirsPartner?.exact != true {
                tint = .fromOurs
                marks = theirsPartner.map { partner in
                    let line = spans.theirs.lowerBound + partner.index
                    return known(index, .fromOurs, partner: line + 1) ?? lineMarks(old: theirs.lines[line].text, new: text)
                } ?? wholeLine(text)
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

    /// A line of `old` laid against one of `new`: equal (`matched`), the one it replaced
    /// (`paired`), or a line only one of them has. In order: both indices only grow.
    enum Pair: Hashable, Sendable {
        case matched(Int, Int), paired(Int, Int), old(Int), new(Int)
    }

    /// A line diff's pairs, and whether its bound was met (`ResolverLayout.alignment`).
    struct Alignment: Hashable, Sendable {
        let pairs: [Pair]
        /// Some stretch was too costly for the full diff: its lines were placed by unique
        /// anchors, or paired by position.
        let bounded: Bool
    }

    /// The most work one line diff may do (Ruling 51), counted as `(n + m) · min(n, m)` of the
    /// stretch it runs on — the shape of `CollectionDifference`'s O((n + m) · D) cost when the
    /// lines all differ. Measured in an optimised build on this Mac, lines that all differ: 100
    /// against 100 (20,000 units) 1.3 ms, 200 against 200 3.5 ms, 400 against 400 6.0 ms; so the
    /// budget, about 224 lines against 224, is about 2–3 ms a diff at worst, and a keystroke's
    /// three diffs of the chunk it changed stay within typing's bar (Ruling 32).
    static let alignmentBudget = 100_000

    /// `old` against `new`: equal lines matched, and in each hunk the k-th removed line paired
    /// with the k-th inserted one; the rest one-sided.
    ///
    /// **Bounded** (Ruling 51). The common prefix and suffix are matched first. What is left
    /// goes to `CollectionDifference` (Myers) when its cost fits `alignmentBudget`. Else lines
    /// that occur once in each, equal but for the spaces and tabs around them, are anchors
    /// (patience): their longest run in order is matched (paired, when only the indentation
    /// differs), and each stretch between two anchors gets the full diff while the budget lasts.
    /// Any stretch left, and a middle with no anchors, is paired by position: the k-th line with
    /// the k-th, matched when equal. So a side that rewrote or re-indented a whole file costs time
    /// linear in its lines, at open and at every keystroke, and a line typed beside it moves no
    /// pairing below it.
    static func alignment(_ old: [[UInt8]], _ new: [[UInt8]]) -> Alignment {
        var work = PairWork(old: old, new: new, budget: alignmentBudget)
        work.align(0..<old.count, 0..<new.count, anchoring: true)
        return Alignment(pairs: work.pairs, bounded: work.bounded)
    }

    private static func pairs(_ old: [[UInt8]], _ new: [[UInt8]]) -> [Pair] { alignment(old, new).pairs }

    private struct PairWork {
        let old: [[UInt8]], new: [[UInt8]]
        var budget: Int
        var pairs: [Pair] = []
        var bounded = false

        init(old: [[UInt8]], new: [[UInt8]], budget: Int) {
            self.old = old
            self.new = new
            self.budget = budget
            pairs.reserveCapacity(max(old.count, new.count))
        }

        /// The pairs of `o` against `n`, appended in order.
        mutating func align(_ o: Range<Int>, _ n: Range<Int>, anchoring: Bool) {
            var low = (o.lowerBound, n.lowerBound), high = (o.upperBound, n.upperBound)
            while low.0 < high.0, low.1 < high.1, old[low.0] == new[low.1] {
                pairs.append(.matched(low.0, low.1))
                low = (low.0 + 1, low.1 + 1)
            }
            var suffix = 0
            while low.0 < high.0 - suffix, low.1 < high.1 - suffix, old[high.0 - 1 - suffix] == new[high.1 - 1 - suffix] {
                suffix += 1
            }
            high = (high.0 - suffix, high.1 - suffix)
            middle(low.0..<high.0, low.1..<high.1, anchoring: anchoring)
            for k in 0..<suffix { pairs.append(.matched(high.0 + k, high.1 + k)) }
        }

        private mutating func middle(_ o: Range<Int>, _ n: Range<Int>, anchoring: Bool) {
            if o.isEmpty || n.isEmpty {
                pairs += o.map { .old($0) }
                pairs += n.map { .new($0) }
                return
            }
            let cost = (o.count + n.count).multipliedReportingOverflow(by: min(o.count, n.count))
            if !cost.overflow, cost.partialValue <= budget {
                budget -= cost.partialValue
                diff(o, n)
                return
            }
            bounded = true
            if anchoring {
                let anchors = Self.anchors(old, o, new, n)
                if !anchors.isEmpty {
                    var start = (o.lowerBound, n.lowerBound)
                    for anchor in anchors {
                        align(start.0..<anchor.0, start.1..<anchor.1, anchoring: false)
                        pairs.append(old[anchor.0] == new[anchor.1] ? .matched(anchor.0, anchor.1) : .paired(anchor.0, anchor.1))
                        start = (anchor.0 + 1, anchor.1 + 1)
                    }
                    align(start.0..<o.upperBound, start.1..<n.upperBound, anchoring: false)
                    return
                }
            }
            byPosition(o, n)
        }

        /// The full diff (`CollectionDifference`), its hunks' lines paired in order.
        private mutating func diff(_ o: Range<Int>, _ n: Range<Int>) {
            var removed = Set<Int>(), inserted = Set<Int>()
            for change in new[n].difference(from: old[o]) {
                switch change {
                case .remove(let offset, _, _): removed.insert(o.lowerBound + offset)
                case .insert(let offset, _, _): inserted.insert(n.lowerBound + offset)
                }
            }
            var i = o.lowerBound, j = n.lowerBound
            while i < o.upperBound || j < n.upperBound {
                var gone: [Int] = [], added: [Int] = []
                while i < o.upperBound, removed.contains(i) {
                    gone.append(i)
                    i += 1
                }
                while j < n.upperBound, inserted.contains(j) {
                    added.append(j)
                    j += 1
                }
                if gone.isEmpty, added.isEmpty {
                    guard i < o.upperBound, j < n.upperBound else { break }
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
        }

        /// The k-th line with the k-th, matched when equal; the longer side's rest one-sided.
        private mutating func byPosition(_ o: Range<Int>, _ n: Range<Int>) {
            let count = min(o.count, n.count)
            for k in 0..<count {
                let i = o.lowerBound + k, j = n.lowerBound + k
                pairs.append(old[i] == new[j] ? .matched(i, j) : .paired(i, j))
            }
            pairs += o.dropFirst(count).map { .old($0) }
            pairs += n.dropFirst(count).map { .new($0) }
        }

        /// Lines that occur exactly once in `o` and once in `n`, equal but for the spaces and
        /// tabs around them (so a re-indented line anchors, as a line it replaced), the longest
        /// run of them in order in both (patience): O(k log k) in their number.
        private static func anchors(_ old: [[UInt8]], _ o: Range<Int>, _ new: [[UInt8]], _ n: Range<Int>)
            -> [(Int, Int)]
        {
            func trimmed(_ line: [UInt8]) -> ArraySlice<UInt8> {
                let blank: (UInt8) -> Bool = { $0 == UInt8(ascii: " ") || $0 == UInt8(ascii: "\t") }
                guard let first = line.firstIndex(where: { !blank($0) }), let last = line.lastIndex(where: { !blank($0) })
                else { return line[0..<0] }
                return line[first...last]
            }
            // Per line: where it is in old (-1 when there twice or more), then in new.
            var seen: [ArraySlice<UInt8>: (old: Int, new: Int)] = [:]
            seen.reserveCapacity(o.count)
            for i in o {
                let key = trimmed(old[i])
                if let entry = seen[key] {
                    if entry.old != -1 { seen[key] = (-1, entry.new) }
                } else {
                    seen[key] = (i, -2)
                }
            }
            for j in n {
                let key = trimmed(new[j])
                guard let entry = seen[key], entry.old >= 0 else { continue }
                seen[key] = (entry.old, entry.new == -2 ? j : -1)
            }
            let candidates = seen.values.filter { $0.old >= 0 && $0.new >= 0 }.sorted { $0.old < $1.old }
            guard !candidates.isEmpty else { return [] }
            // The longest increasing run of new positions, by patience sorting.
            var tails: [Int] = []  // index into candidates of the smallest tail of each length
            var previous = [Int](repeating: -1, count: candidates.count)
            for (index, candidate) in candidates.enumerated() {
                var low = 0, high = tails.count
                while low < high {
                    let middle = (low + high) / 2
                    if candidates[tails[middle]].new < candidate.new { low = middle + 1 } else { high = middle }
                }
                if low > 0 { previous[index] = tails[low - 1] }
                if low == tails.count { tails.append(index) } else { tails[low] = index }
            }
            var run: [(Int, Int)] = []
            var index = tails.last ?? -1
            while index >= 0 {
                run.append((candidates[index].old, candidates[index].new))
                index = previous[index]
            }
            return run.reversed()
        }
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

    /// One side's stage on its own: its lines, and each line's tint and marks against stage 1
    /// (none without it). Depends on no chunk.
    fileprivate struct Stage: Sendable {
        let lines: [Line]
        let tints: [RowTint]
        let marks: [[Range<Int>]]

        init(_ stage: Data, side: ConflictSide, base: [Line]?) {
            let lines = ResolverLayout.lines(of: stage)
            var tints = [RowTint](repeating: .none, count: lines.count)
            var marks = [[Range<Int>]](repeating: [], count: lines.count)
            if let base {
                Column.tint(
                    ResolverLayout.pairs(base.map(\.key), lines.map(\.key)), old: base, lines: lines, offset: 0,
                    changed: side == .ours ? .oursChanged : .theirsChanged, tints: &tints, marks: &marks)
            }
            self.lines = lines
            self.tints = tints
            self.marks = marks
        }
    }

    /// One side's stage: its lines, each line's tint and marks, and each chunk's span of lines.
    fileprivate struct Column {
        let lines: [Line]
        let tints: [RowTint]
        let marks: [[Range<Int>]]
        /// Per chunk, in `chunks` order; they tile `lines`.
        let spans: [Range<Int>]

        init(stage: Stage?, side: ConflictSide, chunks: [ResolverChunk], base: [Line]?) {
            func sideOf(_ block: ConflictBlock) -> Data { side == .ours ? block.ours : block.theirs }
            // A stage that is missing (never for a blocks presentation) is rebuilt from the chunks.
            let lines =
                stage?.lines
                ?? chunks.flatMap { chunk in
                    ResolverLayout.lines(of: chunk.commonOriginal ?? "")
                        + chunk.blocks.flatMap { ResolverLayout.lines(of: sideOf($0)) }
                }
            let keys = lines.map(\.key)

            var blocks: [Located] = []
            var contexts = Context.all(chunks).makeIterator()
            for (index, chunk) in chunks.enumerated() {
                for block in chunk.blocks {
                    let context = contexts.next() ?? (.unknown, .unknown)
                    blocks.append(
                        Located(
                            chunk: index, lines: ResolverLayout.lines(of: sideOf(block)).map(\.key),
                            base: block.base.map { ResolverLayout.lines(of: $0) }, before: context.before,
                            after: context.after))
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

            // Tints: against stage 1 everywhere (the stage's own, kept across refits), then each
            // block's lines against the block's base.
            let changed: RowTint = side == .ours ? .oursChanged : .theirsChanged
            var tints: [RowTint], marks: [[Range<Int>]]
            if let stage {
                (tints, marks) = (stage.tints, stage.marks)
            } else {
                tints = [RowTint](repeating: .none, count: lines.count)
                marks = [[Range<Int>]](repeating: [], count: lines.count)
                if let base {
                    Self.tint(
                        ResolverLayout.pairs(base.map(\.key), keys), old: base, lines: lines, offset: 0, changed: changed,
                        tints: &tints, marks: &marks)
                }
            }
            for (q, block) in blocks.enumerated() {
                let start = min(starts[q], keys.count), end = min(blockEnd(q), keys.count)
                let base = block.base ?? []
                Self.tint(
                    ResolverLayout.pairs(base.map(\.key), Array(keys[start..<end])), old: base, lines: lines,
                    offset: start, changed: changed, tints: &tints, marks: &marks)
            }

            self.lines = lines
            self.tints = tints
            self.marks = marks
            self.spans = spans
        }

        /// Tints and marks the lines `pairs` says changed, from `offset` on.
        static func tint(
            _ pairs: [Pair], old: [Line], lines: [Line], offset: Int, changed: RowTint, tints: inout [RowTint],
            marks: inout [[Range<Int>]]
        ) {
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

        func cell(_ index: Int) -> LayoutCell {
            LayoutCell(lineNumber: index + 1, text: lines[index].text, tint: tints[index], marks: marks[index])
        }

        /// What is known to sit next to a block in the stage.
        enum Context {
            /// Nothing known.
            case unknown
            /// Right at the previous block's end, or at the file's start.
            case adjacent
            /// The end of the file.
            case end
            /// Git's common text.
            case common([[UInt8]])

            /// Each block's neighbours, for every block in document order. Through `Segments`
            /// when the chunk ids allow it, which also sees inside merged chunks; else from the
            /// neighbouring chunks alone.
            static func all(_ chunks: [ResolverChunk]) -> [(before: Context, after: Context)] {
                if let segments = Segments(chunks) {
                    return chunks.indices.flatMap { index in segments.blockSegments(of: index).map(segments.context) }
                }
                return chunks.indices.flatMap { index in
                    let count = chunks[index].blocks.count
                    return (0..<count).map { position in
                        (
                            before: position == 0 ? before(chunks, index) : .unknown,
                            after: position == count - 1 ? after(chunks, index) : .unknown
                        )
                    }
                }
            }

            /// Next to common text the chunk's edge is a block, merged or not (the parse never
            /// writes two common segments in a row).
            private static func before(_ chunks: [ResolverChunk], _ index: Int) -> Context {
                let merged = chunks[index].isMerged
                guard index > 0 else { return merged ? .unknown : .adjacent }
                let previous = chunks[index - 1]
                if previous.blocks.isEmpty { return .common(ResolverLayout.lines(of: previous.commonOriginal ?? "").map(\.key)) }
                return merged || previous.isMerged ? .unknown : .adjacent
            }

            private static func after(_ chunks: [ResolverChunk], _ index: Int) -> Context {
                guard index < chunks.count - 1 else { return chunks[index].isMerged ? .unknown : .end }
                let next = chunks[index + 1]
                return next.blocks.isEmpty ? .common(ResolverLayout.lines(of: next.commonOriginal ?? "").map(\.key)) : .unknown
            }
        }

        /// The conflict's segments as the parse wrote them, recovered from the chunk ids (a chunk's
        /// id is its first segment's index): common text and blocks alternate, so one chunk that
        /// is not merged gives every segment's kind. That places each block of a merged chunk at
        /// its segment, and gives a merged chunk's common text when it held one stretch of it.
        /// nil when no chunk is unmerged, or when the ids do not alternate as that predicts.
        struct Segments {
            let chunks: [ResolverChunk]
            let reference: (id: Int, isBlock: Bool)

            init?(_ chunks: [ResolverChunk]) {
                guard let plain = chunks.first(where: { !$0.isMerged }) else { return nil }
                self.chunks = chunks
                reference = (plain.id, !plain.blocks.isEmpty)
                for index in chunks.indices {
                    let chunk = chunks[index]
                    if !chunk.isMerged {
                        guard isBlock(chunk.id) == !chunk.blocks.isEmpty else { return nil }
                    } else if let ids = ids(of: index) {
                        guard ids.count(where: isBlock) == chunk.blocks.count else { return nil }
                    }
                }
            }

            func isBlock(_ segment: Int) -> Bool { ((segment - reference.id) % 2 == 0) == reference.isBlock }

            /// The segments chunk `index` covers; nil for a merged last chunk, whose count is not
            /// known (it may or may not end with common text).
            func ids(of index: Int) -> Range<Int>? {
                if index + 1 < chunks.count { return chunks[index].id..<chunks[index + 1].id }
                return chunks[index].isMerged ? nil : chunks[index].id..<(chunks[index].id + 1)
            }

            func blockSegments(of index: Int) -> [Int] {
                var segments: [Int] = []
                var segment = chunks[index].id
                while segments.count < chunks[index].blocks.count {
                    if isBlock(segment) { segments.append(segment) }
                    segment += 1
                }
                return segments
            }

            /// Git's text of a common segment, when its chunk holds no other common segment.
            func commonText(_ segment: Int) -> [[UInt8]]? {
                guard !isBlock(segment), let index = chunks.lastIndex(where: { $0.id <= segment }),
                    let ids = ids(of: index), ids.contains(segment),
                    !chunks[index].isMerged || ids.count(where: { !isBlock($0) }) == 1
                else { return nil }
                return ResolverLayout.lines(of: chunks[index].commonOriginal ?? "").map(\.key)
            }

            func context(_ segment: Int) -> (before: Context, after: Context) {
                let before: Context =
                    segment == 0 || isBlock(segment - 1) ? .adjacent : commonText(segment - 1).map(Context.common) ?? .unknown
                let after: Context
                if let total = ids(of: chunks.count - 1)?.upperBound, segment == total - 1 {
                    after = .end
                } else if isBlock(segment + 1) {
                    after = .unknown
                } else {
                    after = commonText(segment + 1).map(Context.common) ?? .unknown
                }
                return (before, after)
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
