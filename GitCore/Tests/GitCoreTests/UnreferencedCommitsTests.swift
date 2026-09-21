import Foundation
import Testing

@testable import GitCore

/// `unreferencedCommits(at:)`: where HEAD is, and how many commits would be left on no ref at all
/// if it moved away from there.
///
/// This is the question behind the fourth loss-capable action in the design doc — leaving a
/// detached HEAD that holds commits nothing else points at. The count only ever has a non-zero
/// answer while HEAD is detached; on a branch the branch itself references everything, by
/// construction.
///
/// The two halves come back together because the confirmation sheet shows both and is later
/// answered against both: a sha read at one moment and a count read at another would let the
/// sheet promise something no single state of the repository ever said.
@Suite struct UnreferencedCommitsTests {
    private let backend = CLIGitBackend()

    /// The case the whole guard exists for: detached exactly at a branch's tip, `git branch -d`
    /// deletes that branch *silently* (git calls it merged into HEAD), and the commits then hang
    /// on the detached HEAD alone.
    @Test func countsCommitsLeftOnNoRefAfterTheirBranchWasDeleted() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("t.txt", "one\n")
        try await repo.commitAll("topic one")
        try repo.write("t.txt", "two\n")
        try await repo.commitAll("topic two")
        try await repo.git(["switch", "-q", "--detach", "topic"])
        // Accepted without complaint, because HEAD *is* the tip: the branch is trivially merged.
        try await repo.git(["branch", "-d", "topic"])

        #expect(try await backend.unreferencedCommits(at: repo.root).count == 2)
    }

    /// The sha is the commit HEAD is on, in full, and it is the commit the count is about — the
    /// confirmation names it, and answering that confirmation is refused unless both still match.
    @Test func namesTheCommitHeadIsOnInFull() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("t.txt", "one\n")
        try await repo.commitAll("topic one")
        try await repo.git(["switch", "-q", "--detach", "topic"])
        try await repo.git(["branch", "-d", "topic"])
        let head = try await repo.revParse("HEAD")

        let unreferenced = try await backend.unreferencedCommits(at: repo.root)

        #expect(unreferenced.headSha == head)
        #expect(unreferenced.headSha?.count == 40)
        #expect(unreferenced.count == 1)
    }

    /// A tag counts as a ref, so a detached HEAD sitting on a tagged commit strands nothing —
    /// and the sha is still reported, since "where HEAD is" is not the part that is conditional.
    @Test func isZeroWhenDetachedAtATaggedCommit() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "--detach", "v1"])

        let unreferenced = try await backend.unreferencedCommits(at: repo.root)

        #expect(unreferenced.count == 0)
        #expect(unreferenced.headSha == (try await repo.revParse("v1^{commit}")))
    }

    /// So does a remote-tracking ref: the commits are still reachable from `origin/…`.
    @Test func isZeroWhenTheCommitsAreOnARemoteTrackingRef() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["switch", "-q", "--detach", "feature"])
        try await repo.git(["branch", "-D", "feature"])

        #expect(try await backend.unreferencedCommits(at: repo.root).count == 0)
    }

    /// On a branch it is 0 whatever the history looks like — the branch references HEAD itself.
    @Test func isZeroOnABranch() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "feature"])

        let unreferenced = try await backend.unreferencedCommits(at: repo.root)

        #expect(unreferenced.count == 0)
        #expect(unreferenced.headSha == (try await repo.revParse("refs/heads/feature")))
    }

    /// An unborn HEAD has no commits at all: no sha to name and nothing to strand. Verified on
    /// git 2.54 under `LC_ALL=C` (which `ProcessRunner` sets): `rev-parse --verify --quiet HEAD`
    /// exits 1 with no output there, where a directory that is not a repository exits 128.
    @Test func hasNoShaAndNoCommitsOnAnUnbornHead() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }

        let unreferenced = try await backend.unreferencedCommits(at: repo.root)

        #expect(unreferenced.headSha == nil)
        #expect(unreferenced.count == 0)
    }

    /// Every *other* failure must throw, so the guard that calls this fails **closed**.
    ///
    /// This pair is the only input to a confirmation that stands between the user and losing
    /// commits; answering 0 for a question that could not be asked would skip that confirmation
    /// silently. "Not a git repository" is an exit 128 with different words (verified the same
    /// way), which is exactly the shape a blanket `catch` would have swallowed.
    @Test func propagatesAFailureThatIsNotAnUnbornHead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-not-a-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: GitError.self) {
            _ = try await backend.unreferencedCommits(at: directory)
        }
    }
}
