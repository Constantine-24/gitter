import Foundation
import Testing

@testable import GitCore

/// `deleteBranch` against a real git. One of only three actions in Gitter that can lose
/// anything, so every refusal here proves — via `RepoState` and the worktree snapshot — that
/// git changed nothing, not just that Gitter reported the right error. `commitsOnlyOn`'s own
/// semantics are covered separately in `CommitsOnlyOnTests.swift`.
@Suite struct BranchDeleteTests {
    private let backend = CLIGitBackend()

    // MARK: - merged

    @Test func deletingAMergedBranchSucceedsWithoutForce() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "-q", "--no-ff", "feature", "-m", "merge feature"])

        let result = try await backend.deleteBranch("feature", force: false, at: repo.root)

        #expect(result == .deleted)
        #expect(try await repo.localBranches() == ["main"])
    }

    // MARK: - not fully merged

    /// `makeBranched` puts exactly one commit on `feature` that `main` does not have.
    @Test func deletingAnUnmergedBranchWithoutForceReturnsTheCountAndTipAndLeavesItInPlace()
        async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let tip = try await repo.revParse("feature")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let result = try await backend.deleteBranch("feature", force: false, at: repo.root)

        #expect(result == .notFullyMerged(uniqueCommits: 1, tip: tip))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.localBranches() == ["feature", "main"])
    }

    @Test func forceDeletingAnUnmergedBranchDeletesItAndTheTipObjectStillExists() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let tip = try await repo.revParse("feature")

        let result = try await backend.deleteBranch("feature", force: true, at: repo.root)

        #expect(result == .deleted)
        #expect(try await repo.localBranches() == ["main"])
        // Still an object in the store: a user can `git branch feature <tip>` from the warning.
        _ = try await repo.git(["cat-file", "-e", tip])
    }

    /// `-d` compares against `sink`, which reaches "feature"'s commit — but `commitsOnlyOn`
    /// reports 0 too, because `sink` is a live ref. The disagreement direction that matters (`-d`
    /// refusing while the count is 0) is covered in `CommitsOnlyOnTests`.
    @Test func deletingABranchMergedElsewhereButNotIntoHeadIsNotFullyMerged() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "-c", "sink", "main"])
        try await repo.git(["merge", "-q", "--no-ff", "feature", "-m", "merge feature into sink"])
        try await repo.git(["switch", "-q", "main"])
        let tip = try await repo.revParse("feature")

        let result = try await backend.deleteBranch("feature", force: false, at: repo.root)

        #expect(result == .notFullyMerged(uniqueCommits: 0, tip: tip))
    }

    // MARK: - current branch, force or not

    @Test(arguments: [false, true])
    func deletingTheCurrentBranchIsRefused(force: Bool) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            _ = try await backend.deleteBranch("main", force: force, at: repo.root)
        }

        #expect(error == .cannotDeleteCurrent("main"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    // MARK: - checked out in a linked worktree

    @Test func deletingABranchCheckedOutInALinkedWorktreeIsRefused() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let worktreePath = repo.root.deletingLastPathComponent()
            .appendingPathComponent("\(repo.root.lastPathComponent)-linked-wt", isDirectory: true)
        try await repo.git(["worktree", "add", "-q", worktreePath.path, "feature"])
        defer { try? FileManager.default.removeItem(at: worktreePath) }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            _ = try await backend.deleteBranch("feature", force: false, at: repo.root)
        }

        #expect(error == .cannotDeleteCurrent("feature"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.localBranches() == ["feature", "main"], "no branch is left behind")
    }

    // MARK: - name refusals

    @Test(arguments: [false, true])
    func deletingANonexistentBranchIsRefused(force: Bool) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            _ = try await backend.deleteBranch("nosuch", force: force, at: repo.root)
        }

        #expect(error == .noSuchBranch("nosuch"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    @Test func deletingAnInvalidNameIsRefusedBeforeGitRuns() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            _ = try await backend.deleteBranch("-oops", force: false, at: repo.root)
        }

        #expect(error == .invalidName("-oops"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }
}
