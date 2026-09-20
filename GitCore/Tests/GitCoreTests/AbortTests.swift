import Foundation
import Testing

@testable import GitCore

/// `abort(_:at:)`: the guards that run before git, what a successful abort restores, and the
/// two ways an abort can fail.
///
/// The cell-by-cell "kept or lost" evidence lives in `AbortKeptAndLostTests`; this suite is
/// about the operation as a whole.
@Suite struct AbortTests {

    // MARK: - What a successful abort restores

    /// (h) of the table, for every operation: HEAD, the branch HEAD is on, the index and every
    /// ref come back exactly as they were before the operation began, and nothing is in
    /// progress afterwards.
    @Test(arguments: AbortCase.allCases)
    func abortRestoresTheRepositoryToItsPreOperationState(kind: AbortCase) async throws {
        let lab = try await makeAbortLab(kind)
        defer { lab.cleanUp() }

        try await lab.abort()

        let after = try await RepoState.capture(lab.repo)
        #expect(after.head == lab.preOperation.head, "HEAD did not come back")
        #expect(after.symbolicHead == lab.preOperation.symbolicHead, "HEAD points somewhere else")
        #expect(after.index == lab.preOperation.index, "the index did not come back")
        #expect(after.refs == lab.preOperation.refs, "refs did not come back")
        #expect(try await lab.operationInProgress() == nil)
    }

