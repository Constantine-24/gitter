import Foundation
import Testing

@testable import GitCore

/// How `DiffParser` cuts a diff into lines: on the `\n` byte, with each hunk line's marker read
/// as its first byte. Swift's `Character` would glue `"\r\n"` into one character (so a CRLF
/// hunk never split) and a marker to a combining mark after it (so the line's kind was lost).
@Suite struct DiffParserLineTests {

    static func diff(_ hunk: String) -> Data {
        Data(("diff --git a/f.txt b/f.txt\nindex 1234567..89abcde 100644\n--- a/f.txt\n+++ b/f.txt\n" + hunk).utf8)
    }

    @Test func aCRLFLineKeepsItsCRAsContent() throws {
        let file = try #require(
            DiffParser.parse(Self.diff("@@ -1,2 +1,2 @@\n a\r\n-b\r\n+X\r\n")).first)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .added])
        #expect(hunk.lines.map(\.text) == ["a\r", "b\r", "X\r"])
        #expect(hunk.lines.map(\.oldNumber) == [1, 2, nil])
        #expect(hunk.lines.map(\.newNumber) == [1, nil, 2])
    }

    @Test func aLoneCRInsideOrAtTheEndOfALineStaysInIt() throws {
        let file = try #require(
            DiffParser.parse(Self.diff("@@ -1 +1 @@\n-a\rb\n+a\rb\r\n\\ No newline at end of file\n")).first)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.lines.map(\.text) == ["a\rb", "a\rb\r", "No newline at end of file"])
        #expect(hunk.lines.map(\.kind) == [.removed, .added, .noNewline])
    }

    @Test func mixedEndingsKeepEachLinesOwn() throws {
        let file = try #require(
            DiffParser.parse(Self.diff("@@ -1,3 +1,4 @@\n a\r\n b\n+X\r\n c\n")).first)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.lines.map(\.text) == ["a\r", "b", "X\r", "c"])
    }

    /// `" \u{301}x"` is two `Character`s, `" \u{301}"` and `"x"`: a character test would not
    /// see the `" "` marker, would end the hunk there, and would lose the line.
    @Test func aLineStartingWithACombiningMarkKeepsItsKindAndItsText() throws {
        let file = try #require(
            DiffParser.parse(Self.diff("@@ -1,2 +1,2 @@\n \u{301}x\n-\u{301}y\n+\u{301}z\n")).first)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.lines.map(\.kind) == [.context, .removed, .added])
        #expect(hunk.lines.map { Array($0.text.unicodeScalars) } == [
            ["\u{301}", "x"], ["\u{301}", "y"], ["\u{301}", "z"],
        ])
    }

    /// git copies the function line into the section heading. It trims trailing whitespace
    /// (measured: a CRLF `int f() {` line gives a heading without the `\r`), but a `\r` inside
    /// the heading stays, and the hunk must still be recognised.
    @Test func aCRInTheSectionHeadingDoesNotHideTheHunk() throws {
        let file = try #require(
            DiffParser.parse(Self.diff("@@ -1 +1 @@ int f()\r{\n-a\n+b\n")).first)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.header == "@@ -1 +1 @@ int f()\r{")
        #expect(hunk.lines.map(\.text) == ["a", "b"])
    }

    /// Through the builder and back: the patch's bytes are the diff's bytes.
    @Test func aCRLFHunkRendersBackByteForByte() throws {
        let file = try #require(
            DiffParser.parse(Self.diff("@@ -1,3 +1,3 @@\n a\r\n-b\r\n+X\r\n c\r\n")).first)
        let patch = try #require(
            PatchBuilder.patch(
                file: file, hunkIDs: Set(file.hunks.map(\.id)), lineIDs: nil, direction: .stage))
        let body = Array(patch.text.utf8).split(separator: UInt8(ascii: "\n")).suffix(4)
        #expect(body.map { String(decoding: $0, as: UTF8.self) } == [" a\r", "-b\r", "+X\r", " c\r"])
        #expect(patch.text.utf8.count(where: { $0 == UInt8(ascii: "\r") }) == 4)
    }

    /// The view drops a CRLF line's `\r`; the model keeps it, since patches are built from it.
    @Test func displayTextDropsOneTrailingCROnly() {
        func line(_ text: String) -> DiffLine {
            DiffLine(id: 0, kind: .context, oldNumber: 1, newNumber: 1, text: text)
        }
        #expect(line("a\r").displayText == "a")
        #expect(line("a\r").text == "a\r")
        #expect(line("a\rb").displayText == "a\rb")
        #expect(line("a\r\r").displayText == "a\r")
        #expect(line("\r").displayText == "")
        #expect(line("a").displayText == "a")
        #expect(line("").displayText == "")
    }

    // MARK: - An empty line is a blank context line (`diff.suppressBlankEmpty`)

    /// Under `diff.suppressBlankEmpty=true` git writes a blank context line as `\n` alone, not
    /// `" \n"` (measured on git 2.54, in `diff` and `diff-tree` alike). It used to end the hunk,
    /// losing every line after it — including changed lines, which then could not be staged.
    @Test func anEmptyLineInsideAHunkIsABlankContextLine() throws {
        let file = try #require(
            DiffParser.parse(Self.diff("@@ -1,4 +1,4 @@\n-a\n+A\n\n-c\n+C\n d\n")).first)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.lines.map(\.kind) == [.removed, .added, .context, .removed, .added, .context])
        #expect(hunk.lines.map(\.text) == ["a", "A", "", "c", "C", "d"])
        #expect(hunk.lines.map(\.oldNumber) == [1, nil, 2, 3, nil, 4])
        #expect(hunk.lines.map(\.newNumber) == [nil, 1, 2, nil, 3, 4])
    }

    /// The last line of the whole output can be the blank one: the diff then ends `\n\n`.
    @Test func anEmptyLastLineOfTheOutputIsStillTheHunksLastContextLine() throws {
        let file = try #require(DiffParser.parse(Self.diff("@@ -1,2 +1,2 @@\n-a\n+A\n\n")).first)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.lines.map(\.kind) == [.removed, .added, .context])
        #expect(hunk.lines.last?.text == "")
    }

    /// Only as many as the header counts, as `git apply` reads it: an empty line once both
    /// sides are complete is not part of the hunk, and the next hunk is still found.
    @Test func anEmptyLineAfterTheHunksCountsIsNotContext() throws {
        let file = try #require(
            DiffParser.parse(Self.diff("@@ -1 +1 @@\n-a\n+A\n\n@@ -5 +5 @@\n-e\n+E\n")).first)
        #expect(file.hunks.count == 2)
        #expect(file.hunks.first?.lines.map(\.kind) == [.removed, .added])
        #expect(file.hunks.last?.lines.map(\.text) == ["e", "E"])
    }
}
