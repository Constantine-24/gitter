import Foundation
import Testing

@testable import GitCore

@Suite struct PatchBuilderTests {

    // MARK: - Helpers

    /// Parses hand-written diff text so the fixtures read like real `git diff` output.
    static func file(_ text: String) throws -> FileDiff {
        try #require(DiffParser.parse(Data((text + "\n").utf8)).first)
    }

    /// IDs of the changed (`+`/`-`) lines whose text matches one of `texts`.
    static func changedIDs(_ file: FileDiff, _ texts: String...) -> Set<DiffLine.ID> {
        Set(
            file.hunks.flatMap(\.lines)
                .filter { ($0.kind == .added || $0.kind == .removed) && texts.contains($0.text) }
                .map(\.id)
        )
    }

    static func allHunks(_ file: FileDiff) -> Set<Hunk.ID> { Set(file.hunks.map(\.id)) }

    // MARK: - Fixtures

    static let additionFixture = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,4 +1,6 @@ fn main
         one
        +alpha
        +beta
         two
         three
         four
        """

    static let removalFixture = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,5 +1,3 @@ fn main
         one
        -alpha
        -beta
         two
         three
        """

    static let replaceFixture = """
        diff --git a/a.txt b/a.txt
        index 1111111..2222222 100644
        --- a/a.txt
        +++ b/a.txt
        @@ -1,4 +1,4 @@ ctx
         head
        -a
        -b
        +A
        +B
         tail
        """

    static let twoHunkFixture = """
        diff --git a/b.txt b/b.txt
        index 1111111..2222222 100644
        --- a/b.txt
        +++ b/b.txt
        @@ -1,3 +1,5 @@ first
         one
        +x
        +y
         two
         three
        @@ -10,3 +12,4 @@ second
         ten
        +z
         eleven
         twelve
        """

    static let threeHunkFixture = """
        diff --git a/d.txt b/d.txt
        index 1111111..2222222 100644
        --- a/d.txt
        +++ b/d.txt
        @@ -1,3 +1,4 @@ h1
         one
        +a1
         two
         three
        @@ -10,3 +11,4 @@ h2
         ten
        +a2
         eleven
         twelve
        @@ -20,3 +22,4 @@ h3
         twenty
        +a3
         twentyone
         twentytwo
        """

    static let noNewlineFixture = """
        diff --git a/c.txt b/c.txt
        index 1111111..2222222 100644
        --- a/c.txt
        +++ b/c.txt
        @@ -1,2 +1,3 @@
         keep
        -old
        \\ No newline at end of file
        +one
        +two
        \\ No newline at end of file
        """

    static let addedFileFixture = """
        diff --git a/new.txt b/new.txt
        new file mode 100644
        index 0000000..1111111
        --- /dev/null
        +++ b/new.txt
        @@ -0,0 +1,3 @@
        +n1
        +n2
        +n3
        """

    static let deletedFileFixture = """
        diff --git a/gone.txt b/gone.txt
        deleted file mode 100644
        index 1111111..0000000
        --- a/gone.txt
        +++ /dev/null
        @@ -1,3 +0,0 @@
        -g1
        -g2
        -g3
        """

    // MARK: - 1. Whole hunk, stage

    @Test func wholeHunkStageReproducesTheHunk() throws {
        let file = try Self.file(Self.additionFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file), lineIDs: nil, direction: .stage)
        #expect(patch == """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1,4 +1,6 @@ fn main
             one
            +alpha
            +beta
             two
             three
             four

            """)
    }

    // MARK: - 2. One of two `+` lines, stage

    @Test func oneOfTwoAddedLinesStaged() throws {
        let file = try Self.file(Self.additionFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "alpha"), direction: .stage)
        #expect(patch == """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1,4 +1,5 @@ fn main
             one
            +alpha
             two
             three
             four

            """)
    }

    // MARK: - 3. One of two `-` lines, stage

    @Test func oneOfTwoRemovedLinesStaged() throws {
        let file = try Self.file(Self.removalFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "alpha"), direction: .stage)
        #expect(patch == """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1,5 +1,4 @@ fn main
             one
            -alpha
             beta
             two
             three

