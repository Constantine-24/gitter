import Foundation
import GitCore

/// Where a chunk of the Result stands.
enum ChunkState: Hashable, Sendable {
    /// Text both sides agree on: git's, or edited by the user (`ResolverChunk.commonOriginal`
    /// tells which lines).
    case common
    /// A conflict no side has been chosen for: an empty slot.
    case waiting
    /// A conflict whose text is exactly `ConflictBlock.composed` of the choice — for the one
    /// that ends the file, less the terminator merge-file added (see `ResolverDocument.take`).
    case taken(BlockChoice)
    /// A conflict the user typed into, or chunks an edit spanned, merged.
    case edited
}

/// One stretch of the Result: a segment of the conflict, or several an edit merged.
struct ResolverChunk: Hashable, Sendable {
    /// Stable for the document's life: the segment's index at the start; a merged chunk takes
    /// the lowest id of those merged.
    let id: Int
    var state: ChunkState
    /// The chunk's Result text ("" while waiting), line endings as in the file.
    var text: String
    /// The conflict blocks this chunk covers: none for common text, one for a conflict, the
    /// union of theirs for a merged chunk.
    let blocks: [ConflictBlock]
    /// For a common chunk: git's text, to tell "Edited by you" lines. For a merged chunk: the
    /// common text it took in, whose lines (like its blocks' sides) are a stage's own. nil for a
    /// conflict that merged nothing.
    let commonOriginal: String?

    /// An edit merged this chunk from several: it holds two blocks or more, or a block and
    /// common text. Such a chunk is `.edited` for good and refuses takes, since a take would
    /// replace the text it took in.
    var isMerged: Bool { blocks.count > 1 || (!blocks.isEmpty && commonOriginal != nil) }
}

/// Why a Result is shown but cannot be typed into. Takes still work, and the block choices
/// do the writing.
enum NotEditable: Hashable, Sendable { case tooLarge, notUTF8 }

/// The resolver's Result for one conflicted file: the file as git's merge composes it, cut into
/// chunks at the conflict blocks, each conflict waiting, taken or edited. Pure: no AppKit, no
/// git. Every offset is UTF-16, as `NSTextView` counts (a `"\r\n"` is one `Character` but two
/// UTF-16 units), and every "unchanged" is a comparison of UTF-8 bytes, never `String ==`, which
/// calls canonically equivalent text equal.
struct ResolverDocument: Hashable, Sendable {
    /// Over either limit the Result is read-only. Provisional, until measured on large files.
    static let editLimitBytes = 2_000_000, editLimitLines = 20_000

    private(set) var chunks: [ResolverChunk]
    let notEditable: NotEditable?
    /// What typed line breaks become: `"\r\n"` when more lines of the conflict text end in
    /// CRLF than in a bare LF, else `"\n"`.
    let lineEnding: String
    /// Stages 2 and 3 in worktree form, for a take of the conflict that ends the file.
    private let oursStage: Data?, theirsStage: Data?

