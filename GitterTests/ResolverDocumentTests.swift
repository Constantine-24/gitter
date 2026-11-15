import Foundation
import GitCore
import Testing

@testable import Gitter

/// The resolver's Result, pure: chunks built from a `ConflictDocument`'s segments, takes,
/// typing (which merges the chunks an edit spans), the bytes Resolve File writes (the final-newline
/// rule is GitCore's own), the leftover-marker count and undo of whole documents. Fixtures are
/// built in code, without git.
@Suite struct ResolverDocumentTests {

    // MARK: - Fixtures

    static func common(_ text: String) -> ConflictSegment { .common(Data(text.utf8)) }

    static func block(_ ours: String, _ base: String?, _ theirs: String) -> ConflictBlock {
        ConflictBlock(ours: Data(ours.utf8), base: base.map { Data($0.utf8) }, theirs: Data(theirs.utf8))
    }

    static func conflict(_ presentation: ConflictPresentation) -> ConflictDocument {
        let stage = ConflictStage(mode: "100644", blob: "a")
        let file = ConflictedFile(path: "f.txt", kind: .bothModified, base: stage, ours: stage, theirs: stage)
        return ConflictDocument(
            snapshot: ConflictSnapshot(file: file, worktreeHash: "h"), presentation: presentation,
            matchesGitsConflict: true, worktree: Data("x\n".utf8))
    }

    /// Stages that end in a newline, so the final-newline rule drops nothing.
    static let endedSides = ConflictSides(
        ours: Data("o\n".utf8), base: Data("b\n".utf8), theirs: Data("t\n".utf8), markerSize: 7)

    static func document(_ segments: [ConflictSegment], sides: ConflictSides = endedSides) throws -> ResolverDocument {
        try #require(ResolverDocument(document: conflict(.blocks(segments)), sides: sides))
    }

    static let block1 = block("o1\n", "b1\n", "t1\n")
    static let block2 = block("o2\n", "b2\n", "t2\n")
    static let block3 = block("o3\n", "b3\n", "t3\n")

    /// top, conflict, mid, conflict, mid2, conflict, end: ids 0…6.
    static let three: [ConflictSegment] = [
        common("top\n"), .block(block1), common("mid\n"), .block(block2), common("mid2\n"), .block(block3),
        common("end\n"),
    ]

    /// top, conflict, mid, conflict, end: ids 0…4.
    static let two: [ConflictSegment] = [
        common("top\nline\n"), .block(block1), common("mid\n"), .block(block2), common("end\n"),
    ]

    static func range(of needle: String, in document: ResolverDocument) -> NSRange {
        (document.resultText as NSString).range(of: needle)
    }

    static func chunk(_ id: Int, _ document: ResolverDocument) throws -> ResolverChunk {
        try #require(document.chunks.first { $0.id == id })
    }

    static let t0 = Date(timeIntervalSinceReferenceDate: 1_000)

    /// The history's undo, required to give a document (a mutating call cannot sit in a macro).
    static func undo(_ history: inout ResolverHistory, _ current: ResolverDocument) throws -> ResolverDocument {
        let previous = history.undo(current)
        return try #require(previous)
    }

    static func redo(_ history: inout ResolverHistory, _ current: ResolverDocument) throws -> ResolverDocument {
        let next = history.redo(current)
        return try #require(next)
    }

    // MARK: - A new document

    @Test func aNewDocumentWaitsOnEveryConflict() throws {
        let document = try Self.document(Self.three)
        #expect(document.chunks.map(\.id) == Array(0...6))
        #expect(document.conflictCount == 3)
        #expect(document.waitingCount == 3)
        #expect(document.isPristine)
        #expect(document.notEditable == nil)
        #expect(document.lineEnding == "\n")
        #expect(document.resultText == "top\nmid\nmid2\nend\n")
        for (id, location) in [(1, 4), (3, 8), (5, 13)] {
            let chunk = try Self.chunk(id, document)
            #expect(chunk.state == .waiting)
            #expect(chunk.text == "")
            #expect(chunk.commonOriginal == nil)
            #expect(document.range(ofChunk: id) == NSRange(location: location, length: 0))
        }
        let top = try Self.chunk(0, document)
        #expect(top.state == .common)
        #expect(top.blocks.isEmpty)
        #expect(top.commonOriginal == "top\n")
        #expect(try Self.chunk(1, document).blocks == [Self.block1])
        #expect(document.range(ofChunk: 2) == NSRange(location: 4, length: 4))
        #expect(document.blockChoices() == nil)
        #expect(document.bytes(sides: Self.endedSides) == nil)
    }

