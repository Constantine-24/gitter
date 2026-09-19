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

    /// Every hunk of `file`, with `lineIDs` defaulting to "all changed lines".
    static func build(
        _ file: FileDiff, _ direction: PatchDirection, _ lineIDs: Set<DiffLine.ID>? = nil
    ) -> Patch? {
        PatchBuilder.patch(
            file: file, hunkIDs: allHunks(file), lineIDs: lineIDs, direction: direction)
    }

    static func text(
        _ file: FileDiff, _ direction: PatchDirection, _ lineIDs: Set<DiffLine.ID>? = nil
    ) -> String? {
        build(file, direction, lineIDs)?.text
    }

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

    // MARK: - 1. Whole hunk, stage

    @Test func wholeHunkStageReproducesTheHunk() throws {
        let file = try Self.file(Self.additionFixture)
        #expect(Self.text(file, .stage) == """
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
        #expect(Self.text(file, .stage, Self.changedIDs(file, "alpha")) == """
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
        #expect(Self.text(file, .stage, Self.changedIDs(file, "alpha")) == """
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
        #expect(Self.text(file, .unstage, Self.changedIDs(file, "alpha")) == """
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
        #expect(Self.text(file, .unstage, Self.changedIDs(file, "alpha")) == """
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
        #expect(Self.text(file, .stage, Self.changedIDs(file, "a", "A")) == """
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
        #expect(Self.text(file, .unstage, Self.changedIDs(file, "a", "A")) == """
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
        #expect(Self.text(file, .stage, Self.changedIDs(file, "x", "z")) == """
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
        #expect(Self.text(file, .unstage, Self.changedIDs(file, "x", "z")) == """
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
        #expect(Self.text(file, .stage, Self.changedIDs(file, "z")) == """
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
        #expect(Self.build(file, .stage, []) == nil)
        #expect(PatchBuilder.patch(file: file, hunkIDs: [], lineIDs: nil, direction: .stage) == nil)
    }

    // MARK: - 8. No-newline markers
    //
    // A marker after line L claims L is the last line of every side L occupies. Rewriting can
    // falsify that, and git then joins two lines without complaining, so the builder
    // re-derives markers rather than copying them. The table below walks
    // {old side lacks a newline} × {new side lacks a newline} × direction × selection.
    // Every expected patch here was applied to a scratch index with
    // `git apply --cached [--reverse]` and the resulting blob compared byte for byte.

    /// old side `keep\nold`, new side `keep\none\ntwo`; neither ends with a newline.
    static let bothNoEOLFixture = """
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

    /// old side `keep\nold` (no newline), new side `keep\none\ntwo\n`.
    static let oldNoEOLFixture = """
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
        """

    /// old side `keep\nold\n`, new side `keep\none\ntwo` (no newline).
    static let newNoEOLFixture = """
        diff --git a/c.txt b/c.txt
        index 1111111..2222222 100644
        --- a/c.txt
        +++ b/c.txt
        @@ -1,2 +1,3 @@
         keep
        -old
        +one
        +two
        \\ No newline at end of file
        """

    /// The marker sits on a trailing context line: both sides really end there.
    static let contextNoEOLFixture = """
        diff --git a/c.txt b/c.txt
        index 1111111..2222222 100644
        --- a/c.txt
        +++ b/c.txt
        @@ -1,2 +1,3 @@
         a
        +b
         tail
        \\ No newline at end of file
        """

    static let cHeader = """
        diff --git a/c.txt b/c.txt
        --- a/c.txt
        +++ b/c.txt
        """

    // --- both sides lack a newline ---

    @Test func bothNoEOLWholeHunkStageIsUnchanged() throws {
        let file = try Self.file(Self.bothNoEOLFixture)
        #expect(Self.text(file, .stage) == Self.cHeader + """

            @@ -1,2 +1,3 @@
             keep
            -old
            \\ No newline at end of file
            +one
            +two
            \\ No newline at end of file

            """)
    }

    /// The converted `-old` still ends the old side, but no longer ends the new side, so it is
    /// split back into `-old` / marker / `+old`. Applying this gives `keep\nold\none\ntwo`;
    /// keeping the marker on a context line would silently yield `keep\noldone\ntwo`.
    @Test func bothNoEOLStagingOnlyAdditionsSplitsTheConvertedLine() throws {
        let file = try Self.file(Self.bothNoEOLFixture)
        #expect(Self.text(file, .stage, Self.changedIDs(file, "one", "two")) == Self.cHeader + """

            @@ -1,2 +1,4 @@
             keep
            -old
            \\ No newline at end of file
            +old
            +one
            +two
            \\ No newline at end of file

            """)
    }

    @Test func bothNoEOLStagingOnlyTheRemovalKeepsItsMarker() throws {
        let file = try Self.file(Self.bothNoEOLFixture)
        #expect(Self.text(file, .stage, Self.changedIDs(file, "old")) == Self.cHeader + """

            @@ -1,2 +1,1 @@
             keep
            -old
            \\ No newline at end of file

            """)
    }

    @Test func bothNoEOLStagingTheRemovalAndOneAddition() throws {
        let file = try Self.file(Self.bothNoEOLFixture)
        #expect(Self.text(file, .stage, Self.changedIDs(file, "old", "one")) == Self.cHeader + """

            @@ -1,2 +1,2 @@
             keep
            -old
            \\ No newline at end of file
            +one

            """)
    }

    @Test func bothNoEOLWholeHunkUnstageIsUnchanged() throws {
        let file = try Self.file(Self.bothNoEOLFixture)
        #expect(Self.text(file, .unstage) == Self.cHeader + """

            @@ -1,2 +1,3 @@
             keep
            -old
            \\ No newline at end of file
            +one
            +two
            \\ No newline at end of file

            """)
    }

    /// `-old` keeps its `-`, but the unselected additions become context after it, so it no
    /// longer ends the old side and its marker must go. The marker on the now-final `two`
    /// binds to both sides, which is true: both end there.
    @Test func bothNoEOLUnstagingOnlyTheRemovalMovesTheMarker() throws {
        let file = try Self.file(Self.bothNoEOLFixture)
        #expect(Self.text(file, .unstage, Self.changedIDs(file, "old")) == Self.cHeader + """

            @@ -1,4 +1,3 @@
             keep
            -old
             one
             two
            \\ No newline at end of file

            """)
    }

    @Test func bothNoEOLUnstagingOneAdditionDropsTheRemovalsMarker() throws {
        let file = try Self.file(Self.bothNoEOLFixture)
        #expect(Self.text(file, .unstage, Self.changedIDs(file, "one")) == Self.cHeader + """

            @@ -1,2 +1,3 @@
             keep
            +one
             two
            \\ No newline at end of file

            """)
    }

    @Test func bothNoEOLUnstagingBothAdditions() throws {
        let file = try Self.file(Self.bothNoEOLFixture)
        #expect(Self.text(file, .unstage, Self.changedIDs(file, "one", "two")) == Self.cHeader + """

            @@ -1,1 +1,3 @@
             keep
            +one
            +two
            \\ No newline at end of file

            """)
    }

    // --- only the old side lacks a newline ---

    @Test func oldNoEOLStagingOnlyAdditionsSplitsButAddsNoTrailingMarker() throws {
        let file = try Self.file(Self.oldNoEOLFixture)
        #expect(Self.text(file, .stage, Self.changedIDs(file, "one", "two")) == Self.cHeader + """

            @@ -1,2 +1,4 @@
             keep
            -old
            \\ No newline at end of file
            +old
            +one
            +two

            """)
    }

    @Test func oldNoEOLUnstagingOnlyTheRemovalDropsEveryMarker() throws {
        let file = try Self.file(Self.oldNoEOLFixture)
        #expect(Self.text(file, .unstage, Self.changedIDs(file, "old")) == Self.cHeader + """

            @@ -1,4 +1,3 @@
             keep
            -old
             one
             two

            """)
    }

    // --- only the new side lacks a newline ---

    /// Mirror of `bothNoEOLStagingOnlyAdditionsSplitsTheConvertedLine`: here the old side does
    /// end with a newline, so the converted line stays plain context and is not split.
    @Test func newNoEOLStagingOnlyAdditionsLeavesTheConvertedLineAlone() throws {
        let file = try Self.file(Self.newNoEOLFixture)
        #expect(Self.text(file, .stage, Self.changedIDs(file, "one", "two")) == Self.cHeader + """

            @@ -1,2 +1,4 @@
             keep
             old
            +one
            +two
            \\ No newline at end of file

            """)
    }

    @Test func newNoEOLStagingOnlyTheRemovalEmitsNoMarker() throws {
        let file = try Self.file(Self.newNoEOLFixture)
        #expect(Self.text(file, .stage, Self.changedIDs(file, "old")) == Self.cHeader + """

            @@ -1,2 +1,1 @@
             keep
            -old

            """)
    }

    @Test func newNoEOLUnstagingOnlyTheRemoval() throws {
        let file = try Self.file(Self.newNoEOLFixture)
        #expect(Self.text(file, .unstage, Self.changedIDs(file, "old")) == Self.cHeader + """

            @@ -1,4 +1,3 @@
             keep
            -old
             one
             two
            \\ No newline at end of file

            """)
    }

    // --- marker on a trailing context line ---

    @Test func markerOnATrailingContextLineIsKept() throws {
        let file = try Self.file(Self.contextNoEOLFixture)
        #expect(Self.text(file, .stage) == Self.cHeader + """

            @@ -1,2 +1,3 @@
             a
            +b
             tail
            \\ No newline at end of file

            """)
    }

    // MARK: - 9. `lineIDs == nil` with a subset of hunks

    @Test func nilLineIDsWithTwoOfThreeHunks() throws {
        let file = try Self.file(Self.threeHunkFixture)
        let chosen = Set([file.hunks[0].id, file.hunks[2].id])
        let patch = PatchBuilder.patch(
            file: file, hunkIDs: chosen, lineIDs: nil, direction: .stage)
        #expect(patch?.text == """
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

    @Test func addedFilePartialUnstageKeepsTheRestAsContext() throws {
        let file = try Self.file(Self.addedFileFixture)
        #expect(file.kind == .added)
        #expect(Self.text(file, .unstage, Self.changedIDs(file, "n1", "n2")) == """
            diff --git a/new.txt b/new.txt
            --- a/new.txt
            +++ b/new.txt
            @@ -1,1 +1,3 @@
            +n1
            +n2
             n3

            """)
    }

    @Test func deletedFilePartialStageGetsANonZeroNewSide() throws {
        let file = try Self.file(Self.deletedFileFixture)
        #expect(file.kind == .deleted)
        #expect(Self.text(file, .stage, Self.changedIDs(file, "g1")) == """
            diff --git a/gone.txt b/gone.txt
            --- a/gone.txt
            +++ b/gone.txt
            @@ -1,3 +1,2 @@
            -g1
             g2
             g3

            """)
    }

    // MARK: - Whole-file selections are refused

    @Test func wholeDeletedFileStageIsRefused() throws {
        let file = try Self.file(Self.deletedFileFixture)
        #expect(
            PatchBuilder.isWholeFileChange(
                file: file, hunkIDs: Self.allHunks(file), lineIDs: nil, direction: .stage))
        #expect(Self.build(file, .stage) == nil)
        // Same when the lines are listed one by one instead of implied by `nil`.
        let every = Self.changedIDs(file, "g1", "g2", "g3")
        #expect(
            PatchBuilder.isWholeFileChange(
                file: file, hunkIDs: Self.allHunks(file), lineIDs: every, direction: .stage))
        #expect(Self.build(file, .stage, every) == nil)
    }

    @Test func wholeAddedFileUnstageIsRefused() throws {
        let file = try Self.file(Self.addedFileFixture)
        #expect(
            PatchBuilder.isWholeFileChange(
                file: file, hunkIDs: Self.allHunks(file), lineIDs: nil, direction: .unstage))
        #expect(Self.build(file, .unstage) == nil)
    }

    @Test func partialAndModifiedSelectionsAreNotWholeFileChanges() throws {
        let deleted = try Self.file(Self.deletedFileFixture)
        #expect(
            PatchBuilder.isWholeFileChange(
                file: deleted, hunkIDs: Self.allHunks(deleted),
                lineIDs: Self.changedIDs(deleted, "g1"), direction: .stage) == false)
        #expect(Self.build(deleted, .stage, Self.changedIDs(deleted, "g1")) != nil)

        let added = try Self.file(Self.addedFileFixture)
        #expect(
            PatchBuilder.isWholeFileChange(
                file: added, hunkIDs: Self.allHunks(added),
                lineIDs: Self.changedIDs(added, "n1"), direction: .unstage) == false)

        // A fully selected *modification* is an ordinary patch, not a whole-file change.
        let modified = try Self.file(Self.additionFixture)
        #expect(
            PatchBuilder.isWholeFileChange(
                file: modified, hunkIDs: Self.allHunks(modified), lineIDs: nil,
                direction: .stage) == false)
        #expect(Self.build(modified, .stage) != nil)

        // Wrong direction for the kind: a deleted file is never unstaged through a patch.
        #expect(
            PatchBuilder.isWholeFileChange(
                file: deleted, hunkIDs: Self.allHunks(deleted), lineIDs: nil,
                direction: .unstage) == false)

        // Not every hunk chosen.
        let three = try Self.file(Self.threeHunkFixture)
        #expect(
            PatchBuilder.isWholeFileChange(
                file: three, hunkIDs: [three.hunks[0].id], lineIDs: nil, direction: .stage)
                == false)
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
        #expect(Self.text(file, .stage) == """
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
        let head = try #require(Self.text(file, .stage)?.split(separator: "\n").prefix(3))
        #expect(head.joined(separator: "\n") == """
            diff --git "a/\\303\\251.txt" "b/\\303\\251.txt"
            --- "a/\\303\\251.txt"
            +++ "b/\\303\\251.txt"
            """)
    }

    @Test func quotedPathWithASpaceGetsBothQuotesAndTab() throws {
        let file = try Self.file(Self.additionFixture, path: "q \"z\" w.txt")
        let head = try #require(Self.text(file, .stage)?.split(separator: "\n").prefix(3))
        #expect(head.joined(separator: "\n") == """
            diff --git "a/q \\\"z\\\" w.txt" "b/q \\\"z\\\" w.txt"
            --- "a/q \\\"z\\\" w.txt"\t
            +++ "b/q \\\"z\\\" w.txt"\t
            """)
    }

    // MARK: - Zero-count edges in a contextless hunk

    @Test func newCountFallingToZeroBacksTheNewStartUp() throws {
        let file = try Self.file(Self.contextlessFixture)
        #expect(Self.text(file, .stage, Self.changedIDs(file, "a", "b")) == """
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
        #expect(Self.text(file, .unstage, Self.changedIDs(file, "A", "B")) == """
            diff --git a/e.txt b/e.txt
            --- a/e.txt
            +++ b/e.txt
            @@ -4,0 +5,2 @@
            +A
            +B

            """)
    }

    // MARK: - needsUnidiffZero

    @Test func contextlessHunkNeedsUnidiffZero() throws {
        let file = try Self.file(Self.contextlessFixture)
        #expect(Self.build(file, .stage)?.needsUnidiffZero == true)
        #expect(Self.build(file, .unstage)?.needsUnidiffZero == true)
    }

    @Test func hunksWithContextDoNotNeedUnidiffZero() throws {
        let file = try Self.file(Self.additionFixture)
        #expect(Self.build(file, .stage)?.needsUnidiffZero == false)
        let twoHunks = try Self.file(Self.twoHunkFixture)
        #expect(Self.build(twoHunks, .unstage)?.needsUnidiffZero == false)
        // The added-file hunk has no context either.
        let added = try Self.file(Self.addedFileFixture)
        #expect(
            Self.build(added, .unstage, Self.changedIDs(added, "n1", "n2"))?.needsUnidiffZero
                == false)
    }
}
