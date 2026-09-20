import Foundation
import Testing

@testable import GitCore

/// Name validation, branch creation and rename against a real git.
@Suite struct BranchBackendTests {
    private let backend = CLIGitBackend()

    // MARK: - validateBranchName

    @Test(arguments: ["ok", "a/b", "feat/x-1", "release.2"])
    func acceptsValidNames(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        #expect(try await backend.validateBranchName(name, at: repo.root) == true)
    }

    /// The first three are rejected before git ever runs (empty, whitespace-only, leading `-`
    /// — the last because git would read it as an option); the rest are git's own rules,
    /// checked with `check-ref-format --branch`.
    @Test(arguments: ["", "   ", "-lead", "--force", "has space", "a..b", "x.lock", "HEAD", "a~b", "a:b"])
    func rejectsInvalidNames(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        #expect(try await backend.validateBranchName(name, at: repo.root) == false)
    }

    @Test func validatingANameNeverTouchesTheRepository() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        _ = try await backend.validateBranchName("whatever", at: repo.root)
        _ = try await backend.validateBranchName("no good", at: repo.root)

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    // MARK: - createBranch

    /// `git branch` writes one ref and nothing else: HEAD, the index and every file stay put.
    @Test func createWithoutSwitchingChangesOnlyRefs() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let before = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        try await backend.createBranch("topic", startPoint: nil, switchTo: false, at: repo.root)

        let after = try await RepoState.capture(repo)
        assertWorktreeUnchanged(repo, since: worktree)
        #expect(after.head == before.head)
        #expect(after.symbolicHead == before.symbolicHead)
        #expect(after.index == before.index)
        #expect(after.refs != before.refs, "the new branch should be the only difference")
        #expect(try await repo.localBranches() == ["feature", "main", "topic"])
        #expect(try await repo.currentBranch() == "main")
        #expect(try await repo.revParse("topic") == before.head.trimmingCharacters(in: .newlines))
    }

    @Test func createAndSwitchMovesHeadToTheNewBranch() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        try await backend.createBranch("topic", startPoint: nil, switchTo: true, at: repo.root)

        #expect(try await repo.currentBranch() == "topic")
        #expect(try await repo.revParse("topic") == (try await repo.revParse("main")))
    }

    @Test(arguments: ["feature", "v1"])
    func createFromANamedStartPoint(startPoint: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let expected = try await repo.revParse(startPoint)

        try await backend.createBranch("topic", startPoint: startPoint, switchTo: false, at: repo.root)

        #expect(try await repo.revParse("topic") == expected)
    }

    @Test func createFromAShaStartPoint() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let sha = try await repo.revParse("feature")

        try await backend.createBranch("topic", startPoint: sha, switchTo: true, at: repo.root)

        #expect(try await repo.revParse("topic") == sha)
        #expect(try await repo.currentBranch() == "topic")
        #expect(try repo.fileContents("a.txt") == "feature\n")
    }

    /// Creating a branch is not a checkout, so a dirty worktree is carried along untouched.
    @Test func createAndSwitchCarriesADirtyFile() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "local edit\n")

        try await backend.createBranch("topic", startPoint: nil, switchTo: true, at: repo.root)

        #expect(try await repo.currentBranch() == "topic")
        #expect(try repo.fileContents("a.txt") == "local edit\n")
    }

    @Test(arguments: [false, true])
    func createOntoAnExistingNameIsRefused(switchTo: Bool) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            try await backend.createBranch("feature", startPoint: nil, switchTo: switchTo, at: repo.root)
        }

        #expect(error == .branchExists("feature"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    @Test(arguments: ["bad name", "-lead", ""])
    func createWithAnInvalidNameIsRefused(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            try await backend.createBranch(name, startPoint: nil, switchTo: false, at: repo.root)
        }

        #expect(error == .invalidName(name))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    // MARK: - renameBranch

    @Test func renameANonCurrentBranch() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let tip = try await repo.revParse("feature")

        try await backend.renameBranch("feature", to: "feature-2", at: repo.root)

        #expect(try await repo.localBranches() == ["feature-2", "main"])
        #expect(try await repo.revParse("feature-2") == tip)
        #expect(try await repo.currentBranch() == "main")
    }

    @Test func renameTheCurrentBranchCarriesHeadAlong() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let worktree = worktreeSnapshot(repo)

        try await backend.renameBranch("main", to: "trunk", at: repo.root)

        #expect(try await repo.currentBranch() == "trunk")
        #expect(try await repo.localBranches() == ["feature", "trunk"])
        assertWorktreeUnchanged(repo, since: worktree)
    }

    @Test func renameOntoAnExistingNameIsRefused() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            try await backend.renameBranch("feature", to: "main", at: repo.root)
        }

        #expect(error == .branchExists("main"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    @Test func renameToAnInvalidNameIsRefused() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            try await backend.renameBranch("feature", to: "-oops", at: repo.root)
        }

        #expect(error == .invalidName("-oops"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    @Test func renameAMissingBranchStaysAPlainCommandFailure() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: GitError.self) {
            try await backend.renameBranch("nosuch", to: "other", at: repo.root)
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }
}
