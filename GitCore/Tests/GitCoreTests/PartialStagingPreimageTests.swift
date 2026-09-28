import Foundation
import Testing

@testable import GitCore

/// A patch built from a diff is applied only to the exact index (and, when unstaging, the exact
/// HEAD) that diff was loaded from.
///
/// A hunk WITH context can apply at an offset: git looks for its context elsewhere and takes
/// the first place it matches, with no option to forbid that. Reproduced by the review of
/// inserted fix 2: two blocks of six `}` lines, `X` added inside block 1, a terminal `git add`
/// that changes one `}` in block 1 — and `git apply --cached` staged `X` into BLOCK 2
/// ("Hunk #1 succeeded at 9 (offset 7 lines)"). So `applyToIndex` now compares the index entry
/// with the blob the diff was built from before it applies anything, and refuses through the
/// same `GitError.commandFailed` → "The file changed since this diff was loaded…" path, with
/// the index, HEAD, refs and worktree left exactly as they were.
@Suite struct PartialStagingPreimageTests {

    static let path = "src/braces.txt"

    /// `a`, six `}`, `b`, six `}`, `c`: block 1 is lines 2–7, block 2 lines 9–14.
    static func blocks(_ edit: (inout [String]) -> Void = { _ in }) -> String {
        var lines = ["a"] + Array(repeating: "}", count: 6) + ["b"]
            + Array(repeating: "}", count: 6) + ["c"]
        edit(&lines)
        return lines.map { $0 + "\n" }.joined()
    }

    /// `X` after the third `}` of block 1 (after line 4).
    static let xInBlock1 = blocks { $0.insert("X", at: 4) }
    /// `X` after the third `}` of block 2 (after line 11).
    static let xInBlock2 = blocks { $0.insert("X", at: 11) }

    // MARK: - Stage

    @Test func aStaleHunkWithContextIsRefusedRatherThanStagedIntoTheOtherBlock() async throws {
        let repo = try await Self.makeRepo(head: Self.blocks(), worktree: Self.xInBlock1)
        defer { repo.cleanUp() }
        let file = try await loadDiff(repo, Self.path)
        let patch = try Self.patch(file, .stage)
        #expect(!patch.hasContextFreeHunk, "\(patch.text)")

        // A terminal changes one `}` of block 1 in the index; the worktree stays as it was.
        try await Self.rewriteIndex(repo, to: Self.blocks { $0[2] = "};" })

        try await Self.expectRefused(
            patch, direction: .stage, in: repo,
            onOldCode: Self.blocks { $0[2] = "};"; $0.insert("X", at: 11) })
    }

    @Test func theSameHunkOnAFreshIndexStagesXIntoBlock1() async throws {
        let repo = try await Self.makeRepo(head: Self.blocks(), worktree: Self.xInBlock1)
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, Self.path)

        try await applySelection(repo, file, direction: .stage)

