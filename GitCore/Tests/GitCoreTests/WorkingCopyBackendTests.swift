import Foundation
import Testing
@testable import GitCore

@Suite struct WorkingCopyBackendTests {
    private func status(_ repo: TestRepo) async throws -> WorkingCopyStatus {
        try await CLIGitBackend().snapshot(at: repo.root).status
    }

    private func fileStatus(_ status: WorkingCopyStatus, _ path: String) -> FileStatus? {
        status.files.first { $0.path == path }
    }

    @Test func stageModifiedFileStagesItAsModifiedNotUnstaged() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("a.txt", "one\ntwo\n")
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        try await backend.stage(paths: ["a.txt"], at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        let file = fileStatus(try await status(repo), "a.txt")
        #expect(file?.staged == .modified)
        #expect(file?.unstaged == nil)
    }

    @Test func stageUntrackedFileStagesItAsAdded() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("seed.txt", "seed\n")
        try await repo.commitAll("root")
        try repo.write("new.txt", "new\n")
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        try await backend.stage(paths: ["new.txt"], at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        let file = fileStatus(try await status(repo), "new.txt")
        #expect(file?.staged == .added)
        #expect(file?.unstaged == nil)
    }

    @Test func unstageReversesStagedModificationAndAddition() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("a.txt", "one\ntwo\n")
        try repo.write("new.txt", "new\n")
        let backend = CLIGitBackend()
        try await backend.stage(paths: ["a.txt", "new.txt"], at: repo.root)
        let before = worktreeSnapshot(repo)

        try await backend.unstage(paths: ["a.txt", "new.txt"], at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        let statusAfter = try await status(repo)
        let a = fileStatus(statusAfter, "a.txt")
        #expect(a?.staged == nil)
        #expect(a?.unstaged == .modified)
        let new = fileStatus(statusAfter, "new.txt")
        #expect(new?.staged == nil)
        #expect(new?.unstaged == .untracked)
    }

