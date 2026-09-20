import Foundation
import Testing

@testable import GitCore

/// Three places where the obvious reading of a merge is wrong, each pinned against real git
/// 2.54 so nobody "simplifies" the code back into them.
@Suite struct MergeEdgeCaseTests {
    /// An **annotated** tag is not a commit: `rev-parse v2` gives the tag *object*'s sha, which
    /// is never what HEAD ends up pointing at. Comparing HEAD against the unpeeled sha would
    /// call this single-parent fast-forward a merge, so the comparison peels with `^{commit}`.
    /// (A lightweight tag and a branch peel to themselves, so nothing else changes.)
    @Test func aFastForwardOntoAnAnnotatedTagIsStillAFastForward() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["tag", "-a", "v2", "-m", "annotated", "feature"])
        let tagObject = try await repo.revParse("v2")
        let commit = try await repo.revParse("feature")
        #expect(tagObject != commit, "an annotated tag must not resolve to its own commit")

        let outcome = try await CLIGitBackend().merge(
            "v2", mode: .fastForwardIfPossible, at: repo.root)

        #expect(outcome == .fastForwarded)
        #expect(try await repo.headSha() == commit)
        #expect(try await repo.parents(of: "HEAD").count == 1)
    }

    /// A branch that changed a file and then changed it back is not an ancestor of HEAD, so
    /// there *is* something to squash — but its net diff is empty. Verified on git 2.54: exit
    /// 0, `SQUASH_MSG` written, **nothing staged**.
    ///
    /// `.squashed` is still the truthful answer, and `.alreadyUpToDate` would be a lie: the
    /// `SQUASH_MSG` git left behind makes the snapshot report `.squash` either way, so telling
    /// the caller "nothing happened" would leave the UI's pending-squash note unexplained. The
    /// way out of this state is Task 5's undo-squash, not a different outcome here.
    @Test func aSquashWhoseNetDiffIsEmptyIsStillAPendingSquash() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try await repo.git(["switch", "-q", "-c", "feature"])
        try repo.write("a.txt", "changed\n")
        try await repo.commitAll("change it")
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("change it back")
        try await repo.git(["switch", "-q", "main"])
        let before = try await repo.headSha()
        let backend = CLIGitBackend()

        let outcome = try await backend.merge("feature", mode: .squash, at: repo.root)

        #expect(outcome == .squashed)
        #expect(try await repo.headSha() == before)
        #expect(try await repo.gitFileExists("SQUASH_MSG"), "git wrote one, so the state is real")
        let snapshot = try await backend.snapshot(at: repo.root)
        #expect(snapshot.status.operationInProgress == .squash)
        #expect(snapshot.status.files.isEmpty, "nothing to stage: the net diff really is empty")
    }

    /// **Not every throw means nothing changed.** Every *refusal* leaves the repository
    /// untouched, but a `pre-merge-commit` hook that exits non-zero fails the merge **after**
    /// git has resolved it: verified on git 2.54, exit 1, `MERGE_HEAD` set, the result staged,
    /// no unmerged entries, and stderr ("Not committing merge; use 'git commit' to complete the
    /// merge.") that the refusal parser rightly does not recognise.
    ///
    /// So it surfaces as `GitError.commandFailed` with git's own words — and the UI must not
    /// render that as "your work is untouched". This test is what stops the distinction being
    /// quietly lost.
    @Test func aFailingMergeHookThrowsWithTheMergeLeftInProgress() async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }
        try repo.writeExecutable(
            ".git/hooks/pre-merge-commit", "#!/bin/sh\necho 'hook says no' >&2\nexit 1\n")
        let before = try await repo.headSha()
        let backend = CLIGitBackend()

        await #expect(throws: GitError.self) {
            _ = try await backend.merge("feature", mode: .alwaysMergeCommit, at: repo.root)
        }

        #expect(try await repo.headSha() == before, "the merge commit was never made")
        #expect(try await repo.gitFileExists("MERGE_HEAD"), "but the merge IS in progress")
        #expect(try await repo.unmergedEntries().isEmpty, "and it is not a conflict")
        let snapshot = try await backend.snapshot(at: repo.root)
        #expect(snapshot.status.operationInProgress == .merge)
        #expect(snapshot.status.files.contains { $0.path == "a.txt" && $0.staged != nil })
    }
}