        #expect(try await indexText(repo, Self.path) == Self.xInBlock1)
        assertWorktreeUnchanged(repo, since: before)
    }

    /// The rule is exactness, not "the context still happens to match": an index that changed
    /// anywhere is not the one the diff showed, and the refresh that follows the refusal shows
    /// the user the real one.
    @Test func anIndexChangedOutsideTheHunkIsRefusedToo() async throws {
        let repo = try await Self.makeRepo(head: Self.blocks(), worktree: Self.xInBlock1)
        defer { repo.cleanUp() }
        let patch = try Self.patch(try await loadDiff(repo, Self.path), .stage)
        try await Self.rewriteIndex(repo, to: Self.blocks { $0[0] = "A" })

        try await Self.expectRefused(
            patch, direction: .stage, in: repo,
            onOldCode: Self.blocks { $0[0] = "A"; $0.insert("X", at: 4) })
    }

    /// A deletion in the worktree, staged line by line.
    @Test func partOfADeletionStagesOnAFreshIndexAndIsRefusedOnAStaleOne() async throws {
        for stale in [false, true] {
            let repo = try await Self.makeRepo(head: "a\nb\nc\n", worktree: nil)
            defer { repo.cleanUp() }
            let file = try await loadDiff(repo, Self.path)
            #expect(file.kind == .deleted)
            let patch = try Self.patch(file, .stage, lines: changedLineIDs(file, "b"))
            guard stale else {
                try await CLIGitBackend().applyToIndex(patch: patch, reverse: false, at: repo.root)
                #expect(try await indexText(repo, Self.path) == "a\nc\n")
                continue
            }
            try await Self.rewriteIndex(repo, to: "a\nb\nc\nd\n")
            try await Self.expectRefused(patch, direction: .stage, in: repo, onOldCode: "a\nc\nd\n")
        }
    }

    // MARK: - Unstage

    /// The staged `X` is committed in a terminal: HEAD now equals the index, and the old
    /// "unstage X" would take X out of the index — staging its DELETION from HEAD.
    @Test func unstagingAfterATerminalCommitIsRefused() async throws {
        let repo = try await Self.makeRepo(
            head: Self.blocks(), staged: Self.xInBlock1, worktree: Self.xInBlock1)
        defer { repo.cleanUp() }
        let patch = try Self.patch(try await loadDiff(repo, Self.path, staged: true), .unstage)
        try await repo.git(["commit", "-q", "-m", "committed in a terminal"])

        try await Self.expectRefused(
            patch, direction: .unstage, in: repo, onOldCode: Self.blocks())
    }

    /// HEAD has an `X` in block 2, and `X` is staged in block 1 too. After a terminal changes
    /// one `}` of block 1 in the index, the reverse patch's context matches only block 2, and
    /// the old apply took the COMMITTED `X` out of the index.
    @Test func aStaleUnstageIsRefusedRatherThanRemovingTheOtherBlocksLine() async throws {
        let both = Self.blocks { $0.insert("X", at: 11); $0.insert("X", at: 4) }
        let repo = try await Self.makeRepo(head: Self.xInBlock2, staged: both, worktree: both)
        defer { repo.cleanUp() }
        let file = try await loadDiff(repo, Self.path, staged: true)
        #expect(file.hunks.count == 1)
        let patch = try Self.patch(file, .unstage)
        #expect(!patch.hasContextFreeHunk, "\(patch.text)")
        let stale = Self.blocks { $0.insert("X", at: 11); $0.insert("X", at: 4); $0[2] = "};" }
        try await Self.rewriteIndex(repo, to: stale)

        try await Self.expectRefused(
            patch, direction: .unstage, in: repo,
            onOldCode: Self.blocks { $0.insert("X", at: 4); $0[2] = "};" })
    }

    /// A new file staged in part: fresh, the rest stays staged; committed in a terminal since,
    /// the old unstage staged the deletion of the line from HEAD.
    @Test func partOfANewFileUnstagesOnAFreshIndexAndIsRefusedAfterACommit() async throws {
        for stale in [false, true] {
            let repo = try await TestRepo.makeEmpty()
            defer { repo.cleanUp() }
            try repo.write("other.txt", "o\n")
            try await repo.commitAll("root")
            try repo.write(Self.path, "x\ny\n")
            try await repo.git(["add", "--", Self.path])
            let file = try await loadDiff(repo, Self.path, staged: true)
            #expect(file.kind == .added)
            let patch = try Self.patch(file, .unstage, lines: changedLineIDs(file, "y"))
            guard stale else {
                try await CLIGitBackend().applyToIndex(patch: patch, reverse: true, at: repo.root)
                #expect(try await indexText(repo, Self.path) == "x\n")
                continue
            }
            try await repo.git(["commit", "-q", "-m", "committed in a terminal"])
            try await Self.expectRefused(patch, direction: .unstage, in: repo, onOldCode: "x\n")
        }
    }

    /// With no commit yet, HEAD's side is the empty tree: the check's `diff --cached` still
    /// answers (zeros → the index blob), and a partial unstage goes through.
    @Test func partOfANewFileUnstagesInARepositoryWithNoCommits() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write(Self.path, "x\ny\n")
        try await repo.git(["add", "--", Self.path])
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, Self.path, staged: true)
        #expect(file.oldBlob == String(repeating: "0", count: 40))

        try await applySelection(repo, file, direction: .unstage, lines: changedLineIDs(file, "y"))

        #expect(try await indexText(repo, Self.path) == "x\n")
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - What the check needs from the diff

    /// A patch whose diff carried no full blob id (here, git's default abbreviated `index`
    /// line) cannot be checked, so it is refused rather than applied unverified.
    @Test func aPatchFromADiffWithAbbreviatedBlobIdsIsRefused() async throws {
        let repo = try await Self.makeRepo(head: Self.blocks(), worktree: Self.xInBlock1)
        defer { repo.cleanUp() }
        let data = try await repo.git(["diff", "--no-color", "-U3", "--", Self.path])
        let file = try #require(DiffParser.parse(data).first)
        let patch = try Self.patch(file, .stage)

        try await Self.expectRefused(patch, direction: .stage, in: repo, onOldCode: Self.xInBlock1)
    }

    /// Mode lines: a partial stage patches content only. The index keeps its mode, as before.
    @Test func aHunkOfAFileWhoseModeAlsoChangedStagesContentOnly() async throws {
        let base = (1...12).map { "l\($0)\n" }
        let repo = try await Self.makeRepo(head: base.joined(), worktree: nil)
        defer { repo.cleanUp() }
        var edited = base
        edited[1] = "A\n"
        edited[10] = "B\n"
        try repo.write(Self.path, edited.joined())
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: repo.root.appendingPathComponent(Self.path).path)
        let file = try await loadDiff(repo, Self.path)
        #expect(file.hunks.count == 2)

        try await applySelection(
            repo, file, direction: .stage, hunks: [try hunkID(file, containing: "A")])

        var expected = base
        expected[1] = "A\n"
        #expect(try await indexText(repo, Self.path) == expected.joined())
        let entry = String(decoding: try await repo.git(["ls-files", "-s", "--", Self.path]), as: UTF8.self)
        #expect(entry.hasPrefix("100644 "), "\(entry)")
    }

    /// Negative control for `expectRefused`: on a fresh index the patch applies, and the
    /// helper has to say so — or every refusal above could be vacuous.
    @Test func expectRefusedFailsWhenThePatchApplies() async throws {
        let repo = try await Self.makeRepo(head: Self.blocks(), worktree: Self.xInBlock1)
        defer { repo.cleanUp() }
        let patch = try Self.patch(try await loadDiff(repo, Self.path), .stage)

        await withKnownIssue("the patch really applies: nothing was refused and the index changed") {
            try await Self.expectRefused(patch, direction: .stage, in: repo, onOldCode: Self.xInBlock1)
        }
        #expect(try await indexText(repo, Self.path) == Self.xInBlock1)
    }

    // MARK: - Support

    /// HEAD holds `head`, the index `staged` (or `head`), the worktree `worktree` (nil: the
    /// file is deleted from the worktree).
    static func makeRepo(head: String, staged: String? = nil, worktree: String?) async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        // Another file, so the worktree baseline is never empty (a deleted `path` leaves it).
        try repo.write("other.txt", "o\n")
        try repo.write(path, head)
        try await repo.commitAll("root")
        if let staged {
            try repo.write(path, staged)
            try await repo.git(["add", "--", path])
        }
        if let worktree {
            try repo.write(path, worktree)
        } else {
            try FileManager.default.removeItem(at: repo.root.appendingPathComponent(path))
        }
        return repo
    }

    static func patch(
        _ file: FileDiff, _ direction: PatchDirection, lines: Set<DiffLine.ID>? = nil
    ) throws -> Patch {
        try #require(
            PatchBuilder.patch(
                file: file, hunkIDs: everyHunkID(file), lineIDs: lines, direction: direction))
    }

    /// Stages `content` the way a terminal would, then puts the worktree back as it was
    /// (missing included), so only the index has moved on from the diff.
    static func rewriteIndex(_ repo: TestRepo, to content: String) async throws {
        let url = repo.root.appendingPathComponent(path)
        let worktree = try? Data(contentsOf: url)
        try repo.write(path, content)
        try await repo.git(["add", "--", path])
        if let worktree {
            try worktree.write(to: url)
        } else {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// `applyToIndex` throws `commandFailed` saying the patch does not apply, and nothing moves.
    /// `onOldCode` is what the index became before the check existed, for the failure message.
    static func expectRefused(
        _ patch: Patch, direction: PatchDirection, in repo: TestRepo, onOldCode: String,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let before = worktreeSnapshot(repo)
        let state = try await RepoState.capture(repo)
        let indexBefore = try await repo.indexContent(of: path)
        #expect(!state.index.isEmpty && !state.head.isEmpty, sourceLocation: sourceLocation)

        let error = await #expect(throws: GitError.self, sourceLocation: sourceLocation) {
            try await CLIGitBackend().applyToIndex(
                patch: patch, reverse: direction == .unstage, at: repo.root)
        }
        if let error {
            guard case .commandFailed(_, let stderr) = error else {
                Issue.record("expected commandFailed, got \(error)", sourceLocation: sourceLocation)
                return
            }
            // What the app turns into "The file changed since this diff was loaded…".
            #expect(stderr.contains("patch does not apply"), "\(stderr)", sourceLocation: sourceLocation)
        }

        let indexAfter = try await repo.indexContent(of: path)
        #expect(
            indexAfter == indexBefore,
            """
            applied to a stale index: \(String(decoding: indexBefore, as: UTF8.self).debugDescription) \
            → \(String(decoding: indexAfter, as: UTF8.self).debugDescription) \
            (before the check: \(onOldCode.debugDescription))
            """,
            sourceLocation: sourceLocation)
        try await assertRepoUnchanged(repo, since: state, worktree: before, sourceLocation: sourceLocation)
    }
}

