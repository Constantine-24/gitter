import Foundation
import Testing

@testable import GitCore

/// Line staging's context-free hunks, measured in A1 Task 3 (Step 5): the patch must apply
/// exactly where the diff showed it, or not at all.
///
/// With `-U3` a hunk has no context line only when it covers the whole file on both sides: a
/// pure addition into an empty file, a whole-file replacement with every `-` selected, or
/// unstaging every `+` of one. On an index that still matches the diff each of these applies
/// and stages exactly the selected lines. On an index that changed after the diff was loaded
/// (a terminal `git add` between the refresh and the click) `applyToIndex` must refuse, and
/// the index, HEAD, refs and worktree stay exactly as they were. `--unidiff-zero` used to turn
/// that refusal into an apply at an offset; the old result is recorded in each stale case.
@Suite struct PartialStagingStaleTests {

    /// A subdirectory path, as in `PartialStagingTests`, so the patch's paths are never bare.
    static let path = "src/f.txt"

    struct Case: Sendable, CustomTestStringConvertible {
        /// Task 3's name for the case (`B2`, `U4`, …), then what it does.
        let name: String
        let head: String
        /// What the index holds when the diff is loaded; nil means it matches HEAD.
        var staged: String? = nil
        let worktree: String
        let direction: PatchDirection
        /// The changed lines selected, by text; nil selects every changed line of the file.
        var selected: [String]? = nil
        /// Fresh: the index after the apply. Stale: unused.
        var expected: String = ""
        /// Stale: what the index is rewritten to after the diff was loaded.
        var staleIndex: String = ""
        /// Stale: what the index became when `--unidiff-zero` was passed (Task 3's measurement).
        var appliedAtAnOffset: String = ""

        var testDescription: String { name }
    }

    // MARK: - Fresh: every case Task 3 measured applies, and stages exactly the selection

    static let fresh: [Case] = [
        Case(
            name: "B1 stage +Y of an addition into an empty file", head: "",
            worktree: "X\nY\n", direction: .stage, selected: ["Y"], expected: "Y\n"),
        Case(
            name: "B3 stage +X +Y into an empty file", head: "",
            worktree: "X\nY\n", direction: .stage, expected: "X\nY\n"),
        Case(
            name: "A1 stage -a -b +X, a whole-file replacement", head: "a\nb\n",
            worktree: "X\n", direction: .stage, expected: "X\n"),
        Case(
            name: "U1 unstage +X +Y of an addition into an empty file", head: "",
            staged: "X\nY\n", worktree: "X\nY\n", direction: .unstage, expected: ""),
        Case(
            name: "C1 stage a replacement of a file without a trailing newline", head: "a\nb",
            worktree: "X\n", direction: .stage, expected: "X\n"),
        Case(
            name: "C2 stage an addition without a trailing newline into an empty file", head: "",
            worktree: "X\nY", direction: .stage, expected: "X\nY"),
        Case(
            name: "C3 unstage all of a replacement, neither side with a trailing newline",
            head: "a\nb", staged: "X\nY", worktree: "X\nY", direction: .unstage, expected: "a\nb"),
        Case(
            name: "C4 stage one blank line replaced by Y", head: "\n",
            worktree: "Y\n", direction: .stage, expected: "Y\n"),
        // Not in Task 3's table, and context-free the same way: U4's fresh twin, and a
        // replacement staged without its addition (the unselected `+` is dropped).
        Case(
            name: "U4 fresh: unstage all of a staged replacement", head: "a\nb\n",
            staged: "X\nY\n", worktree: "X\nY\n", direction: .unstage, expected: "a\nb\n"),
        Case(
            name: "A1 stage -a -b without +X", head: "a\nb\n",
            worktree: "X\n", direction: .stage, selected: ["a", "b"], expected: ""),
        // Measured with this fix: a file emptied, and a lone line without a newline.
        Case(
            name: "stage emptying a file without a trailing newline", head: "a\nb",
            worktree: "", direction: .stage, expected: ""),
        Case(
            name: "unstage a staged emptying of a file", head: "a\nb\n",
            staged: "", worktree: "", direction: .unstage, expected: "a\nb\n"),
        Case(
            name: "stage one line without a trailing newline into an empty file", head: "",
            worktree: "X", direction: .stage, expected: "X"),
    ]

