import Foundation
import Testing

@testable import GitCore

/// `ConflictParser` on hand-written diff3 text: bytes in, bytes out, never re-encoded.
@Suite struct ConflictParserTests {
    static func data(_ text: String) -> Data { Data(text.utf8) }

    static func block(_ ours: String, _ base: String?, _ theirs: String) -> ConflictSegment {
        .block(ConflictBlock(ours: data(ours), base: base.map(data), theirs: data(theirs)))
    }

    @Test func twoBlocksWithCommonTextBetween() {
        let text = """
            a
            <<<<<<< ours
            b1
            ||||||| base
            b
            =======
            b2
            >>>>>>> theirs
            c
            d
            <<<<<<< ours
            e1
            ||||||| base
            e
            =======
            e2
            >>>>>>> theirs
            f

            """

        let segments = ConflictParser.parse(Self.data(text), markerSize: 7)

        #expect(segments == [
            .common(Self.data("a\n")),
            Self.block("b1\n", "b\n", "b2\n"),
            .common(Self.data("c\nd\n")),
            Self.block("e1\n", "e\n", "e2\n"),
            .common(Self.data("f\n")),
        ])
    }

    @Test func blocksAtTheVeryStartAndTheVeryEnd() {
        let text = """
            <<<<<<< ours
            x1
            ||||||| base
            x
            =======
            x2
            >>>>>>> theirs
            middle
            <<<<<<< ours
            y1
            ||||||| base
            y
            =======
            y2
            >>>>>>> theirs

            """

        let segments = ConflictParser.parse(Self.data(text), markerSize: 7)

        #expect(segments == [
            Self.block("x1\n", "x\n", "x2\n"),
            .common(Self.data("middle\n")),
            Self.block("y1\n", "y\n", "y2\n"),
        ])
    }

    @Test func anEmptyOursSide() {
        let text = "a\n<<<<<<< ours\n||||||| base\nb\n=======\nb2\n>>>>>>> theirs\nc\n"

        let segments = ConflictParser.parse(Self.data(text), markerSize: 7)

        #expect(segments == [.common(Self.data("a\n")), Self.block("", "b\n", "b2\n"), .common(Self.data("c\n"))])
    }

    /// An add/add: the base section is there and empty, which is not the same as absent.
    @Test func anEmptyBaseSection() {
        let text = "<<<<<<< ours\nOURS\n||||||| base\n=======\nTHEIRS\n>>>>>>> theirs\n"

        let segments = ConflictParser.parse(Self.data(text), markerSize: 7)

        #expect(segments == [Self.block("OURS\n", "", "THEIRS\n")])
    }

    @Test func aBlockWithNoBaseSectionHasANilBase() {
        let text = "<<<<<<< ours\nOURS\n=======\nTHEIRS\n>>>>>>> theirs\n"

        #expect(ConflictParser.parse(Self.data(text), markerSize: 7) == [Self.block("OURS\n", nil, "THEIRS\n")])
    }

    @Test func crlfStaysInsideTheSegments() {
        let text = "a\r\n<<<<<<< ours\r\nb1\r\n||||||| base\r\nb\r\n=======\r\nb2\r\n>>>>>>> theirs\r\nc\r\n"

        let segments = ConflictParser.parse(Self.data(text), markerSize: 7)

        #expect(segments == [
            .common(Self.data("a\r\n")),
            Self.block("b1\r\n", "b\r\n", "b2\r\n"),
            .common(Self.data("c\r\n")),
        ])
    }

    @Test func aLastLineWithoutANewlineIsKept() {
        let text = "<<<<<<< ours\nb1\n||||||| base\nb\n=======\nb2\n>>>>>>> theirs\nend"

        #expect(ConflictParser.parse(Self.data(text), markerSize: 7)?.last == .common(Self.data("end")))
    }

    @Test func bytesThatAreNotUTF8SurviveUntouched() {
        var text = Data("<<<<<<< ours\n".utf8)
        text.append(contentsOf: [0xff, 0xfe, 0x0a])
        text.append(Data("||||||| base\n=======\nt\n>>>>>>> theirs\n".utf8))

        let segments = ConflictParser.parse(text, markerSize: 7)

        #expect(segments == [.block(ConflictBlock(ours: Data([0xff, 0xfe, 0x0a]), base: Data(), theirs: Self.data("t\n")))])
    }

    /// RF1: content lines that look like git's markers, at git's size, inside both sides. At
    /// size 8 they are content, and the two real blocks are all there is.
    @Test func markerLikeContentAtTheDefaultSizeIsContentAtALargerOne() {
        let text = """
            top
            <<<<<<<< ours
            =======
            <<<<<<< x
            ours line
            |||||||| base
            base line
            ========
            |||||||
            theirs line
            =======
            >>>>>>>> theirs
            middle
            <<<<<<<< ours
            <<<<<<< x
            |||||||| base
            ========
            >>>>>>> y
            >>>>>>>> theirs
            bottom

            """

        let segments = ConflictParser.parse(Self.data(text), markerSize: 8)

        #expect(segments == [
            .common(Self.data("top\n")),
            Self.block("=======\n<<<<<<< x\nours line\n", "base line\n", "|||||||\ntheirs line\n=======\n"),
            .common(Self.data("middle\n")),
            Self.block("<<<<<<< x\n", "", ">>>>>>> y\n"),
            .common(Self.data("bottom\n")),
        ])
        #expect(segments?.filter { if case .block = $0 { return true } else { return false } }.count == 2)
    }

    @Test(arguments: [
        // A block never closed.
        "a\n<<<<<<< ours\nb\n=======\nc\n",
        // A separator outside any block.
        "a\n=======\nb\n",
        // A closing marker outside any block.
        "a\n>>>>>>> theirs\n",
        // A base marker outside any block.
        "a\n||||||| base\n",
        // A second opening marker inside a block.
        "<<<<<<< ours\na\n<<<<<<< ours\n=======\nb\n>>>>>>> theirs\n",
        // A closing marker before the separator.
        "<<<<<<< ours\na\n>>>>>>> theirs\n",
        // A base marker after the separator.
        "<<<<<<< ours\na\n=======\n||||||| base\nb\n>>>>>>> theirs\n",
        // Two base markers.
        "<<<<<<< ours\na\n||||||| base\n||||||| base\n=======\nb\n>>>>>>> theirs\n",
        // Everything but the end marker.
        "<<<<<<< ours\na\n||||||| base\nb\n=======\nc",
    ])
    func unbalancedTextIsNil(text: String) {
        #expect(ConflictParser.parse(Self.data(text), markerSize: 7) == nil, "\(text.debugDescription)")
    }

    /// A smudge filter that prefixes every line (M 26's `S:`) leaves no marker at line start:
    /// that is plain text with no blocks, and the caller treats "no blocks" from a rebuild git
    /// counted blocks in as unparsable.
    @Test func textWithNoMarkersIsOneCommonSegment() {
        let text = "S:a\nS:<<<<<<< ours\nS:b\n"

        #expect(ConflictParser.parse(Self.data(text), markerSize: 7) == [.common(Self.data(text))])
    }

    @Test func safeMarkerSizeIsSevenForPlainText() {
        #expect(ConflictParser.safeMarkerSize([Self.data("a\nb\n"), Self.data("<<< x\n== y\n")]) == 7)
        #expect(ConflictParser.safeMarkerSize([]) == 7)
    }

    @Test func safeMarkerSizeOutgrowsTheLongestRunAtALineStart() {
        #expect(ConflictParser.safeMarkerSize([Self.data("a\n"), Self.data("x\n<<<<<<<<\n")]) == 9)
        #expect(ConflictParser.safeMarkerSize([Self.data("=======\n")]) == 8)
        #expect(ConflictParser.safeMarkerSize([Self.data("|||||||||| x")]) == 11)
        #expect(ConflictParser.safeMarkerSize([Self.data(">>>>>>>>>>>>\r\n")]) == 13)
        // Not at a line start: not a marker, whatever its length.
        #expect(ConflictParser.safeMarkerSize([Self.data("a <<<<<<<<<<<<\n")]) == 7)
        // A run is of one character: `<<<<===` is a run of four.
        #expect(ConflictParser.safeMarkerSize([Self.data("<<<<====\n")]) == 7)
    }

    @Test func withoutLabelsKeepsTheLineEnding() {
        #expect(ConflictParser.withoutLabels(Self.data("<<<<<<< HEAD\r\n"), markerSize: 7) == Self.data("<<<<<<<\r\n"))
    }

    @Test func withoutLabelsStripsEveryLabelledMarkerAndNothingElse() {
        let text = "a\n<<<<<<< HEAD\nb\n||||||| 9b81dea\nc\n=======\nd\n>>>>>>> feature~1\n"
            + "<<<<<<<< wider\n<<<<<<<x\n=======\n>>>>>>> last"

        let stripped = ConflictParser.withoutLabels(Self.data(text), markerSize: 7)

        #expect(stripped == Self.data(
            "a\n<<<<<<<\nb\n|||||||\nc\n=======\nd\n>>>>>>>\n"
                + "<<<<<<<< wider\n<<<<<<<x\n=======\n>>>>>>>"))
    }

    @Test func withoutLabelsAtAWiderSize() {
        let text = "<<<<<<<<< HEAD\n<<<<<<< content\n>>>>>>>>> x\n"

        #expect(ConflictParser.withoutLabels(Self.data(text), markerSize: 9)
            == Self.data("<<<<<<<<<\n<<<<<<< content\n>>>>>>>>>\n"))
    }
}
