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
    /// X's command — `git rebase --abort` during a merge exits 0 while doing nothing, which
    /// would look like success and leave the merge exactly where it was.
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

    // MARK: - When the abort itself fails

    /// Git's documented "in some cases be unable to reconstruct" case, pinned down.
    ///
    /// `touched.txt` is a file the operation rewrote without conflicting; editing it *after*
    /// the operation began leaves it differing from HEAD in both the index and the worktree,
    /// and the two-way reset every one of these aborts performs refuses to proceed
    /// ("error: Entry 'touched.txt' not uptodate. Cannot merge.", exit 128). Verified atomic:
    /// nothing at all changes, and the operation is still in progress afterwards.
    @Test(arguments: [AbortCase.merge, .squash, .cherryPick, .revert])
    func abortRefusesWhenAFileTheOperationRewroteHasAnUnstagedEdit(
        kind: AbortCase
    ) async throws {
        let lab = try await makeAbortLab(kind)
        defer { lab.cleanUp() }
        try lab.repo.write("touched.txt", "EDITED AFTER\n")
        let state = try await RepoState.capture(lab.repo)
        let worktree = worktreeSnapshot(lab.repo)

        await #expect(throws: GitError.self) { try await lab.abort() }

        try await assertRepoUnchanged(lab.repo, since: state, worktree: worktree)
        #expect(try await lab.operationInProgress() == kind.operation)
    }

    /// The same edit does not stop a rebase: `rebase --abort` resets hard, so it overwrites the
    /// edit rather than refusing over it. Stated as its own test because it is the opposite
    /// answer to the one above, from the same starting point.
    @Test func abortingARebaseOverwritesAnUnstagedEditInsteadOfRefusing() async throws {
        let lab = try await makeAbortLab(.rebase)
        defer { lab.cleanUp() }
        try lab.repo.write("touched.txt", "EDITED AFTER\n")

        try await lab.abort()

        #expect(try lab.now("touched.txt") == (try lab.before("touched.txt")))
        #expect(try await lab.operationInProgress() == nil)
    }

    /// The one abort that is **not** atomic when it fails, verified on git 2.54.
    ///
    /// `git am --abort` cleans the conflicted index *first* and rewinds the branch second, so
    /// when the rewind is refused ("Entry 'touched.txt' not uptodate. Cannot merge." / "fatal:
    /// failed to clean index") the conflict is already gone while the branch still carries the
    /// commits `am` made and `rebase-apply/` is still there. The user is left mid-`am` with
    /// their conflict resolution destroyed, and retrying fails identically until the unstaged
    /// edit is dealt with. Nothing Gitter can do about that except never claim a failed abort
    /// left the repository untouched.
    @Test func anAbortedAmCanFailHalfWay() async throws {
        let repo = try await makeAmWhoseFirstPatchRewrites("touched.txt")
        defer { repo.cleanUp() }
        #expect(try await repo.unmergedEntries().isEmpty == false)
        let headMidAm = try await repo.headSha()
        try repo.write("touched.txt", "EDITED AFTER\n")

        await #expect(throws: GitError.self) {
            try await CLIGitBackend().abort(.applyingPatches, at: repo.root)
        }

        #expect(try await repo.unmergedEntries().isEmpty, "the conflict was cleaned up anyway")
        #expect(try await repo.headSha() == headMidAm, "the branch was not rewound")
        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        #expect(status.operationInProgress == .applyingPatches, "still mid-am")
    }

    // MARK: - Fixtures used by more than one test above

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

    /// A `git am` stopped at a conflict, where the patch it *did* apply rewrote `path`. That
    /// is what makes the rewind refuse once `path` is edited without being staged.
    private func makeAmWhoseFirstPatchRewrites(_ path: String) async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("c1.txt", "base\n")
        try repo.write(path, "base\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "side"])
        try repo.write(path, "from the first patch\n")
        try await repo.commitAll("patch one")
        try repo.write("c1.txt", "side\n")
        try await repo.commitAll("patch two")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("c1.txt", "main\n")
        try await repo.commitAll("main")
        let patches = try await repo.git(["format-patch", "-2", "--stdout", "side"])
        try patches.write(to: repo.root.appendingPathComponent(".git/patches.mbox"))
        try await repo.git(["am", "-3", ".git/patches.mbox"], allowedExitCodes: [128])
        return repo
    }
}
