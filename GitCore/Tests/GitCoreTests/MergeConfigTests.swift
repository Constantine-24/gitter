import Foundation
import Testing

@testable import GitCore

/// The mode the user picked in the sheet must win over whatever `merge.ff` the repository's
/// config happens to set. Verified on git 2.54 — and one of these only passes because
/// `.squash` is spelled `merge --ff --squash`: plain `merge --squash` is *fatal* under
/// `merge.ff=false` ("options '--squash' and '--no-ff.' cannot be used together") and under
/// `merge.ff=only` on a diverged branch ("Not possible to fast-forward, aborting.").
@Suite struct MergeConfigTests {
    private static func configure(_ repo: TestRepo, mergeFF: String) async throws {
        try await repo.git(["config", "merge.ff", mergeFF])
    }

    @Test(arguments: ["false", "only", "true"])
    func fastForwardIfPossibleStillFastForwards(mergeFF: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await Self.configure(repo, mergeFF: mergeFF)
        let tip = try await repo.revParse("feature")

        let outcome = try await CLIGitBackend().merge(
            "feature", mode: .fastForwardIfPossible, at: repo.root)

        #expect(outcome == .fastForwarded)
        #expect(try await repo.headSha() == tip)
    }

    @Test(arguments: ["false", "only", "true"])
    func alwaysMergeCommitStillMakesAMergeCommit(mergeFF: String) async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }
        try await Self.configure(repo, mergeFF: mergeFF)
        let before = try await repo.headSha()
        let tip = try await repo.revParse("feature")

        let outcome = try await CLIGitBackend().merge(
            "feature", mode: .alwaysMergeCommit, at: repo.root)

        #expect(outcome == .merged)
        #expect(try await repo.parents(of: "HEAD") == [before, tip])
    }

    /// `merge.ff=false` + a fast-forwardable branch, and `merge.ff=only` + a diverged one, are
    /// the two combinations that make a bare `merge --squash` fail outright.
    @Test(arguments: [("false", false), ("only", true), ("true", true), ("true", false)])
    func squashStillSquashes(mergeFF: String, diverged: Bool) async throws {
        let repo = diverged ? try await TestRepo.makeDiverged() : try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await Self.configure(repo, mergeFF: mergeFF)
        let before = try await repo.headSha()

        let outcome = try await CLIGitBackend().merge("feature", mode: .squash, at: repo.root)

        #expect(outcome == .squashed)
        #expect(try await repo.headSha() == before)
        #expect(try await repo.indexContent(of: "a.txt") == Data("feature\n".utf8))
    }
}