/// The blob ids `DiffParser` reads off a diff's `index` line, for every header shape git
/// writes (measured on git 2.54 with `diff --cached -M --full-index`).
@Suite struct DiffBlobIDTests {
    static let a = String(repeating: "a", count: 40)
    static let b = String(repeating: "b", count: 40)
    static let zero = String(repeating: "0", count: 40)

    static func file(_ header: String) throws -> FileDiff {
        try #require(DiffParser.parse(Data((header + "@@ -1 +1 @@\n-x\n+y\n").utf8)).first)
    }

    @Test func aModificationCarriesBothIdsWithOrWithoutTheModeAfterThem() throws {
        let plain = try Self.file("diff --git a/f b/f\nindex \(Self.a)..\(Self.b) 100644\n--- a/f\n+++ b/f\n")
        #expect(plain.oldBlob == Self.a && plain.newBlob == Self.b)
        let modeChanged = try Self.file(
            "diff --git a/f b/f\nold mode 100644\nnew mode 100755\nindex \(Self.a)..\(Self.b)\n--- a/f\n+++ b/f\n")
        #expect(modeChanged.oldBlob == Self.a && modeChanged.newBlob == Self.b)
    }

    @Test func aMissingSideIsAllZeros() throws {
        let added = try Self.file(
            "diff --git a/f b/f\nnew file mode 100644\nindex \(Self.zero)..\(Self.b)\n--- /dev/null\n+++ b/f\n")
        #expect(added.kind == .added && added.oldBlob == Self.zero && added.newBlob == Self.b)
        let deleted = try Self.file(
            "diff --git a/f b/f\ndeleted file mode 100644\nindex \(Self.a)..\(Self.zero)\n--- a/f\n+++ /dev/null\n")
        #expect(deleted.kind == .deleted && deleted.oldBlob == Self.a && deleted.newBlob == Self.zero)
    }

