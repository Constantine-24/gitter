import Foundation
import Testing

@testable import GitCore

/// Every way `merge(_:mode:at:)` can be refused, each one proving git changed **nothing** —
/// not a file, not HEAD, not the index, not a ref. A conflict is not in here: that is an
/// outcome, and it lives in `MergeTests.swift`.
@Suite struct MergeRefusalTests {
    /// Runs `body` on a repository, asserts it threw, and asserts the repository is
    /// byte-for-byte what it was beforehand.
    private static func refusal(
        _ repo: TestRepo, sourceLocation: SourceLocation = #_sourceLocation,
        _ body: (CLIGitBackend) async throws -> Void
    ) async throws -> Error? {
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        var thrown: Error?
        do {
            try await body(CLIGitBackend())
            Issue.record("expected a refusal, but the merge succeeded", sourceLocation: sourceLocation)
        } catch {
            thrown = error
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree,
                                      sourceLocation: sourceLocation)
        return thrown
    }

    // MARK: - A tracked file the merge would overwrite

    /// The two shapes git prints for the same hazard — exit 1 when the merge would have
    /// fast-forwarded, exit 2 when it would have been a true merge — both reach the UI as one
    /// error naming the file. Never key on the exit code.
    @Test(arguments: [MergeMode.fastForwardIfPossible, .alwaysMergeCommit, .squash])
    func aDirtyTrackedFileTheMergeWouldOverwrite(mode: MergeMode) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "my own edit\n")

        let error = try await Self.refusal(repo) { backend in
            _ = try await backend.merge("feature", mode: mode, at: repo.root)
        }
        #expect(error as? BranchOperationError == .wouldOverwrite(tracked: ["a.txt"], untracked: []))
    }

    @Test func aDirtyTrackedFileBlockingATrueMerge() async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "my own edit\n")

        let error = try await Self.refusal(repo) { backend in
            _ = try await backend.merge("feature", mode: .alwaysMergeCommit, at: repo.root)
        }
        #expect(error as? BranchOperationError == .wouldOverwrite(tracked: ["a.txt"], untracked: []))
    }

    // MARK: - An untracked file the merge would clobber

    @Test func anUntrackedFileInTheWay() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try await repo.git(["switch", "-q", "-c", "feature"])
        try repo.write("new.txt", "from the branch\n")
        try await repo.commitAll("add new.txt")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("new.txt", "mine, not committed\n")

        let error = try await Self.refusal(repo) { backend in
            _ = try await backend.merge("feature", mode: .fastForwardIfPossible, at: repo.root)
        }
        #expect(error as? BranchOperationError == .wouldOverwrite(tracked: [], untracked: ["new.txt"]))
        #expect(try repo.fileContents("new.txt") == "mine, not committed\n")
    }

    // MARK: - A dirty INDEX

    /// Verified on git 2.54, and a genuine surprise: a **true** merge refuses over *any* index
    /// entry that differs from HEAD, even one in a file the merge never touches. git still
    /// says "would be overwritten by merge", which is not true of `keep.txt` here, so this gets
    /// its own error rather than being folded into `.wouldOverwrite`.
    @Test(arguments: ["a.txt", "keep.txt"])
    func aStagedChangeRefusesATrueMergeEvenWhenTheMergeDoesNotTouchIt(path: String) async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }
        try repo.write(path, "staged\n")
        try await repo.git(["add", path])

        let error = try await Self.refusal(repo) { backend in
            _ = try await backend.merge("feature", mode: .alwaysMergeCommit, at: repo.root)
        }
        #expect(error as? BranchOperationError == .indexNotClean)
    }

    @Test func aStagedChangeRefusesASquashOfADivergedBranch() async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }
        try repo.write("keep.txt", "staged\n")
        try await repo.git(["add", "keep.txt"])

        let error = try await Self.refusal(repo) { backend in
            _ = try await backend.merge("feature", mode: .squash, at: repo.root)
        }
        #expect(error as? BranchOperationError == .indexNotClean)
    }

    /// The other half of the same verification: a **fast-forward** does not go through the
    /// merge strategy at all, so git allows it and the staged change rides along untouched.
    /// Recorded as a test so the asymmetry is a known fact rather than a surprise.
    @Test func aStagedChangeDoesNotBlockAFastForwardAndSurvivesIt() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try repo.write("keep.txt", "staged\n")
        try await repo.git(["add", "keep.txt"])
        let tip = try await repo.revParse("feature")

        let outcome = try await CLIGitBackend().merge(
            "feature", mode: .fastForwardIfPossible, at: repo.root)

        #expect(outcome == .fastForwarded)
        #expect(try await repo.headSha() == tip)
        #expect(try await repo.indexContent(of: "keep.txt") == Data("staged\n".utf8))
        #expect(try repo.fileContents("keep.txt") == "staged\n")
    }

    // MARK: - Another operation already in progress

    @Test func mergingWhileConflictsAreStillUnresolved() async throws {
        let repo = try await TestRepo.makeConflicting()
        defer { repo.cleanUp() }
        _ = try await CLIGitBackend().merge("feature", mode: .alwaysMergeCommit, at: repo.root)

        let error = try await Self.refusal(repo) { backend in
            _ = try await backend.merge("feature", mode: .alwaysMergeCommit, at: repo.root)
        }
        #expect(error as? BranchOperationError == .operationInProgress("resolving conflicts"))
    }

    /// Conflicts resolved but the merge not committed: `MERGE_HEAD` is still there and git
    /// refuses with different words, which must map to the same case.
    @Test func mergingWithAnUnconcludedMerge() async throws {
        let repo = try await TestRepo.makeConflicting()
        defer { repo.cleanUp() }
        _ = try await CLIGitBackend().merge("feature", mode: .alwaysMergeCommit, at: repo.root)
        try repo.write("a.txt", "resolved\n")
        try await repo.git(["add", "a.txt"])

        let error = try await Self.refusal(repo) { backend in
            _ = try await backend.merge("feature", mode: .alwaysMergeCommit, at: repo.root)
        }
        #expect(error as? BranchOperationError == .operationInProgress("merging"))
    }

    // MARK: - Nothing to merge

    @Test func aBranchThatDoesNotExist() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        let error = try await Self.refusal(repo) { backend in
            _ = try await backend.merge("nosuch-branch", mode: .fastForwardIfPossible, at: repo.root)
        }
        #expect(error as? BranchOperationError == .noSuchBranch("nosuch-branch"))
    }

    /// A name that would be read as an option never reaches git at all.
    @Test(arguments: ["-x", "--force", ""])
    func aNameGitWouldReadAsAnOptionIsRejectedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        let error = try await Self.refusal(repo) { backend in
            _ = try await backend.merge(name, mode: .fastForwardIfPossible, at: repo.root)
        }
        #expect(error as? BranchOperationError == .invalidName(name))
    }

    /// git refuses unrelated histories outright and Gitter does not recognise the wording, so
    /// it surfaces as `GitError.commandFailed` with git's own message — which is exactly the
    /// contract: nothing unrecognised is ever swallowed, and nothing changed.
    @Test(arguments: MergeMode.allCases)
    func unrelatedHistories(mode: MergeMode) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try await repo.git(["checkout", "-q", "--orphan", "orphan-branch"])
        try await repo.git(["rm", "-rq", "--cached", "."])
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("a.txt"))
        try repo.write("b.txt", "other history\n")
        try await repo.commitAll("orphan root")
        try await repo.git(["switch", "-q", "main"])

        let error = try await Self.refusal(repo) { backend in
            _ = try await backend.merge("orphan-branch", mode: mode, at: repo.root)
        }
        guard case .commandFailed(_, let stderr) = try #require(error as? GitError) else {
            Issue.record("expected GitError.commandFailed, got \(String(describing: error))")
            return
        }
        #expect(stderr.contains("refusing to merge unrelated histories"))
    }
}
