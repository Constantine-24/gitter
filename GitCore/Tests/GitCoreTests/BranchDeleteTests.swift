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

    // MARK: - not fully merged: the upstream half of "compares against @{upstream} if one is
    // set, otherwise HEAD"

    /// `X` gets one commit pushed (setting its upstream to `origin/X`) and then one more that is
    /// NOT pushed. Merging `X` into HEAD ("main") doesn't help `-d` succeed: it compares against
    /// the (unadvanced) upstream, not HEAD, and refuses — while `commitsOnlyOn` truthfully
    /// reports 0, since the unpushed commit is now reachable via "main" too.
    @Test func deletingABranchAheadOfItsUpstreamIsNotFullyMergedEvenWhenMergedIntoHead()
        async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        let remote = try await addBareRemote(to: repo)
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["push", "-q", "origin", "main"])

        try await repo.git(["switch", "-q", "-c", "X"])
        try repo.write("a.txt", "two\n")
        try await repo.commitAll("X: pushed commit")
        try await repo.git(["push", "-q", "-u", "origin", "X"])
        try repo.write("a.txt", "three\n")
        try await repo.commitAll("X: unpushed commit")
        let tip = try await repo.revParse("X")
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["merge", "-q", "--no-ff", "X", "-m", "merge X into main"])
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let result = try await backend.deleteBranch("X", force: false, at: repo.root)

        #expect(result == .notFullyMerged(uniqueCommits: 0, tip: tip))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// The mirror: `Y` is merged into its own upstream (trivially — nothing local outruns what
    /// was pushed) but not into HEAD ("main"). `-d` succeeds on the upstream comparison alone
    /// and prints a warning to stderr that Gitter deliberately ignores — `deleteBranch` only
    /// special-cases the *refusal* text "is not fully merged"; a warning alongside exit 0 is
    /// still a plain `.deleted`. The commit is not lost: it stays reachable from the
    /// remote-tracking ref after the local branch is gone.
    @Test func deletingABranchMergedIntoItsUpstreamButNotHeadSucceedsWithAWarning() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        let remote = try await addBareRemote(to: repo)
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["push", "-q", "origin", "main"])

        try await repo.git(["switch", "-q", "-c", "Y"])
        try repo.write("a.txt", "two\n")
        try await repo.commitAll("Y's commit")
        try await repo.git(["push", "-q", "-u", "origin", "Y"])
        let tip = try await repo.revParse("Y")
        try await repo.git(["switch", "-q", "main"])
        // Y is not merged into main (HEAD) — only into its own upstream, trivially.

        let result = try await backend.deleteBranch("Y", force: false, at: repo.root)

        #expect(result == .deleted)
        #expect(try await repo.localBranches() == ["main"])
        // Still reachable, via the remote-tracking ref, not the (now-gone) local branch.
        _ = try await repo.git(["merge-base", "--is-ancestor", tip, "refs/remotes/origin/Y"])
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

    @Test(arguments: [false, true])
    func deletingABranchCheckedOutInALinkedWorktreeIsRefused(force: Bool) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let worktreePath = repo.root.deletingLastPathComponent()
            .appendingPathComponent("\(repo.root.lastPathComponent)-linked-wt", isDirectory: true)
        try await repo.git(["worktree", "add", "-q", worktreePath.path, "feature"])
        defer { try? FileManager.default.removeItem(at: worktreePath) }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            _ = try await backend.deleteBranch("feature", force: force, at: repo.root)
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

    // MARK: - Helpers

    /// A bare repo beside `repo.root`, added as its `origin` remote. Nothing is pushed —
    /// callers push whatever the scenario needs, so a branch's upstream ends up exactly where
    /// the test wants it.
    private func addBareRemote(to repo: TestRepo) async throws -> URL {
        let remote = repo.root.deletingLastPathComponent()
            .appendingPathComponent("\(repo.root.lastPathComponent)-origin.git", isDirectory: true)
        try FileManager.default.createDirectory(at: remote, withIntermediateDirectories: true)
        _ = try await ProcessRunner().run("/usr/bin/git", ["init", "-q", "--bare", "."], cwd: remote)
        try await repo.git(["remote", "add", "origin", remote.path])
        return remote
    }
}
