import Foundation
import Testing

@testable import GitCore

/// A file whose bytes are not UTF-8 (Latin-1 here): `DiffLine.text` is a `String`, so the
/// parser decodes such a byte as U+FFFD, and a patch built from it would write `EF BF BD` back.
/// The diff therefore says it was not valid UTF-8, and hunk and line staging (and discard) are
/// not offered for it; file-level staging, which git does from the bytes, stays available.
@Suite struct NonUTF8DiffTests {
    static let latin1Line = Data([0x63, 0x61, 0x66, 0xE9, 0x0A])  // "caf\xE9\n"

    static func diff(_ body: Data) -> Data {
        Data("diff --git a/f.txt b/f.txt\nindex 1234567..89abcde 100644\n--- a/f.txt\n+++ b/f.txt\n@@ -1,2 +1,3 @@\n a\n".utf8)
            + body + Data(" b\n".utf8)
    }

    @Test func aDiffWithALatin1LineIsNotValidUTF8() throws {
        let file = try #require(DiffParser.parse(Self.diff(Data("+".utf8) + Self.latin1Line)).first)
        #expect(file.isValidUTF8 == false)
        // The baseline that makes the flag mean something: the same diff in UTF-8 is valid.
        let utf8 = try #require(DiffParser.parse(Self.diff(Data("+café\n".utf8))).first)
        #expect(utf8.isValidUTF8)
    }

    @Test func onlyTheFileWithTheByteIsMarked() throws {
        let two = Self.diff(Data("+".utf8) + Self.latin1Line)
            + Data("diff --git a/g.txt b/g.txt\n--- a/g.txt\n+++ b/g.txt\n@@ -1 +1 @@\n-x\n+y\n".utf8)
        let files = DiffParser.parse(two)
        #expect(files.map(\.isValidUTF8) == [false, true])
    }

    @Test func noPartialStagingOrPatchForANonUTF8Diff() throws {
        let file = try #require(DiffParser.parse(Self.diff(Data("+".utf8) + Self.latin1Line)).first)
        #expect(file.kind == .modified && !file.hunks.isEmpty)
        #expect(PatchBuilder.supportsPartial(file, direction: .stage) == false)
        #expect(PatchBuilder.supportsPartial(file, direction: .unstage) == false)
        #expect(PatchBuilder.patch(
            file: file, hunkIDs: everyHunkID(file), lineIDs: nil, direction: .stage) == nil)
        #expect(PatchBuilder.patch(
            file: file, hunkIDs: everyHunkID(file), lineIDs: nil, direction: .unstage) == nil)
    }

    /// The bug this closes, end to end: before, the added Latin-1 line reached the index as
    /// `caf\xEF\xBF\xBD`. Now no patch is built, and a whole-file `git add` stages the bytes.
    @Test func aLatin1FileIsStagedWholeAndByteExact() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f.txt", "a\nb\n")
        try await repo.commitAll("root")
        let bytes = Data("a\n".utf8) + Self.latin1Line + Data("b\n".utf8)
        try bytes.write(to: repo.root.appendingPathComponent("f.txt"))

        let file = try await loadDiff(repo, "f.txt")
        #expect(file.isValidUTF8 == false)
        #expect(PatchBuilder.supportsPartial(file, direction: .stage) == false)
        #expect(PatchBuilder.patch(
            file: file, hunkIDs: everyHunkID(file), lineIDs: nil, direction: .stage) == nil)

        try await CLIGitBackend().stage(paths: ["f.txt"], at: repo.root)
        #expect(try await repo.indexContent(of: "f.txt") == bytes)
        let staged = try await loadDiff(repo, "f.txt", staged: true)
        #expect(staged.isValidUTF8 == false)
        #expect(PatchBuilder.supportsPartial(staged, direction: .unstage) == false)
    }
}
