import Foundation
import Testing

@testable import GitCore

/// The heart of the milestone: when git refuses, Gitter reports *what* it refused over and
/// the repository is byte-for-byte as it was — no worktree change, no moved HEAD, no index
/// change, no new or altered ref.
@Suite struct BranchRefusalTests {
    private let backend = CLIGitBackend()

    @Test func switchIsRefusedByAConflictingLocalEditAndChangesNothing() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "my local edit\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError { try await backend.switchTo(branch: "feature", at: repo.root) }

        #expect(error == .wouldOverwrite(tracked: ["a.txt"], untracked: []))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.currentBranch() == "main")
        #expect(try repo.fileContents("a.txt") == "my local edit\n")
    }

    /// Every conflicting file is named, not just the first — the UI decides what to elide.
    @Test func theRefusalNamesEveryConflictingFile() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "feature"])
        try repo.write("b.txt", "feature b\n")
        try repo.write("c d.txt", "feature c\n")
        try await repo.commitAll("more feature files")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("a.txt", "local\n")
        try repo.write("b.txt", "local\n")
        try repo.write("c d.txt", "local\n")
        try await repo.git(["add", "-A"])  // staged, and still a conflict
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError { try await backend.switchTo(branch: "feature", at: repo.root) }

        guard case .wouldOverwrite(let tracked, let untracked) = try #require(error) else {
            Issue.record("expected .wouldOverwrite, got \(String(describing: error))")
            return
        }
        #expect(tracked.sorted() == ["a.txt", "b.txt", "c d.txt"])
        #expect(untracked.isEmpty)
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    @Test func switchIsRefusedByAnUntrackedFileThatWouldBeOverwritten() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "feature"])
        try repo.write("added-on-feature.txt", "from the branch\n")
        try await repo.commitAll("add a file only feature has")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("added-on-feature.txt", "mine, untracked\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError { try await backend.switchTo(branch: "feature", at: repo.root) }

        #expect(error == .wouldOverwrite(tracked: [], untracked: ["added-on-feature.txt"]))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try repo.fileContents("added-on-feature.txt") == "mine, untracked\n")
    }

    /// git can refuse over both kinds at once, and then the user must hear about both:
    /// reporting only the tracked file would have them fix it, retry, and be refused again.
    @Test func aRefusalOverBothKindsAtOnceNamesBoth() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "feature"])
        try repo.write("only-on-feature.txt", "from the branch\n")
        try await repo.commitAll("a file only feature has")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("a.txt", "my tracked edit\n")
        try repo.write("only-on-feature.txt", "my untracked file\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError { try await backend.switchTo(branch: "feature", at: repo.root) }

        #expect(error == .wouldOverwrite(tracked: ["a.txt"], untracked: ["only-on-feature.txt"]))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    @Test func switchIsRefusedWhileAMergeIsInProgress() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "main side\n")
        try await repo.commitAll("main change")
        try await repo.git(["branch", "other", "main"])
        try await repo.git(["merge", "feature"], allowedExitCodes: [1])
        #expect(try await backend.snapshot(at: repo.root).status.operationInProgress == .merge)
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError { try await backend.switchTo(branch: "other", at: repo.root) }

        #expect(error == .operationInProgress("merging"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    @Test func detachIsRefusedByAConflictingLocalEditAndChangesNothing() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "my local edit\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError { try await backend.checkoutDetached("feature", at: repo.root) }

        #expect(error == .wouldOverwrite(tracked: ["a.txt"], untracked: []))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.currentBranch() == "main", "HEAD must not even become detached")
    }

    @Test func trackIsRefusedByAConflictingLocalEditAndChangesNothing() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try repo.write("a.txt", "my local edit\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            try await backend.trackRemoteBranch("origin/feat/x", at: repo.root)
        }

        #expect(error == .wouldOverwrite(tracked: ["a.txt"], untracked: []))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.localBranches() == ["feature", "main"], "no branch is left behind")
    }

    /// A file whose name contains a space, a double quote and a non-ASCII byte survives the
    /// round trip through git's stderr intact. Verified on git 2.54: this message prints names
    /// raw, so nothing may be unquoted on the way back.
    @Test func awkwardFileNamesComeBackExactly() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let awkward = "sp ace \"q\" uni-é.txt"
        try await repo.git(["switch", "-q", "feature"])
        try repo.write(awkward, "feature\n")
        try await repo.commitAll("awkward name")
        try await repo.git(["switch", "-q", "main"])
        try repo.write(awkward, "untracked local copy\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError { try await backend.switchTo(branch: "feature", at: repo.root) }

        #expect(error == .wouldOverwrite(tracked: [], untracked: [awkward]))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }
}