    /// The Result of `document`'s blocks, every conflict waiting; nil unless the presentation
    /// is `.blocks`. Every segment's bytes are decoded as UTF-8, else the document is
    /// `.notUTF8` and shows a lossy decoding; over the edit limits it is `.tooLarge`. Of `sides`
    /// it keeps ours and theirs, which decide how a take of a conflict ending the file ends.
    init?(document: ConflictDocument, sides: ConflictSides) {
        guard case .blocks(let segments) = document.presentation else { return nil }
        var size = 0, lines = 0, crlf = 0, lf = 0
        var valid = true
        func decoded(_ data: Data) -> String {
            if let text = String(validating: data, as: UTF8.self) { return text }
            valid = false
            return String(decoding: data, as: UTF8.self)
        }
        func measure(_ data: Data) {
            size += data.count
            var previous: UInt8 = 0
            for byte in data {
                if byte == UInt8(ascii: "\n") {
                    lines += 1
                    if previous == UInt8(ascii: "\r") { crlf += 1 } else { lf += 1 }
                }
                previous = byte
            }
        }
        var chunks: [ResolverChunk] = []
        for (id, segment) in segments.enumerated() {
            switch segment {
            case .common(let data):
                measure(data)
                let text = decoded(data)
                chunks.append(ResolverChunk(id: id, state: .common, text: text, blocks: [], commonOriginal: text))
            case .block(let block):
                for data in [block.ours, block.base ?? Data(), block.theirs] {
                    measure(data)
                    _ = decoded(data)
                }
                chunks.append(ResolverChunk(id: id, state: .waiting, text: "", blocks: [block], commonOriginal: nil))
            }
        }
        self.chunks = chunks
        self.lineEnding = crlf > lf ? "\r\n" : "\n"
        self.oursStage = sides.ours
        self.theirsStage = sides.theirs
        // Not UTF-8 wins over too large: its text is a lossy decoding, which `bytes` never writes.
        if !valid {
            notEditable = .notUTF8
        } else if size > Self.editLimitBytes || lines > Self.editLimitLines {
            notEditable = .tooLarge
        } else {
            notEditable = nil
        }
    }

    // MARK: - Reading

    /// The chunks' text joined: what the Result column shows.
    var resultText: String { chunks.map(\.text).joined() }

    /// Conflicts in the Result: chunks that hold a block. Two conflicts merged count as one.
    var conflictCount: Int { chunks.count { !$0.blocks.isEmpty } }

    var waitingCount: Int { chunks.count { $0.state == .waiting } }

    /// No take and no edit since the start: every conflict waiting, every common chunk git's
    /// bytes.
    var isPristine: Bool {
        chunks.allSatisfy { chunk in
            switch chunk.state {
            case .waiting: true
            case .common: Self.same(chunk.text, chunk.commonOriginal)
            case .taken, .edited: false
            }
        }
    }

    /// The chunk's range in `resultText`, in UTF-16; `NSNotFound` for an unknown id. A waiting
    /// slot is an empty range where its text would go.
    func range(ofChunk id: Int) -> NSRange {
        var location = 0
        for chunk in chunks {
            let length = chunk.text.utf16.count
            if chunk.id == id { return NSRange(location: location, length: length) }
            location += length
        }
        return NSRange(location: NSNotFound, length: 0)
    }

    // MARK: - Takes

    /// Puts `choice`'s composition of the chunk's block in place, waiting, taken or edited
    /// alike (taking again replaces the text; undo is the history's). Nothing for common text,
    /// a merged chunk or an unknown id. Works while `notEditable` is set.
    ///
    /// A conflict that ends the file is composed without the line terminator merge-file gave a
    /// side whose stage has none — GitCore's `ConflictBlock.addedFinalTerminator`, the rule
    /// `resolve(choices:)` follows (Ruling 9) — so the Result shows the file's end exactly as it
    /// is written, and an edit anywhere in the chunk keeps it.
    @discardableResult
    mutating func take(_ choice: BlockChoice, chunk id: Int) -> Bool {
        guard let index = chunks.firstIndex(where: { $0.id == id }), !chunks[index].isMerged,
            let block = chunks[index].blocks.first
        else { return false }
        var composed = block.composed(choice)
        if index == chunks.count - 1, let side = block.lastSideWritten(choice),
            let stage = side == .ours ? oursStage : theirsStage
        {
            composed.removeLast(block.addedFinalTerminator(choice, stage: stage))
        }
        let text = String(validating: composed, as: UTF8.self) ?? String(decoding: composed, as: UTF8.self)
        guard chunks[index].state != .taken(choice) || !chunks[index].text.utf8.elementsEqual(text.utf8) else {
            return false
        }
        chunks[index].text = text
        chunks[index].state = .taken(choice)
        return true
    }

    /// Takes `side` for every waiting conflict; taken and edited ones stay as they are.
    mutating func takeRest(_ side: ConflictSide) {
        for chunk in chunks where chunk.state == .waiting {
            take(side == .ours ? .ours : .theirs, chunk: chunk.id)
        }
    }

