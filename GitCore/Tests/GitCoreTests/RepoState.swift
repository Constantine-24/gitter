import Foundation
import Testing

@testable import GitCore

/// The parts of a repository *outside* the worktree that a refused operation must leave
/// exactly as it found them: HEAD's commit, which ref HEAD points at (or that it is
/// detached), the whole index, and every ref.
///
/// `assertWorktreeUnchanged` alone cannot prove a refusal was a true no-op: a command that
/// moved HEAD, rewrote the index or created a branch while leaving files alone would still
/// pass it. Capturing this alongside the worktree snapshot closes that gap.
struct RepoState: Equatable {
    /// `git rev-parse HEAD` — empty in a repository with no commits.
    let head: String
    /// `git symbolic-ref -q HEAD` — empty when HEAD is detached.
    let symbolicHead: String
    /// `git ls-files -s` — mode, object, merge stage and path for every index entry.
    let index: String
    /// `git for-each-ref` — every branch, tag and remote-tracking ref with its object.
    let refs: String

    static func capture(_ repo: TestRepo) async throws -> RepoState {
        // `rev-parse HEAD` exits 128 before the first commit and `symbolic-ref -q HEAD`
        // exits 1 when HEAD is detached; both are states a test may legitimately capture.
        RepoState(
            head: try await text(repo, ["rev-parse", "HEAD"], allowedExitCodes: [128]),
            symbolicHead: try await text(repo, ["symbolic-ref", "-q", "HEAD"], allowedExitCodes: [1]),
            index: try await text(repo, ["ls-files", "-s"]),
            refs: try await text(repo, ["for-each-ref"])
        )
    }

    private static func text(
        _ repo: TestRepo, _ arguments: [String], allowedExitCodes: Set<Int32> = []
    ) async throws -> String {
        let data = try await repo.git(arguments, allowedExitCodes: allowedExitCodes)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Asserts a refused operation changed *nothing*: not the worktree, not HEAD, not the index,
/// not a single ref.
func assertRepoUnchanged(
    _ repo: TestRepo, since state: RepoState, worktree: [String: Data],
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    assertWorktreeUnchanged(repo, since: worktree, sourceLocation: sourceLocation)
    let now = try await RepoState.capture(repo)
    #expect(now.head == state.head, "HEAD moved", sourceLocation: sourceLocation)
    #expect(
        now.symbolicHead == state.symbolicHead, "HEAD points somewhere else",
        sourceLocation: sourceLocation)
    #expect(now.index == state.index, "the index changed", sourceLocation: sourceLocation)
    #expect(now.refs == state.refs, "refs changed", sourceLocation: sourceLocation)
}

/// Proves `RepoState` really distinguishes each of the four things it records; without this
/// the comparisons in every refusal test could be silently vacuous, as an earlier
/// worktree-snapshot bug made `assertWorktreeUnchanged` for a while.
///
/// Deliberately written with plain `#expect` on *differences* rather than `withKnownIssue`
/// around a failing assertion, so the suite's known-issue count stays where it is.
@Suite struct RepoStateTests {
    @Test func noticesAMovedHeadAnAlteredIndexAndANewRef() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        let before = try await RepoState.capture(repo)
        #expect(!before.head.isEmpty)
        #expect(!before.index.isEmpty)

        try repo.write("b.txt", "two\n")
        try await repo.commitAll("second")  // moves HEAD and the index
        try await repo.git(["branch", "extra"])  // adds a ref

        let after = try await RepoState.capture(repo)
        #expect(after != before)
        #expect(after.head != before.head)
        #expect(after.index != before.index)
        #expect(after.refs != before.refs)
        #expect(after.symbolicHead == before.symbolicHead)
    }

    @Test func noticesADetachedHead() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        let before = try await RepoState.capture(repo)
        #expect(before.symbolicHead == "refs/heads/main\n")

        try await repo.git(["switch", "--detach", "HEAD"])

        let after = try await RepoState.capture(repo)
        #expect(after.symbolicHead == "")
        #expect(after.head == before.head)
    }
}
