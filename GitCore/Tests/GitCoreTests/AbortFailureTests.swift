import Foundation
import Testing

@testable import GitCore

/// The two ways `abort(_:at:)` itself can fail, and what is left behind when it does.
///
/// Split from `AbortTests` for length, but they belong together: a caller that renders every
/// throw as "nothing happened" would be right four times out of five and wrong — destructively
/// — the fifth.
@Suite struct AbortFailureTests {

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

    // MARK: - Fixture

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