    /// The rebase half of (h), stated on its own because "the index came back" would also be
    /// true of a rebase that had never moved: a rebase detaches HEAD, and the abort has to put
    /// it back *on the branch*, at the branch's original tip.
    @Test(arguments: [AbortCase.rebase, .rebaseApplyBackend])
    func abortingARebasePutsHeadBackOnTheOriginalBranchTip(kind: AbortCase) async throws {
        let lab = try await makeAbortLab(kind)
        defer { lab.cleanUp() }
        #expect(try await lab.repo.currentBranch() == nil, "a rebase in progress detaches HEAD")

        try await lab.abort()

        #expect(try await lab.repo.currentBranch() == "side")
        #expect(try await lab.repo.revParse("HEAD") == lab.preOperation.head.trimmingCharacters(
            in: .whitespacesAndNewlines))
    }

    /// (h) for `git am`, which is the only operation that has already **committed** something
    /// by the time it stops. Verified on git 2.54: `am --abort` rewinds the branch past those
    /// commits — the cleanly applied patch is gone from the branch and the file it added is
    /// gone from the worktree. (The commit object survives in the reflog; the branch does not
    /// point at it any more.)
    @Test func abortingAnAmDiscardsThePatchesItHadAlreadyApplied() async throws {
        let lab = try await makeAbortLab(.applyingPatches)
        defer { lab.cleanUp() }
        #expect(FileManager.default.fileExists(
            atPath: lab.repo.root.appendingPathComponent("applied.txt").path),
            "the first patch should have been applied before the second one conflicted")

        try await lab.abort()

        #expect(!FileManager.default.fileExists(
            atPath: lab.repo.root.appendingPathComponent("applied.txt").path))
        let subjects = String(decoding: try await lab.repo.git(["log", "--format=%s"]), as: UTF8.self)
        #expect(!subjects.contains("patch one"))
    }

    // MARK: - The guards that run before git

    /// Nothing in progress: `abort` throws without running git, and the repository — including
    /// work that is merely *staged* — is untouched.
    ///
    /// This guard is the load-bearing one. See
    /// `resetMergeWithNoSquashPendingSilentlyDiscardsStagedWork` below for what the `.squash`
    /// command would otherwise have done to the same repository.
    @Test(arguments: [
        RepositoryOperation.merge, .cherryPick, .revert, .rebase, .applyingPatches, .squash,
    ])
    func abortingWithNothingInProgressThrowsAndChangesNothing(
        operation: RepositoryOperation
    ) async throws {
        let repo = try await makeRepositoryWithUncommittedWork()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError { try await CLIGitBackend().abort(operation, at: repo.root) }

        #expect(error == .noOperationInProgress)
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// Why `abort` asks the repository what is really in progress instead of trusting its
    /// caller. Verified on git 2.54 and reproduced here: with no squash pending,
    /// `git reset --merge` — the command `abort(.squash)` runs — exits **0** and silently
    /// throws away everything that was staged. A stale button in the UI would be enough.
    @Test func resetMergeWithNoSquashPendingSilentlyDiscardsStagedWork() async throws {
        let repo = try await makeRepositoryWithUncommittedWork()
        defer { repo.cleanUp() }

        try await repo.git(["reset", "--merge"])  // exit 0: no refusal, no warning

        #expect(try repo.fileContents("staged.txt") == "one\n", "the staged work was destroyed")
        #expect(try repo.fileContents("unstaged.txt") == "UNSTAGED WORK\n")
    }

    /// The UI can be a refresh behind. Asking to abort X while Y is in progress must never run
    /// X's command.
    ///
    /// Four of the five `--abort`s fail loudly when they are the wrong one — verified on git
    /// 2.54, `rebase`, `cherry-pick`, `revert` and `am` all exit **128** during a merge and
    /// leave `MERGE_HEAD` intact — so for those the guard is belt and braces. The sixth command
    /// is the one that matters; see
    /// `abortingASquashWhileARealMergeIsInProgressThrowsAndChangesNothing`.
    @Test func abortingTheWrongOperationThrowsAndChangesNothing() async throws {
        let lab = try await makeAbortLab(.merge)
        defer { lab.cleanUp() }
        let state = try await RepoState.capture(lab.repo)
        let worktree = worktreeSnapshot(lab.repo)

        let error = await branchError {
            try await CLIGitBackend().abort(.rebase, at: lab.repo.root)
        }

        #expect(error == .operationMismatch(expected: .rebase, actual: .merge))
        try await assertRepoUnchanged(lab.repo, since: state, worktree: worktree)
        #expect(try await lab.operationInProgress() == .merge)
    }

    /// The mismatch in the other direction, and with the two operations git itself cannot tell
    /// apart from a directory listing: a stuck `git am` must not be aborted as a rebase.
    @Test func abortingAnAmAsARebaseThrowsAndChangesNothing() async throws {
        let lab = try await makeAbortLab(.applyingPatches)
        defer { lab.cleanUp() }
        let state = try await RepoState.capture(lab.repo)
        let worktree = worktreeSnapshot(lab.repo)

        let error = await branchError {
            try await CLIGitBackend().abort(.rebase, at: lab.repo.root)
        }

        #expect(error == .operationMismatch(expected: .rebase, actual: .applyingPatches))
        try await assertRepoUnchanged(lab.repo, since: state, worktree: worktree)
    }

    /// The mismatch that is not belt and braces. `reset --merge` — the command `abort(.squash)`
    /// runs — is the only one of the six that does *not* refuse when it is the wrong one: run
    /// during a real merge it exits 0 and aborts **the merge**, under a button labelled "Undo
    /// Squash". The companion below shows it happening.
    @Test func abortingASquashWhileARealMergeIsInProgressThrowsAndChangesNothing() async throws {
        let lab = try await makeAbortLab(.merge)
        defer { lab.cleanUp() }
        let state = try await RepoState.capture(lab.repo)
        let worktree = worktreeSnapshot(lab.repo)

        let error = await branchError {
            try await CLIGitBackend().abort(.squash, at: lab.repo.root)
        }

        #expect(error == .operationMismatch(expected: .squash, actual: .merge))
        try await assertRepoUnchanged(lab.repo, since: state, worktree: worktree)
        #expect(try await lab.operationInProgress() == .merge)
        #expect(try await lab.repo.gitFileExists("MERGE_HEAD"))
    }

    /// What the guard above prevents, measured. Nothing about `git reset --merge` says it is
    /// only for squashes: during a conflicted merge it silently ends the merge — `MERGE_HEAD`
    /// gone, every unmerged entry gone, exit 0, not a word on stderr.
    @Test func resetMergeDuringARealMergeSilentlyAbortsTheMerge() async throws {
        let lab = try await makeAbortLab(.merge)
        defer { lab.cleanUp() }
        #expect(try await lab.repo.unmergedEntries().isEmpty == false)

        try await lab.repo.git(["reset", "--merge"])  // exit 0

        #expect(try await lab.repo.gitFileExists("MERGE_HEAD") == false, "the merge was aborted")
        #expect(try await lab.repo.unmergedEntries().isEmpty)
        #expect(try await CLIGitBackend().snapshot(at: lab.repo.root).status
            .operationInProgress == nil)
    }

    /// The one `.applyingPatches` state a *pre-existing staged* change can reach, and the only
    /// place in the table where a staged change survives an abort.
    ///
    /// Verified on git 2.54: `git am` refuses a dirty index outright ("fatal: Dirty index:
    /// cannot apply patches (dirty: other.txt)", exit 128) — but it has already created
    /// `rebase-apply/applying` by then and does not clean it up, so the snapshot reports an
    /// `am` in progress for an `am` that applied nothing at all. Aborting that exits 0, removes
    /// the directory, and leaves the staged work exactly where it was.
    @Test func anAmRefusedOverADirtyIndexStillReportsAnOperationAndAbortsCleanly() async throws {
        let repo = try await makeAbortHistory(.applyingPatches)
        defer { repo.cleanUp() }
        try repo.write("other.txt", "STAGED BEFORE\n")
        try await repo.git(["add", "other.txt"])
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        try await repo.git(["am", "-3", ".git/patches.mbox"], allowedExitCodes: [128])

        #expect(try await CLIGitBackend().snapshot(at: repo.root).status
            .operationInProgress == .applyingPatches, "an am that applied nothing")
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)

        try await CLIGitBackend().abort(.applyingPatches, at: repo.root)

        #expect(try repo.fileContents("other.txt") == "STAGED BEFORE\n")
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await CLIGitBackend().snapshot(at: repo.root).status.operationInProgress == nil)
    }

    // MARK: - Fixtures


    /// A clean repository with one staged change, one unstaged change and one untracked file —
    /// exactly the work an abort run by mistake must not be allowed near.
    private func makeRepositoryWithUncommittedWork() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("staged.txt", "one\n")
        try repo.write("unstaged.txt", "one\n")
        try await repo.commitAll("base")
        try repo.write("staged.txt", "STAGED WORK\n")
        try await repo.git(["add", "staged.txt"])
        try repo.write("unstaged.txt", "UNSTAGED WORK\n")
        try repo.write("untracked.txt", "UNTRACKED\n")
        return repo
    }
}
