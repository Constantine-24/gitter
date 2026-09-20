import Foundation
import Testing

@testable import GitCore

/// Switching, detaching and checking out a remote branch — the operations that write
/// working-tree files.
@Suite struct BranchSwitchTests {
    private let backend = CLIGitBackend()

    // MARK: - switchTo

    @Test func switchOnACleanTreeUpdatesHeadAndFiles() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        try await backend.switchTo(branch: "feature", at: repo.root)

        #expect(try await repo.currentBranch() == "feature")
        #expect(try repo.fileContents("a.txt") == "feature\n")
        let status = try await backend.snapshot(at: repo.root).status
        #expect(status.branch == "feature")
        #expect(status.files.isEmpty)
    }

    /// git's default, and the reason Gitter needs no stash: an edit to a file that is the same
    /// on both branches rides along.
    @Test func switchCarriesANonConflictingLocalEdit() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try repo.write("keep.txt", "my work in progress\n")

        try await backend.switchTo(branch: "feature", at: repo.root)

        #expect(try await repo.currentBranch() == "feature")
        #expect(try repo.fileContents("keep.txt") == "my work in progress\n")
        #expect(try repo.fileContents("a.txt") == "feature\n")
    }

    /// `--no-guess` is load-bearing: without it `git switch feat/x` silently *creates* a local
    /// branch tracking `origin/feat/x`. Gitter has an explicit action for that
    /// (`trackRemoteBranch`), and a plain switch must never do it by accident.
    @Test func switchDoesNotInventALocalBranchFromARemoteOne() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: GitError.self) {
            try await backend.switchTo(branch: "feat/x", at: repo.root)
        }

        #expect(try await repo.localBranches() == ["feature", "main"])
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    @Test func switchToAMissingBranchStaysAPlainCommandFailure() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: GitError.self) {
            try await backend.switchTo(branch: "nosuch", at: repo.root)
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    @Test(arguments: ["", "-lead"])
    func switchToAnInvalidNameNeverReachesGit(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError { try await backend.switchTo(branch: name, at: repo.root) }

        #expect(error == .invalidName(name))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    // MARK: - checkoutDetached

    @Test func detachAtASha() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let sha = try await repo.revParse("feature")

        try await backend.checkoutDetached(sha, at: repo.root)

        #expect(try await repo.currentBranch() == nil)
        let status = try await backend.snapshot(at: repo.root).status
        #expect(status.branch == nil, "a detached HEAD has no branch")
        #expect(status.headSha == sha)
        #expect(try repo.fileContents("a.txt") == "feature\n")
    }

    @Test func detachAtATag() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let expected = try await repo.revParse("v1^{commit}")

        try await backend.checkoutDetached("v1", at: repo.root)

        #expect(try await repo.currentBranch() == nil)
        #expect(try await backend.snapshot(at: repo.root).status.headSha == expected)
    }

    @Test func detachAtAMissingRevisionStaysAPlainCommandFailure() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: GitError.self) {
            try await backend.checkoutDetached("nosuch", at: repo.root)
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    // MARK: - trackRemoteBranch

    @Test func trackCreatesALocalBranchWithTheRestOfTheNameAndAnUpstream() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }

        try await backend.trackRemoteBranch("origin/feat/x", at: repo.root)

        #expect(try await repo.currentBranch() == "feat/x", "only the first path component is the remote")
        #expect(try await repo.upstream(of: "feat/x") == "origin/feat/x")
        #expect(try await repo.revParse("feat/x") == (try await repo.revParse("origin/feat/x")))
        #expect(try repo.fileContents("a.txt") == "feature\n")
    }

    @Test func trackAnAlreadyExistingLocalBranchJustSwitchesToIt() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["branch", "feat/x", "main"])  // a local branch that is NOT the remote's tip
        let localTip = try await repo.revParse("feat/x")
        #expect(localTip != (try await repo.revParse("origin/feat/x")))

        try await backend.trackRemoteBranch("origin/feat/x", at: repo.root)

        #expect(try await repo.currentBranch() == "feat/x")
        #expect(try await repo.revParse("feat/x") == localTip, "the existing branch must not be moved")
        #expect(try await repo.upstream(of: "feat/x") == nil, "no upstream is invented for it")
    }

    /// A remote whose own name contains a slash is not special-cased: the first component is
    /// taken as the remote, so `my/remote/feature` yields a local branch called
    /// `remote/feature`. The upstream is still correct, because git resolves the full
    /// `my/remote/feature` for `--track`. Recorded as tested behaviour, not an endorsement.
    @Test func trackKeepsAFragmentOfASlashedRemoteNameInTheLocalBranch() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch(named: "my/remote")
        defer { try? FileManager.default.removeItem(at: remote) }

        try await backend.trackRemoteBranch("my/remote/feat/x", at: repo.root)

        #expect(try await repo.currentBranch() == "remote/feat/x")
        #expect(try await repo.upstream(of: "remote/feat/x") == "my/remote/feat/x")
    }

    @Test(arguments: ["origin", "origin/", "", "-origin/x"])
    func trackRejectsAnythingThatIsNotRemoteSlashBranch(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError { try await backend.trackRemoteBranch(name, at: repo.root) }

        #expect(error == .invalidName(name))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }
}
