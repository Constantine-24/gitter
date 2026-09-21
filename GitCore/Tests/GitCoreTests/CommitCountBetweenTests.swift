import Foundation
import Testing

@testable import GitCore

/// `commitCount(in:notIn:)` — the number behind the merge sheet's "N commits in <branch> are not
/// in <current>".
///
/// It is a one-way question (`<base>..<branch>`), which is what separates it from
/// `commitsOnlyOn`: that one asks "reachable from nowhere else at all", this one asks only
/// "which of these commits would the merge bring in". A branch merged elsewhere but not here
/// still has commits to bring in, and the sheet must say so.
@Suite struct CommitCountBetweenTests {
    private let backend = CLIGitBackend()

    @Test func countsTheCommitsTheMergeWouldBringIn() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try await repo.git(["switch", "-q", "-c", "feature"])
        try repo.write("a.txt", "two\n")
        try await repo.commitAll("first")
        try repo.write("a.txt", "three\n")
        try await repo.commitAll("second")
        try await repo.git(["switch", "-q", "main"])

        #expect(try await backend.commitCount(in: "feature", notIn: "HEAD", at: repo.root) == 2)
    }

    /// One direction only: commits the base has and the branch does not are none of this
    /// question's business, and counting them would overstate what a merge brings in.
    @Test func ignoresCommitsOnTheBaseSide() async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }

        #expect(try await backend.commitCount(in: "feature", notIn: "HEAD", at: repo.root) == 1)
        #expect(try await backend.commitCount(in: "HEAD", notIn: "feature", at: repo.root) == 1)
    }

    @Test func isZeroWhenTheBaseAlreadyContainsTheBranch() async throws {
        let repo = try await TestRepo.makeAlreadyMerged()
        defer { repo.cleanUp() }

        #expect(try await backend.commitCount(in: "feature", notIn: "HEAD", at: repo.root) == 0)
    }

    /// Unlike `commitsOnlyOn`, being merged into some *other* branch does not make this zero:
    /// those commits are still not in HEAD, and merging would still bring them over.
    @Test func countsCommitsAlreadyMergedIntoSomeOtherBranch() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "-c", "sink", "main"])
        try await repo.git(["merge", "-q", "--no-ff", "feature", "-m", "merge feature into sink"])
        try await repo.git(["switch", "-q", "main"])

        #expect(try await backend.commitsOnlyOn(branch: "feature", at: repo.root) == 0)
        #expect(try await backend.commitCount(in: "feature", notIn: "HEAD", at: repo.root) == 1)
    }

    /// A detached HEAD is a legal merge target (git allows it and so does `merge`), so the
    /// sheet's line has to work there too.
    @Test func worksWithADetachedHead() async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "--detach", "HEAD"])

        #expect(try await repo.currentBranch() == nil)
        #expect(try await backend.commitCount(in: "feature", notIn: "HEAD", at: repo.root) == 1)
    }

    /// A tag and a branch can share a name, and git's lookup order picks the **tag** — so the
    /// sheet's number would describe a merge the user never asked for. The spelling the caller
    /// uses is what settles it, which is why `incomingCommitCount` asks for `refs/heads/<name>`.
    @Test func theBranchRefSpellingCountsTheBranchWhereTheBareNameCountsTheTag() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try await repo.git(["switch", "-q", "-c", "dup"])
        try repo.write("b.txt", "b\n")
        try await repo.commitAll("branch commit 1")
        try repo.write("b.txt", "bb\n")
        try await repo.commitAll("branch commit 2")
        try await repo.git(["switch", "-q", "-c", "elsewhere", "main"])
        try repo.write("c.txt", "c\n")
        try await repo.commitAll("tag commit")
        try await repo.git(["tag", "dup"])
        try await repo.git(["switch", "-q", "main"])

        #expect(try await backend.commitCount(in: "refs/heads/dup", notIn: "HEAD", at: repo.root) == 2)
        #expect(try await backend.commitCount(in: "dup", notIn: "HEAD", at: repo.root) == 1)
    }

    /// The sheet must never show a made-up number, so a revision git cannot resolve throws
    /// rather than counting 0 — and it throws git's own words, with the exit code and the
    /// "bad revision" wording the trailing `--` is there to produce.
    @Test func throwsForARevisionGitCannotResolve() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        do {
            _ = try await backend.commitCount(in: "no-such-branch", notIn: "HEAD", at: repo.root)
            Issue.record("expected a throw, but a count came back")
        } catch GitError.commandFailed(let exitCode, let stderr) {
            #expect(exitCode == 128)
            #expect(stderr.contains("bad revision 'HEAD..no-such-branch'"), "\(stderr)")
        }
    }

    @Test func rejectsARevisionThatWouldBeReadAsAnOptionBeforeGitRuns() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        let inBranch = await branchError {
            _ = try await backend.commitCount(in: "--all", notIn: "HEAD", at: repo.root)
        }
        #expect(inBranch == .invalidName("--all"))

        let base = await branchError {
            _ = try await backend.commitCount(in: "feature", notIn: "-x", at: repo.root)
        }
        #expect(base == .invalidName("-x"))
    }
}
