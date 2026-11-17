import Foundation
import GitCore
import GitterSyntax
import Testing

@testable import Gitter

/// Syntax colours Task 3: the diff's lines take their tokens from the whole source text of their
/// side, line for line, and a line that does not match its source stays plain.
@Suite struct DiffSyntaxTests {

    /// One file's diff, parsed from a unified diff whose header is written here.
    static func diff(_ body: String, path: String = "a.swift") -> FileDiff {
        let text = """
            diff --git a/\(path) b/\(path)
            index 1111111111111111111111111111111111111111..2222222222222222222222222222222222222222 100644
            --- a/\(path)
            +++ b/\(path)

            """ + body
        let diffs = DiffParser.parse(Data(text.utf8))
        precondition(diffs.count == 1, "the fixture parses to one file")
        return diffs[0]
    }

    /// `let a = 1` turned into `var a = "x"` under an unchanged import.
    static let change = diff("""
        @@ -1,2 +1,2 @@
         import Foundation
        -let a = 1
        +var a = "x"

        """)
    static let old = "import Foundation\nlet a = 1\n"
    static let new = "import Foundation\nvar a = \"x\"\n"

    static func line(_ kind: DiffLineKind, in diff: FileDiff, _ index: Int = 0) -> DiffLine {
        diff.hunks.flatMap(\.lines).filter { $0.kind == kind }[index]
    }

    @Test func removedLinesUseOldTextAndAddedUseNew() throws {
        let tokens = DiffSyntax.lineTokens(for: Self.change, old: Self.old, new: Self.new, language: .swift)

        let removed = try #require(tokens[Self.line(.removed, in: Self.change).id])
        #expect(removed.contains(SyntaxToken(range: 0..<3, kind: .keyword)))
        let added = try #require(tokens[Self.line(.added, in: Self.change).id])
        #expect(added.contains(SyntaxToken(range: 0..<3, kind: .keyword)))
        #expect(added.contains(SyntaxToken(range: 8..<11, kind: .string)))
    }

    /// A context line is checked against, and coloured from, the new text only.
    @Test func contextLineUsesNewText() throws {
        let context = Self.line(.context, in: Self.change).id

        let fromNew = DiffSyntax.lineTokens(for: Self.change, old: nil, new: Self.new, language: .swift)
        #expect(fromNew[context]?.contains(SyntaxToken(range: 0..<6, kind: .keyword)) == true)
        let fromOld = DiffSyntax.lineTokens(for: Self.change, old: Self.old, new: nil, language: .swift)
        #expect(fromOld[context] == nil)
        #expect(fromOld[Self.line(.removed, in: Self.change).id] != nil)
    }

    @Test func mismatchedLineStaysPlain() {
        // Line 2 of this new text is not the diff's `+var a = "x"` (a clean filter, an edit since).
        let new = "import Foundation\nvar a = \"y\"\n"

        let tokens = DiffSyntax.lineTokens(for: Self.change, old: Self.old, new: new, language: .swift)

        #expect(tokens[Self.line(.added, in: Self.change).id] == nil)
        #expect(tokens[Self.line(.context, in: Self.change).id] != nil)
        #expect(tokens[Self.line(.removed, in: Self.change).id] != nil)
    }

    /// A line longer than `SyntaxHighlighter.maxLineLength` stays plain, so a minified line can't
    /// stall the main actor building its row, while a line at the cap and the file's short lines
    /// still colour.
    @Test func aLineOverTheLengthCapStaysPlain() throws {
        let cap = SyntaxHighlighter.maxLineLength
        // `let s = "…"`: nine units before the string's text, one after it.
        let atCap = "let s = \"" + String(repeating: "x", count: cap - 10) + "\""
        let overCap = "let t = \"" + String(repeating: "y", count: cap - 9) + "\""
        #expect(atCap.utf16.count == cap)
        #expect(overCap.utf16.count == cap + 1)
        let diff = Self.diff("""
            @@ -0,0 +1,3 @@
            +\(atCap)
            +\(overCap)
            +let a = 1

            """)
        let new = "\(atCap)\n\(overCap)\nlet a = 1\n"

        let tokens = DiffSyntax.lineTokens(for: diff, old: nil, new: new, language: .swift)

        let first = try #require(tokens[Self.line(.added, in: diff, 0).id])
        #expect(first.contains(SyntaxToken(range: 0..<3, kind: .keyword)))
        #expect(first.contains { $0.kind == .string && $0.range.upperBound == cap })
        #expect(tokens[Self.line(.added, in: diff, 1).id] == nil)
        #expect(tokens[Self.line(.added, in: diff, 2).id]?.contains(SyntaxToken(range: 0..<3, kind: .keyword)) == true)
    }

