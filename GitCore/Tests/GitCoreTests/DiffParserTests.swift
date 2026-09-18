import Foundation
import Testing

@testable import GitCore

@Suite struct DiffParserTests {
    static func fixtureData(_ name: String) throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: name, withExtension: "txt", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    // MARK: diff-unstaged.txt

    @Test func unstagedHasTwoFiles() throws {
        let diffs = DiffParser.parse(try Self.fixtureData("diff-unstaged"))
        #expect(diffs.count == 2)
    }

    @Test func unstagedFirstFileHunkHeaderAndCounts() throws {
        let diffs = DiffParser.parse(try Self.fixtureData("diff-unstaged"))
        let file = try #require(diffs.first)
        #expect(file.oldPath == "a.txt")
        #expect(file.newPath == "a.txt")
        #expect(file.kind == .modified)
        #expect(file.isBinary == false)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.header == "@@ -2,3 +2,4 @@ a")
        #expect(hunk.oldStart == 2)
        #expect(hunk.oldCount == 3)
        #expect(hunk.newStart == 2)
        #expect(hunk.newCount == 4)
        #expect(hunk.lines.count == 4)
    }

    @Test func unstagedFirstFileLineNumbers() throws {
        let diffs = DiffParser.parse(try Self.fixtureData("diff-unstaged"))
        let file = try #require(diffs.first)
        let hunk = try #require(file.hunks.first)
        let oldNumbers = hunk.lines.map(\.oldNumber)
        let newNumbers = hunk.lines.map(\.newNumber)
        #expect(oldNumbers == [2, 3, 4, nil])
        #expect(newNumbers == [2, 3, 4, 5])
        let last = try #require(hunk.lines.last)
        #expect(last.kind == .added)
        #expect(last.text == "wc change")
    }

    // MARK: diff-staged.txt

    @Test func stagedHasThreeFiles() throws {
        let diffs = DiffParser.parse(try Self.fixtureData("diff-staged"))
        #expect(diffs.count == 3)
    }

    @Test func stagedRenamedFile() throws {
        let diffs = DiffParser.parse(try Self.fixtureData("diff-staged"))
        let renamed = try #require(diffs.first { $0.kind == .renamed })
        #expect(renamed.oldPath == "keep.txt")
        #expect(renamed.newPath == "renamed.txt")
        #expect(renamed.hunks.isEmpty)
    }

    @Test func stagedDeletedFile() throws {
        let diffs = DiffParser.parse(try Self.fixtureData("diff-staged"))
        let deleted = try #require(diffs.first { $0.kind == .deleted })
        #expect(deleted.newPath == nil)
        #expect(deleted.oldPath == "src/one.txt")
        let hunk = try #require(deleted.hunks.first)
        let removed = hunk.lines.filter { $0.kind == .removed }
        #expect(removed.count == 2)
    }

    @Test func stagedAddedFile() throws {
        let diffs = DiffParser.parse(try Self.fixtureData("diff-staged"))
        let added = try #require(diffs.first { $0.kind == .added })
        #expect(added.oldPath == nil)
        #expect(added.newPath == "staged.txt")
        let hunk = try #require(added.hunks.first)
        let addedLines = hunk.lines.filter { $0.kind == .added }
        #expect(addedLines.count == 1)
    }

    // MARK: show-merge-diff.txt

    @Test func mergeDiffHasOneFile() throws {
        let diffs = DiffParser.parse(try Self.fixtureData("show-merge-diff"))
        #expect(diffs.count == 1)
        let file = try #require(diffs.first)
        #expect(file.oldPath == "src/one.txt")
        #expect(file.newPath == "src/one.txt")
        #expect(file.kind == .modified)
    }

    // MARK: Hand-written cases

    @Test func binaryFileIsDetected() {
        let text = """
        diff --git a/x.png b/x.png
        index 1234567..89abcde 100644
        Binary files a/x.png and b/x.png differ
        """
        let diffs = DiffParser.parse(Data(text.utf8))
        #expect(diffs.count == 1)
        let file = diffs[0]
        #expect(file.isBinary == true)
        #expect(file.oldPath == "x.png")
        #expect(file.newPath == "x.png")
        #expect(file.hunks.isEmpty)
    }

    @Test func noNewlineAtEndOfFileMarksLine() throws {
        let text = """
        diff --git a/a.txt b/a.txt
        index 1234567..89abcde 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -old
        \\ No newline at end of file
        +new
        \\ No newline at end of file
        """
        let diffs = DiffParser.parse(Data(text.utf8))
        let file = try #require(diffs.first)
        let hunk = try #require(file.hunks.first)
        let noNewlineLines = hunk.lines.filter { $0.kind == .noNewline }
        #expect(noNewlineLines.count == 2)
        for line in noNewlineLines {
            #expect(line.oldNumber == nil)
            #expect(line.newNumber == nil)
        }
    }

    @Test func hunkHeaderWithoutCountsDefaultsToOne() throws {
        let text = """
        diff --git a/a.txt b/a.txt
        index 1234567..89abcde 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1 +1 @@
        -old
        +new
        """
        let diffs = DiffParser.parse(Data(text.utf8))
        let file = try #require(diffs.first)
        let hunk = try #require(file.hunks.first)
        #expect(hunk.oldStart == 1)
        #expect(hunk.oldCount == 1)
        #expect(hunk.newStart == 1)
        #expect(hunk.newCount == 1)
    }

    @Test func emptyInputProducesEmptyArray() {
        #expect(DiffParser.parse(Data()).isEmpty)
    }
}
