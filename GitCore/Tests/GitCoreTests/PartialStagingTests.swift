import Foundation
import Testing

@testable import GitCore

/// Round trips for hunk- and line-level staging against a real repository: load the diff the
/// app shows, build a patch with `PatchBuilder`, apply it with `applyToIndex`, then assert on
/// what git itself reports. No-newline cases live in `PartialStagingNewlineTests`.
@Suite struct PartialStagingTests {

    // MARK: - Fixture

    /// A path in a subdirectory, so the patch's paths are never bare file names.
    static let path = "src/app.txt"

    /// 30 numbered lines: `line01` … `line30`.
    static let original: [String] = (1...30).map { "line" + ($0 < 10 ? "0\($0)" : "\($0)") }

    /// Three well-separated changes, which `-U3` renders as three hunks: an addition after
    /// `line05`, a deletion of `line15`/`line16`, and a replacement of `line25`/`line26`.
    static let modified: [String] = {
        var lines = original
        lines[24] = "REPL-1"
        lines[25] = "REPL-2"
        lines.removeSubrange(14...15)
        lines.insert(contentsOf: ["added-a", "added-b"], at: 5)
        return lines
    }()

    static func text(_ lines: [String]) -> String { lines.joined(separator: "\n") + "\n" }

    /// A repo whose HEAD holds `original` and whose worktree holds `modified`.
    static func makeRepo() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write(path, text(original))
        try await repo.commitAll("root")
        try repo.write(path, text(modified))
        return repo
    }

    /// `original` with the given edits applied, for stating an expected index exactly.
    static func expected(_ edit: (inout [String]) -> Void) -> String {
        var lines = original
        edit(&lines)
        return text(lines)
    }

    // MARK: - 1. Whole hunk

    @Test func stagingOneWholeHunkLeavesTheOtherTwoUnstaged() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, Self.path)
        #expect(file.hunks.count == 3)

        try await applySelection(
            repo, file, direction: .stage, hunks: [try hunkID(file, containing: "added-a")])

        let staged = try await changedLines(repo, Self.path, staged: true)
        let unstaged = try await changedLines(repo, Self.path, staged: false)
        #expect(staged == ["+added-a", "+added-b"])
        #expect(unstaged == ["-line15", "-line16", "-line25", "-line26", "+REPL-1", "+REPL-2"])
        let index = try await indexText(repo, Self.path)
        #expect(index == Self.expected { $0.insert(contentsOf: ["added-a", "added-b"], at: 5) })
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - 2. One `+` of a two-line addition

    @Test func stagingOneAddedLineStagesOnlyThatLine() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, Self.path)

        try await applySelection(
            repo, file, direction: .stage, lines: changedLineIDs(file, "added-a"))

        let staged = try await changedLines(repo, Self.path, staged: true)
        #expect(staged == ["+added-a"])
        let index = try await indexText(repo, Self.path)
        #expect(index == Self.expected { $0.insert("added-a", at: 5) })
        let unstaged = try await changedLines(repo, Self.path, staged: false)
        #expect(unstaged.contains("+added-b"))
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - 3. One `-` of a two-line deletion

    @Test func stagingOneRemovedLineStagesOnlyThatLine() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, Self.path)

        try await applySelection(
            repo, file, direction: .stage, lines: changedLineIDs(file, "line15"))

        let staged = try await changedLines(repo, Self.path, staged: true)
        #expect(staged == ["-line15"])
        let index = try await indexText(repo, Self.path)
        #expect(index == Self.expected { $0.remove(at: 14) })
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - 4. Half a replacement

    @Test func stagingHalfOfAReplacementStagesOnlyThatPair() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, Self.path)

        try await applySelection(
            repo, file, direction: .stage, lines: changedLineIDs(file, "line25", "REPL-1"))

        let staged = try await changedLines(repo, Self.path, staged: true)
        #expect(staged == ["-line25", "+REPL-1"])
        // The unselected `-line26` becomes context and keeps its place in the hunk, so the
        // selected `+REPL-1` lands after it rather than where `line25` was. That is exactly
        // what `git add -p` does with the same selection: the hunk's line order is the diff's.
        let index = try await indexText(repo, Self.path)
        #expect(index == Self.expected { $0.remove(at: 24); $0.insert("REPL-1", at: 25) })
        let unstaged = try await changedLines(repo, Self.path, staged: false)
        #expect(unstaged.contains("-line26"))
        #expect(unstaged.contains("+REPL-2"))
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - 5. Unstaging one line

    @Test func unstagingOneLineMovesItBackToTheUnstagedSide() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        try await CLIGitBackend().stageAll(at: repo.root)
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, Self.path, staged: true)

        try await applySelection(
            repo, file, direction: .unstage, lines: changedLineIDs(file, "added-a"))

        let unstaged = try await changedLines(repo, Self.path, staged: false)
        #expect(unstaged == ["+added-a"])
        let staged = try await changedLines(repo, Self.path, staged: true)
        #expect(!staged.contains("+added-a"))
        #expect(staged.contains("+added-b"))
        let index = try await indexText(repo, Self.path)
        #expect(index == Self.text(Self.modified.filter { $0 != "added-a" }))
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - 6. Property: hunk by hunk equals `git add`

    @Test func stagingEveryHunkInTurnEqualsGitAdd() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let twin = try await TestRepo.makeEmpty()
        defer { twin.cleanUp() }
        try twin.write(Self.path, Self.text(Self.original))
        try await twin.commitAll("root")
        try twin.write(Self.path, Self.text(Self.modified))
        try await twin.git(["add", "-A"])
        let before = worktreeSnapshot(repo)

        // Reload the diff each time: every applied hunk shifts the line numbers of the rest.
        for _ in 0..<5 {
            let files = try await CLIGitBackend()
                .workingCopyDiff(at: repo.root, path: Self.path, staged: false)
            guard let file = files.first, let hunk = file.hunks.first else { break }
            try await applySelection(repo, file, direction: .stage, hunks: [hunk.id])
        }

        let unstaged = try await changedLines(repo, Self.path, staged: false)
        #expect(unstaged.isEmpty)
        let mine = try await repo.git(["diff", "--cached"])
        let theirs = try await twin.git(["diff", "--cached"])
        #expect(mine == theirs)
        #expect(try await indexText(repo, Self.path) == Self.text(Self.modified))
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - 7. Partial stage of an unstaged deletion

    @Test func partiallyStagingADeletedFileKeepsTheRestInTheIndex() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("gone.txt", "g1\ng2\ng3\ng4\ng5\n")
        try repo.write("keep.txt", "keep\n")
        try await repo.commitAll("root")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("gone.txt"))
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, "gone.txt")
        #expect(file.kind == .deleted)

        // Selecting the whole deletion is file-level work, not a patch.
        #expect(
            PatchBuilder.patch(
                file: file, hunkIDs: everyHunkID(file), lineIDs: nil, direction: .stage) == nil)

        try await applySelection(
            repo, file, direction: .stage, lines: changedLineIDs(file, "g1", "g2"))

        #expect(try await indexText(repo, "gone.txt") == "g3\ng4\ng5\n")
        #expect(!FileManager.default.fileExists(
            atPath: repo.root.appendingPathComponent("gone.txt").path))
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - 8. Partial unstage of a staged addition

    @Test func partiallyUnstagingANewFileLeavesTheRestInTheIndex() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("seed.txt", "seed\n")
        try await repo.commitAll("root")
        try repo.write("fresh.txt", "n1\nn2\nn3\nn4\nn5\n")
        try await CLIGitBackend().stage(paths: ["fresh.txt"], at: repo.root)
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, "fresh.txt", staged: true)
        #expect(file.kind == .added)

        // Unstaging the whole addition is file-level work, not a patch.
        #expect(
            PatchBuilder.patch(
                file: file, hunkIDs: everyHunkID(file), lineIDs: nil, direction: .unstage) == nil)

        try await applySelection(
            repo, file, direction: .unstage, lines: changedLineIDs(file, "n1", "n2"))

        #expect(try await indexText(repo, "fresh.txt") == "n3\nn4\nn5\n")
        let headFiles = try await repo.git(["ls-tree", "--name-only", "-r", "HEAD"])
        #expect(!String(decoding: headFiles, as: UTF8.self).contains("fresh.txt"))
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - 10. Awkward path

    @Test func partialStagingWorksForAPathWithASpaceAndNonASCII() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let name = "données/mon fichier.txt"
        try repo.write(name, "a\nb\nc\nd\ne\nf\n")
        try await repo.commitAll("root")
        try repo.write(name, "a\nB\nc\nd\nE\nf\n")
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, name)

        try await applySelection(
            repo, file, direction: .stage, lines: changedLineIDs(file, "b", "B"))

        let staged = try await changedLines(repo, name, staged: true)
        #expect(staged == ["-b", "+B"])
        #expect(try await indexText(repo, name) == "a\nB\nc\nd\ne\nf\n")
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - 11. A stale patch

    @Test func aStalePatchThrowsAndLeavesTheIndexUnchanged() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, Self.path)
        let patch = try #require(
            PatchBuilder.patch(
                file: file, hunkIDs: everyHunkID(file), lineIDs: nil, direction: .stage))

        // The index moves on after the diff was loaded, so the patch's old side no longer
        // matches what git reads.
        try await CLIGitBackend().stageAll(at: repo.root)
        let indexBefore = try await repo.indexContent(of: Self.path)

        await #expect(throws: GitError.self) {
            try await CLIGitBackend().applyToIndex(patch: patch, reverse: false, at: repo.root)
        }

        #expect(try await repo.indexContent(of: Self.path) == indexBefore)
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - Context-free hunks (a one-line file)

    @Test func stagingTheAddedLineOfAOneLineFileKeepsBothLines() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("solo.txt", "old\n")
        try await repo.commitAll("root")
        try repo.write("solo.txt", "new\n")
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, "solo.txt")

        let patch = try await applySelection(
            repo, file, direction: .stage, lines: changedLineIDs(file, "new"))

        // The unselected `-` became context, so this hunk still has one.
        #expect(!patch.needsUnidiffZero)
        #expect(try await indexText(repo, "solo.txt") == "old\nnew\n")
        assertWorktreeUnchanged(repo, since: before)
    }

    @Test func stagingTheRemovedLineOfAOneLineFileEmptiesIt() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("solo.txt", "old\n")
        try await repo.commitAll("root")
        try repo.write("solo.txt", "new\n")
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, "solo.txt")

        // Dropping the unselected `+` leaves a hunk with no context at all: the
        // `--unidiff-zero` path.
        let patch = try await applySelection(
            repo, file, direction: .stage, lines: changedLineIDs(file, "old"))

        #expect(patch.needsUnidiffZero)
        #expect(try await indexText(repo, "solo.txt") == "")
        assertWorktreeUnchanged(repo, since: before)
    }
}