            """)
    }

    // MARK: - 4. The same two cases, unstage

    @Test func oneOfTwoAddedLinesUnstaged() throws {
        let file = try Self.file(Self.additionFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "alpha"), direction: .unstage)
        #expect(patch == """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1,5 +1,6 @@ fn main
             one
            +alpha
             beta
             two
             three
             four

            """)
    }

    @Test func oneOfTwoRemovedLinesUnstaged() throws {
        let file = try Self.file(Self.removalFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "alpha"), direction: .unstage)
        #expect(patch == """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1,4 +1,3 @@ fn main
             one
            -alpha
             two
             three

            """)
    }

    // MARK: - 5. Mixed replace, one pair selected

    @Test func mixedReplacePartialStage() throws {
        let file = try Self.file(Self.replaceFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "a", "A"), direction: .stage)
        #expect(patch == """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1,4 +1,4 @@ ctx
             head
            -a
             b
            +A
             tail

            """)
    }

    @Test func mixedReplacePartialUnstage() throws {
        let file = try Self.file(Self.replaceFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "a", "A"), direction: .unstage)
        #expect(patch == """
            diff --git a/a.txt b/a.txt
            --- a/a.txt
            +++ b/a.txt
            @@ -1,4 +1,4 @@ ctx
             head
            -a
            +A
             B
             tail

            """)
    }

    // MARK: - 6. Two hunks, running delta

    @Test func secondHunkStartReflectsDeltaWhenStaging() throws {
        let file = try Self.file(Self.twoHunkFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "x", "z"), direction: .stage)
        #expect(patch == """
            diff --git a/b.txt b/b.txt
            --- a/b.txt
            +++ b/b.txt
            @@ -1,3 +1,4 @@ first
             one
            +x
             two
             three
            @@ -10,3 +11,4 @@ second
             ten
            +z
             eleven
             twelve

            """)
    }

    @Test func secondHunkStartReflectsDeltaWhenUnstaging() throws {
        let file = try Self.file(Self.twoHunkFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "x", "z"), direction: .unstage)
        #expect(patch == """
            diff --git a/b.txt b/b.txt
            --- a/b.txt
            +++ b/b.txt
            @@ -1,4 +1,5 @@ first
             one
            +x
             y
             two
             three
            @@ -11,3 +12,4 @@ second
             ten
            +z
             eleven
             twelve

            """)
    }

    // MARK: - 7. Empty selections

    @Test func hunkWithNothingSelectedIsOmittedAndContributesNoDelta() throws {
        let file = try Self.file(Self.twoHunkFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "z"), direction: .stage)
        #expect(patch == """
            diff --git a/b.txt b/b.txt
            --- a/b.txt
            +++ b/b.txt
            @@ -10,3 +10,4 @@ second
             ten
            +z
             eleven
             twelve

            """)
    }

    @Test func nothingSelectedAtAllReturnsNil() throws {
        let file = try Self.file(Self.twoHunkFixture)
        #expect(
            PatchBuilder.patch(
                file: file, hunkIDs: Self.allHunks(file), lineIDs: [], direction: .stage) == nil)
        #expect(
            PatchBuilder.patch(file: file, hunkIDs: [], lineIDs: nil, direction: .stage) == nil)
    }

    // MARK: - 8. No-newline markers

    @Test func noNewlineMarkersSurviveAWholeHunk() throws {
        let file = try Self.file(Self.noNewlineFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file), lineIDs: nil, direction: .stage)
        #expect(patch == """
            diff --git a/c.txt b/c.txt
            --- a/c.txt
            +++ b/c.txt
            @@ -1,2 +1,3 @@
             keep
            -old
            \\ No newline at end of file
            +one
            +two
            \\ No newline at end of file

            """)
    }

    @Test func noNewlineMarkerIsDroppedWithItsAddedLine() throws {
        let file = try Self.file(Self.noNewlineFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "old", "one"), direction: .stage)
        #expect(patch == """
            diff --git a/c.txt b/c.txt
            --- a/c.txt
            +++ b/c.txt
            @@ -1,2 +1,2 @@
             keep
            -old
            \\ No newline at end of file
            +one