    @Test func onlyABlocksPresentationHasAResult() {
        for presentation in [ConflictPresentation.wholeFile(reason: .binary), .submodule] {
            #expect(ResolverDocument(document: Self.conflict(presentation), sides: Self.endedSides) == nil)
        }
    }

    @Test func rangesAreUTF16() throws {
        let document = try Self.document([Self.common("😀 é\r\n"), .block(Self.block1), Self.common("z\n")])
        #expect(document.range(ofChunk: 0) == NSRange(location: 0, length: 6))
        #expect(document.range(ofChunk: 1) == NSRange(location: 6, length: 0))
        #expect(document.range(ofChunk: 2) == NSRange(location: 6, length: 2))
        #expect(document.range(ofChunk: 99).location == NSNotFound)
    }

    // MARK: - Takes

    @Test func takesComposeTheSides() throws {
        var document = try Self.document(Self.three)
        document.take(.ours, chunk: 1)
        #expect(try Self.chunk(1, document).text == "o1\n")
        #expect(try Self.chunk(1, document).state == .taken(.ours))
        #expect(document.blockChoices() == nil)
        document.take(.oursThenTheirs, chunk: 3)
        #expect(try Self.chunk(3, document).text == "o2\nt2\n")
        document.take(.theirsThenOurs, chunk: 5)
        #expect(try Self.chunk(5, document).text == "t3\no3\n")
        #expect(document.resultText == "top\no1\nmid\no2\nt2\nmid2\nt3\no3\nend\n")
        #expect(document.waitingCount == 0)
        #expect(document.conflictCount == 3)
        #expect(!document.isPristine)
        #expect(document.blockChoices() == [.ours, .oursThenTheirs, .theirsThenOurs])
        document.take(.theirs, chunk: 1)
        #expect(try Self.chunk(1, document).text == "t1\n")
        #expect(document.blockChoices() == [.theirs, .oursThenTheirs, .theirsThenOurs])
    }

    @Test func aTakeOnACommonChunkChangesNothing() throws {
        var document = try Self.document(Self.three)
        let before = document
        document.take(.ours, chunk: 0)
        document.take(.ours, chunk: 42)
        #expect(document == before)
    }

    @Test func anEditedConflictCanBeTakenAgain() throws {
        var document = try Self.document(Self.three)
        document.take(.ours, chunk: 1)
        document.replace(Self.range(of: "o1", in: document), with: "mine")
        #expect(try Self.chunk(1, document).state == .edited)
        document.take(.theirs, chunk: 1)
        #expect(try Self.chunk(1, document).state == .taken(.theirs))
        #expect(try Self.chunk(1, document).text == "t1\n")
    }

    @Test func takeRestFillsOnlyWaiting() throws {
        var document = try Self.document(Self.three)
        document.take(.ours, chunk: 1)
        document.replace(document.range(ofChunk: 3), with: "typed\n")
        document.takeRest(.theirs)
        #expect(try Self.chunk(1, document).state == .taken(.ours))
        #expect(try Self.chunk(1, document).text == "o1\n")
        #expect(try Self.chunk(3, document).state == .edited)
        #expect(try Self.chunk(3, document).text == "typed\n")
        #expect(try Self.chunk(5, document).state == .taken(.theirs))
        #expect(try Self.chunk(5, document).text == "t3\n")
        #expect(document.waitingCount == 0)
        #expect(document.blockChoices() == nil)

        var fresh = try Self.document(Self.three)
        fresh.takeRest(.ours)
        #expect(fresh.blockChoices() == [.ours, .ours, .ours])
    }

    // MARK: - Typing

    @Test func typingInAWaitingSlotMakesItEdited() throws {
        var document = try Self.document(Self.three)
        document.replace(document.range(ofChunk: 3), with: "typed\n")
        let typed = try Self.chunk(3, document)
        #expect(typed.state == .edited)
        #expect(typed.text == "typed\n")
        #expect(typed.blocks == [Self.block2])
        #expect(try Self.chunk(2, document).text == "mid\n")
        #expect(try Self.chunk(4, document).text == "mid2\n")
        #expect(document.chunks.map(\.id) == Array(0...6))
        #expect(document.waitingCount == 2)
        #expect(document.conflictCount == 3)
        #expect(!document.isPristine)
        #expect(document.resultText == "top\nmid\ntyped\nmid2\nend\n")
    }

    @Test func typingInACommonChunkKeepsItCommon() throws {
        var document = try Self.document(Self.three)
        document.replace(Self.range(of: "mid2", in: document), with: "middle")
        let edited = try Self.chunk(4, document)
        #expect(edited.state == .common)
        #expect(edited.text == "middle\n")
        #expect(edited.commonOriginal == "mid2\n")
        #expect(document.waitingCount == 3)
        #expect(!document.isPristine)
        #expect(document.chunks.count == 7)
    }

