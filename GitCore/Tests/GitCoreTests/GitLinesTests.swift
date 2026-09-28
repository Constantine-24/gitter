import Foundation
import Testing

@testable import GitCore

/// `GitLines.split` cuts at the `\n` byte and nowhere else.
@Suite struct GitLinesTests {
    static func lines(_ text: String) -> [String] { GitLines.split(Data(text.utf8)) }

    @Test func aCRBeforeTheNewlineStaysOnItsOwnLine() {
        #expect(Self.lines("a\r\nb\n") == ["a\r", "b"])
        #expect(Self.lines("a\r\nb\r\n").map { Array($0.unicodeScalars) } == [["a", "\r"], ["b", "\r"]])
    }

    @Test func charactersSwiftCallsNewlinesDoNotCut() {
        #expect(Self.lines("a\u{2028}b\tc\nd\u{85}e\nf\rg\nh\u{0B}i\u{0C}j\n")
            == ["a\u{2028}b\tc", "d\u{85}e", "f\rg", "h\u{0B}i\u{0C}j"])
    }

    @Test func aTrailingNewlineAddsNoLineButInnerEmptyLinesStay() {
        #expect(Self.lines("") == [])
        #expect(Self.lines("\n") == [""])
        #expect(Self.lines("a") == ["a"])
        #expect(Self.lines("a\n\nb\n") == ["a", "", "b"])
        #expect(Self.lines("a\n\n") == ["a", ""])
    }
}
