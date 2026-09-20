import Foundation
import Testing

@testable import GitCore

/// Undoing a **pending squash** — `abort(.squash)`, which runs `git reset --merge`.
///
/// A pending squash is not like the other five: git set no pseudo-ref, nothing is half-written
/// in the worktree, and from the index alone it is indistinguishable from work the user staged
/// by hand. All that marks it is `SQUASH_MSG`. So the interesting questions are different —
/// does the marker go away, does an empty squash behave, and does a *conflicting* squash come
/// out the same way — and they are asked here rather than in the table suite.
@Suite struct UndoSquashTests {

    /// The ordinary case: a squash that applied cleanly, undone. Everything the squash staged
    /// is unstaged *and* removed from the worktree (including a file it created), the message
    /// git left behind is gone, and the snapshot stops reporting an operation.
    @Test func undoingACleanSquashUnstagesEverythingAndRemovesTheMessage() async throws {
        let repo = try await makeSquashable()
        defer { repo.cleanUp() }
        try repo.write("other.txt", AbortMarker.preExistingEdit)
        try repo.write("untracked-before.txt", AbortMarker.untrackedBefore)
        let state = try await RepoState.capture(repo)
        try await repo.git(["merge", "--ff", "--squash", "feature"])
        #expect(try await repo.gitFileExists("SQUASH_MSG"))
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("added.txt").path))

        try await CLIGitBackend().abort(.squash, at: repo.root)

        #expect(try await repo.gitFileExists("SQUASH_MSG") == false)
        #expect(try await CLIGitBackend().snapshot(at: repo.root).status.operationInProgress == nil)
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("added.txt").path))
        #expect(try repo.fileContents("touched.txt") == "base\n")
        #expect(try await RepoState.capture(repo) == state, "HEAD, the index or a ref moved")
        // The two things a squash never had any business touching.
        #expect(try repo.fileContents("other.txt") == AbortMarker.preExistingEdit)
        #expect(try repo.fileContents("untracked-before.txt") == AbortMarker.untrackedBefore)
    }

    /// The squash with **nothing staged**: a branch that changed a file and changed it back is
    /// not an ancestor of HEAD, so git squashes it, writes `SQUASH_MSG` and stages nothing
    /// (verified on git 2.54 — this is `MergeOutcome.squashed`'s "may be empty" note).
    ///
    /// Undoing it therefore has nothing to unstage, and its whole job is to remove the marker.
    /// Without that, the snapshot would go on reporting a squash in progress for ever.
    @Test func undoingAnEmptySquashRemovesTheMessageAndNothingElse() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f.txt", "base\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "feature"])
        try repo.write("f.txt", "changed\n")
        try await repo.commitAll("change it")
        try repo.write("f.txt", "base\n")
        try await repo.commitAll("change it back")
        try await repo.git(["switch", "-q", "main"])
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        try await repo.git(["merge", "--ff", "--squash", "feature"])
        #expect(try await repo.gitFileExists("SQUASH_MSG"))
        #expect(try await CLIGitBackend().snapshot(at: repo.root).status.operationInProgress == .squash)
        #expect(try await repo.git(["diff", "--cached", "--name-only"]).isEmpty, "nothing was staged")

        try await CLIGitBackend().abort(.squash, at: repo.root)

        #expect(try await repo.gitFileExists("SQUASH_MSG") == false)
        #expect(try await CLIGitBackend().snapshot(at: repo.root).status.operationInProgress == nil)
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// A squash that **conflicted**. There is no `MERGE_HEAD` to clear and `git merge --abort`
    /// would refuse ("fatal: There is no merge to abort"), so `reset --merge` is the only way
    /// out — and it does clear the unmerged index entries as well as the message.
    @Test func undoingAConflictingSquashClearsTheConflictToo() async throws {
        let lab = try await makeAbortLab(.squash)
        defer { lab.cleanUp() }
        #expect(try await lab.repo.unmergedEntries().isEmpty == false)
        #expect(try await lab.repo.gitFileExists("MERGE_HEAD") == false)

        try await lab.abort()

        #expect(try await lab.repo.unmergedEntries().isEmpty)
        #expect(try await lab.repo.gitFileExists("SQUASH_MSG") == false)
        #expect(try await lab.operationInProgress() == nil)
    }

    /// `main`, a `feature` branch that rewrites `touched.txt` and adds `added.txt`, and an
    /// `other.txt` both branches share. Squashing `feature` into `main` never conflicts.
    private func makeSquashable() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("touched.txt", "base\n")
        try repo.write("other.txt", "base\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "feature"])
        try repo.write("touched.txt", "feature\n")
        try repo.write("added.txt", "added by the feature branch\n")
        try await repo.commitAll("feature")
        try await repo.git(["switch", "-q", "main"])
        return repo
    }
}