    /// Canonically equal is not unchanged: the bytes differ, so the document is not pristine.
    @Test func aDecomposedRetypeIsAnEdit() throws {
        var document = try Self.document([Self.common("caf\u{E9}\n"), .block(Self.block1)])
        document.replace(NSRange(location: 3, length: 1), with: "e\u{301}")
        #expect(!document.isPristine)
        document.take(.ours, chunk: 1)
        #expect(document.blockChoices() == nil)
    }

    /// An edit that only reaches a waiting slot's edge leaves the slot waiting; a caret at the
    /// slot types into it.
    @Test func anEditAtASlotsEdgeLeavesItWaiting() throws {
        var document = try Self.document(Self.two)
        document.replace(Self.range(of: "line\n", in: document), with: "x\n")
        #expect(try Self.chunk(0, document).text == "top\nx\n")
        #expect(try Self.chunk(1, document).state == .waiting)
        document.replace(Self.range(of: "mid\n", in: document), with: "")
        #expect(try Self.chunk(1, document).state == .waiting)
        #expect(try Self.chunk(3, document).state == .waiting)
        #expect(document.chunks.count == 5)
        #expect(document.waitingCount == 2)
    }

    @Test func untouchedBytesSurviveAnEdit() throws {
        let segments: [ConflictSegment] = [
            Self.common("one\r\ntwo middle three\r\n"), .block(Self.block("o\r\n", "b\r\n", "t\r\n")),
            Self.common("end\r\n"),
        ]
        let original = try #require(ConflictSegment.composed(segments, choices: [.ours]))
        var document = try Self.document(segments)
        #expect(document.lineEnding == "\r\n")
        document.take(.ours, chunk: 1)
        #expect(document.bytes(sides: Self.endedSides) == original)
        document.replace(Self.range(of: "middle", in: document), with: "new\nword")
        #expect(document.bytes(sides: Self.endedSides) == Data("one\r\ntwo new\r\nword three\r\no\r\nend\r\n".utf8))
    }

    @Test func typedNewlinesBecomeTheFilesEnding() throws {
        var crlf = try Self.document([
            Self.common("a\r\nb\r\nc\n"), .block(Self.block("o\r\n", nil, "t\n")),
        ])
        #expect(crlf.lineEnding == "\r\n")
        crlf.replace(NSRange(location: 0, length: 0), with: "1\r2\r\n3\n4")
        #expect(try Self.chunk(0, crlf).text == "1\r\n2\r\n3\r\n4a\r\nb\r\nc\n")

        var lf = try Self.document([Self.common("a\nb\r\nc\n"), .block(Self.block("o\r\n", nil, "t\n"))])
        #expect(lf.lineEnding == "\n")
        lf.replace(NSRange(location: 0, length: 0), with: "1\r2\r\n3\n")
        #expect(try Self.chunk(0, lf).text == "1\n2\n3\na\nb\r\nc\n")

        // A tie is LF.
        let tie = try Self.document([Self.common("a\r\nb\n"), .block(Self.block("o\r\n", nil, "t\n"))])
        #expect(tie.lineEnding == "\n")
    }

    /// A range end between the halves of a surrogate pair is refused, not widened: the
    /// document, and so every byte, stays as it was.
    @Test func aRangeThatSplitsASurrogatePairChangesNothing() throws {
        var document = try Self.document([Self.common("a😀b\n"), .block(Self.block1)])
        document.take(.ours, chunk: 1)
        let before = document
        let bytes = try #require(document.bytes(sides: Self.endedSides))
        for range in [NSRange(location: 2, length: 0), NSRange(location: 1, length: 1), NSRange(location: 2, length: 2)] {
            document.replace(range, with: "x")
            #expect(document == before, "\(range)")
            #expect(document.bytes(sides: Self.endedSides) == bytes, "\(range)")
        }
        document.replace(NSRange(location: 1, length: 2), with: "x")
        #expect(document.resultText == "axb\no1\n")
    }

    @Test func aRangeOutsideTheTextChangesNothing() throws {
        var document = try Self.document(Self.three)
        let before = document
        document.replace(NSRange(location: 17, length: 1), with: "x")
        document.replace(NSRange(location: NSNotFound, length: 0), with: "x")
        document.replace(NSRange(location: 3, length: 0), with: "")
        #expect(document == before)
        document.replace(NSRange(location: 17, length: 0), with: "x")
        #expect(document.resultText == "top\nmid\nmid2\nend\nx")
    }

    // MARK: - Spanning edits