    @Test func aRenameWithChangesCarriesIdsAndAPureRenameOrAModeOnlyChangeNone() throws {
        let renamed = try Self.file(
            "diff --git a/r b/r2\nsimilarity index 87%\nrename from r\nrename to r2\nindex \(Self.a)..\(Self.b) 100644\n--- a/r\n+++ b/r2\n")
        #expect(renamed.kind == .renamed && renamed.oldBlob == Self.a && renamed.newBlob == Self.b)
        let pure = try #require(
            DiffParser.parse(Data("diff --git a/p b/p2\nsimilarity index 100%\nrename from p\nrename to p2\n".utf8)).first)
        #expect(pure.oldBlob == nil && pure.newBlob == nil)
        let modeOnly = try #require(
            DiffParser.parse(Data("diff --git a/m b/m\nold mode 100644\nnew mode 100755\n".utf8)).first)
        #expect(modeOnly.oldBlob == nil && modeOnly.newBlob == nil)
    }

    @Test func abbreviatedIdsAreReadAsPrintedAndAHunkLineIsNeverTakenForOne() throws {
        let short = try Self.file("diff --git a/f b/f\nindex 1234567..89abcde 100644\n--- a/f\n+++ b/f\n")
        #expect(short.oldBlob == "1234567" && short.newBlob == "89abcde")
        #expect(!CLIGitBackend.isFullObjectID("1234567"))
        let text = "diff --git a/f b/f\nindex \(Self.a)..\(Self.b) 100644\n--- a/f\n+++ b/f\n@@ -1 +1 @@\n-x\n+y\n"
            + "index \(Self.b)..\(Self.a)\n"
        let file = try #require(DiffParser.parse(Data(text.utf8)).first)
        #expect(file.oldBlob == Self.a && file.newBlob == Self.b)
    }

    /// Through the real pipeline: the diffs the app loads name the full ids of both sides.
    @Test func workingCopyDiffsCarryFullIdsOfTheIndexAndTheOtherSide() async throws {
        let repo = try await PartialStagingPreimageTests.makeRepo(
            head: "a\n", staged: "a\nb\n", worktree: "a\nb\nc\n")
        defer { repo.cleanUp() }
        let path = PartialStagingPreimageTests.path
        func id(_ rev: String) async throws -> String { try await repo.revParse(rev) }

        let unstaged = try await loadDiff(repo, path)
        #expect(unstaged.oldBlob == (try await id(":" + path)))
        let worktreeID = String(
            decoding: try await repo.git(["hash-object", "--", path]), as: UTF8.self
        ).trimmingCharacters(in: .newlines)
        #expect(unstaged.newBlob == worktreeID)
        let staged = try await loadDiff(repo, path, staged: true)
        #expect(staged.oldBlob == (try await id("HEAD:" + path)))
        #expect(staged.newBlob == (try await id(":" + path)))
    }

    @Test func theCheckReadsGitsRecordsByteForByte() {
        #expect(CLIGitBackend.isFullObjectID(Self.a))
        #expect(CLIGitBackend.isFullObjectID(Self.zero))
        #expect(CLIGitBackend.isFullObjectID(String(repeating: "c", count: 64)))
        #expect(!CLIGitBackend.isFullObjectID(String(repeating: "A", count: 40)))
        #expect(!CLIGitBackend.isFullObjectID(String(repeating: "a", count: 41)))

        let entries = CLIGitBackend.indexEntries(
            Data("100644 \(Self.a) 0\tsp ace\tx\0100644 \(Self.b) 2\tu\0".utf8))
        #expect(entries.count == 2)
        #expect(entries[0].blob == Self.a && entries[0].stage == "0" && entries[0].path == Array("sp ace\tx".utf8))
        #expect(entries[1].stage == "2")

        let raw = CLIGitBackend.rawDiffRecords(
            Data(":000000 100644 \(Self.zero) \(Self.b) A\0n.txt\0:100644 100644 \(Self.a) \(Self.b) M\0m\0".utf8))
        #expect(raw.count == 2)
        #expect(raw[0].old == Self.zero && raw[0].new == Self.b && raw[0].path == Array("n.txt".utf8))
        #expect(raw[1].old == Self.a && raw[1].path == Array("m".utf8))
        #expect(CLIGitBackend.rawDiffRecords(Data()).isEmpty)
    }
}
