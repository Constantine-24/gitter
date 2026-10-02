import Foundation
import Testing

@testable import GitCore

/// A2 Task 4, fix round 4: a source read that fails makes the operation's source part unknown
/// instead of making `operationPaths` throw. The rule then is the one a squash without commit
/// lines always had: `AUTO_MERGE` ∪ the unmerged paths when a text conflict proves `AUTO_MERGE`
/// fresh, else nil (every staged path counts as the operation's). And a squash of more commits
/// than one argument list holds is read in batches, not refused by the kernel.
@Suite struct OperationSourceFailureTests {
    private let backend = CLIGitBackend()

    /// A full-length object name no repository holds.
    static let missingCommit = String(repeating: "de", count: 20)

    enum Edit: String, CaseIterable, Sendable {
        /// The real `commit <sha>` line replaced by a missing commit's.
        case replaced
        /// A missing commit's line put before the real one.
        case prepended
    }

    private func staged(_ paths: [String], _ repo: TestRepo) async throws -> DiscardRequest {
        .stagedAndUnstaged(paths: paths, expected: try await backend.discardExpectation(tracked: paths, includingStaged: true, at: repo.root))
    }

    /// A conflicted ort squash (`f.txt` UU) whose `SQUASH_MSG` names a missing commit, with the
    /// user's own change to keep.txt staged.
    private func squashNamingAMissingCommit(_ edit: Edit) async throws -> TestRepo {
        let repo = try await ConflictFixtures.squash(kind: .bothModified)
        let url = repo.root.appendingPathComponent(".git/SQUASH_MSG")
        let original = try String(contentsOf: url, encoding: .utf8)
        let bogus = "commit \(Self.missingCommit)"
        let edited: String
        switch edit {
        case .replaced:
            edited = original.replacingOccurrences(
                of: #"(?m)^commit [0-9a-f]{40}$"#, with: bogus, options: .regularExpression)
        case .prepended:
            edited = bogus + "\n" + original
        }
        #expect(edited != original && edited.contains(bogus))
        let real = try await repo.revParse("theirs")
        #expect(original.contains("commit \(real)"))
        #expect(edited.contains("commit \(real)") == (edit == .prepended))
        try Data(edited.utf8).write(to: url)
        try repo.write("keep.txt", "keep USER\n")
        try await repo.git(["add", "--", "keep.txt"])
        #expect(try await backend.operationInProgress(at: repo.root) == .squash)
        // A baseline that can fail: git itself cannot read the commit the message names.
        let failed = try await repo.git(["merge-base", "--independent", Self.missingCommit], allowedExitCodes: [128])
        #expect(failed.isEmpty)
        return repo
    }

    /// Refused before anything was written; refs/stash and the operation's files untouched.
    private func expectRefused(_ request: DiscardRequest, _ refusal: DiscardRefusal, in repo: TestRepo) async throws {
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let stash = try await repo.stashRef()
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        await #expect(throws: refusal) {
            _ = try await backend.discard(request, trasher: trasher, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
        #expect(try await repo.stashRef() == stash, "refs/stash moved")
    }

    // MARK: - A squash whose message names a missing commit

    /// While f.txt's text conflict shows `AUTO_MERGE` fresh, the squash's paths are `AUTO_MERGE`
    /// ∪ unmerged: f.txt is the squash's, the user's keep.txt is not, and its staged side can be
    /// discarded. The conflict document reads as before.
    @Test(arguments: Edit.allCases)
    func aMissingCommitInTheMessageFallsBackToAFreshAutoMerge(_ edit: Edit) async throws {
        let repo = try await squashNamingAMissingCommit(edit)
        defer { repo.cleanUp() }

        let paths = try #require(try await backend.operationPaths(at: repo.root))
        #expect(paths.contains("f.txt"))
        #expect(!paths.contains("keep.txt"))
        #expect(try await backend.canReopen("f.txt", at: repo.root) == false, "f.txt is still unmerged")
        let file = try #require(try await backend.snapshot(at: repo.root).status.files.first { $0.path == "f.txt" }?.conflict)
        let document = try await backend.conflictDocument(for: file, at: repo.root)
        #expect(document.matchesGitsConflict)

        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        _ = try await backend.discard(try await staged(["keep.txt"], repo), trasher: trasher, at: repo.root)
        #expect(try repo.bytes("keep.txt") == Data("keep\n".utf8))
        #expect(try await repo.indexContent(of: "keep.txt") == Data("keep\n".utf8))
        #expect(try await backend.operationInProgress(at: repo.root) == .squash)
    }

    /// Once f.txt is resolved nothing proves `AUTO_MERGE` fresh: the paths are unknown (nil),
    /// f.txt cannot be reopened, and every staged-side discard is refused with nothing written.
    @Test(arguments: Edit.allCases)
    func aMissingCommitInTheMessageWithNoConflictLeftRefusesEveryStagedPath(_ edit: Edit) async throws {
        let repo = try await squashNamingAMissingCommit(edit)
        defer { repo.cleanUp() }
        try await ReopenTests.resolveUU(repo)

        #expect(try await backend.operationPaths(at: repo.root) == nil)
        #expect(try await backend.canReopen("f.txt", at: repo.root) == false)
        try await expectRefused(try await staged(["keep.txt"], repo), .partOfOperation(["keep.txt"]), in: repo)
    }

    // MARK: - A merge whose MERGE_HEAD names a missing commit

    /// The same rule for a merge: a missing commit in `MERGE_HEAD` falls back to the fresh
    /// `AUTO_MERGE` while a text conflict proves it, and to nil after.
    @Test func aMissingCommitInMergeHeadFallsBackToTheConservativeRule() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let url = repo.root.appendingPathComponent(".git/MERGE_HEAD")
        try Data("\(Self.missingCommit)\n".utf8).write(to: url)
        try repo.write("keep.txt", "keep USER\n")
        try await repo.git(["add", "--", "keep.txt"])
        #expect(try await backend.operationInProgress(at: repo.root) == .merge)

        let paths = try #require(try await backend.operationPaths(at: repo.root))
        #expect(paths.contains("f.txt"))
        #expect(!paths.contains("keep.txt"))

        try await ReopenTests.resolveUU(repo)
        #expect(try await backend.operationPaths(at: repo.root) == nil)
        #expect(try await backend.canReopen("f.txt", at: repo.root) == false)
        try await expectRefused(try await staged(["keep.txt"], repo), .partOfOperation(["keep.txt"]), in: repo)
    }

    // MARK: - A squash of more commits than one argument list holds

    /// 30 000 commits on `t`, each rewriting f.txt, squashed onto `main` as a fast-forward (no
    /// `AUTO_MERGE`): `SQUASH_MSG` lists every one, ≈1.2 MB of object names, over macOS's
    /// 1 MiB ARG_MAX (measured: 24 000 already fails with E2BIG). The squash's paths are still
    /// read from the message — f.txt, not the user's u.txt.
    @Test func aSquashOfMoreCommitsThanOneArgumentListHoldsIsReadInBatches() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f.txt", "base\n")
        try repo.write("u.txt", "u\n")
        try await repo.commitAll("base")
        let count = 30_000
        var stream = "reset refs/heads/t\nfrom refs/heads/main\n"
        for i in 0..<count {
            let data = "\(i)\n"
            stream += "commit refs/heads/t\ncommitter t <t@t> \(1_700_000_000 + i) +0000\ndata 2\nc\n"
            stream += "M 100644 inline f.txt\ndata \(data.utf8.count)\n\(data)\n"
        }
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("gitter-fi-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data(stream.utf8).write(to: file)
        _ = try await isolatedRunner().run(
            "/bin/sh", ["-c", "exec /usr/bin/git fast-import --quiet < \"$1\"", "sh", file.path], cwd: repo.root)
        try await repo.git(["merge", "-q", "--squash", "t"])
        #expect(try await backend.operationInProgress(at: repo.root) == .squash)
        #expect((try await repo.git(["rev-parse", "-q", "--verify", "AUTO_MERGE"], allowedExitCodes: [1])).isEmpty,
                "an AUTO_MERGE would let the fallback pass this test")
        let message = try String(contentsOf: repo.root.appendingPathComponent(".git/SQUASH_MSG"), encoding: .utf8)
        let listed = message.split(separator: "\n").filter { $0.hasPrefix("commit ") }.count
        #expect(listed == count)
        #expect(listed * 41 > 1 << 20, "the list fits one argument list: the test proves less")
        try repo.write("u.txt", "u USER\n")
        try await repo.git(["add", "--", "u.txt"])

        #expect(try await backend.operationPaths(at: repo.root) == ["f.txt"])
        try await expectRefused(try await staged(["f.txt"], repo), .partOfOperation(["f.txt"]), in: repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        _ = try await backend.discard(try await staged(["u.txt"], repo), trasher: trasher, at: repo.root)
        #expect(try await repo.indexContent(of: "u.txt") == Data("u\n".utf8))
    }
}