    @Test func aSpanningEditMergesChunks() throws {
        var document = try Self.document(Self.two)
        #expect(document.conflictCount == 2)
        #expect(document.waitingCount == 2)
        // From inside "line", through the waiting slot, into "mid".
        let start = Self.range(of: "ne\n", in: document).location
        let end = Self.range(of: "mid", in: document).location + 2
        document.replace(NSRange(location: start, length: end - start), with: "X")
        #expect(document.chunks.map(\.id) == [0, 3, 4])
        let merged = try Self.chunk(0, document)
        #expect(merged.state == .edited)
        #expect(merged.text == "top\nliXd\n")
        #expect(merged.blocks == [Self.block1])
        #expect(merged.isMerged)
        #expect(document.conflictCount == 2)
        #expect(document.waitingCount == 1)
        #expect(document.resultText == "top\nliXd\nend\n")
    }

    @Test func aSpanningEditIntoATakenConflict() throws {
        var document = try Self.document(Self.two)
        document.take(.ours, chunk: 1)
        let start = Self.range(of: "ne\n", in: document).location
        let end = Self.range(of: "o1", in: document).location + 1
        document.replace(NSRange(location: start, length: end - start), with: "")
        #expect(document.chunks.map(\.id) == [0, 2, 3, 4])
        let merged = try Self.chunk(0, document)
        #expect(merged.state == .edited)
        #expect(merged.text == "top\nli1\n")
        #expect(merged.blocks == [Self.block1])
        #expect(document.conflictCount == 2)
        #expect(document.waitingCount == 1)
    }

    @Test func aMergedChunkRefusesTakes() throws {
        var document = try Self.document(Self.two)
        document.take(.ours, chunk: 1)
        document.replace(NSRange(location: 0, length: Self.range(of: "o1", in: document).location + 1), with: "")
        let merged = try Self.chunk(0, document)
        document.take(.theirs, chunk: 0)
        document.takeRest(.theirs)
        #expect(try Self.chunk(0, document) == merged)
        #expect(document.blockChoices() == nil)
    }

    /// Two conflicts merged are one conflict: the count is of chunks that hold blocks.
    @Test func twoMergedConflictsCountAsOne() throws {
        var document = try Self.document(Self.two)
        document.take(.ours, chunk: 1)
        document.take(.theirs, chunk: 3)
        let start = Self.range(of: "o1", in: document).location + 1
        let end = Self.range(of: "t2", in: document).location + 1
        document.replace(NSRange(location: start, length: end - start), with: "-")
        #expect(document.chunks.map(\.id) == [0, 1, 4])
        let merged = try Self.chunk(1, document)
        #expect(merged.text == "o-2\n")
        #expect(merged.blocks == [Self.block1, Self.block2])
        #expect(merged.commonOriginal == "mid\n")
        #expect(merged.state == .edited)
        #expect(document.conflictCount == 1)
        #expect(document.waitingCount == 0)
        #expect(document.bytes(sides: Self.endedSides) == Data("top\nline\no-2\nend\n".utf8))
    }

    // MARK: - Chunk edges (Rulings 11 and 12)

    /// Whether every chunk but the last ends at a line edge: the text before its end is empty or
    /// ends in `\n` (a CRLF's last byte too).
    static func everyChunkEndsAtALineEdge(_ document: ResolverDocument) -> Bool {
        var before = Data()
        for chunk in document.chunks.dropLast() {
            before.append(contentsOf: chunk.text.utf8)
            if let last = before.last, last != UInt8(ascii: "\n") { return false }
        }
        return true
    }

    /// A backspace at the start of the line after a taken conflict: the conflict no longer ends
    /// at a line edge, so it merges with the common text after it into one edited chunk.
    @Test func deletingABreakAfterATakenConflictMergesItWithTheNext() throws {
        var document = try Self.document(Self.two)
        document.take(.ours, chunk: 1)
        let before = document
        var history = ResolverHistory()
        history.record(document, coalescingTypingIn: 1, at: Self.t0)
        let end = document.range(ofChunk: 1)
        let changed = document.replace(NSRange(location: end.location + end.length - 1, length: 1), with: "")
        #expect(changed == 1)
        #expect(document.chunks.map(\.id) == [0, 1, 3, 4])
        let merged = try Self.chunk(1, document)
        #expect(merged.state == .edited)
        #expect(merged.text == "o1mid\n")
        #expect(merged.blocks == [Self.block1])
        #expect(merged.commonOriginal == "mid\n")
        #expect(merged.isMerged)
        #expect(document.resultText == "top\nline\no1mid\nend\n")
        #expect(Self.everyChunkEndsAtALineEdge(document))
        // Undo splits it back.
        let undone = try Self.undo(&history, document)
        #expect(undone == before)
        #expect(try Self.chunk(1, undone).state == .taken(.ours))
    }

