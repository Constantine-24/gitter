import Foundation
import Testing

@testable import GitCore

/// One test per cell of the kept/lost table, so the confirmation sheet's wording can never
/// drift away from what git actually does.
///
/// Every case starts from `makeAbortLab`, which puts one of each kind of change in place
/// before aborting: (a) an uncommitted edit that was already there, (b) an untracked file that
/// was already there, (c) an unstaged edit made after the operation began, (d) a change staged
/// after it began, (e) a half-finished conflict resolution, (f) a conflict resolved and
/// staged, (g) an untracked file created after it began. "Discarded" is asserted as "back to
/// exactly the bytes it held before the operation began", not merely "changed".
@Suite struct AbortKeptAndLostTests {

    // MARK: - Kept

    /// (a) An uncommitted edit that was already there, in a file the operation never touches.
    ///
    /// Rebase is absent because it cannot be reached: git refuses to *start* a rebase while any
    /// tracked file is dirty — see `aRebaseRefusesToStartWithAnUnstagedEdit` below.
    @Test(arguments: AbortCase.allCases.filter(\.acceptsAPreExistingEdit))
    func aPreExistingUncommittedEditIsKept(kind: AbortCase) async throws {
        let lab = try await makeAbortLab(kind)
        defer { lab.cleanUp() }

        try await lab.abort()

        #expect(try lab.now("other.txt") == AbortMarker.preExistingEdit)
    }

    /// The reason (a) has no rebase row: there is no rebase with pre-existing dirt to lose,
    /// because git will not begin one. Nothing changes and no rebase starts.
    @Test(arguments: [["rebase", "main"], ["rebase", "--apply", "main"]])
    func aRebaseRefusesToStartWithAnUnstagedEdit(command: [String]) async throws {
        let lab = try await makeAbortLab(.rebase)
        defer { lab.cleanUp() }
        try await lab.abort()  // back to a plain checkout of `side`
        try lab.repo.write("other.txt", AbortMarker.preExistingEdit)

        try await lab.repo.git(command, allowedExitCodes: [1])

        #expect(try await lab.operationInProgress() == nil)
        #expect(try lab.now("other.txt") == AbortMarker.preExistingEdit)
    }

