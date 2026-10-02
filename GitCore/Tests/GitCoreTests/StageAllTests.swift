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

    /// The three V4 measured by hand, pinned: an intent-to-add entry, a nested repository, and
    /// an intent-to-add *rename* — `mv q e; git add -N e` reads `2 .R … e` then `q`, and the
    /// deleted `q` has no record of its own, so it is staged through the pair's original path
    /// (fix round 1). With and without a conflict beside them.
    @Test(arguments: [false, true])
    func intentToAddAndNestedRepositoriesAreStagedAsAddAllStagesThem(conflict: Bool) async throws {
        let repo = conflict
            ? try await ConflictFixtures.merge(kind: .bothModified) { try $0.write("q", "q\n") }
            : try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        if !conflict {
            try repo.write("keep.txt", "keep\n")
            try repo.write("q", "q\n")
            try await repo.commitAll("base")
        }
        try FileManager.default.moveItem(
            at: repo.root.appendingPathComponent("q"), to: repo.root.appendingPathComponent("e"))
        try await repo.git(["add", "-N", "e"])
        try repo.write("ita.txt", "intent to add\n")
        try await repo.git(["add", "-N", "ita.txt"])
        let nested = TestRepo(root: repo.root.appendingPathComponent("nested"))
        try FileManager.default.createDirectory(at: nested.root, withIntermediateDirectories: true)
        try await nested.git(["init", "-q", "-b", "main"])
        try nested.write("n", "n\n")
        try await nested.git(["add", "n"])
        try await nested.git(["-c", "user.name=t", "-c", "user.email=t@t", "commit", "-q", "-m", "n"])
        let porcelain = String(decoding: try await repo.git(["status", "--porcelain=v2", "-z"]), as: UTF8.self)
        #expect(porcelain.contains(" e\0q\0"), "\(porcelain.debugDescription)")
        let unmerged = String(decoding: try await repo.git(["ls-files", "-u", "-s"]), as: UTF8.self)
        let reference = try Self.copy(repo)
        defer { reference.cleanUp() }
        try await reference.git(["add", "-A"])

        try await CLIGitBackend().stageAll(at: repo.root)

        let expected = try await Self.staging(reference).filter { !$0.hasSuffix("\tf.txt") }
            + unmerged.split(separator: "\n").map(String.init)
        let staged = try await Self.staging(repo)
        #expect(staged.sorted() == expected.sorted())
        #expect(!staged.contains { $0.hasSuffix("\tq") }, "q stayed in the index")
        #expect(staged.contains { $0.hasPrefix("160000 ") && $0.hasSuffix("\tnested") })
    }

    /// Fix round 2: a conflicted file moved to a new name that is then marked intent-to-add
    /// reads `2 .R … e` then the *unmerged* path as the pair's original, beside that path's own
    /// `u` record. The original must not be added: that would resolve the conflict as a
    /// deletion. A UD (the worktree holds ours) and a UU whose worktree was set to stage 2.
    @Test(arguments: [(ConflictFixtureKind.deletedByThem, "ud.txt"), (.bothModified, "f.txt")])
    func aConflictedPathPairedWithAnIntentToAddRenameStaysUnmerged(kind: ConflictFixtureKind, path: String) async throws {
        let repo = try await ConflictFixtures.merge(kind: kind)
        defer { repo.cleanUp() }
        let url = repo.root.appendingPathComponent(path)
        try await repo.git(["show", ":2:\(path)"]).write(to: url)
        try FileManager.default.moveItem(at: url, to: repo.root.appendingPathComponent("e"))
        try await repo.git(["add", "-N", "e"])
        try repo.write("keep.txt", "keep EDITED\n")
        let porcelain = String(decoding: try await repo.git(["status", "--porcelain=v2", "-z"]), as: UTF8.self)
        // Not vacuous: git really does pair the new name with the conflicted path.
        #expect(porcelain.contains(" e\0\(path)\0"), "\(porcelain.debugDescription)")
        let unmerged = String(decoding: try await repo.git(["ls-files", "-u", "-s"]), as: UTF8.self)
        #expect(!unmerged.isEmpty)
        let reference = try Self.copy(repo)
        defer { reference.cleanUp() }
        try await reference.git(["add", "-A"])

        try await CLIGitBackend().stageAll(at: repo.root)

        #expect(String(decoding: try await repo.git(["ls-files", "-u", "-s"]), as: UTF8.self) == unmerged)
        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        #expect(status.files.first { $0.path == path }?.conflict?.kind == (kind == .bothModified ? .bothModified : .deletedByThem))
        let expected = try await Self.staging(reference).filter { !$0.hasSuffix("\t\(path)") }
            + unmerged.split(separator: "\n").map(String.init)
        #expect(try await Self.staging(repo).sorted() == expected.sorted())
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

/// Final review M1 (measured on git 2.54): the snapshot's status honours
/// `status.showUntrackedFiles=no`, so an untracked `secret.env` is not on screen, while Stage All
/// reads `--untracked-files=normal` and adds it — a merge's Commit then took it unasked. The
/// confirmation is built from `stageAllPaths`, the very list `stageAll` stages, and the staging
/// refuses a list that is not the confirmed one.
@Suite struct StageAllPreviewTests {
    static let backend = CLIGitBackend()

    /// A merge stopped on f.txt (resolved, staged) and h.txt (still unmerged); g.txt edited; an
    /// untracked secret.env; `status.showUntrackedFiles=no`.
    static func mergeWithAHiddenFile() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("f.txt", "a\n")
        try repo.write("g.txt", "g\n")
        try repo.write("h.txt", "h\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "feature"])
        try repo.write("f.txt", "F\n")
        try repo.write("h.txt", "H F\n")
        try await repo.commitAll("F")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", "M\n")
        try repo.write("h.txt", "H M\n")
        try await repo.commitAll("M")
        try await repo.git(["config", "status.showUntrackedFiles", "no"])
        try await repo.git(["merge", "feature"], allowedExitCodes: [1])
        try repo.write("f.txt", "RES\n")
        try await repo.git(["add", "f.txt"])
        try repo.write("g.txt", "g edit\n")
        try repo.write("secret.env", "SECRET=1\n")
        return repo
    }

    @Test func thePreviewIsExactlyWhatStageAllStagesWhateverShowUntrackedFiles() async throws {
        let repo = try await Self.mergeWithAHiddenFile()
        defer { repo.cleanUp() }
        // The baseline that can fail: the snapshot does not show the untracked file.
        let shown = try await Self.backend.snapshot(at: repo.root).status.files.map(\.path)
        #expect(!shown.contains("secret.env"))
        #expect(shown.contains("g.txt"))

        let preview = try await Self.backend.stageAllPaths(at: repo.root)
        #expect(Set(preview) == ["g.txt", "secret.env"])

        let reference = try StageAllTests.copy(repo)
        defer { reference.cleanUp() }
        try await Self.backend.stageAll(at: reference.root)
        try await Self.backend.stageAll(expecting: preview, at: repo.root)

        #expect(try await StageAllTests.staging(repo) == (try await StageAllTests.staging(reference)))
        #expect(try await repo.isInIndex("secret.env"))
        let unmerged = String(decoding: try await repo.git(["ls-files", "-u"]), as: UTF8.self)
        #expect(unmerged.contains("h.txt"), "the conflict stays")
    }

    /// The list the snapshot would have shown (no secret.env): refused, nothing staged.
    @Test func aListThatIsNotTheCurrentOneIsRefusedAndNothingIsStaged() async throws {
        let repo = try await Self.mergeWithAHiddenFile()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: StageAllChanged(paths: ["g.txt", "secret.env"])) {
            try await Self.backend.stageAll(expecting: ["g.txt"], at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
        #expect(!(try await repo.isInIndex("secret.env")))
    }
}