    /// Removing just the line break before a waiting slot is refused (Ruling 14): it would turn
    /// the conflict into "edited" with neither side chosen. A backspace with the caret in the
    /// empty slot is that range.
    @Test func deletingTheBreakBeforeAWaitingSlotIsRefused() throws {
        var document = try Self.document(Self.three)
        let before = document
        let slot = document.range(ofChunk: 3).location
        let changed = document.replace(NSRange(location: slot - 1, length: 1), with: "")
        #expect(changed == nil)
        #expect(document == before)
        #expect(try Self.chunk(3, document).state == .waiting)

        // A CRLF break, whole or its last half.
        let segments: [ConflictSegment] = [
            Self.common("a\r\n"), .block(Self.block("o\r\n", "b\r\n", "t\r\n")), Self.common("z\r\n"),
        ]
        var crlf = try Self.document(segments)
        let crlfBefore = crlf
        let at = crlf.range(ofChunk: 1).location
        let whole = crlf.replace(NSRange(location: at - 2, length: 2), with: "")
        let half = crlf.replace(NSRange(location: at - 1, length: 1), with: "")
        #expect(whole == nil && half == nil)
        #expect(crlf == crlfBefore)
    }

    /// More than the break, or typing over it, is an ordinary edit: Ruling 11 merges as before.
    @Test func deletingMoreThanTheBreakBeforeASlotStillMerges() throws {
        var document = try Self.document(Self.three)
        let slot = document.range(ofChunk: 3).location
        let changed = document.replace(NSRange(location: slot - 2, length: 2), with: "")
        #expect(changed == 2)
        #expect(document.chunks.map(\.id) == [0, 1, 2, 5, 6])
        #expect(try Self.chunk(2, document).text == "mimid2\n")
        #expect(Self.everyChunkEndsAtALineEdge(document))

        var typed = try Self.document(Self.three)
        let at = typed.range(ofChunk: 3).location
        #expect(typed.replace(NSRange(location: at - 1, length: 1), with: "!") == 2)
        #expect(try Self.chunk(2, typed).text == "mid!mid2\n")
    }

    /// Half a CRLF is no line edge: the `\r` left behind still merges.
    @Test func aCRLFHalfIsNoLineEdge() throws {
        let segments: [ConflictSegment] = [
            Self.common("a\r\n"), .block(Self.block("o\r\n", "b\r\n", "t\r\n")), Self.common("z\r\n"),
        ]
        var document = try Self.document(segments)
        document.take(.ours, chunk: 1)
        let end = document.range(ofChunk: 1)
        document.replace(NSRange(location: end.location + end.length - 1, length: 1), with: "")
        #expect(document.chunks.map(\.id) == [0, 1])
        #expect(try Self.chunk(1, document).text == "o\rz\r\n")
        #expect(Self.everyChunkEndsAtALineEdge(document))

        var whole = try Self.document(segments)
        whole.take(.ours, chunk: 1)
        let span = whole.range(ofChunk: 1)
        whole.replace(NSRange(location: span.location + span.length - 2, length: 2), with: "")
        #expect(whole.chunks.map(\.id) == [0, 1])
        #expect(try Self.chunk(1, whole).text == "oz\r\n")
    }

    /// Ruling 15: an empty taken conflict typed into gets the file's line ending too, so it
    /// never runs into the line after it.
    @Test func typingIntoAnEmptyTakenConflictAddsTheLineEnding() throws {
        var document = try Self.document([Self.common("a\n"), .block(Self.block("", "b\n", "t\n")), Self.common("z\n")])
        document.take(.ours, chunk: 1)
        #expect(try Self.chunk(1, document).text == "")
        let changed = document.replace(NSRange(location: 2, length: 0), with: "x")
        #expect(changed == 1)
        #expect(document.chunks.map(\.id) == [0, 1, 2])
        #expect(try Self.chunk(1, document).text == "x\n")
        #expect(try Self.chunk(1, document).state == .edited)
        #expect(document.resultText == "a\nx\nz\n")
    }

    /// The last chunk may end inside a line: the file's own end.
    @Test func theLastChunkMayEndInsideALine() throws {
        var document = try Self.document(Self.two)
        let end = document.resultText.utf16.count
        document.replace(NSRange(location: end - 1, length: 1), with: "")
        #expect(document.chunks.map(\.id) == Array(0...4))
        #expect(try Self.chunk(4, document).text == "end")
        #expect(try Self.chunk(4, document).state == .common)
    }