    /// (a′) A change **staged** before the operation began. There is no such cell to fill for
    /// five of the seven, because git refuses to start the operation at all while the index
    /// differs from HEAD — verified on git 2.54, with a different message and a different exit
    /// code every time, and nothing changed in any of them:
    ///
    /// | | |
    /// |---|---|
    /// | true merge | `Your local changes to the following files would be overwritten by merge:` (exit 2) |
    /// | cherry-pick | `error: your local changes would be overwritten by cherry-pick.` (exit 128) |
    /// | revert | `error: your local changes would be overwritten by revert.` (exit 128) |
    /// | rebase (both backends) | `error: cannot rebase: Your index contains uncommitted changes.` (exit 1) |
    ///
    /// `git am` is the exception and has its own test
    /// (`AbortTests.anAmRefusedOverADirtyIndexStillReportsAnOperationAndAbortsCleanly`): it
    /// refuses too, but leaves its marker behind. The squash is the *other* exception and the
    /// dangerous one — see `UndoSquashTests.undoingASquashStartedOutsideGitterDestroysWork…`.
    @Test(arguments: [AbortCase.merge, .cherryPick, .revert, .rebase, .rebaseApplyBackend])
    func anOperationWillNotEvenStartWithAChangeAlreadyStaged(kind: AbortCase) async throws {
        let repo = try await makeAbortHistory(kind)
        defer { repo.cleanUp() }
        try repo.write("other.txt", AbortMarker.stagedBefore)
        try await repo.git(["add", "other.txt"])
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        try await startOperationExpectingARefusal(kind, in: repo)

        #expect(try await CLIGitBackend().snapshot(at: repo.root).status.operationInProgress == nil)
        #expect(try repo.fileContents("other.txt") == AbortMarker.stagedBefore)
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// (b) An untracked file that was already there.
    @Test(arguments: AbortCase.allCases)
    func aPreExistingUntrackedFileIsKept(kind: AbortCase) async throws {
        let lab = try await makeAbortLab(kind)
        defer { lab.cleanUp() }

        try await lab.abort()

        #expect(try lab.now("untracked-before.txt") == AbortMarker.untrackedBefore)
    }

    /// (c), for the five operations that keep it: an unstaged edit made after the operation
    /// began, to a file the operation does not touch.
    @Test(arguments: AbortCase.allCases.filter(\.keepsUnstagedEditsMadeAfterItBegan))
    func anUnstagedEditMadeDuringTheOperationIsKept(kind: AbortCase) async throws {
        let lab = try await makeAbortLab(kind)
        defer { lab.cleanUp() }

        try await lab.abort()

        #expect(try lab.now("afterU.txt") == AbortMarker.unstagedAfter)
    }

    /// (g) An untracked file created after the operation began. No abort deletes untracked
    /// files — none of these commands is `git clean`.
    @Test(arguments: AbortCase.allCases)
    func anUntrackedFileCreatedDuringTheOperationIsKept(kind: AbortCase) async throws {
        let lab = try await makeAbortLab(kind)
        defer { lab.cleanUp() }

        try await lab.abort()

        #expect(try lab.now("untracked-after.txt") == AbortMarker.untrackedAfter)
    }

    // MARK: - Discarded

    /// (c), for the two that do not keep it: `rebase --abort` resets hard, so an unstaged edit
    /// made during the rebase — in a file the rebase never touched — goes with it. This is the
    /// one row where the sheet must say something different for a rebase.
    @Test(arguments: AbortCase.allCases.filter { !$0.keepsUnstagedEditsMadeAfterItBegan })
    func anUnstagedEditMadeDuringARebaseIsDiscarded(kind: AbortCase) async throws {
        let lab = try await makeAbortLab(kind)
        defer { lab.cleanUp() }

        try await lab.abort()

        #expect(try lab.now("afterU.txt") == (try lab.before("afterU.txt")))
        #expect(try lab.now("afterU.txt") != AbortMarker.unstagedAfter)
    }

    /// (d) Anything staged after the operation began — even in a file the operation never
    /// touched — is discarded from the index *and* from the worktree.
    @Test(arguments: AbortCase.allCases)
    func aChangeStagedDuringTheOperationIsDiscarded(kind: AbortCase) async throws {
        let lab = try await makeAbortLab(kind)
        defer { lab.cleanUp() }

        try await lab.abort()

        #expect(try lab.now("afterS.txt") == (try lab.before("afterS.txt")))
        #expect(try lab.now("afterS.txt") != AbortMarker.stagedAfter)
    }

    /// (e) A half-finished conflict resolution, left in the worktree and never staged.
    @Test(arguments: AbortCase.allCases)
    func anUnstagedConflictResolutionIsDiscarded(kind: AbortCase) async throws {
        let lab = try await makeAbortLab(kind)
        defer { lab.cleanUp() }

        try await lab.abort()

        #expect(try lab.now("c1.txt") == (try lab.before("c1.txt")))
        #expect(try lab.now("c1.txt") != AbortMarker.partialResolution)
    }

    /// (f) A conflict the user resolved *and staged* — the closest thing to finished work an
    /// abort destroys, and the sentence the sheet most needs to get right.
    @Test(arguments: AbortCase.allCases)
    func aStagedConflictResolutionIsDiscarded(kind: AbortCase) async throws {
        let lab = try await makeAbortLab(kind)
        defer { lab.cleanUp() }

        try await lab.abort()

        #expect(try lab.now("c2.txt") == (try lab.before("c2.txt")))
        #expect(try lab.now("c2.txt") != AbortMarker.resolvedAndStaged)
    }

    /// The operation's own work: a file it rewrote without any conflict at all goes back too.
    ///
    /// The two rebase cases are absent for a reason that is not an omission: a rebase replays
    /// the branch's *own* commits, so `touched.txt` holds the same bytes during the rebase as it
    /// did before it started, and there is nothing to observe. What the rebase changes is where
    /// the branch points, and that is covered by
    /// `AbortTests.abortingARebasePutsHeadBackOnTheOriginalBranchTip`.
    @Test(arguments: AbortCase.allCases.filter { $0 != .rebase && $0 != .rebaseApplyBackend })
    func theOperationsOwnChangesAreDiscarded(kind: AbortCase) async throws {
        let lab = try await makeAbortLab(kind)
        defer { lab.cleanUp() }
        #expect(try lab.now("touched.txt") != (try lab.before("touched.txt")),
                "the fixture should have let the operation rewrite this file")

        try await lab.abort()

        #expect(try lab.now("touched.txt") == (try lab.before("touched.txt")))
    }
}
