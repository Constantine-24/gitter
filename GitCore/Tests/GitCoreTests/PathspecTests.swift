import Foundation
import Testing

@testable import GitCore

/// Every path the backend hands git after `--` is a *pathspec*, not a file name: `a*.txt`
/// matches `a b.txt` too, `notes[1].txt` matches `notes1.txt`, and a leading `:` is pathspec
/// magic rather than the first character of a name. These tests pin that a file whose name
/// happens to look like a pattern is treated as exactly itself.
@Suite struct PathspecTests {
    private func status(_ repo: TestRepo) async throws -> WorkingCopyStatus {
        try await CLIGitBackend().snapshot(at: repo.root).status
    }

    private func stagedPaths(_ repo: TestRepo) async throws -> [String] {
        try await status(repo).files.filter { $0.staged != nil }.map(\.path).sorted()
    }

    /// Two committed files whose names differ only in that one of them is a glob that matches
    /// the other; both are then modified in the worktree.
    private func makeGlobRepo() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("a*.txt", "one\n")
        try repo.write("a b.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("a*.txt", "one\ntwo\n")
        try repo.write("a b.txt", "one\ntwo\n")
        return repo
    }

    // MARK: - stage / unstage

    @Test func stageOfAGlobLikeNameStagesOnlyThatFile() async throws {
        let repo = try await makeGlobRepo()
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)

        try await CLIGitBackend().stage(paths: ["a*.txt"], at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        #expect(try await stagedPaths(repo) == ["a*.txt"])
    }

    @Test func unstageOfAGlobLikeNameUnstagesOnlyThatFile() async throws {
        let repo = try await makeGlobRepo()
        defer { repo.cleanUp() }
        let backend = CLIGitBackend()
        try await backend.stageAll(at: repo.root)
        let before = worktreeSnapshot(repo)

        try await backend.unstage(paths: ["a*.txt"], at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        #expect(try await stagedPaths(repo) == ["a b.txt"])
    }

    @Test func unstageOfAGlobLikeNameInRepoWithNoCommitsUnstagesOnlyThatFile() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a*.txt", "one\n")
        try repo.write("a b.txt", "one\n")
        try await repo.git(["add", "-A"])
        let before = worktreeSnapshot(repo)

        // The no-commits branch runs `git rm --cached`, whose paths are pathspecs too.
        try await CLIGitBackend().unstage(paths: ["a*.txt"], at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        #expect(try await stagedPaths(repo) == ["a b.txt"])
    }

    // MARK: - Diffs

    @Test func unstagedDiffOfAGlobLikeNameCoversOnlyThatFile() async throws {
        let repo = try await makeGlobRepo()
        defer { repo.cleanUp() }

        let diffs = try await CLIGitBackend()
            .workingCopyDiff(at: repo.root, path: "a*.txt", staged: false)

        #expect(diffs.count == 1)
        #expect(diffs.first?.displayPath == "a*.txt")
    }

    @Test func stagedDiffOfAGlobLikeNameCoversOnlyThatFile() async throws {
        let repo = try await makeGlobRepo()
        defer { repo.cleanUp() }
        try await CLIGitBackend().stageAll(at: repo.root)

        let diffs = try await CLIGitBackend()
            .workingCopyDiff(at: repo.root, path: "a*.txt", staged: true)

        #expect(diffs.count == 1)
        #expect(diffs.first?.displayPath == "a*.txt")
    }

    @Test func untrackedGlobLikeNameDiffsAsAWholeNewFile() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        // The tracked file is the one the untracked name's glob would match, so an
        // `ls-files` probe that globs answers "tracked" for a file that is not.
        try repo.write("a b.txt", "committed\n")
        try await repo.commitAll("root")
        try repo.write("a*.txt", "brand new\n")

        let diffs = try await CLIGitBackend()
            .workingCopyDiff(at: repo.root, path: "a*.txt", staged: false)

        #expect(diffs.count == 1)
        #expect(diffs.first?.displayPath == "a*.txt")
        #expect(diffs.first?.hunks.first?.lines.map(\.text) == ["brand new"])
    }

    @Test func commitDiffOfAGlobLikeNameCoversOnlyThatFile() async throws {
        let repo = try await makeGlobRepo()
        defer { repo.cleanUp() }
        try await repo.commitAll("both changed")

        let diffs = try await CLIGitBackend()
            .commitDiff(at: repo.root, sha: try await repo.headSha(), path: "a*.txt")

        #expect(diffs.count == 1)
        #expect(diffs.first?.displayPath == "a*.txt")
    }

    // MARK: - Other pattern-shaped names

    @Test func bracketNameIsStagedAndDiffedAsItself() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        // `notes[1].txt` as a pathspec is a character class matching `notes1.txt`.
        try repo.write("notes[1].txt", "one\n")
        try repo.write("notes1.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("notes[1].txt", "one\ntwo\n")
        try repo.write("notes1.txt", "one\ntwo\n")
        let before = worktreeSnapshot(repo)

        let diffs = try await CLIGitBackend()
            .workingCopyDiff(at: repo.root, path: "notes[1].txt", staged: false)
        #expect(diffs.map(\.displayPath) == ["notes[1].txt"])

        try await CLIGitBackend().stage(paths: ["notes[1].txt"], at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        #expect(try await stagedPaths(repo) == ["notes[1].txt"])
    }

    @Test func leadingColonNameIsStagedAndDiffedAsItself() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("seed.txt", "seed\n")
        try await repo.commitAll("root")
        // A leading `:` introduces pathspec magic, so git rejects the bare name outright.
        try repo.write(":colon.txt", "hello\n")
        let before = worktreeSnapshot(repo)
        #expect(before[":colon.txt"] == Data("hello\n".utf8))

        let diffs = try await CLIGitBackend()
            .workingCopyDiff(at: repo.root, path: ":colon.txt", staged: false)
        #expect(diffs.map(\.displayPath) == [":colon.txt"])

        try await CLIGitBackend().stage(paths: [":colon.txt"], at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        #expect(try await stagedPaths(repo) == [":colon.txt"])

        let stagedDiffs = try await CLIGitBackend()
            .workingCopyDiff(at: repo.root, path: ":colon.txt", staged: true)
        #expect(stagedDiffs.map(\.displayPath) == [":colon.txt"])

        try await CLIGitBackend().unstage(paths: [":colon.txt"], at: repo.root)
        #expect(try await stagedPaths(repo) == [])
        assertWorktreeUnchanged(repo, since: before)
    }
}