    /// A line number past the source's end is a mismatch too, never a crash.
    @Test func aLineNumberPastTheEndStaysPlain() {
        let tokens = DiffSyntax.lineTokens(
            for: Self.change, old: Self.old, new: "import Foundation\n", language: .swift)

        #expect(tokens[Self.line(.added, in: Self.change).id] == nil)
        #expect(tokens[Self.line(.context, in: Self.change).id] != nil)
    }

    /// `core.autocrlf`: the worktree has CRLF, the diff (from the cleaned blob) has none.
    @Test func crlfWorktreeAgainstLFBlobStillColours() {
        let new = "import Foundation\r\nvar a = \"x\"\r\n"

        let tokens = DiffSyntax.lineTokens(for: Self.change, old: Self.old, new: new, language: .swift)

        #expect(tokens[Self.line(.added, in: Self.change).id]?.contains(SyntaxToken(range: 0..<3, kind: .keyword)) == true)
        #expect(tokens[Self.line(.context, in: Self.change).id] != nil)
    }

    /// The other way round: the diff's lines keep their `\r`, which is not compared.
    @Test func crlfDiffLinesMatchTheirCRLFSource() {
        let change = Self.diff("@@ -1,2 +1,2 @@\n import Foundation\r\n-let a = 1\r\n+var a = \"x\"\r\n")
        let old = "import Foundation\r\nlet a = 1\r\n"
        let new = "import Foundation\r\nvar a = \"x\"\r\n"

        let tokens = DiffSyntax.lineTokens(for: change, old: old, new: new, language: .swift)

        #expect(tokens[Self.line(.removed, in: change).id]?.contains(SyntaxToken(range: 0..<3, kind: .keyword)) == true)
        #expect(tokens[Self.line(.added, in: change).id]?.contains(SyntaxToken(range: 8..<11, kind: .string)) == true)
    }

    @Test func noNewlineLineIsPlain() throws {
        let change = Self.diff("""
            @@ -1,2 +1,2 @@
             import Foundation
            -let a = 1
            +var a = "x"
            \\ No newline at end of file

            """)
        let new = "import Foundation\nvar a = \"x\""

        let tokens = DiffSyntax.lineTokens(for: change, old: Self.old, new: new, language: .swift)

        #expect(tokens[Self.line(.noNewline, in: change).id] == nil)
        #expect(tokens[Self.line(.added, in: change).id] != nil)
    }

    @Test func binaryOrInvalidUTF8IsPlain() {
        let binary = FileDiff(
            oldPath: "a.swift", newPath: "a.swift", kind: .modified, isBinary: true, hunks: Self.change.hunks)
        let latin1 = FileDiff(
            oldPath: "a.swift", newPath: "a.swift", kind: .modified, isBinary: false, hunks: Self.change.hunks,
            isValidUTF8: false)

        #expect(DiffSyntax.lineTokens(for: binary, old: Self.old, new: Self.new, language: .swift).isEmpty)
        #expect(DiffSyntax.lineTokens(for: latin1, old: Self.old, new: Self.new, language: .swift).isEmpty)
        // Bytes that are not UTF-8 are no text at all.
        #expect(DiffSyntax.text(Data([0x6C, 0x65, 0x74, 0xE9, 0x0A])) == nil)
        #expect(DiffSyntax.text(Data("let\n".utf8)) == "let\n")
    }