    /// Typing into a waiting slot of a chunk that is not the last adds the file's line ending
    /// when the typed text has none, so the slot never runs into the next line (Ruling 12).
    @Test func slotTypingAddsTheLineEnding() throws {
        var document = try Self.document(Self.three)
        let changed = document.replace(document.range(ofChunk: 3), with: "x")
        #expect(changed == 3)
        #expect(try Self.chunk(3, document).text == "x\n")
        #expect(try Self.chunk(3, document).state == .edited)
        #expect(document.chunks.map(\.id) == Array(0...6))
        #expect(document.resultText == "top\nmid\nx\nmid2\nend\n")

        // Already ended: nothing added.
        var ended = try Self.document(Self.three)
        ended.replace(ended.range(ofChunk: 3), with: "x\n")
        #expect(try Self.chunk(3, ended).text == "x\n")

        // The file's ending, CRLF here.
        var crlf = try Self.document([
            Self.common("a\r\n"), .block(Self.block("o\r\n", "b\r\n", "t\r\n")), Self.common("z\r\n"),
        ])
        crlf.replace(crlf.range(ofChunk: 1), with: "x")
        #expect(try Self.chunk(1, crlf).text == "x\r\n")
        #expect(crlf.chunks.map(\.id) == [0, 1, 2])
    }

    /// The slot that ends the file is typed as it is: the file's end is the user's.
    @Test func slotTypingAtTheEndAddsNothing() throws {
        var document = try Self.document(Self.endsInABlock, sides: Self.unendedSides)
        document.replace(document.range(ofChunk: 1), with: "x")
        #expect(try Self.chunk(1, document).text == "x")
        #expect(document.resultText == "a\nx")
    }

    @Test func replaceAndTakeSayWhetherAnythingChanged() throws {
        var document = try Self.document(Self.three)
        let nothingTyped = document.replace(NSRange(location: 3, length: 0), with: "")
        let outside = document.replace(NSRange(location: 99, length: 0), with: "x")
        let typed = document.replace(Self.range(of: "mid2", in: document), with: "m")
        #expect(nothingTyped == nil && outside == nil && typed == 4)
        let first = document.take(.ours, chunk: 1)
        let again = document.take(.ours, chunk: 1)
        let common = document.take(.ours, chunk: 0)
        let other = document.take(.theirs, chunk: 1)
        #expect(first && !again && !common && other)
    }

    // MARK: - Undo

    @Test func undoSplitsASpanningEditBack() throws {
        var document = try Self.document(Self.two)
        document.take(.ours, chunk: 1)
        let before = document
        var history = ResolverHistory()
        history.record(document, coalescingTypingIn: 0, at: Self.t0)
        let start = Self.range(of: "ne\n", in: document).location
        document.replace(NSRange(location: start, length: 6), with: "Q")
        // "top\nliQ" ends inside a line, so it takes in "mid\n" too (Ruling 11).
        #expect(document.chunks.map(\.id) == [0, 3, 4])
        #expect(try Self.chunk(0, document).text == "top\nliQmid\n")
        let merged = document

        let undone = try Self.undo(&history, document)
        #expect(undone.chunks == before.chunks)
        #expect(undone == before)
        let undoNone = history.undo(undone)
        #expect(undoNone == nil)
        let redone = try Self.redo(&history, undone)
        #expect(redone == merged)
        let redoNone = history.redo(redone)
        #expect(redoNone == nil)
    }

    /// Types `text` at the start of chunk 0, recording the step first, as the store will.
    static func type(
        _ text: String, _ document: inout ResolverDocument, _ history: inout ResolverHistory, after seconds: Double
    ) {
        history.record(document, coalescingTypingIn: 0, at: t0.addingTimeInterval(seconds))
        document.replace(NSRange(location: 0, length: 0), with: text)
    }

    @Test func typingCoalescesWithinASecond() throws {
        let original = try Self.document(Self.three)
        var document = original
        var history = ResolverHistory()
        Self.type("a", &document, &history, after: 0)
        Self.type("b", &document, &history, after: 0.5)
        Self.type("c", &document, &history, after: 1.2)
        #expect(document.resultText.hasPrefix("cbatop"))
        let undone = try Self.undo(&history, document)
        #expect(undone == original)
        let undoNone = history.undo(undone)
        #expect(undoNone == nil)
    }

    @Test func aPauseStartsANewStep() throws {
        let original = try Self.document(Self.three)
        var document = original
        var history = ResolverHistory()
        Self.type("a", &document, &history, after: 0)
        let typedA = document
        Self.type("b", &document, &history, after: 2)
        let first = try Self.undo(&history, document)
        #expect(first == typedA)
        let second = try Self.undo(&history, first)
        #expect(second == original)
    }

