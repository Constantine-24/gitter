import Foundation
import Testing

@testable import GitCore

/// Ruling 25 (A2 Task 4, fix round 3): what an operation's source commits change, on ordinary
/// ort stops. A squash reads its commits from `SQUASH_MSG` (its tip, `merge-base
/// --independent` of the listed commits, against each merge base with HEAD), so its paths
/// outlive its last conflict. A source commit with several parents — `cherry-pick -m` /
/// `revert -m` of a merge — is read against its mainline only: `sequencer/opts`' `mainline`
/// for a range, else the parent whose changes cover the `AUTO_MERGE` diff.
@Suite struct OperationSourceTests {
    private let backend = CLIGitBackend()

    private func staged(_ paths: [String], _ repo: TestRepo) async throws -> DiscardRequest {
        .stagedAndUnstaged(paths: paths, expected: try await backend.discardExpectation(tracked: paths, includingStaged: true, at: repo.root))
    }

    // MARK: - A squash after its last conflict (R1)

    /// A conflicted squash, every conflict resolved: no text conflict is left to show
    /// `AUTO_MERGE` fresh, but `SQUASH_MSG` still names the squashed commit. f.txt can be
    /// reopened, and the user's own staged u.txt is not the squash's.
    @Test func aSquashKeepsItsPathsAfterItsLastConflictIsResolved() async throws {
        let repo = try await ConflictFixtures.squash(kind: .bothModified, prepare: { repo in
            try repo.write("u.txt", "u\n")
        })
        defer { repo.cleanUp() }
        try await ReopenTests.resolveUU(repo)
        try repo.write("u.txt", "u USER\n")
        try await repo.git(["add", "--", "u.txt"])
        #expect(try await backend.operationInProgress(at: repo.root) == .squash)
        #expect(try await repo.git(["ls-files", "-u"]).isEmpty)

        let paths = Set(try #require(try await backend.operationPaths(at: repo.root)))
        #expect(paths.contains("f.txt"))
        #expect(!paths.contains("u.txt"))
        #expect(try await backend.canReopen("f.txt", at: repo.root))
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        _ = try await backend.discard(try await staged(["u.txt"], repo), trasher: trasher, at: repo.root)
        #expect(try repo.bytes("u.txt") == Data("u\n".utf8))
        #expect(try await repo.indexContent(of: "u.txt") == Data("u\n".utf8))
    }

    /// A clean `merge --squash -s resolve` right after a clean pick: `AUTO_MERGE` is the pick's
    /// and nothing is unmerged, so only `SQUASH_MSG` tells the squash's o.txt from the user's
    /// staged z.txt.
    @Test func aCleanResolveSquashReadsItsPathsFromItsMessage() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("o.txt", "o\n")
        try repo.write("p.txt", "p\n")
        try repo.write("z.txt", "z\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "t2"])
        try repo.write("o.txt", "o T2\n")
        try await repo.commitAll("t2")
        try await repo.git(["switch", "-q", "-c", "pickme", "main"])
        try repo.write("p.txt", "p PICK\n")
        try await repo.commitAll("pick")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("z.txt", "z MAIN\n")
        try await repo.commitAll("main")
        try await repo.git(["cherry-pick", "pickme"])
        try await repo.git(["merge", "-q", "--squash", "-s", "resolve", "t2"])
        #expect(try await backend.operationInProgress(at: repo.root) == .squash)
        #expect(!(try await repo.git(["rev-parse", "-q", "--verify", "AUTO_MERGE"], allowedExitCodes: [1])).isEmpty,
                "no stale AUTO_MERGE: the test proves less")
        #expect(try await repo.indexContent(of: "o.txt") == Data("o T2\n".utf8))
        try repo.write("z.txt", "z USER\n")
        try await repo.git(["add", "--", "z.txt"])

        let paths = Set(try #require(try await backend.operationPaths(at: repo.root)))
        #expect(paths.contains("o.txt"))
        #expect(!paths.contains("z.txt"))
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        await #expect(throws: DiscardRefusal.partOfOperation(["o.txt"])) {
            _ = try await backend.discard(try await staged(["o.txt"], repo), trasher: trasher, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        _ = try await backend.discard(try await staged(["z.txt"], repo), trasher: trasher, at: repo.root)
        #expect(try repo.bytes("z.txt") == Data("z MAIN\n".utf8))
    }

    // MARK: - A merge commit picked or reverted against its mainline (R2)

    /// base: f.txt, s.txt. `side` changes f and s; `main` adds m.txt, then merges side (M1),
    /// then adds m2.txt and merges `side2` (q.txt, M2). `other`, from base, changes f.
    private func mergeHistory() async throws -> (repo: TestRepo, m1: String, m2: String) {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("f.txt", "a\nb\nc\n")
        try repo.write("s.txt", "s\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "side"])
        try repo.write("s.txt", "s SIDE\n")
        try repo.write("f.txt", "a\nb SIDE\nc\n")
        try await repo.commitAll("side1")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("m.txt", "m\n")
        try await repo.commitAll("m1")
        try await repo.git(["merge", "-q", "--no-edit", "side"])
        let m1 = try await repo.headSha()
        try await repo.git(["switch", "-q", "-c", "side2", "main"])
        try repo.write("q.txt", "q\n")
        try await repo.commitAll("side2")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("m2.txt", "m2\n")
        try await repo.commitAll("m2")
        try await repo.git(["merge", "-q", "--no-edit", "side2"])
        let m2 = try await repo.headSha()
        try await repo.git(["switch", "-q", "-c", "other", "main~3"])
        try repo.write("f.txt", "a\nb OTHER\nc\n")
        try await repo.commitAll("o1")
        return (repo, m1, m2)
    }

    /// The stop's conflict resolved, then the user stages `path`: Continue must name it.
    private func expectOtherStaged(_ path: String, _ text: String, in repo: TestRepo, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        try repo.write("f.txt", "a\nb RESOLVED\nc\n")
        try await repo.git(["add", "--", "f.txt"])
        try repo.write(path, text)
        try await repo.git(["add", "--", path])
        let paths = try #require(try await backend.operationPaths(at: repo.root), sourceLocation: sourceLocation)
        #expect(!paths.contains(path), "\(path) counted as the operation's: \(paths)", sourceLocation: sourceLocation)
        #expect(try await backend.continueReadiness(at: repo.root) == .otherStagedChanges([path]), sourceLocation: sourceLocation)
    }

    @Test func aMergeCommitPickedAgainstItsMainlineDoesNotOwnTheMainlinesPaths() async throws {
        let (repo, m1, _) = try await mergeHistory()
        defer { repo.cleanUp() }
        try await repo.git(["cherry-pick", "-m", "1", m1], allowedExitCodes: [1])
        #expect(try await backend.operationInProgress(at: repo.root) == .cherryPick)
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(".git/sequencer").path))

        try await expectOtherStaged("m.txt", "m USER\n", in: repo)
    }

    @Test func aMergeCommitRevertedAgainstItsMainlineDoesNotOwnTheMainlinesPaths() async throws {
        let (repo, m1, _) = try await mergeHistory()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", "a\nb LATER\nc\n")
        try await repo.commitAll("later")
        try await repo.git(["revert", "-m", "1", "--no-edit", m1], allowedExitCodes: [1])
        #expect(try await backend.operationInProgress(at: repo.root) == .revert)

        try await expectOtherStaged("m.txt", "m USER\n", in: repo)
    }

    /// A range records its mainline in `sequencer/opts` (`mainline = 1`, measured).
    @Test func aRangeOfMergeCommitsUsesTheRecordedMainline() async throws {
        let (repo, m1, m2) = try await mergeHistory()
        defer { repo.cleanUp() }
        try await repo.git(["cherry-pick", "-m", "1", m1, m2], allowedExitCodes: [1])
        #expect(try await backend.operationInProgress(at: repo.root) == .cherryPick)
        let opts = try String(contentsOf: repo.root.appendingPathComponent(".git/sequencer/opts"), encoding: .utf8)
        #expect(opts.contains("mainline = 1"))

        try await expectOtherStaged("m.txt", "m USER\n", in: repo)
    }
}
