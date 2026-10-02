import Foundation
import Testing

@testable import GitCore

/// Ruling 22 (A2 Task 4, fix round 1): `AUTO_MERGE` can be stale while an operation is in
/// progress. Only ort writes it; `merge -s resolve`, an octopus merge and `cherry-pick` /
/// `revert --strategy=resolve` neither write nor delete it, and a clean cherry-pick, a clean
/// finished rebase or a clean `stash apply` leave one behind (M 31). `operationPaths` is
/// therefore the union of the `AUTO_MERGE` diff (dropped when detectably stale), the paths the
/// operation's source commits change, and the unmerged paths — and the M 21 trap stays shut.
@Suite struct StaleAutoMergeTests {
    private let backend = CLIGitBackend()

    static let zT1 = "z1\nz2 T1\nz3\n"

    /// base: f, z, p, o, d/z, ren; `t1` changes f, z, d/z and renames ren; `t2` changes o;
    /// `pickme` changes p; `main` changes f.
    private func lab() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("f.txt", "a\nb\nc\n")
        try repo.write("z.txt", "z1\nz2\nz3\n")
        try repo.write("p.txt", "p\n")
        try repo.write("o.txt", "o\n")
        try repo.write("d/z.txt", "dz\n")
        try repo.write("ren.txt", (1...8).map { "r\($0)\n" }.joined())
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "t1"])
        try repo.write("f.txt", "a\nb T1\nc\n")
        try repo.write("z.txt", Self.zT1)
        try repo.write("d/z.txt", "dz T1\n")
        try await repo.git(["mv", "ren.txt", "renamed.txt"])
        try await repo.commitAll("t1")
        try await repo.git(["switch", "-q", "-c", "t2", "main"])
        try repo.write("o.txt", "o T2\n")
        try await repo.commitAll("t2")
        try await repo.git(["switch", "-q", "-c", "pickme", "main"])
        try repo.write("p.txt", "p PICK\n")
        try await repo.commitAll("pick")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", "a\nb MAIN\nc\n")
        try await repo.commitAll("main")
        return repo
    }

    /// A clean cherry-pick: it leaves `AUTO_MERGE` behind (M 31), the stale tree below.
    private func leaveAStaleAutoMerge(_ repo: TestRepo) async throws {
        try await repo.git(["cherry-pick", "pickme"])
        #expect(try await backend.operationInProgress(at: repo.root) == nil)
        #expect(!(try await repo.git(["rev-parse", "-q", "--verify", "AUTO_MERGE"], allowedExitCodes: [1])).isEmpty,
                "no stale AUTO_MERGE: the test proves nothing")
    }

    private func autoMergeDiff(_ repo: TestRepo) async throws -> Set<String> {
        let data = try await repo.git(["diff", "--name-only", "-z", "--no-renames", "HEAD", "AUTO_MERGE"])
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init))
    }

    private func staged(_ paths: [String], _ repo: TestRepo) async throws -> DiscardRequest {
        .stagedAndUnstaged(paths: paths, expected: try await backend.discardExpectation(tracked: paths, includingStaged: true, at: repo.root))
    }

    /// Refused with `refusal`, and nothing written: worktree, HEAD, index, refs, `refs/stash`,
    /// the operation's files.
    private func expectRefused(
        _ request: DiscardRequest, _ refusal: DiscardRefusal, in repo: TestRepo,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let stash = try await repo.stashRef()
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        await #expect(throws: refusal, sourceLocation: sourceLocation) {
            _ = try await backend.discard(request, trasher: trasher, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree, sourceLocation: sourceLocation)
        try await assertOperationUnchanged(repo, since: operation, sourceLocation: sourceLocation)
        #expect(try await repo.stashRef() == stash, "refs/stash moved", sourceLocation: sourceLocation)
    }

    enum NonOrt: String, CaseIterable, Sendable { case octopus, resolve, pickResolve }

    /// The review's probe: after a clean cherry-pick, each non-ort stop stages `z.txt` (t1's
    /// change) while `AUTO_MERGE` is the pick's tree — `diff HEAD AUTO_MERGE` is empty. The
    /// staged side of `z.txt` is the operation's.
    @Test(arguments: NonOrt.allCases)
    func aNonOrtStopOverAStaleAutoMergeKeepsItsOwnPaths(_ how: NonOrt) async throws {
        let repo = try await lab()
        defer { repo.cleanUp() }
        try await leaveAStaleAutoMerge(repo)
        switch how {
        case .octopus: try await repo.git(["merge", "--no-edit", "t2", "t1"], allowedExitCodes: [1, 2])
        case .resolve: try await repo.git(["merge", "--no-edit", "-s", "resolve", "t1"], allowedExitCodes: [1])
        case .pickResolve: try await repo.git(["cherry-pick", "--strategy=resolve", "t1"], allowedExitCodes: [1])
        }
        #expect(try await backend.operationInProgress(at: repo.root) == (how == .pickResolve ? .cherryPick : .merge))
        #expect(try await repo.indexContent(of: "z.txt") == Data(Self.zT1.utf8))
        #expect(try await autoMergeDiff(repo).isEmpty, "AUTO_MERGE is not the stale pick tree")

        let paths = Set(try #require(try await backend.operationPaths(at: repo.root)))
        #expect(paths.isSuperset(of: ["f.txt", "z.txt", "d/z.txt", "ren.txt", "renamed.txt"]))
        #expect(!paths.contains("p.txt"))
        try await expectRefused(try await staged(["z.txt"], repo), .partOfOperation(["z.txt"]), in: repo)
    }

    /// A clean `merge -s resolve --no-commit --no-ff` stop: nothing unmerged, so a stale
    /// `AUTO_MERGE` cannot be told from a fresh one; the source commit's paths still count.
    @Test func aCleanResolveMergeStopKeepsItsOwnPaths() async throws {
        let repo = try await lab()
        defer { repo.cleanUp() }
        try await leaveAStaleAutoMerge(repo)
        try await repo.git(["merge", "-q", "--no-edit", "-s", "resolve", "--no-commit", "--no-ff", "t2"])
        #expect(try await backend.operationInProgress(at: repo.root) == .merge)
        #expect(try await repo.indexContent(of: "o.txt") == Data("o T2\n".utf8))

        let paths = Set(try #require(try await backend.operationPaths(at: repo.root)))
        #expect(paths.contains("o.txt"))
        try await expectRefused(try await staged(["o.txt"], repo), .partOfOperation(["o.txt"]), in: repo)
    }

    /// A clean `stash apply` leaves an `AUTO_MERGE` holding the user's own change (p.txt). At
    /// the conflicted resolve stop that follows it is detectably stale — it does not differ from
    /// HEAD at the conflicted f.txt — so p.txt is not the operation's, and z.txt is.
    @Test func aStaleAutoMergeFromAStashApplyIsNotTheOperations() async throws {
        let repo = try await lab()
        defer { repo.cleanUp() }
        try repo.write("p.txt", "p USER\n")
        try await repo.git(["stash", "push", "-q"])
        try await repo.git(["stash", "apply", "-q"])
        #expect(try await autoMergeDiff(repo) == ["p.txt"], "the stash apply wrote no AUTO_MERGE of its own")
        try await repo.git(["merge", "--no-edit", "-s", "resolve", "t1"], allowedExitCodes: [1])
        #expect(try await backend.operationInProgress(at: repo.root) == .merge)
        try await repo.git(["add", "--", "p.txt"])
        #expect(try await autoMergeDiff(repo) == ["p.txt"])

        let paths = Set(try #require(try await backend.operationPaths(at: repo.root)))
        #expect(!paths.contains("p.txt"))
        #expect(paths.isSuperset(of: ["f.txt", "z.txt"]))
        try await expectRefused(try await staged(["z.txt"], repo), .partOfOperation(["z.txt"]), in: repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        _ = try await backend.discard(try await staged(["p.txt"], repo), trasher: trasher, at: repo.root)
        #expect(try repo.bytes("p.txt") == Data("p\n".utf8))
    }

    enum OrtStop: String, CaseIterable, Sendable { case merge, squash }

    /// ort follows a rename: ours renamed a.txt to b.txt, theirs changed a.txt, and the change
    /// lands in b.txt — a path no source commit names. The fresh `AUTO_MERGE` keeps it in the
    /// set (a squash has no source commit at all, so this is all it has).
    @Test(arguments: OrtStop.allCases)
    func ortsRenameFollowingPathIsTheOperations(_ stop: OrtStop) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", (1...8).map { "a\($0)\n" }.joined())
        try repo.write("f.txt", "a\nb\nc\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "theirs"])
        try repo.write("a.txt", (1...8).map { $0 == 4 ? "a4 THEIRS\n" : "a\($0)\n" }.joined())
        try repo.write("f.txt", "a\nb T\nc\n")
        try await repo.commitAll("theirs")
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["mv", "a.txt", "b.txt"])
        try repo.write("f.txt", "a\nb M\nc\n")
        try await repo.commitAll("ours")
        try await repo.git(stop == .merge ? ["merge", "--no-edit", "theirs"] : ["merge", "--squash", "theirs"], allowedExitCodes: [1])
        #expect(try await backend.operationInProgress(at: repo.root) == (stop == .merge ? .merge : .squash))
        #expect(String(decoding: try await repo.indexContent(of: "b.txt"), as: UTF8.self).contains("a4 THEIRS"))

        let paths = Set(try #require(try await backend.operationPaths(at: repo.root)))
        #expect(paths.isSuperset(of: ["b.txt", "f.txt"]))
        try await expectRefused(try await staged(["b.txt"], repo), .partOfOperation(["b.txt"]), in: repo)
    }

    /// A squash records no source commit, so without a conflict to show that `AUTO_MERGE` is
    /// fresh its paths cannot be told: nil, every staged path the operation's.
    @Test func aCleanSquashCannotTellItsPaths() async throws {
        let repo = try await lab()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "-q", "--squash", "t2"])
        #expect(try await backend.operationInProgress(at: repo.root) == .squash)
        #expect(try await autoMergeDiff(repo) == ["o.txt"])

        #expect(try await backend.operationPaths(at: repo.root) == nil)
    }

    /// Task 3's readiness on a stale-`AUTO_MERGE` stop: every staged path is the stopped
    /// commit's, so Skip is ready, and after the resolution Continue is, with no "other" path.
    @Test func skipAndContinueReadinessCountTheCommitsPathsOverAStaleAutoMerge() async throws {
        let repo = try await lab()
        defer { repo.cleanUp() }
        try await leaveAStaleAutoMerge(repo)
        try await repo.git(["cherry-pick", "--strategy=resolve", "t1"], allowedExitCodes: [1])
        #expect(try await autoMergeDiff(repo).isEmpty)

        let skip = try await backend.skipReadiness(at: repo.root)
        guard case .ready(let paths) = skip else {
            Issue.record("expected .ready, got \(skip)")
            return
        }
        #expect(Set(paths).isSuperset(of: ["f.txt", "z.txt"]))

        try repo.write("f.txt", "a\nb RESOLVED\nc\n")
        try await repo.git(["add", "--", "f.txt"])
        #expect(try await backend.continueReadiness(at: repo.root) == .ready)
    }
}