    @Test func aTakeOrAnotherChunkStartsANewStep() throws {
        let original = try Self.document(Self.three)
        var document = original
        var history = ResolverHistory()
        Self.type("a", &document, &history, after: 0)
        let typedA = document
        history.record(document, coalescingTypingIn: nil, at: Self.t0.addingTimeInterval(0.1))
        document.take(.ours, chunk: 1)
        let taken = document
        Self.type("b", &document, &history, after: 0.2)
        let typedB = document
        history.record(document, coalescingTypingIn: 2, at: Self.t0.addingTimeInterval(0.3))
        document.replace(Self.range(of: "mid\n", in: document), with: "m\n")

        var step = try Self.undo(&history, document)
        #expect(step == typedB)
        step = try Self.undo(&history, step)
        #expect(step == taken)
        step = try Self.undo(&history, step)
        #expect(step == typedA)
        step = try Self.undo(&history, step)
        #expect(step == original)
    }

    @Test func typingAfterAnUndoIsItsOwnStep() throws {
        let original = try Self.document(Self.three)
        var document = original
        var history = ResolverHistory()
        Self.type("a", &document, &history, after: 0)
        document = try Self.undo(&history, document)
        Self.type("b", &document, &history, after: 0.3)
        let redoNone = history.redo(document)
        #expect(redoNone == nil)
        let undone = try Self.undo(&history, document)
        #expect(undone == original)
    }

    // MARK: - Bytes

    /// The stage for ours lacks a final newline; theirs' has one.
    static let unendedSides = ConflictSides(
        ours: Data("a\nlast OURS".utf8), base: Data("a\nlast\n".utf8), theirs: Data("a\nlast THEIRS\n".utf8),
        markerSize: 7)
    static let endBlock = block("last OURS\n", "last\n", "last THEIRS\n")
    static let endsInABlock: [ConflictSegment] = [common("a\n"), .block(endBlock)]

    /// A conflict that ends the file is taken without the terminator merge-file added, so the
    /// Result shows exactly what is written, and an edit elsewhere in it keeps that end (Ruling 6).
    @Test func theFinalNewlineRuleMatchesGitCore() throws {
        var document = try Self.document(Self.endsInABlock, sides: Self.unendedSides)
        func expectWritten(_ text: String, sourceLocation: SourceLocation = #_sourceLocation) {
            #expect(document.resultText == text, sourceLocation: sourceLocation)
            #expect(document.bytes(sides: Self.unendedSides) == Data(text.utf8), sourceLocation: sourceLocation)
        }
        document.take(.ours, chunk: 1)
        expectWritten("a\nlast OURS")
        document.take(.theirsThenOurs, chunk: 1)
        expectWritten("a\nlast THEIRS\nlast OURS")
        document.take(.theirs, chunk: 1)
        expectWritten("a\nlast THEIRS\n")
        document.take(.ours, chunk: 1)
        document.replace(Self.range(of: "OURS", in: document), with: "MINE")
        #expect(try Self.chunk(1, document).state == .edited)
        expectWritten("a\nlast MINE")
        document.replace(NSRange(location: document.resultText.utf16.count, length: 0), with: "\n")
        expectWritten("a\nlast MINE\n")

        // takeRest too; a block that does not end the file keeps every byte.
        var rest = try Self.document(Self.endsInABlock, sides: Self.unendedSides)
        rest.takeRest(.ours)
        #expect(rest.resultText == "a\nlast OURS")
        var inside = try Self.document(Self.endsInABlock + [Self.common("z")], sides: Self.unendedSides)
        inside.take(.ours, chunk: 1)
        #expect(inside.resultText == "a\nlast OURS\nz")
    }