    /// A1 gap (E1 Task 2): the unstage — `restore --no-recurse-submodules --staged` — of a
    /// submodule whose new commit is staged, under `submodule.recurse=true`, puts HEAD's gitlink
    /// back in the index and touches nothing inside the submodule: its checkout, an edit and
    /// an untracked file there are kept (measured once by hand in A1 Task 3; now pinned).
    @Test func unstagingASubmoduleUnderRecursionKeepsTheWorkInsideIt() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "a\n")
        try repo.write("sub/s", "s\n")
        let sub = TestRepo(root: repo.root.appendingPathComponent("sub"))
        let identity = ["-c", "user.name=T", "-c", "user.email=t@t", "-c", "commit.gpgsign=false"]
        try await sub.git(["init", "-q", "-b", "main"])
        try await sub.git(["add", "s"])
        try await sub.git(identity + ["commit", "-q", "-m", "s1"])
        let first = try await sub.headSha()
        try await repo.git(["add", "a.txt", "sub"])
        try await repo.git(["commit", "-q", "-m", "with sub"])

        try sub.write("s", "s\ns2\n")
        try await sub.git(["add", "s"])
        try await sub.git(identity + ["commit", "-q", "-m", "s2"])
        let second = try await sub.headSha()
        try await repo.git(["add", "sub"])
        #expect(try await repo.indexLine("sub") == "160000 \(second) 0\tsub\n", "the new commit is not staged")
        try sub.write("s", "s\ns2\nwork inside\n")
        try sub.write("untracked", "u\n")
        try await repo.git(["config", "submodule.recurse", "true"])
        let inside = worktreeSnapshot(sub)

        try await CLIGitBackend().unstage(paths: ["sub"], at: repo.root)

        #expect(try await repo.indexLine("sub") == "160000 \(first) 0\tsub\n")
        #expect(try await sub.headSha() == second, "the submodule's checkout moved")
        assertWorktreeUnchanged(sub, since: inside)
        #expect(try sub.bytes("s") == Data("s\ns2\nwork inside\n".utf8))
        #expect(try sub.bytes("untracked") == Data("u\n".utf8))
    }

    @Test func stageAllPicksUpModifiedUntrackedAndDeleted() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try repo.write("b.txt", "two\n")
        try await repo.commitAll("root")
        try repo.write("a.txt", "one\nmore\n")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("b.txt"))
        try repo.write("c.txt", "three\n")
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        try await backend.stageAll(at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        let statusAfter = try await status(repo)
        #expect(fileStatus(statusAfter, "a.txt")?.staged == .modified)
        #expect(fileStatus(statusAfter, "b.txt")?.staged == .deleted)
        #expect(fileStatus(statusAfter, "c.txt")?.staged == .added)
    }

    @Test func unstageAllEmptiesStagedSide() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("a.txt", "one\nmore\n")
        try repo.write("new.txt", "new\n")
        let backend = CLIGitBackend()
        try await backend.stageAll(at: repo.root)
        let before = worktreeSnapshot(repo)

        try await backend.unstageAll(at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        let statusAfter = try await status(repo)
        #expect(statusAfter.files.allSatisfy { $0.staged == nil })
        #expect(fileStatus(statusAfter, "a.txt")?.unstaged == .modified)
        #expect(fileStatus(statusAfter, "new.txt")?.unstaged == .untracked)
    }

    @Test func unstageInRepoWithNoCommitsLeavesFileUntrackedAndOnDisk() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "content\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        try await backend.unstage(paths: ["a.txt"], at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        let statusAfter = try await status(repo)
        let file = fileStatus(statusAfter, "a.txt")
        #expect(file?.staged == nil)
        #expect(file?.unstaged == .untracked)
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("a.txt").path))
    }

    @Test func unstageInRepoWithNoCommitsIgnoresUnmatchedPaths() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "content\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        try await backend.unstage(paths: ["a.txt", "nope.txt"], at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        let statusAfter = try await status(repo)
        let file = fileStatus(statusAfter, "a.txt")
        #expect(file?.staged == nil)
        #expect(file?.unstaged == .untracked)
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("a.txt").path))
    }

    @Test func unstageAllInRepoWithNoCommitsLeavesFilesUntrackedAndOnDisk() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "content\n")
        try repo.write("b.txt", "content2\n")
        try await repo.git(["add", "-A"])
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        try await backend.unstageAll(at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        let statusAfter = try await status(repo)
        #expect(statusAfter.files.allSatisfy { $0.staged == nil })
        #expect(fileStatus(statusAfter, "a.txt")?.unstaged == .untracked)
        #expect(fileStatus(statusAfter, "b.txt")?.unstaged == .untracked)
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("a.txt").path))
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("b.txt").path))
    }

    @Test func unstageAllOnEmptyIndexInRepoWithNoCommitsIsANoOp() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let backend = CLIGitBackend()

        try await backend.unstageAll(at: repo.root)

        // The worktree is genuinely empty here, so `assertWorktreeUnchanged` (which refuses an
        // empty baseline) does not apply; assert emptiness directly instead.
        #expect(worktreeSnapshot(repo).isEmpty)
        let statusAfter = try await status(repo)
        #expect(statusAfter.files.isEmpty)
    }

    @Test func pathWithSpaceAndNonASCIINameRoundTrips() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("seed.txt", "seed\n")
        try await repo.commitAll("root")
        let name = "héllo world.txt"
        try repo.write(name, "content\n")
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        try await backend.stage(paths: [name], at: repo.root)
        let afterStage = try await status(repo)
        #expect(fileStatus(afterStage, name)?.staged == .added)
        assertWorktreeUnchanged(repo, since: before)

        try await backend.unstage(paths: [name], at: repo.root)
        let afterUnstage = try await status(repo)
        #expect(fileStatus(afterUnstage, name)?.staged == nil)
        #expect(fileStatus(afterUnstage, name)?.unstaged == .untracked)
        assertWorktreeUnchanged(repo, since: before)
    }

    @Test func worktreeSnapshotRecursesIntoNestedDirectories() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("seed.txt", "seed\n")
        try await repo.commitAll("root")
        let nestedPath = "dir/sub/nested é.txt"
        try repo.write(nestedPath, "nested content\n")
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)
        #expect(before[nestedPath] == Data("nested content\n".utf8))

        try await backend.stage(paths: [nestedPath], at: repo.root)
        try await backend.unstage(paths: [nestedPath], at: repo.root)

        let after = worktreeSnapshot(repo)
        #expect(after[nestedPath] == before[nestedPath])
        #expect(after == before)
    }

    @Test func emptyPathsReturnsWithoutRunningGitEvenOutsideARepo() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-test-nonrepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let backend = CLIGitBackend()

        try await backend.stage(paths: [], at: dir)
        try await backend.unstage(paths: [], at: dir)
    }
}