    // MARK: - Typing

    /// Replaces `range` (UTF-16, in `resultText`) with `typed`, its `\n`, `\r\n` and `\r` each
    /// made `lineEnding`. Nothing while `notEditable` is set, for a range outside the text, or
    /// for an empty range with nothing typed.
    ///
    /// Which chunks it touches:
    /// - an empty range (a caret): the empty conflict chunk there, so typing into a waiting slot
    ///   reaches it; else the chunk the caret is inside or at the start of; at the very end, the
    ///   last chunk;
    /// - a non-empty range: every chunk it overlaps, and the empty ones strictly inside it. An
    ///   empty chunk at the range's edge is not touched, so replacing the line before a waiting
    ///   slot leaves the slot waiting.
    ///
    /// One chunk touched: common text stays `.common` (its edited lines are told against
    /// `commonOriginal`); a conflict becomes `.edited`. Several: they merge into one `.edited`
    /// chunk with the lowest id, the union of their blocks and the common text they held.
    ///
    /// Chunk edges stay line edges (Ruling 11): every chunk but the last ends where a line
    /// starts, so the Result's rows map one-to-one onto its lines. An edit that leaves the chunk
    /// it changed ending inside a line — a backspace at the start of the line after a taken
    /// conflict — merges that chunk with the next, by the same rule, until it ends at a line
    /// edge or is the last; an empty chunk in between (a waiting slot) is merged in too. Undo
    /// splits it back, like any edit. So that typing into a waiting slot never does that, text
    /// typed into the slot of a chunk that is not the last gets `lineEnding` after it when it
    /// does not end in a line break (Ruling 12).
    ///
    /// Returns the id of the chunk the edit ended in, or nil when nothing was changed.
    @discardableResult
    mutating func replace(_ range: NSRange, with typed: String) -> Int? {
        guard notEditable == nil, range.location != NSNotFound, range.location >= 0, range.length >= 0 else { return nil }
        var starts: [Int] = []
        var total = 0
        for chunk in chunks {
            starts.append(total)
            total += chunk.text.utf16.count
        }
        let end = range.location + range.length
        guard end <= total, !chunks.isEmpty else { return nil }
        var typed = Self.normalized(typed, to: lineEnding)
        guard range.length > 0 || !typed.isEmpty else { return nil }

        let lengths = chunks.map { $0.text.utf16.count }
        // An end between the halves of a surrogate pair is refused, not widened: replacing there
        // would turn the other half into U+FFFD, a byte change outside the edit. A pair never
        // spans two chunks, each being whole text.
        func splitsAPair(_ offset: Int) -> Bool {
            guard let index = chunks.indices.first(where: { starts[$0] < offset && offset < starts[$0] + lengths[$0] })
            else { return false }
            let units = chunks[index].text.utf16
            return UTF16.isTrailSurrogate(units[units.index(units.startIndex, offsetBy: offset - starts[index])])
        }
        guard !splitsAPair(range.location), !splitsAPair(end) else { return nil }
        let touched: [Int]
        if range.length == 0 {
            let at = range.location
            let empty = chunks.indices.filter { starts[$0] == at && lengths[$0] == 0 }
            let inside = chunks.indices.first { starts[$0] <= at && at < starts[$0] + lengths[$0] }
            guard let index = empty.first(where: { !chunks[$0].blocks.isEmpty }) ?? inside ?? empty.first
                ?? chunks.indices.last(where: { starts[$0] + lengths[$0] == at })
            else { return nil }
            touched = [index]
            if chunks[index].state == .waiting, index < chunks.count - 1, typed.utf8.last != UInt8(ascii: "\n") {
                typed += lineEnding
            }
        } else {
            touched = chunks.indices.filter { index in
                let start = starts[index], length = lengths[index]
                return length > 0
                    ? start < end && start + length > range.location
                    : range.location < start && start < end
            }
        }
        guard let first = touched.first, let last = touched.last else { return nil }

        let span = chunks[first...last]
        let local = NSRange(location: range.location - starts[first], length: range.length)
        let text = (span.map(\.text).joined() as NSString).replacingCharacters(in: local, with: typed)
        if first == last {
            chunks[first].text = text
            if !chunks[first].blocks.isEmpty { chunks[first].state = .edited }
        } else {
            chunks.replaceSubrange(first...last, with: [Self.merged(span, text: text)])
        }
        let index = first
        while index < chunks.count - 1, !endsAtALineEdge(index) {
            let pair = chunks[index...(index + 1)]
            chunks.replaceSubrange(index...(index + 1), with: [Self.merged(pair, text: pair.map(\.text).joined())])
        }
        return chunks[index].id
    }