    @Test(arguments: fresh)
    func aContextFreeHunkOnAFreshIndexStagesExactlyTheSelection(_ c: Case) async throws {
        let repo = try await Self.makeRepo(c)
        defer { repo.cleanUp() }
        let file = try await loadDiff(repo, Self.path, staged: c.direction == .unstage)
        let before = worktreeSnapshot(repo)
        let head = try await repo.headSha()

        let patch = try await applySelection(
            repo, file, direction: c.direction, lines: Self.lineIDs(file, c.selected))

        // The case is what it claims to be: a hunk with no context line.
        #expect(patch.hasContextFreeHunk, "\(patch.text)")
        let index = try await indexText(repo, Self.path)
        #expect(index == c.expected)
        expectNoJoinedLines(index, sources: ["a", "b", "X", "Y"])
        #expect(try await repo.headSha() == head)
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - Stale: every case Task 3 measured is refused, and nothing moves

    static let stale: [Case] = [
        Case(
            name: "B2 stage +Y, index now a Y b", head: "",
            worktree: "X\nY\n", direction: .stage, selected: ["Y"],
            staleIndex: "a\nY\nb\n", appliedAtAnOffset: "Y\na\nY\nb\n"),
        Case(
            name: "B4 stage +X +Y, index now X", head: "",
            worktree: "X\nY\n", direction: .stage,
            staleIndex: "X\n", appliedAtAnOffset: "X\nY\nX\n"),
        Case(
            name: "A2 stage -a -b +X, index now X a b", head: "a\nb\n",
            worktree: "X\n", direction: .stage,
            staleIndex: "X\na\nb\n", appliedAtAnOffset: "X\nX\n"),
        Case(
            name: "A3 stage -a -b +X, index now q a b a b", head: "a\nb\n",
            worktree: "X\n", direction: .stage,
            staleIndex: "q\na\nb\na\nb\n", appliedAtAnOffset: "q\nX\na\nb\n"),
        Case(
            name: "U2 unstage +X +Y, index now 1 X Y 2 X Y", head: "",
            staged: "X\nY\n", worktree: "X\nY\n", direction: .unstage,
            staleIndex: "1\nX\nY\n2\nX\nY\n", appliedAtAnOffset: "1\n2\nX\nY\n"),
        Case(
            name: "U3 unstage +X +Y, index now q r X Y", head: "",
            staged: "X\nY\n", worktree: "X\nY\n", direction: .unstage,
            staleIndex: "q\nr\nX\nY\n", appliedAtAnOffset: "q\nr\n"),
        Case(
            name: "U4 unstage all of a replacement, index now q X Y", head: "a\nb\n",
            staged: "X\nY\n", worktree: "X\nY\n", direction: .unstage,
            staleIndex: "q\nX\nY\n", appliedAtAnOffset: "q\na\nb\n"),
    ]

    @Test(arguments: stale)
    func aContextFreeHunkOnAStaleIndexIsRefusedAndChangesNothing(_ c: Case) async throws {
        let repo = try await Self.makeRepo(c)
        defer { repo.cleanUp() }
        let file = try await loadDiff(repo, Self.path, staged: c.direction == .unstage)
        let patch = try #require(
            PatchBuilder.patch(
                file: file, hunkIDs: everyHunkID(file), lineIDs: Self.lineIDs(file, c.selected),
                direction: c.direction))
        #expect(patch.hasContextFreeHunk, "\(patch.text)")

        // The index moves on after the diff was loaded; the worktree does not.
        try await Self.rewriteIndex(repo, to: c.staleIndex)
        let before = worktreeSnapshot(repo)
        let state = try await RepoState.capture(repo)
        let indexBefore = try await indexText(repo, Self.path)
        #expect(indexBefore == c.staleIndex)
        #expect(!state.index.isEmpty && !state.head.isEmpty)

        let error = await #expect(throws: GitError.self) {
            try await CLIGitBackend().applyToIndex(
                patch: patch, reverse: c.direction == .unstage, at: repo.root)
        }
        // `commandFailed` is what the app turns into "The file changed since this diff was
        // loaded…" (`PatchDidNotApply`), with git's own words after it.
        if let error {
            guard case .commandFailed(_, let stderr) = error else {
                Issue.record("expected commandFailed, got \(error)")
                return
            }
            #expect(stderr.contains("patch does not apply"), "\(stderr)")
        }

        let indexAfter = try await indexText(repo, Self.path)
        let measured = c.appliedAtAnOffset.debugDescription
        #expect(
            indexAfter == indexBefore,
            "applied at an offset: \(indexBefore.debugDescription) → \(indexAfter.debugDescription) (Task 3 measured \(measured))")
        try await assertRepoUnchanged(repo, since: state, worktree: before)
    }

    // MARK: - Support

    /// HEAD holds `head`, the index `staged` (or `head`), the worktree `worktree`.
    static func makeRepo(_ c: Case) async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write(path, c.head)
        try await repo.commitAll("root")
        if let staged = c.staged {
            try repo.write(path, staged)
            try await repo.git(["add", "--", path])
        }
        try repo.write(path, c.worktree)
        return repo
    }

    /// Stages `content` for `path` the way a terminal would, then puts the worktree's bytes
    /// back, so only the index has moved on from the diff.
    static func rewriteIndex(_ repo: TestRepo, to content: String) async throws {
        let url = repo.root.appendingPathComponent(path)
        let worktree = try Data(contentsOf: url)
        try repo.write(path, content)
        try await repo.git(["add", "--", path])
        try worktree.write(to: url)
    }

    static func lineIDs(_ file: FileDiff, _ texts: [String]?) -> Set<DiffLine.ID>? {
        guard let texts else { return nil }
        return Set(
            file.hunks.flatMap(\.lines)
                .filter { ($0.kind == .added || $0.kind == .removed) && texts.contains($0.text) }
                .map(\.id))
    }
}
