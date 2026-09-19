import Foundation
import Testing

@testable import GitCore

/// Round trips for `\ No newline at end of file`, the one rule whose failure mode is silent:
/// a marker that is no longer true makes `git apply` join the line before it to the line after
/// it (`old` + `plus1` → `oldplus1`) and report success. Every case therefore asserts the
/// index's exact bytes and checks explicitly that no line is two source lines glued together.
@Suite struct PartialStagingNewlineTests {

    /// Builds a repo whose HEAD holds `head` and whose worktree holds `worktree`, both written
    /// byte-for-byte (a missing trailing newline is the whole point).
    private static func makeRepo(
        _ path: String, head: String, worktree: String
    ) async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write(path, head)
        try await repo.commitAll("root")
        try repo.write(path, worktree)
        return repo
    }

    private static let sources = ["alpha", "beta", "old", "plus1", "plus2"]

    // MARK: - Brief case 9: the last line of a file without a trailing newline

    @Test func stagingTheLastLineChangeOfAFileWithoutATrailingNewline() async throws {
        let repo = try await Self.makeRepo(
            "tail.txt", head: "one\ntwo\nthree", worktree: "one\ntwo\nTHREE")
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, "tail.txt")

        try await applySelection(repo, file, direction: .stage)

        let index = try await indexText(repo, "tail.txt")
        #expect(index == "one\ntwo\nTHREE")
        expectNoJoinedLines(index, sources: ["one", "two", "three", "THREE"])
        #expect(try await changedLines(repo, "tail.txt", staged: false).isEmpty)
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - (a) both sides lack a newline; stage only the `+` lines

    @Test func stagingOnlyTheAddedLinesWhenBothSidesLackATrailingNewline() async throws {
        let repo = try await Self.makeRepo(
            "ab.txt", head: "alpha\nbeta\nold", worktree: "alpha\nbeta\nplus1\nplus2")
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, "ab.txt")

        // `-old` is not selected, so it stays in the index — and the marker that followed it
        // no longer describes the new side, which now runs on to `plus2`.
        try await applySelection(
            repo, file, direction: .stage, lines: changedLineIDs(file, "plus1", "plus2"))

        let index = try await indexText(repo, "ab.txt")
        #expect(index == "alpha\nbeta\nold\nplus1\nplus2")
        expectNoJoinedLines(index, sources: Self.sources)
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - (b) both sides lack a newline; unstage only the `-` line

    @Test func unstagingOnlyTheRemovedLineWhenBothSidesLackATrailingNewline() async throws {
        let repo = try await Self.makeRepo(
            "ab.txt", head: "alpha\nbeta\nold", worktree: "alpha\nbeta\nplus1\nplus2")
        defer { repo.cleanUp() }
        try await CLIGitBackend().stageAll(at: repo.root)
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, "ab.txt", staged: true)

        // Reverse-applied: `old` comes back while `plus1`/`plus2` stay staged, so the marker
        // belongs after `plus2` — the line both sides of this patch really end on.
        try await applySelection(
            repo, file, direction: .unstage, lines: changedLineIDs(file, "old"))

        let index = try await indexText(repo, "ab.txt")
        #expect(index == "alpha\nbeta\nold\nplus1\nplus2")
        expectNoJoinedLines(index, sources: Self.sources)
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - (c) only the new side lacks a newline; stage an earlier `+`

    @Test func stagingAnEarlierAddedLineWhenOnlyTheNewSideLacksATrailingNewline() async throws {
        let repo = try await Self.makeRepo(
            "cd1.txt", head: "alpha\nbeta\n", worktree: "alpha\nbeta\nplus1\nplus2")
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, "cd1.txt")

        // The marker belonged to `plus2`, which is dropped: the index keeps its newline.
        try await applySelection(
            repo, file, direction: .stage, lines: changedLineIDs(file, "plus1"))

        let index = try await indexText(repo, "cd1.txt")
        #expect(index == "alpha\nbeta\nplus1\n")
        expectNoJoinedLines(index, sources: Self.sources)
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - (d) only the old side lacks a newline; the file gains one

    @Test func stagingTheAddedLineWhenOnlyTheOldSideLacksATrailingNewline() async throws {
        let repo = try await Self.makeRepo(
            "cd2.txt", head: "alpha\nbeta", worktree: "alpha\nbeta\nplus1\n")
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let file = try await loadDiff(repo, "cd2.txt")

        // `+beta` is git's re-emission of the last line now that it has a newline; selecting
        // only `+plus1` still has to split the unselected `-beta` back out so the marker binds
        // to the old side, which is the side that ends without a newline.
        try await applySelection(
            repo, file, direction: .stage, lines: changedLineIDs(file, "plus1"))

        let index = try await indexText(repo, "cd2.txt")
        #expect(index == "alpha\nbeta\nplus1\n")
        expectNoJoinedLines(index, sources: Self.sources)
        #expect(try await changedLines(repo, "cd2.txt", staged: false).isEmpty)
        assertWorktreeUnchanged(repo, since: before)
    }
}
