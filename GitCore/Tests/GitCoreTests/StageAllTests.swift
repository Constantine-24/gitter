import Foundation
import Testing

@testable import GitCore

/// Stage All never resolves a conflicted path (M 22): everything else is staged exactly as
/// `add -A` would stage it.
@Suite struct StageAllTests {
    /// The index (`ls-files -s`) and the untracked and ignored sets: what `add -A` changes.
    static func staging(_ repo: TestRepo) async throws -> [String] {
        let index = String(decoding: try await repo.git(["ls-files", "-s"]), as: UTF8.self)
        let untracked = String(decoding: try await repo.git(["ls-files", "-o", "--exclude-standard"]), as: UTF8.self)
        let ignored = String(decoding: try await repo.git(["ls-files", "-o", "-i", "--exclude-standard"]), as: UTF8.self)
        return index.split(separator: "\n").map(String.init)
            + untracked.split(separator: "\n").map { "untracked \($0)" }
            + ignored.split(separator: "\n").map { "ignored \($0)" }
    }

    /// A copy of the whole repository, `.git` included, for the reference `add -A`.
    static func copy(_ repo: TestRepo) throws -> TestRepo {
        let copy = TestRepo(root: FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-test-\(UUID().uuidString)", isDirectory: true))
        try FileManager.default.copyItem(at: repo.root, to: copy.root)
        return copy
    }

    /// Every kind of change `add -A` sweeps up, beside the conflict.
    static func makeChanges(_ repo: TestRepo) async throws {
        try repo.write(".gitignore", "*.log\nudir/*.tmp\n")
        try repo.write("keep.txt", "keep EDITED\n")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("gone.txt"))
        try FileManager.default.moveItem(
            at: repo.root.appendingPathComponent("old.txt"), to: repo.root.appendingPathComponent("new.txt"))
        try repo.write("untracked.txt", "untracked\n")
        try repo.write("udir/a", "a\n")
        try repo.write("udir/sub/b", "b\n")
        try repo.write("udir/c.tmp", "ignored inside an untracked directory\n")
        try repo.write("ignored.log", "ignored\n")
        try repo.write("sp ace.txt", "sp ace EDITED\n")
    }

    static func prepare(_ repo: TestRepo) async throws {
        try repo.write("gone.txt", "gone\n")
        try repo.write("old.txt", "renamed\nline two\nline three\n")
        try repo.write("sp ace.txt", "sp ace\n")
    }

    @Test func aMergeKeepsItsConflictAndStagesEverythingElse() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified, prepare: Self.prepare)
        defer { repo.cleanUp() }
        try await Self.makeChanges(repo)
        let unmerged = String(decoding: try await repo.git(["ls-files", "-u", "-s"]), as: UTF8.self)
        #expect(unmerged.split(separator: "\n").count == 3)
        let reference = try Self.copy(repo)
        defer { reference.cleanUp() }
        try await reference.git(["add", "-A"])

        try await CLIGitBackend().stageAll(at: repo.root)

        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        #expect(status.files.first { $0.path == "f.txt" }?.conflict?.kind == .bothModified)
        #expect(String(decoding: try await repo.git(["ls-files", "-u", "-s"]), as: UTF8.self) == unmerged)
        // `add -A` on the copy, minus what it did to the conflicted path, plus its stages.
        let expected = try await Self.staging(reference).filter { !$0.hasSuffix("\tf.txt") }
            + unmerged.split(separator: "\n").map(String.init)
        #expect(try await Self.staging(repo).sorted() == expected.sorted())
        // Not vacuous: each kind of change really was staged.
        let staged = status.files.filter { $0.conflict == nil }
        #expect(staged.allSatisfy { $0.unstaged == nil || $0.unstaged == .ignored }, "\(staged)")
        #expect(Set(staged.map(\.path)).isSuperset(of: [
            "keep.txt", "gone.txt", "new.txt", "untracked.txt", "udir/a", "udir/sub/b", "sp ace.txt", ".gitignore",
        ]), "\(staged.map(\.path))")
    }

    /// DU and UD stay unmerged too, whether the file is on disk or not.
    @Test(arguments: [ConflictFixtureKind.deletedByUs, .deletedByThem, .renameRename, .binary])
    func anyKindOfConflictIsLeftUnmerged(kind: ConflictFixtureKind) async throws {
        let repo = try await ConflictFixtures.rebase(kind: kind)
        defer { repo.cleanUp() }
        try repo.write("keep.txt", "keep EDITED\n")
        let unmerged = try await repo.git(["ls-files", "-u", "-s"])

        try await CLIGitBackend().stageAll(at: repo.root)

        #expect(try await repo.git(["ls-files", "-u", "-s"]) == unmerged)
        #expect(String(decoding: try await repo.git(["diff", "--name-only"]), as: UTF8.self)
            .split(separator: "\n").allSatisfy { kind.unmergedPaths.contains(String($0)) })
    }

    @Test func withNoConflictItIsAddAll() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("keep.txt", "keep\n")
        try await Self.prepare(repo)
        try await repo.commitAll("base")
        try await Self.makeChanges(repo)
        try repo.write("staged.txt", "staged\n")
        try await repo.git(["add", "staged.txt"])
        try repo.write("staged.txt", "staged then edited\n")
        let reference = try Self.copy(repo)
        defer { reference.cleanUp() }
        try await reference.git(["add", "-A"])

        try await CLIGitBackend().stageAll(at: repo.root)

        let staged = try await Self.staging(repo)
        #expect(staged == (try await Self.staging(reference)))
        #expect(staged.contains { $0.hasSuffix("\tudir/sub/b") })
        #expect(staged.contains("ignored ignored.log"))
    }

    @Test func withNothingToStageItDoesNothing() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let before = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        try await CLIGitBackend().stageAll(at: repo.root)

        try await assertRepoUnchanged(repo, since: before, worktree: worktree)
    }
}
