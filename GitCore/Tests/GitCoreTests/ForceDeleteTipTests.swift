import Foundation
import Testing

@testable import GitCore

/// `forceDeleteBranch(_:expectedTip:at:)` — the half of a delete that can actually lose commits,
/// and the check that keeps it honest.
///
/// The warning the user answers names a tip and a count. Between reading that warning and
/// clicking "Delete Anyway" the branch can move: a commit from a terminal, a `git update-ref`, a
/// rename plus a new branch under the old name. Deleting whatever the ref happens to point at
/// then orphans commits the warning never mentioned, and the recreate command it printed puts
/// back the *old* tip — silently losing the rest. So the force delete verifies the tip first and
/// refuses when it does not match, which is what these tests pin.
@Suite struct ForceDeleteTipTests {
    private let backend = CLIGitBackend()

    // MARK: - The tip moved

    /// The reviewer's scenario: the warning is on screen for a one-commit branch, a terminal adds
    /// a second commit, and the force delete must refuse rather than orphan two commits under a
    /// warning that named one.
    @Test func refusesWhenTheTipMovedAndKeepsEveryCommit() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let warned = try await repo.revParse("feature")

        // What a terminal does while the warning is up.
        try await repo.git(["switch", "-q", "feature"])
        try repo.write("a.txt", "moved on\n")
        try await repo.commitAll("second feature commit")
        try await repo.git(["switch", "-q", "main"])
        let moved = try await repo.revParse("feature")
        #expect(moved != warned)

        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            try await backend.forceDeleteBranch("feature", expectedTip: warned, at: repo.root)
        }

        #expect(error == .branchMoved(name: "feature", expected: warned, actual: moved))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.localBranches() == ["feature", "main"])
        // Both commits, not just the one the warning named.
        _ = try await repo.git(["cat-file", "-e", warned])
        _ = try await repo.git(["cat-file", "-e", moved])
    }

    /// Same root cause, different disguise: the branch is renamed away and a *new* branch takes
    /// the old name. The name still resolves, so a name-only guard would go ahead.
    @Test func refusesWhenABranchWasRecreatedUnderTheSameNameAtAnotherCommit() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let warned = try await repo.revParse("feature")

        try await repo.git(["branch", "-m", "feature", "feature-kept"])
        try await repo.git(["branch", "feature", "main"])
        let recreated = try await repo.revParse("feature")
        #expect(recreated != warned)

        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            try await backend.forceDeleteBranch("feature", expectedTip: warned, at: repo.root)
        }

        #expect(error == .branchMoved(name: "feature", expected: warned, actual: recreated))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// The comparison is on the whole 40-character object name. An abbreviation is not "close
    /// enough": `git update-ref -d <ref> <oldvalue>` would happily accept one (verified on git
    /// 2.54), and a prefix match is a weaker promise than the one the sheet makes.
    @Test func refusesAnAbbreviatedTipEvenWhenItIsAPrefixOfTheRealOne() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let tip = try await repo.revParse("feature")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            try await backend.forceDeleteBranch(
                "feature", expectedTip: String(tip.prefix(7)), at: repo.root)
        }

        #expect(error == .branchMoved(name: "feature", expected: String(tip.prefix(7)), actual: tip))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// Gone entirely is a different answer from moved, and the one the user should see: the
    /// branch they were warned about no longer exists.
    @Test func refusesWhenTheBranchIsGoneAltogether() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let tip = try await repo.revParse("feature")
        try await repo.git(["branch", "-D", "feature"])
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            try await backend.forceDeleteBranch("feature", expectedTip: tip, at: repo.root)
        }

        #expect(error == .noSuchBranch("feature"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    // MARK: - The tip is still what was shown

    @Test func deletesTheBranchWhenTheTipIsStillTheOneTheWarningNamed() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let tip = try await repo.revParse("feature")

        try await backend.forceDeleteBranch("feature", expectedTip: tip, at: repo.root)

        #expect(try await repo.localBranches() == ["main"])
        // The commit object survives, so the sheet's recreate command is still honest.
        _ = try await repo.git(["cat-file", "-e", tip])
    }

    /// The round trip the UI actually makes: the tip a refused plain delete hands back is
    /// exactly what the force delete accepts, with no reformatting in between.
    @Test func theTipAPlainDeleteReportsIsTheOneTheForceDeleteAccepts() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        let result = try await backend.deleteBranch("feature", at: repo.root)

        guard case .notFullyMerged(_, let tip) = result else {
            Issue.record("expected a refusal to force, got \(result)")
            return
        }
        #expect(tip.count == 40)
        try await backend.forceDeleteBranch("feature", expectedTip: tip, at: repo.root)
        #expect(try await repo.localBranches() == ["main"])
    }

    // MARK: - The checks that come first

    /// The current branch is refused before the tip is even read: it is refused whatever the tip
    /// says, and "the branch moved" would be the wrong thing to tell the user.
    @Test func refusesTheCurrentBranchEvenWithTheRightTip() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let tip = try await repo.revParse("main")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            try await backend.forceDeleteBranch("main", expectedTip: tip, at: repo.root)
        }

        #expect(error == .cannotDeleteCurrent("main"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    @Test func refusesANameThatWouldBeReadAsAnOptionBeforeGitRuns() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            try await backend.forceDeleteBranch(
                "-oops", expectedTip: String(repeating: "0", count: 40), at: repo.root)
        }

        #expect(error == .invalidName("-oops"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }
}
