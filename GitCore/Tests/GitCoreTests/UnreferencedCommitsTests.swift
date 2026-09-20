import Foundation
import Testing

@testable import GitCore

/// `unreferencedCommitCount(at:)`: how many commits would be left on no ref at all if HEAD moved
/// away from where it is now.
///
/// This is the question behind the fourth loss-capable action in the design doc — leaving a
/// detached HEAD that holds commits nothing else points at. It only ever has a non-zero answer
/// while HEAD is detached; on a branch the branch itself references everything, by construction.
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

        #expect(try await backend.unreferencedCommitCount(at: repo.root) == 2)
    }

    /// A tag counts as a ref, so a detached HEAD sitting on a tagged commit strands nothing.
    @Test func isZeroWhenDetachedAtATaggedCommit() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "--detach", "v1"])

        #expect(try await backend.unreferencedCommitCount(at: repo.root) == 0)
    }

    /// So does a remote-tracking ref: the commits are still reachable from `origin/…`.
    @Test func isZeroWhenTheCommitsAreOnARemoteTrackingRef() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["switch", "-q", "--detach", "feature"])
        try await repo.git(["branch", "-D", "feature"])

        #expect(try await backend.unreferencedCommitCount(at: repo.root) == 0)
    }

    /// On a branch it is 0 whatever the history looks like — the branch references HEAD itself.
    @Test func isZeroOnABranch() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "feature"])

        #expect(try await backend.unreferencedCommitCount(at: repo.root) == 0)
    }

    /// An unborn HEAD has no commits at all. `rev-list HEAD` exits 128 there — verified on git
    /// 2.54 under `LC_ALL=C`: "fatal: ambiguous argument 'HEAD': unknown revision or path not in
    /// the working tree." — which is not a failure worth propagating: there is nothing to strand.
    @Test func isZeroOnAnUnbornHead() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }

        #expect(try await backend.unreferencedCommitCount(at: repo.root) == 0)
    }

    /// Every *other* exit 128 must throw, so the guard that calls this fails **closed**.
    ///
    /// This count is the only input to a confirmation that stands between the user and losing
    /// commits; answering 0 for a question that could not be asked would skip that confirmation
    /// silently. "Not a git repository" is another exit 128 with different words (verified the
    /// same way), which is exactly the shape a blanket `catch` would have swallowed.
    @Test func propagatesAnExitCode128ThatIsNotAnUnbornHead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-not-a-repo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        await #expect(throws: GitError.self) {
            _ = try await backend.unreferencedCommitCount(at: directory)
        }
    }
}