    /// Chunks an edit merged, holding `text`: the lowest id, the union of their blocks and the
    /// common text they held; `.edited` with a block, else `.common`.
    private static func merged(_ span: ArraySlice<ResolverChunk>, text: String) -> ResolverChunk {
        let blocks = span.flatMap(\.blocks)
        let originals = span.compactMap(\.commonOriginal)
        return ResolverChunk(
            id: span.map(\.id).min() ?? span[span.startIndex].id, state: blocks.isEmpty ? .common : .edited,
            text: text, blocks: blocks, commonOriginal: originals.isEmpty ? nil : originals.joined())
    }

    /// Whether the chunk at `index` ends where a line starts: the text up to its end is empty or
    /// ends in `\n` (a CRLF's last byte too).
    private func endsAtALineEdge(_ index: Int) -> Bool {
        for chunk in chunks[...index].reversed() {
            if let last = chunk.text.utf8.last { return last == UInt8(ascii: "\n") }
        }
        return true
    }

    // MARK: - Writing

    /// The choice for each block, in order, when the Result is exactly what they compose:
    /// nothing waiting, edited or merged, and every common chunk git's bytes. Then the block
    /// write can do the writing (and does, for a document that is not editable).
    func blockChoices() -> [BlockChoice]? {
        var choices: [BlockChoice] = []
        for chunk in chunks {
            guard !chunk.isMerged else { return nil }
            switch chunk.state {
            case .common: guard Self.same(chunk.text, chunk.commonOriginal) else { return nil }
            case .taken(let choice): choices.append(choice)
            case .waiting, .edited: return nil
            }
        }
        return choices
    }

    /// The bytes Resolve File writes: `resultText` as UTF-8, in worktree form, exactly as shown
    /// — a take of the conflict ending the file already ends as `resolve(choices:)` would end it
    /// (see `take`). nil while a conflict is waiting, and for a `.notUTF8` document, whose text
    /// is a lossy decoding: its block choices do the writing. `sides` is the interface's; the
    /// stages that decide the end were kept at init.
    func bytes(sides: ConflictSides) -> Data? {
        guard waitingCount == 0, notEditable != .notUTF8 else { return nil }
        return Data(resultText.utf8)
    }

    /// Marker lines at `markerSize` (`isMarker`) in text the user typed into: `.edited` chunks and edited common ones. A line equal to one of the
    /// chunk's own stage lines — its blocks' ours, base and theirs, or the common text it holds
    /// from git — is not counted: a stage's own lines are not markers (M 5).
    func leftoverMarkerLines(markerSize: Int) -> Int {
        var count = 0
        for chunk in chunks {
            switch chunk.state {
            case .edited: break
            case .common: guard !Self.same(chunk.text, chunk.commonOriginal) else { continue }
            case .waiting, .taken: continue
            }
            var stageLines = Set<Data>()
            for block in chunk.blocks {
                for side in [block.ours, block.base ?? Data(), block.theirs] {
                    stageLines.formUnion(Self.lines(of: side))
                }
            }
            if let original = chunk.commonOriginal { stageLines.formUnion(Self.lines(of: Data(original.utf8))) }
            count += Self.lines(of: Data(chunk.text.utf8)).count { line in
                Self.isMarker(line, size: markerSize) && !stageLines.contains(line)
            }
        }
        return count
    }

