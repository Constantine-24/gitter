import Foundation
import Testing
@testable import GitCore

@Suite struct CLIGitBackendTests {
    /// Builds a repo with a root commit on `main`, a `feature` branch that diverges and is
    /// merged back with `--no-ff` (so the graph has a real merge), then leaves the worktree
    /// with one staged edit, one unstaged edit, and one untracked file.
    private struct Fixture {
        let repo: TestRepo
        let rootSha: String
        let mergeSha: String
    }

    private func makeFixture() async throws -> Fixture {
        let repo = try await TestRepo.makeEmpty()

        try repo.write("a.txt", "line1\n")
        try await repo.commitAll("root commit")
        let rootSha = try await repo.headSha()

        try await repo.git(["checkout", "-q", "-b", "feature"])
        try repo.write("b.txt", "b\n")
        try await repo.commitAll("add b on feature")

        try await repo.git(["checkout", "-q", "main"])
        try repo.write("c.txt", "c\n")
        try await repo.commitAll("add c on main")

        try await repo.git(["merge", "--no-ff", "-q", "-m", "merge feature", "feature"])
        let mergeSha = try await repo.headSha()

        // Unstaged edit.
        try repo.write("a.txt", "line1\nline2\n")
        // Staged edit.
        try repo.write("c.txt", "c\nc2\n")
        try await repo.git(["add", "c.txt"])
        // Untracked file.
        try repo.write("d.txt", "d1\nd2\n")

        return Fixture(repo: repo, rootSha: rootSha, mergeSha: mergeSha)
    }

    @Test func snapshotReportsBranchCommitsAndFileStatuses() async throws {
        let fixture = try await makeFixture()
        defer { fixture.repo.cleanUp() }
        let backend = CLIGitBackend()

        let snapshot = try await backend.snapshot(at: fixture.repo.root)

        #expect(snapshot.status.branch == "main")
        #expect(snapshot.commits.count == 4)
        #expect(snapshot.graph.count == snapshot.commits.count)
        #expect(snapshot.refs.localBranches.map(\.name).sorted() == ["feature", "main"])

        let byPath = Dictionary(uniqueKeysWithValues: snapshot.status.files.map { ($0.path, $0) })
        #expect(byPath["a.txt"]?.unstaged == .modified)
        #expect(byPath["c.txt"]?.staged == .modified)
        #expect(byPath["d.txt"]?.unstaged == .untracked)
    }

    @Test func workingCopyDiffUnstagedHasOneAddedLine() async throws {
        let fixture = try await makeFixture()
        defer { fixture.repo.cleanUp() }
        let backend = CLIGitBackend()

        let diffs = try await backend.workingCopyDiff(at: fixture.repo.root, path: "a.txt", staged: false)

        #expect(diffs.count == 1)
        let addedLines = diffs[0].hunks.flatMap(\.lines).filter { $0.kind == .added }
        #expect(addedLines.count == 1)
        #expect(addedLines[0].text == "line2")
    }

    @Test func workingCopyDiffStagedShowsIndexChange() async throws {
        let fixture = try await makeFixture()
        defer { fixture.repo.cleanUp() }
        let backend = CLIGitBackend()

        let diffs = try await backend.workingCopyDiff(at: fixture.repo.root, path: "c.txt", staged: true)

        #expect(diffs.count == 1)
        let addedLines = diffs[0].hunks.flatMap(\.lines).filter { $0.kind == .added }
        #expect(addedLines.count == 1)
        #expect(addedLines[0].text == "c2")
    }

    @Test func workingCopyDiffUntrackedFileIsAllAdditions() async throws {
        let fixture = try await makeFixture()
        defer { fixture.repo.cleanUp() }
        let backend = CLIGitBackend()

        let diffs = try await backend.workingCopyDiff(at: fixture.repo.root, path: "d.txt", staged: false)

        #expect(diffs.count == 1)
        let lines = diffs[0].hunks.flatMap(\.lines)
        #expect(!lines.isEmpty)
        #expect(lines.allSatisfy { $0.kind == .added })
    }

    @Test func commitFilesOfMergeListsMergedFile() async throws {
        let fixture = try await makeFixture()
        defer { fixture.repo.cleanUp() }
        let backend = CLIGitBackend()

        let files = try await backend.commitFiles(at: fixture.repo.root, sha: fixture.mergeSha)

        #expect(files.contains { $0.path == "b.txt" })
    }

    @Test func commitDiffOnRootCommitUsesRootFallback() async throws {
        let fixture = try await makeFixture()
        defer { fixture.repo.cleanUp() }
        let backend = CLIGitBackend()

        let diffs = try await backend.commitDiff(at: fixture.repo.root, sha: fixture.rootSha, path: nil)

        #expect(diffs.count == 1)
        #expect(diffs[0].newPath == "a.txt")
        let addedLines = diffs[0].hunks.flatMap(\.lines).filter { $0.kind == .added }
        #expect(addedLines.map(\.text) == ["line1"])
    }

    @Test func commitFilesOfRootCommitUsesRootFallback() async throws {
        let fixture = try await makeFixture()
        defer { fixture.repo.cleanUp() }
        let backend = CLIGitBackend()

        let files = try await backend.commitFiles(at: fixture.repo.root, sha: fixture.rootSha)

        #expect(files.map(\.path) == ["a.txt"])
    }

    @Test func emptyRepoSnapshotHasNoCommitsAndDoesNotCrash() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let backend = CLIGitBackend()

        let snapshot = try await backend.snapshot(at: repo.root)

        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.graph.isEmpty)
        #expect(snapshot.status.branch == "main" || snapshot.status.branch == "master")
    }

    @Test func isGitAvailableTrueForRealGit() async {
        let available = await CLIGitBackend.isGitAvailable(at: "/usr/bin/git")
        #expect(available)
    }

    @Test func isGitAvailableFalseForBogusPath() async {
        let available = await CLIGitBackend.isGitAvailable(at: "/nonexistent/git")
        #expect(!available)
    }
}