            """)
    }

    @Test func noNewlineMarkerSurvivesARemovedLineTurnedIntoContext() throws {
        let file = try Self.file(Self.noNewlineFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "one", "two"), direction: .stage)
        #expect(patch == """
            diff --git a/c.txt b/c.txt
            --- a/c.txt
            +++ b/c.txt
            @@ -1,2 +1,4 @@
             keep
             old
            \\ No newline at end of file
            +one
            +two
            \\ No newline at end of file

            """)
    }

    @Test func noNewlineMarkerIsDroppedWithItsRemovedLineWhenUnstaging() throws {
        let file = try Self.file(Self.noNewlineFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "one"), direction: .unstage)
        #expect(patch == """
            diff --git a/c.txt b/c.txt
            --- a/c.txt
            +++ b/c.txt
            @@ -1,2 +1,3 @@
             keep
            +one
             two
            \\ No newline at end of file

            """)
    }

    // MARK: - 9. `lineIDs == nil` with a subset of hunks

    @Test func nilLineIDsWithTwoOfThreeHunks() throws {
        let file = try Self.file(Self.threeHunkFixture)
        let chosen = Set([file.hunks[0].id, file.hunks[2].id])
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: chosen, lineIDs: nil, direction: .stage)
        #expect(patch == """
            diff --git a/d.txt b/d.txt
            --- a/d.txt
            +++ b/d.txt
            @@ -1,3 +1,4 @@ h1
             one
            +a1
             two
             three
            @@ -20,3 +21,4 @@ h3
             twenty
            +a3
             twentyone
             twentytwo

            """)
    }

    // MARK: - 10. Added and deleted files get a modification header

    @Test func addedFileUnstagesAsAModification() throws {
        let file = try Self.file(Self.addedFileFixture)
        #expect(file.kind == .added)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file), lineIDs: nil, direction: .unstage)
        #expect(patch == """
            diff --git a/new.txt b/new.txt
            --- a/new.txt
            +++ b/new.txt
            @@ -0,0 +1,3 @@
            +n1
            +n2
            +n3

            """)
    }

    @Test func addedFilePartialUnstageKeepsTheRestAsContext() throws {
        let file = try Self.file(Self.addedFileFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "n1", "n2"), direction: .unstage)
        #expect(patch == """
            diff --git a/new.txt b/new.txt
            --- a/new.txt
            +++ b/new.txt
            @@ -1,1 +1,3 @@
            +n1
            +n2
             n3

            """)
    }

    // MARK: - Zero-count edges in a contextless hunk

    /// Both sides of this hunk can collapse to zero, unlike a hunk that carries context.
    static let contextlessFixture = """
        diff --git a/e.txt b/e.txt
        index 1111111..2222222 100644
        --- a/e.txt
        +++ b/e.txt
        @@ -5,2 +5,2 @@
        -a
        -b
        +A
        +B
        """

    @Test func newCountFallingToZeroBacksTheNewStartUp() throws {
        let file = try Self.file(Self.contextlessFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "a", "b"), direction: .stage)
        #expect(patch == """
            diff --git a/e.txt b/e.txt
            --- a/e.txt
            +++ b/e.txt
            @@ -5,2 +4,0 @@
            -a
            -b

            """)
    }

    @Test func oldCountFallingToZeroBacksTheOldStartUp() throws {
        let file = try Self.file(Self.contextlessFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "A", "B"), direction: .unstage)
        #expect(patch == """
            diff --git a/e.txt b/e.txt
            --- a/e.txt
            +++ b/e.txt
            @@ -4,0 +5,2 @@
            +A
            +B

            """)
    }

    @Test func deletedFileStagesAsAModification() throws {
        let file = try Self.file(Self.deletedFileFixture)
        #expect(file.kind == .deleted)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file), lineIDs: nil, direction: .stage)
        #expect(patch == """
            diff --git a/gone.txt b/gone.txt
            --- a/gone.txt
            +++ b/gone.txt
            @@ -1,3 +0,0 @@
            -g1
            -g2
            -g3