    /// Every take, LF and CRLF, with neither stage ending in a newline: the bytes are GitCore's
    /// composition less the terminator GitCore's helper says merge-file added.
    @Test(arguments: ["\n", "\r\n"], [BlockChoice.ours, .theirs, .oursThenTheirs, .theirsThenOurs])
    func takenBytesAreGitCoresComposition(eol: String, choice: BlockChoice) throws {
        let block = Self.block("O\(eol)", "B\(eol)", "T\(eol)")
        let segments: [ConflictSegment] = [Self.common("a\(eol)"), .block(block)]
        let sides = ConflictSides(
            ours: Data("a\(eol)O".utf8), base: Data("a\(eol)B".utf8), theirs: Data("a\(eol)T".utf8), markerSize: 7)
        var document = try Self.document(segments, sides: sides)
        document.take(choice, chunk: 1)
        var expected = try #require(ConflictSegment.composed(segments, choices: [choice]))
        let side = try #require(block.lastSideWritten(choice))
        let dropped = block.addedFinalTerminator(choice, stage: try #require(side == .ours ? sides.ours : sides.theirs))
        #expect(dropped == eol.utf8.count)
        expected.removeLast(dropped)
        #expect(document.bytes(sides: sides) == expected)
        #expect(Data(document.resultText.utf8) == expected)
    }

    // MARK: - Leftover markers

    @Test func markerLinesFromAStageDoNotCount() throws {
        let marked = Self.block("o\n", "b\n", "=======\nt\n")
        var document = try Self.document([Self.common("a\n"), .block(marked), Self.common("z\n")])
        document.take(.theirs, chunk: 1)
        #expect(document.leftoverMarkerLines(markerSize: 7) == 0)
        document.replace(Self.range(of: "t\n", in: document), with: "u\n")
        #expect(try Self.chunk(1, document).state == .edited)
        #expect(document.leftoverMarkerLines(markerSize: 7) == 0)

        document.replace(Self.range(of: "z", in: document), with: "<<<<<<< x\nz")
        #expect(document.leftoverMarkerLines(markerSize: 7) == 1)
        #expect(document.leftoverMarkerLines(markerSize: 11) == 0)
        document.replace(Self.range(of: "z", in: document), with: "<<<<<<<<<<<\r\n>>>>>>>>>>> y\nz")
        #expect(document.leftoverMarkerLines(markerSize: 11) == 2)
        #expect(document.leftoverMarkerLines(markerSize: 7) == 1)
    }

    /// A common line git wrote (a Markdown underline) is a stage's line too.
    @Test func aCommonLineFromTheStagesDoesNotCount() throws {
        var document = try Self.document([Self.common("Title\n=======\nbody\n"), .block(Self.block1)])
        document.replace(Self.range(of: "body", in: document), with: "text")
        #expect(document.leftoverMarkerLines(markerSize: 7) == 0)
        document.replace(Self.range(of: "text", in: document), with: "|||||||\n=======")
        #expect(document.leftoverMarkerLines(markerSize: 7) == 1)
        // A separator with text after it still counts: the check errs toward asking.
        document.replace(Self.range(of: "|||||||\n", in: document), with: "======= x\n")
        #expect(document.leftoverMarkerLines(markerSize: 7) == 1)
        document.replace(Self.range(of: "======= x", in: document), with: "========")
        #expect(document.leftoverMarkerLines(markerSize: 7) == 0)
    }

    /// Untouched text counts nothing: a taken side's lines are a stage's.
    @Test func untouchedTextHasNoLeftoverMarkers() throws {
        var document = try Self.document([Self.common("<<<<<<< a\n"), .block(Self.block(">>>>>>> o\n", nil, "t\n"))])
        document.take(.ours, chunk: 1)
        #expect(document.leftoverMarkerLines(markerSize: 7) == 0)
    }

    // MARK: - Not editable

    @Test func notUTF8IsNotEditable() throws {
        let segments: [ConflictSegment] = [
            .common(Data([0x61, 0xFF, 0x0A])), .block(Self.block1), Self.common("z\n"),
        ]
        var document = try Self.document(segments)
        #expect(document.notEditable == .notUTF8)
        let before = document
        document.replace(NSRange(location: 0, length: 1), with: "x")
        #expect(document == before)
        document.take(.theirs, chunk: 1)
        #expect(try Self.chunk(1, document).state == .taken(.theirs))
        #expect(document.waitingCount == 0)
        #expect(document.blockChoices() == [.theirs])
        // The text shown is not the file's bytes: Resolve File writes through the choices.
        #expect(document.bytes(sides: Self.endedSides) == nil)
    }

    @Test func overTheLimitIsNotEditable() throws {
        let lines = String(repeating: "x\n", count: ResolverDocument.editLimitLines + 1)
        var byLines = try Self.document([Self.common(lines), .block(Self.block1)])
        #expect(byLines.notEditable == .tooLarge)
        let before = byLines
        byLines.replace(NSRange(location: 0, length: 1), with: "y")
        #expect(byLines == before)
        byLines.take(.ours, chunk: 1)
        #expect(try Self.chunk(1, byLines).state == .taken(.ours))
        #expect(byLines.bytes(sides: Self.endedSides) == Data((lines + "o1\n").utf8))

        let wide = String(repeating: "x", count: ResolverDocument.editLimitBytes) + "\n"
        #expect(try Self.document([Self.common(wide), .block(Self.block1)]).notEditable == .tooLarge)

        // Too large and not UTF-8: the lossy text is never written.
        var both = try Self.document([.common(Data(lines.utf8) + Data([0xFF, 0x0A])), .block(Self.block1)])
        #expect(both.notEditable == .notUTF8)
        both.take(.ours, chunk: 1)
        #expect(both.bytes(sides: Self.endedSides) == nil)
        #expect(both.blockChoices() == [.ours])

        let under = String(repeating: "x\n", count: ResolverDocument.editLimitLines - 10)
        #expect(try Self.document([Self.common(under), .block(Self.block1)]).notEditable == nil)
    }
}