    /// The hunk starts inside a comment that opened above it: only the whole file says so, which
    /// is why the whole file is parsed and not the hunk's lines.
    @Test func multiLineCommentOpenedBeforeTheHunk() throws {
        let old = "import Foundation\n/*\nfirst\nsecond\n*/\nlet a = 1\n"
        let new = "import Foundation\n/*\nfirst\ninserted\nsecond\n*/\nlet a = 1\n"
        let change = Self.diff("""
            @@ -3,3 +3,4 @@
             first
            +inserted
             second
             */

            """)

        let tokens = DiffSyntax.lineTokens(for: change, old: old, new: new, language: .swift)

        let first = try #require(change.hunks.first?.lines.first)
        #expect(first.displayText == "first")
        #expect(tokens[first.id] == [SyntaxToken(range: 0..<5, kind: .comment)])
        #expect(tokens[Self.line(.added, in: change).id] == [SyntaxToken(range: 0..<8, kind: .comment)])
    }

    // MARK: - From bytes

    /// The language comes from the displayed path, then from the first line of the text.
    @Test func coloursPickTheLanguageFromThePathOrTheShebang() {
        let script = Self.diff("@@ -1,2 +1,2 @@\n #!/bin/sh\n-echo one\n+echo \"two\"\n", path: "run")
        let colours = DiffSyntax.colours(
            for: script, old: Data("#!/bin/sh\necho one\n".utf8), new: Data("#!/bin/sh\necho \"two\"\n".utf8))
        #expect(colours[Self.line(.added, in: script).id]?.contains { $0.kind == .string } == true)

        let notes = Self.diff("@@ -1 +1 @@\n-let a = 1\n+var a = 2\n", path: "notes.txt")
        #expect(DiffSyntax.colours(for: notes, old: Data("let a = 1\n".utf8), new: Data("var a = 2\n".utf8)).isEmpty)
    }

    // MARK: - The sides

    @Test func theSidesFollowTheSelection() {
        let diff = Self.change
        let old = DiffSyntax.Source.blob("1111111111111111111111111111111111111111")
        let blobNew = DiffSyntax.Source.blob("2222222222222222222222222222222222222222")

        #expect(DiffSyntax.sourceSides(for: diff, selection: .workingCopy, staged: false) == (old, .worktree("a.swift")))
        #expect(DiffSyntax.sourceSides(for: diff, selection: .workingCopy, staged: true) == (old, blobNew))
        #expect(DiffSyntax.sourceSides(for: diff, selection: .commit("abc"), staged: false) == (old, blobNew))
        #expect(DiffSyntax.sourceSides(for: diff, selection: .stash("abc"), staged: false) == (old, blobNew))
        #expect(DiffSyntax.sourceSides(for: diff, selection: .comparisonChanges, staged: false) == (old, blobNew))
    }

    @Test func aMissingSideHasNoSource() {
        let added = DiffParser.parse(Data("""
            diff --git a/n.swift b/n.swift
            new file mode 100644
            index 0000000000000000000000000000000000000000..2222222222222222222222222222222222222222
            --- /dev/null
            +++ b/n.swift
            @@ -0,0 +1 @@
            +let a = 1

            """.utf8))[0]
        let deleted = DiffParser.parse(Data("""
            diff --git a/d.swift b/d.swift
            deleted file mode 100644
            index 1111111111111111111111111111111111111111..0000000000000000000000000000000000000000
            --- a/d.swift
            +++ /dev/null
            @@ -1 +0,0 @@
            -let a = 1

            """.utf8))[0]

        #expect(DiffSyntax.sourceSides(for: added, selection: .commit("abc"), staged: false).old == .none)
        #expect(DiffSyntax.sourceSides(for: added, selection: .workingCopy, staged: false) == (.none, .worktree("n.swift")))
        #expect(DiffSyntax.sourceSides(for: deleted, selection: .workingCopy, staged: false).new == .none)
        #expect(DiffSyntax.sourceSides(for: deleted, selection: .commit("abc"), staged: false).new == .none)
        let binary = FileDiff(oldPath: "a.swift", newPath: "a.swift", kind: .modified, isBinary: true, hunks: [],
                              oldBlob: "1111111", newBlob: "2222222")
        #expect(DiffSyntax.sourceSides(for: binary, selection: .commit("abc"), staged: false) == (.none, .none))
    }
}
