import Foundation
import Testing

@testable import GitCore

/// `commitsOnlyOn`'s semantics, letter by letter against `GitBranchBackend`'s doc comment: what
/// counts as "elsewhere" (b, c, d), how it can disagree with what `git branch -d` itself
/// considers merged (a/e — the other direction is `BranchDeleteTests`'s
/// `deletingABranchMergedElsewhereButNotIntoHeadIsNotFullyMerged`), and the one case where it
/// cannot be trusted at all (the current branch).
@Suite struct CommitsOnlyOnTests {
    private let backend = CLIGitBackend()

    @Test func aMergedBranchIsZero() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "-q", "--no-ff", "feature", "-m", "merge feature"])

        #expect(try await backend.commitsOnlyOn(branch: "feature", at: repo.root) == 0)
    }

    @Test func anUnmergedBranchCountsItsOneUniqueCommit() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        #expect(try await backend.commitsOnlyOn(branch: "feature", at: repo.root) == 1)
    }

    @Test func countsEveryUniqueCommitNotJustTheTip() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("a.txt", "two\n")
        try await repo.commitAll("first")
        try repo.write("a.txt", "three\n")
        try await repo.commitAll("second")
        try await repo.git(["switch", "-q", "main"])

        #expect(try await backend.commitsOnlyOn(branch: "topic", at: repo.root) == 2)
    }

    /// (a)/(e): `-d` compares only against upstream-or-HEAD, so it can refuse a branch this
    /// method truthfully reports as 0 — merged into "sink", just not into HEAD ("main"). See
    /// `BranchDeleteTests.deletingABranchMergedElsewhereButNotIntoHeadIsNotFullyMerged` for the
    /// matching `deleteBranch` behaviour.
    @Test func isZeroWhenMergedIntoAnotherBranchEvenThoughMinusDWouldStillRefuse() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "-c", "sink", "main"])
        try await repo.git(["merge", "-q", "--no-ff", "feature", "-m", "merge feature into sink"])
        try await repo.git(["switch", "-q", "main"])

        #expect(try await backend.commitsOnlyOn(branch: "feature", at: repo.root) == 0)
    }

    /// (b): a remote-tracking ref for the same commit counts as "elsewhere" — the commit is not
    /// actually at risk even though nothing local has merged it.
    @Test func isZeroWhenTheBranchIsAlsoOnARemoteTrackingRef() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }

        #expect(try await backend.commitsOnlyOn(branch: "feature", at: repo.root) == 0)
    }

    /// (c): a tag on the same commit counts too.
    @Test func isZeroWhenTheBranchIsAlsoReachableFromATag() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["tag", "feature-tag", "feature"])

        #expect(try await backend.commitsOnlyOn(branch: "feature", at: repo.root) == 0)
    }

    /// (d), part one: `refs/stash` is a real ref under `refs/`, but it is excluded — a stash
    /// entry is not a place a commit is kept. A pop or a drop removes it, and `--all` sees only
    /// `stash@{0}`, so the next entry pushed (by a terminal, or by the record every discard
    /// files) would take the cover away without a word. A branch whose only unmerged commit is
    /// also a stash entry's parent counts that commit.
    @Test func countsACommitThatOnlyAStashEntryAlsoReaches() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("a.txt", "two\n")
        try await repo.commitAll("topic's unique commit")
        try repo.write("a.txt", "dirty\n")
        try await repo.git(["stash", "push", "-q", "-m", "on topic"])
        try await repo.git(["switch", "-q", "main"])
        // Baseline: the stash entry really does reach the commit.
        let unique = try await repo.revParse("topic")
        #expect(try await repo.revParse("refs/stash^1") == unique)

        #expect(try await backend.commitsOnlyOn(branch: "topic", at: repo.root) == 1)
    }

    /// (d), part two: the opposite of the stash case. A surviving ref that once reached the
    /// commit but has since moved away leaves only a reflog trail, and `--all` expands live ref
    /// tips, never reflogs — so the commit still counts as unique here.
    @Test func staysAccurateWhenOnlyAnotherRefsStaleReflogOnceReachedTheCommit() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try await repo.git(["switch", "-q", "-c", "X"])
        try repo.write("a.txt", "two\n")
        try await repo.commitAll("D: X's unique commit")
        try await repo.git(["switch", "-q", "-c", "Y", "X"])
        try repo.write("a.txt", "three\n")
        try await repo.commitAll("E: descendant of D, on Y")
        try await repo.git(["switch", "-q", "main"])
        // Y no longer reaches D; only Y's own reflog remembers having been there.
        try await repo.git(["branch", "-f", "Y", "main"])

        #expect(try await backend.commitsOnlyOn(branch: "X", at: repo.root) == 1)
    }

    /// Documented, verified caveat: `--all` "pretend[s] as if … HEAD" is listed too, so a branch
    /// that IS HEAD always sees itself as reachable "elsewhere". `deleteBranch` never calls this
    /// for the current branch (it refuses first), but the method itself must not be misread.
    @Test func isZeroForTheCurrentBranchRegardlessOfMergeStatus() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "feature"])

        #expect(try await backend.commitsOnlyOn(branch: "feature", at: repo.root) == 0)
    }

    /// A symbolic ref under `refs/heads` or `refs/tags` is not a place a commit is kept (E3
    /// B4.3): `--all` lists it as a ref of its own, so one pointing at the branch being deleted
    /// covered its commits and the count came back **0** where three would be lost. Deleting
    /// the branch leaves the symref dangling. One pointing at another branch changes nothing.
    @Test(arguments: ["refs/heads/z", "refs/tags/t"])
    func aSymrefAtTheBranchIsNotAHolder(symref: String) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try await repo.git(["switch", "-q", "-c", "ltopic"])
        for step in 1...3 {
            try repo.write("t\(step).txt", "\(step)\n")
            try await repo.commitAll("ltopic \(step)")
        }
        try await repo.git(["switch", "-q", "main"])
        #expect(try await backend.commitsOnlyOn(branch: "ltopic", at: repo.root) == 3)

        try await repo.git(["symbolic-ref", "refs/heads/x", "refs/heads/main"])
        #expect(try await backend.commitsOnlyOn(branch: "ltopic", at: repo.root) == 3)

        try await repo.git(["symbolic-ref", symref, "refs/heads/ltopic"])
        #expect(try await repo.symbolicRef(symref) == "refs/heads/ltopic")
        #expect(try await backend.commitsOnlyOn(branch: "ltopic", at: repo.root) == 3,
                "a pointer at the branch is not a second holder of its commits")

        // A real holder in the same namespace still is one.
        if symref.hasPrefix("refs/heads/") {
            try await repo.git(["branch", "keep", "ltopic"])
        } else {
            try await repo.git(["tag", "keep", "ltopic"])
        }
        #expect(try await backend.commitsOnlyOn(branch: "ltopic", at: repo.root) == 0)
    }

    @Test func rejectsAnInvalidNameBeforeGitRuns() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        let error = await branchError {
            _ = try await backend.commitsOnlyOn(branch: "-oops", at: repo.root)
        }
        #expect(error == .invalidName("-oops"))
    }
}