            """)
    }

    @Test func deletedFilePartialStageGetsANonZeroNewSide() throws {
        let file = try Self.file(Self.deletedFileFixture)
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file),
            lineIDs: Self.changedIDs(file, "g1"), direction: .stage)
        #expect(patch == """
            diff --git a/gone.txt b/gone.txt
            --- a/gone.txt
            +++ b/gone.txt
            @@ -1,3 +1,2 @@
            -g1
             g2
             g3

            """)
    }

    // MARK: - 11. Eligibility

    @Test(arguments: [
        (FileDiffKind.modified, true, true),
        (FileDiffKind.added, false, true),
        (FileDiffKind.deleted, true, false),
        (FileDiffKind.renamed, false, false),
        (FileDiffKind.copied, false, false),
    ])
    func eligibilityByKind(kind: FileDiffKind, stage: Bool, unstage: Bool) throws {
        let hunks = try Self.file(Self.additionFixture).hunks
        let file = FileDiff(
            oldPath: "a.txt", newPath: "a.txt", kind: kind, isBinary: false, hunks: hunks)
        #expect(PatchBuilder.supportsPartial(file, direction: .stage) == stage)
        #expect(PatchBuilder.supportsPartial(file, direction: .unstage) == unstage)
    }

    @Test func binaryAndHunklessFilesAreNeverEligible() throws {
        let hunks = try Self.file(Self.additionFixture).hunks
        let binary = FileDiff(
            oldPath: "a.png", newPath: "a.png", kind: .modified, isBinary: true, hunks: hunks)
        let hunkless = FileDiff(
            oldPath: "a.txt", newPath: "a.txt", kind: .modified, isBinary: false, hunks: [])
        for file in [binary, hunkless] {
            #expect(PatchBuilder.supportsPartial(file, direction: .stage) == false)
            #expect(PatchBuilder.supportsPartial(file, direction: .unstage) == false)
        }
    }

    // MARK: - 12. Path quoting

    /// The fixtures reuse a parsed hunk with a substituted path: `DiffParser` would otherwise
    /// carry git's trailing TAB back into the path it reports.
    static func file(_ text: String, path: String) throws -> FileDiff {
        let parsed = try file(text)
        return FileDiff(
            oldPath: path, newPath: path, kind: .modified, isBinary: false, hunks: parsed.hunks)
    }

    @Test func pathWithASpaceGetsATrailingTab() throws {
        let file = try Self.file(Self.additionFixture, path: "my file.txt")
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file), lineIDs: nil, direction: .stage)
        #expect(patch == """
            diff --git a/my file.txt b/my file.txt
            --- a/my file.txt\t
            +++ b/my file.txt\t
            @@ -1,4 +1,6 @@ fn main
             one
            +alpha
            +beta
             two
             three
             four

            """)
    }

    @Test func nonASCIIPathIsCQuoted() throws {
        let file = try Self.file(Self.additionFixture, path: "é.txt")
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file), lineIDs: nil, direction: .stage)
        let head = try #require(patch?.split(separator: "\n").prefix(3).joined(separator: "\n"))
        #expect(head == """
            diff --git "a/\\303\\251.txt" "b/\\303\\251.txt"
            --- "a/\\303\\251.txt"
            +++ "b/\\303\\251.txt"
            """)
    }

    @Test func quotedPathWithASpaceGetsBothQuotesAndTab() throws {
        let file = try Self.file(Self.additionFixture, path: "q \"z\" w.txt")
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: Self.allHunks(file), lineIDs: nil, direction: .stage)
        let head = try #require(patch?.split(separator: "\n").prefix(3).joined(separator: "\n"))
        #expect(head == """
            diff --git "a/q \\\"z\\\" w.txt" "b/q \\\"z\\\" w.txt"
            --- "a/q \\\"z\\\" w.txt"\t
            +++ "b/q \\\"z\\\" w.txt"\t
            """)
    }
}