    // MARK: - Helpers

    /// Equal UTF-8 bytes; a nil original is never the same.
    private static func same(_ text: String, _ original: String?) -> Bool {
        guard let original else { return false }
        return text.utf8.elementsEqual(original.utf8)
    }

    /// A line (without its line ending) that is exactly `size` of `<`, `=`, `>` or `|`, then a
    /// space or nothing — the shape of Mark Resolved's scan, for all four characters. `=` with a
    /// label counts too, though git never writes one: the check errs toward asking.
    private static func isMarker(_ line: Data, size: Int) -> Bool {
        guard let first = line.first, "<=>|".utf8.contains(first) else { return false }
        let run = line.prefix { $0 == first }.count
        guard run == size else { return false }
        let rest = line.dropFirst(run)
        return rest.isEmpty || rest.first == UInt8(ascii: " ")
    }

    /// Each line of `data` without its `\n` or `\r\n`.
    private static func lines(of data: Data) -> [Data] {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).map { line in
            line.last == UInt8(ascii: "\r") ? Data(line.dropLast()) : Data(line)
        }
    }

    /// `typed` with every `\r\n`, `\r` and `\n` made `ending`.
    private static func normalized(_ typed: String, to ending: String) -> String {
        var result = ""
        var scalars = typed.unicodeScalars[...]
        while let scalar = scalars.popFirst() {
            switch scalar {
            case "\r":
                if scalars.first == "\n" { scalars.removeFirst() }
                result += ending
            case "\n":
                result += ending
            default:
                result.unicodeScalars.append(scalar)
            }
        }
        return result
    }
}

/// Undo and redo for one Result, of whole documents: a step restores the document as it was
/// before it. Consecutive typing in one chunk, each keystroke within `typingPause` of the last,
/// is one step; a take, a rest-of-file take, a pause or another chunk starts a new one.
struct ResolverHistory: Hashable, Sendable {
    static let typingPause: TimeInterval = 1

    private var undoStack: [ResolverDocument] = []
    private var redoStack: [ResolverDocument] = []
    /// The chunk and time of the last keystroke recorded, while typing may still coalesce.
    private var typingChunk: Int?
    private var typedAt: Date?

    init() {}

    var canUndo: Bool { !undoStack.isEmpty }
    var canRedo: Bool { !redoStack.isEmpty }

    /// Records `before`, the document as it is before a change, and clears redo. `chunk` is the
    /// chunk being typed in, nil for anything else (a take, a rest-of-file take): typing in the
    /// same chunk within `typingPause` of the last keystroke joins the step already recorded.
    mutating func record(_ before: ResolverDocument, coalescingTypingIn chunk: Int?, at time: Date) {
        redoStack.removeAll()
        if let chunk, chunk == typingChunk, let typedAt {
            let pause = time.timeIntervalSince(typedAt)
            if pause >= 0, pause <= Self.typingPause {
                self.typedAt = time
                return
            }
        }
        undoStack.append(before)
        typingChunk = chunk
        typedAt = chunk == nil ? nil : time
    }

    /// The document before the last step, with `current` kept for redo; nil when there is none.
    mutating func undo(_ current: ResolverDocument) -> ResolverDocument? {
        guard let previous = undoStack.popLast() else { return nil }
        redoStack.append(current)
        endTyping()
        return previous
    }

    /// The document the last undo left, with `current` kept for undo; nil when there is none.
    mutating func redo(_ current: ResolverDocument) -> ResolverDocument? {
        guard let next = redoStack.popLast() else { return nil }
        undoStack.append(current)
        endTyping()
        return next
    }

    /// Typing after an undo or a redo is a step of its own.
    private mutating func endTyping() {
        typingChunk = nil
        typedAt = nil
    }
}
