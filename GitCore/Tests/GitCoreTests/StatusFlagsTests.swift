import Foundation
import Testing

@testable import GitCore

/// What porcelain v2 says about a path that status used to throw away: intent-to-add, a
/// submodule, and an untracked directory that is really another repository. Stash and discard
/// refuse all three, so the snapshot has to know them.
///
/// Measured on git 2.54.0 (`git status --porcelain=v2 -z`), which is what the parser reads:
/// ```
/// 1 .A N... 000000 000000 100644 0000…0000 0000…0000 n        git add -N n
/// 1 .M SC.. 160000 160000 160000 b425…ad0b b425…ad0b sub      a submodule that moved
/// ? nested/                                                 an untracked nested repository
/// 2 .R N... 100644 100644 100644 e69d…5391 e69d…5391 R100 e\0q  i-t-a q deleted, i-t-a e empty
/// ```
/// Porcelain v2 shows an i-t-a entry with zero modes and zero shas, not the empty blob that
/// `ls-files -s` shows (M A.0). The worktree side is the only place an `A` or an `R` can come
/// from an intent-to-add entry: git pairs a deleted i-t-a entry with a new one as a worktree
/// rename.
@Suite struct StatusFlagsTests {
    private func file(_ path: String, in repo: TestRepo) async throws -> FileStatus {
        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        return try #require(status.files.first { $0.path == path }, "\(status.files)")
    }

    private func makeRepo() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        return repo
    }

    @Test func anIntentToAddFileIsIntentToAdd() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("n", "new\n")
        try await repo.git(["add", "-N", "n"])

        let n = try await file("n", in: repo)

        #expect(n.isIntentToAdd)
        #expect(!n.isSubmodule)
        #expect(!n.isNestedRepository)
        #expect(n.staged == nil)
        #expect(n.unstaged == .added)
    }

    @Test func anIntentToAddFileGitPairsWithADeletedOneIsStillIntentToAdd() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("q", "")
        try await repo.git(["add", "-N", "q"])
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("q"))
        try repo.write("e", "")
        try await repo.git(["add", "-N", "e"])

        let e = try await file("e", in: repo)

        #expect(e.unstaged == .renamed)
        #expect(e.originalPath == "q")
        #expect(e.isIntentToAdd)
    }

    /// The same pairing under `status.renames=copies`, measured: an i-t-a copy of a file that
    /// has also changed is `2 .C N... … C100 c`, then `a`.
    @Test func anIntentToAddCopyOfAChangedFileIsStillIntentToAdd() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a", "l1\nl2\nl3\nl4\n")
        try await repo.commitAll("root")
        try repo.write("c", "l1\nl2\nl3\nl4\n")
        try await repo.git(["add", "-N", "c"])
        try repo.write("a", "l1\nl2\nl3\nl4\nl5\n")
        try await repo.git(["config", "status.renames", "copies"])

        let c = try await file("c", in: repo)

        #expect(c.unstaged == .copied)
        #expect(c.originalPath == "a")
        #expect(c.isIntentToAdd)
        #expect(!(try await file("a", in: repo)).isIntentToAdd)
    }

    @Test func aSubmoduleThatMovedIsASubmodule() async throws {
        let upstream = try await makeRepo()
        defer { upstream.cleanUp() }
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try await repo.git([
            "-c", "protocol.file.allow=always", "submodule", "add", "-q", upstream.root.path, "sub",
        ])
        try await repo.commitAll("add sub")
        let sub = TestRepo(root: repo.root.appendingPathComponent("sub"))
        try await sub.git(["config", "user.email", "t@t"])
        try await sub.git(["config", "user.name", "Tester"])
        try await sub.git(["commit", "-q", "--allow-empty", "-m", "moved"])

        let entry = try await file("sub", in: repo)

        #expect(entry.isSubmodule)
        #expect(entry.unstaged == .modified)
        #expect(!entry.isIntentToAdd)
        #expect(!entry.isNestedRepository)
    }

    @Test func anUntrackedDirectoryHoldingARepositoryIsANestedRepository() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        let nested = repo.root.appendingPathComponent("nested")
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try await TestRepo(root: nested).git(["init", "-q"])
        try repo.write("plain/x.txt", "x\n")

        let entry = try await file("nested/", in: repo)
        let plain = try await file("plain/", in: repo)

        #expect(entry.isNestedRepository)
        #expect(entry.isUntracked)
        #expect(!entry.isSubmodule)
        #expect(!plain.isNestedRepository, "an ordinary untracked directory is not a repository")
    }

    /// A linked worktree or a separated git dir leaves `.git` as a *file*; it is a repository
    /// all the same.
    @Test func aGitFileMakesANestedRepositoryToo() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("linked/.git", "gitdir: /nonexistent\n")
        try repo.write("linked/x.txt", "x\n")

        let entry = try await file("linked/", in: repo)

        #expect(entry.isNestedRepository)
    }

    @Test func anOrdinaryFileIsNoneOfTheThree() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "two\n")
        try repo.write("b.txt", "new\n")
        try await repo.git(["add", "b.txt"])
        try repo.write("u.txt", "untracked\n")

        for path in ["a.txt", "b.txt", "u.txt"] {
            let entry = try await file(path, in: repo)
            #expect(!entry.isIntentToAdd, "\(path)")
            #expect(!entry.isSubmodule, "\(path)")
            #expect(!entry.isNestedRepository, "\(path)")
        }
    }
}
