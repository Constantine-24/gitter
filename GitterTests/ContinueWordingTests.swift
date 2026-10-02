import Foundation
import GitCore
import Testing

@testable import Gitter

/// Every sentence the operation bar, the composer, the Continue / Skip / Stage All sheets and
/// their notices put on screen (`ContinueWording`), pinned. Pure: no store, no git.
@Suite struct ContinueWordingTests {

    static let picked = CommitRef(sha: "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432", subject: "Change the parser")
    static let onto = CommitRef(sha: "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d", subject: "Upstream work")

    // MARK: - Progress, per operation and shape

    @Test func aRebaseSaysWhichCommitOfHowManyItStoppedAt() {
        let progress = OperationProgress(
            operation: .rebase, step: 2, total: 3, current: Self.picked, headName: "feature", onto: Self.onto)
        #expect(
            ContinueWording.progress(.rebase, progress, branch: nil)
                == "Rebasing feature onto 1a2b3c4: stopped at commit 2 of 3, 9f8e7d6 Change the parser.")
    }

    @Test func aDetachedRebaseAndOneWithoutStepsStillSayWhereItIs() {
        let detached = OperationProgress(operation: .rebase, step: 1, total: 1, current: Self.picked, onto: Self.onto)
        #expect(
            ContinueWording.progress(.rebase, detached, branch: nil)
                == "Rebasing a detached HEAD onto 1a2b3c4: stopped at commit 1 of 1, 9f8e7d6 Change the parser.")
        let noSteps = OperationProgress(operation: .rebase, current: Self.picked, headName: "feature", onto: Self.onto)
        #expect(
            ContinueWording.progress(.rebase, noSteps, branch: nil)
                == "Rebasing feature onto 1a2b3c4: stopped at 9f8e7d6 Change the parser.")
    }

    /// A failed `exec` or a `break` stops with no commit (Task 3: `.stoppedAgain` carries no
    /// git words), so the bar's own sentence is all the user gets.
    @Test func aRebaseStopWithNoCommitSaysSoWithItsStep() {
        let exec = OperationProgress(operation: .rebase, step: 3, total: 5, headName: "feature", onto: Self.onto)
        #expect(
            ContinueWording.progress(.rebase, exec, branch: nil)
                == "Rebasing feature onto 1a2b3c4: stopped at step 3 of 5, which has no commit to resolve "
                + "(an exec command that failed, or a break).")
    }

    @Test func aCherryPickSaysSingleOrHowManyAreLeft() {
        let single = OperationProgress(operation: .cherryPick, current: Self.picked)
        #expect(ContinueWording.progress(.cherryPick, single, branch: "main") == "Cherry-picking 9f8e7d6 Change the parser.")
        let range = OperationProgress(operation: .cherryPick, remaining: 3, current: Self.picked)
        #expect(
            ContinueWording.progress(.cherryPick, range, branch: "main")
                == "Cherry-picking 9f8e7d6 Change the parser: 3 commits to go, this one included.")
        let last = OperationProgress(operation: .cherryPick, remaining: 1, current: Self.picked)
        #expect(
            ContinueWording.progress(.cherryPick, last, branch: "main")
                == "Cherry-picking 9f8e7d6 Change the parser, the last commit of the range.")
    }

    @Test func aRevertSaysSingleOrHowManyAreLeft() {
        let single = OperationProgress(operation: .revert, current: Self.picked)
        #expect(ContinueWording.progress(.revert, single, branch: "main") == "Reverting 9f8e7d6 Change the parser.")
        let range = OperationProgress(operation: .revert, remaining: 2, current: Self.picked)
        #expect(
            ContinueWording.progress(.revert, range, branch: "main")
                == "Reverting 9f8e7d6 Change the parser: 2 commits to go, this one included.")
    }

    @Test func aMergeNamesWhatComesInAndWhere() {
        let named = OperationProgress(
            operation: .merge, mergeHead: Self.picked, mergedName: "feature")
        #expect(ContinueWording.progress(.merge, named, branch: "main") == "Merging feature into main.")
        let unnamed = OperationProgress(operation: .merge, mergeHead: Self.picked)
        #expect(ContinueWording.progress(.merge, unnamed, branch: nil) == "Merging 9f8e7d6 into HEAD.")
    }

    @Test func noProgressAndTheOtherOperationsHaveNoProgressSentence() {
        #expect(ContinueWording.progress(.rebase, nil, branch: "main") == nil)
        #expect(ContinueWording.progress(.squash, OperationProgress(operation: .squash), branch: "main") == nil)
        #expect(
            ContinueWording.progress(.applyingPatches, OperationProgress(operation: .applyingPatches), branch: "main")
                == nil)
        let pickWithoutCommit = OperationProgress(operation: .cherryPick)
        #expect(ContinueWording.progress(.cherryPick, pickWithoutCommit, branch: "main") == nil)
    }

    /// The bar: where, then what next. Without a progress sentence, the operation's note.
    @Test func theBarJoinsProgressAndTheNextStepOrFallsBackToTheNote() {
        let range = OperationProgress(operation: .cherryPick, remaining: 3, current: Self.picked)
        #expect(
            ContinueWording.bar(.cherryPick, range, branch: "main", hasConflicts: true)
                == "Cherry-picking 9f8e7d6 Change the parser: 3 commits to go, this one included. "
                + "Resolve the conflicts, then continue.")
        #expect(
            ContinueWording.bar(.cherryPick, range, branch: "main", hasConflicts: false)
                == "Cherry-picking 9f8e7d6 Change the parser: 3 commits to go, this one included. Continue when ready.")
        #expect(
            ContinueWording.bar(.squash, OperationProgress(operation: .squash), branch: "main", hasConflicts: false)
                == "Squash pending — commit to finish.")
        #expect(
            ContinueWording.bar(.rebase, nil, branch: nil, hasConflicts: true)
                == "Rebase in progress — resolve the conflicts, then continue.")
    }

    /// "Continue when ready." beside a Continue that is off for a reason of the repository's
    /// (an empty pick, unstaged changes) would contradict the line under the bar, which says
    /// what to do instead.
    @Test func aBlockedContinueDropsTheNextStepButConflictsKeepIt() {
        let single = OperationProgress(operation: .cherryPick, current: Self.picked)
        #expect(
            ContinueWording.bar(.cherryPick, single, branch: "main", hasConflicts: false, continueBlocked: true)
                == "Cherry-picking 9f8e7d6 Change the parser.")
        #expect(
            ContinueWording.bar(.cherryPick, single, branch: "main", hasConflicts: true, continueBlocked: true)
                == "Cherry-picking 9f8e7d6 Change the parser. Resolve the conflicts, then continue.")
        #expect(
            ContinueWording.bar(.cherryPick, single, branch: "main", hasConflicts: false, continueBlocked: false)
                == "Cherry-picking 9f8e7d6 Change the parser. Continue when ready.")
    }

    @Test func theNextStepIsCommitForAMergeAndContinueForTheOthers() {
        #expect(ContinueWording.nextStep(.merge, hasConflicts: true) == "Resolve the conflicts, then commit.")
        #expect(ContinueWording.nextStep(.merge, hasConflicts: false) == "Commit to complete the merge.")
        #expect(ContinueWording.nextStep(.squash, hasConflicts: false) == "Commit to finish the squash.")
        #expect(ContinueWording.nextStep(.rebase, hasConflicts: true) == "Resolve the conflicts, then continue.")
        #expect(ContinueWording.nextStep(.revert, hasConflicts: false) == "Continue when ready.")
        // `git am` stays abort-only in Gitter: the terminal is still its way forward.
        #expect(
            ContinueWording.nextStep(.applyingPatches, hasConflicts: true)
                == "Resolve the conflicts, then run `git am --continue` in a terminal.")
    }

    // MARK: - Buttons

    @Test func theContinueButtonNamesTheOperationAndAsksWithAnEllipsis() {
        #expect(ContinueWording.continueTitle(.rebase, asks: false) == "Continue Rebase")
        #expect(ContinueWording.continueTitle(.cherryPick, asks: false) == "Continue Cherry-Pick")
        #expect(ContinueWording.continueTitle(.revert, asks: true) == "Continue Revert\u{2026}")
        #expect(ContinueWording.skipButton == "Skip This Commit\u{2026}")
        #expect(RepositoryOperation.rebase.commitButtonTitle == "Continue Rebase")
        #expect(RepositoryOperation.cherryPick.commitButtonTitle == "Continue Cherry-Pick")
        #expect(RepositoryOperation.revert.commitButtonTitle == "Continue Revert")
        #expect(RepositoryOperation.merge.commitButtonTitle == "Commit Merge")
        #expect(RepositoryOperation.squash.commitButtonTitle == "Commit Squash")
    }

    // MARK: - Why Continue is off

    @Test func everyContinueReasonIsWorded() {
        #expect(ContinueWording.unresolved(["a.txt"]) == "Resolve the conflict in \"a.txt\" first.")
        #expect(
            ContinueWording.unresolved(["a.txt", "b.txt"])
                == "Resolve the conflicts in 2 files first: \"a.txt\" and \"b.txt\".")
        #expect(
            ContinueWording.unstaged(.rebase, ["x.txt"])
                == "A rebase can't continue while a tracked file has unstaged changes: \"x.txt\". "
                + "Stage or discard them first.")
        // A range is blocked by any unstaged change (conservative): no collision is claimed.
        #expect(
            ContinueWording.unstaged(.cherryPick, ["x.txt", "y.txt"])
                == "The cherry-pick has more commits to apply, and Gitter doesn't continue it while tracked files "
                + "have unstaged changes: \"x.txt\" and \"y.txt\". Stage or discard them first.")
        #expect(ContinueWording.enterMessage == "Enter a commit message first.")
        #expect(ContinueWording.reading(.rebase) == "Gitter is still reading where the rebase is.")
        #expect(
            ContinueWording.readFailed(.revert, "boom")
                == "Gitter couldn't read where the revert is: boom")
        #expect(
            ContinueWording.notContinuable(.merge)
                == "A merge is concluded by committing it, not by Continue.")
        #expect(
            ContinueWording.noStoppedCommit(.rebase)
                == "Gitter couldn't read which commit the rebase stopped on.")
    }

    /// A cherry-pick or revert whose resolution changes nothing cannot continue (git refuses,
    /// M 30); Skip is the way on — unless other staged files block that too (Ruling 20).
    @Test func anEmptyPickSaysSkipAndADeadEndSaysHowOut() {
        #expect(
            ContinueWording.emptyResult(.cherryPick, Self.picked, otherStaged: [])
                == "The resolution leaves 9f8e7d6 with no changes, so there is nothing to commit. Skip it instead.")
        #expect(
            ContinueWording.emptyResult(.revert, Self.picked, otherStaged: ["n.txt"])
                == "The resolution leaves 9f8e7d6 with no changes of its own, and \"n.txt\" is staged but not part "
                + "of it, so it can't be continued or skipped. Unstage \"n.txt\" in a terminal (git restore "
                + "--staged), or discard it (Gitter keeps a copy in the Stashes list), then skip the commit.")
    }

    // MARK: - Why Skip is off

    @Test func everySkipReasonNamesItsFiles() {
        #expect(ContinueWording.noCommitToSkip == "There is no commit to skip at this step.")
        #expect(
            ContinueWording.skipOtherChanges(["o.txt"])
                == "\"o.txt\" has changes that are not part of this commit, and Gitter skips only when every change "
                + "belongs to it. Discard them first (Gitter keeps a copy in the Stashes list).")
        #expect(
            ContinueWording.skipNeedsCleanPaths(["a.txt", "b.txt"])
                == "Stage or discard these first: \"a.txt\" and \"b.txt\". Git can't put them back as they are.")
    }

    // MARK: - The empty-result confirmation (rebase)

    @Test func theEmptyConfirmationSaysTheCommitIsLeftOut() {
        #expect(ContinueWording.emptyTitle(Self.picked) == "Leave 9f8e7d6 out of the rebase?")
        #expect(
            ContinueWording.emptyBody(Self.picked, otherStaged: [])
                == "The resolution leaves 9f8e7d6 \"Change the parser\" with no changes against what the rebase has "
                + "built so far, so the rebase leaves this commit out and goes on with the next one.")
        #expect(ContinueWording.emptyButton(otherStaged: []) == "Leave It Out and Continue")
    }

    /// Ruling 20: other staged files keep the commit — both facts on one sheet.
    @Test func theEmptyConfirmationWithOtherStagedFilesSaysTheCommitKeepsThem() {
        let body = ContinueWording.emptyBody(Self.picked, otherStaged: ["n.txt", "m.txt"])
        #expect(
            body
                == "The resolution leaves 9f8e7d6 \"Change the parser\" with no changes of its own. 2 other staged "
                + "files are not part of it: \"n.txt\" and \"m.txt\". The commit is not left out: it keeps them, "
                + "under its own title and author, as if they were its changes.")
        #expect(!body.contains("leaves this commit out"))
        #expect(ContinueWording.emptyTitle(Self.picked, otherStaged: ["n.txt"]) == "Commit 1 other staged file as 9f8e7d6?")
        #expect(ContinueWording.emptyButton(otherStaged: ["n.txt"]) == "Continue and Commit It")
        #expect(ContinueWording.emptyButton(otherStaged: ["n.txt", "m.txt"]) == "Continue and Commit Them")
    }

    // MARK: - The other-staged confirmation

    @Test func theOtherStagedConfirmationSaysWhereTheFilesGo() {
        #expect(ContinueWording.othersTitle(2) == "Commit 2 other staged files too?")
        #expect(ContinueWording.othersTitle(1) == "Commit 1 other staged file too?")
        #expect(
            ContinueWording.othersBody(.rebase, Self.picked, ["n.txt"])
                == "\"n.txt\" is staged but not part of 9f8e7d6 \"Change the parser\". Git commits everything that is "
                + "staged, so it goes into that commit, under its title and author.")
        #expect(
            ContinueWording.othersBody(.revert, Self.picked, ["n.txt", "m.txt"])
                == "\"n.txt\" and \"m.txt\" are staged but not part of the revert of 9f8e7d6. Git commits everything "
                + "that is staged, so they go into the revert commit.")
        #expect(
            ContinueWording.othersBody(.cherryPick, nil, ["n.txt"])
                == "\"n.txt\" is staged but not part of the commit being cherry-picked. Git commits everything that "
                + "is staged, so it goes into that commit, under its title and author.")
    }

    // MARK: - The skip confirmation

    @Test func theSkipConfirmationSaysWhatGoesAndWhereTheCopyGoes() {
        #expect(ContinueWording.skipQuestion(Self.picked) == "Skip 9f8e7d6 \"Change the parser\"?")
        #expect(
            ContinueWording.skipBody(.rebase)
                == "The rebase goes on without this commit: its changes are not applied.")
        #expect(ContinueWording.skipBody(.cherryPick) == "The cherry-pick goes on without this commit: it is not picked.")
        #expect(ContinueWording.skipBody(.revert) == "The revert goes on without this commit: it is not reverted.")
        #expect(
            ContinueWording.skipFiles(["a.txt", "b.txt"])
                == "These 2 files go back to how they are in HEAD, resolved or not:")
        #expect(ContinueWording.skipFiles(["a.txt"]) == "This file goes back to how it is in HEAD, resolved or not:")
        #expect(ContinueWording.skipFiles([]) == "Nothing has changed yet, so no file is put back.")
        #expect(
            ContinueWording.skipDestination(Self.picked, paths: ["a.txt"])
                == "Gitter first keeps a copy of their current contents in the Stashes list, as \"Skipped by Gitter: "
                + "9f8e7d6 Change the parser\".")
        #expect(ContinueWording.skipDestination(Self.picked, paths: []) == nil)
        #expect(ContinueWording.skipConfirm == "Skip Commit")
    }

    // MARK: - Stage All during an operation

    @Test func theStageAllConfirmationNamesTheFilesOutsideTheOperation() {
        #expect(ContinueWording.stageAllQuestion(.merge) == "Stage files that are not part of the merge?")
        #expect(
            ContinueWording.stageAllBody(.merge, count: 3, known: true)
                == "These 3 files are not part of the merge and will be in its commit:")
        #expect(
            ContinueWording.stageAllBody(.squash, count: 1, known: true)
                == "This file is not part of the squash and will be in its commit:")
        #expect(
            ContinueWording.stageAllBody(.rebase, count: 2, known: true)
                == "These 2 files are not part of the commit the rebase stopped on and will be committed with it:")
        #expect(
            ContinueWording.stageAllBody(.cherryPick, count: 2, known: false)
                == "Gitter can't tell which changes belong to the cherry-pick, so these are all 2 files Stage All "
                + "would add. Every one of them will be in its commit:")
        #expect(ContinueWording.stageAllConfirm == "Stage All")
        // Final review M1: GitCore refused a list that was not the confirmed one.
        #expect(ContinueWording.stageAllChanged
            == "The files Stage All would add changed after they were read, so nothing was staged. "
            + "Look at the list again, then use Stage All.")
    }

    // MARK: - Outcomes

    @Test func everyOutcomeIsWorded() {
        #expect(ContinueWording.finished(.rebase) == "Rebase finished.")
        #expect(ContinueWording.finished(.cherryPick) == "Cherry-pick finished.")
        #expect(ContinueWording.finished(.revert) == "Revert finished.")
        #expect(
            ContinueWording.finishedWithConflicts(.rebase, 2)
                == "The rebase finished, but its autostash conflicted in 2 files. Git kept the autostash in the "
                + "Stashes list.")
        #expect(
            ContinueWording.finishedWithConflicts(.rebase, 1)
                == "The rebase finished, but its autostash conflicted in 1 file. Git kept the autostash in the "
                + "Stashes list.")
        #expect(
            ContinueWording.finishedWithConflicts(.cherryPick, 2)
                == "The cherry-pick finished, but left 2 files conflicted.")
        #expect(
            ContinueWording.failed(.rebase, "pre-commit hook said no\n")
                == "The rebase did not continue. Git said: pre-commit hook said no")
        #expect(ContinueWording.failed(.revert, "  ") == "The revert did not continue, and git said nothing about why.")
    }

    /// A range that made its commit and then stranded the rest (Task 3, `.sequenceHalted`): the
    /// commit is there, no operation is detected, and git's leftover list is named.
    /// A Continue that halted the range (fix round 1, measured): the current commit was made,
    /// git refused the next; the bar, not this sentence, lists what was not applied.
    @Test func aContinueThatHaltedSaysTheCommitWasMadeAndPointsAtTheBar() {
        let text = ContinueWording.sequenceHalted(.cherryPick, "error: The following untracked working tree files would be overwritten by merge:\n\tg.txt")
        #expect(
            text
                == "Git made the commit, then stopped the cherry-pick before the next one: error: The following "
                + "untracked working tree files would be overwritten by merge: g.txt. No cherry-pick is in progress "
                + "now. The bar below lists the commits it did not apply and how to apply them.")
        #expect(!text.contains("--continue"))
    }

    /// A Skip that halted the range made **no** commit (measured: HEAD unchanged).
    @Test func aSkipThatHaltedClaimsNoCommit() {
        let text = ContinueWording.skipHalted(.revert, Self.picked, recorded: true, "error: would be overwritten")
        #expect(
            text
                == "Skipped 9f8e7d6 \u{2014} its changes are in the Stashes list. Git then stopped the revert before the "
                + "next commit: error: would be overwritten. No revert is in progress now. The bar below lists the "
                + "commits it did not apply and how to apply them.")
        #expect(!text.contains("made the commit"))
        #expect(
            ContinueWording.skipHalted(.cherryPick, Self.picked, recorded: false, "")
                == "Skipped 9f8e7d6. Git then stopped the cherry-pick before the next commit. No cherry-pick is in "
                + "progress now. The bar below lists the commits it did not apply and how to apply them.")
    }

    static let two = CommitRef(sha: "1600000000000000000000000000000000000000", subject: "Pick two")
    static let three = CommitRef(sha: "3800000000000000000000000000000000000000", subject: "Pick three")

    /// The persistent bar while `sequencer/` stays with no operation: the commits not applied,
    /// the safe way forward (measured: `--quit` keeps HEAD, index and worktree), and what
    /// `--continue` would do (measured: it leaves the first out). Commands carry full shas, and
    /// are to be copied first: once git drops `sequencer/`, the bar that holds them is gone
    /// (fix round 3).
    @Test func theHaltedBarNamesTheCommitsAndTheSafeWayForward() {
        let pick = HaltedSequence(operation: .cherryPick, notApplied: [Self.two, Self.three], total: 2)
        #expect(
            ContinueWording.halted(pick)
                == "The cherry-pick stopped part-way and is not in progress: git did not apply 2 commits, 1600000 Pick "
                + "two and 3800000 Pick three.")
        #expect(
            ContinueWording.haltedWayForward(pick)
                == "To apply them, first copy this command: `git cherry-pick \(Self.two.sha) \(Self.three.sha)`. Then "
                + "move away what git refused over, run `git cherry-pick --quit` in a terminal (it changes no file and "
                + "no commit, and this bar goes with it), then the copied command. Don't run `git cherry-pick "
                + "--continue`: it would leave out 1600000.")
        #expect(ContinueWording.reapplyCommand(pick) == "git cherry-pick \(Self.two.sha) \(Self.three.sha)")
        let revert = HaltedSequence(operation: .revert, notApplied: [Self.two], total: 1)
        #expect(
            ContinueWording.halted(revert)
                == "The revert stopped part-way and is not in progress: git did not apply 1 commit, 1600000 Pick two.")
        #expect(
            ContinueWording.haltedWayForward(revert)
                == "To apply it, first copy this command: `git revert \(Self.two.sha)`. Then move away what git refused "
                + "over, run `git revert --quit` in a terminal (it changes no file and no commit, and this bar goes "
                + "with it), then the copied command. Don't run `git revert --continue`: it would leave out 1600000.")
        let long = HaltedSequence(operation: .cherryPick, notApplied: [Self.two, Self.three], total: 25)
        #expect(ContinueWording.halted(long).hasSuffix("1600000 Pick two, 3800000 Pick three and 23 more."))
        #expect(ContinueWording.reapplyCommand(long) == nil)
        #expect(
            ContinueWording.haltedWayForward(long).hasPrefix(
                "To apply them, first copy the list in .git/sequencer/todo (--quit removes it). Then move away"))
    }

    /// Ruling 30: a range stop concluded by `git commit` is not a halt — `--continue` is right.
    @Test func aCommittedStopSaysTheRestIsWaitingForContinue() {
        let one = CommitRef(sha: "07b9cd9000000000000000000000000000000000", subject: "c1")
        let waiting = HaltedSequence(
            operation: .cherryPick, notApplied: [Self.two, Self.three], total: 2, committed: one)
        #expect(
            ContinueWording.halted(waiting)
                == "07b9cd9 c1 was committed with git commit, and the rest of the cherry-pick is waiting: 2 commits, "
                + "1600000 Pick two and 3800000 Pick three.")
        #expect(
            ContinueWording.haltedWayForward(waiting)
                == "Run `git cherry-pick --continue` in a terminal to apply them: git treats 07b9cd9 as done. Gitter "
                + "can't continue it itself, since git keeps no cherry-pick in progress for it. Or run `git "
                + "cherry-pick --quit` to leave them out.")
        #expect(ContinueWording.reapplyCommand(waiting) == nil)
        #expect(!ContinueWording.haltedWayForward(waiting).contains("Don't run"))
        let revert = HaltedSequence(operation: .revert, notApplied: [Self.two], total: 1, committed: one)
        #expect(
            ContinueWording.halted(revert)
                == "07b9cd9 c1 was committed with git commit, and the rest of the revert is waiting: 1 commit, 1600000 "
                + "Pick two.")
        #expect(ContinueWording.haltedWayForward(revert).hasPrefix("Run `git revert --continue` in a terminal to apply it:"))
    }

    // MARK: - A stop over a stale sequencer list (fix round 2, Ruling 29)

    /// Over a stale list `remaining` counts the old list's lines, and "then continue" would
    /// contradict the warning: the bar says only which commit this stop is.
    @Test func overAStaleListTheBarSaysOnlyWhichCommit() {
        let progress = OperationProgress(operation: .cherryPick, remaining: 2, current: Self.picked)
        #expect(
            ContinueWording.bar(.cherryPick, progress, branch: "main", hasConflicts: true, stale: true)
                == "Cherry-picking 9f8e7d6 Change the parser.")
        #expect(
            ContinueWording.bar(.cherryPick, progress, branch: "main", hasConflicts: true)
                == "Cherry-picking 9f8e7d6 Change the parser: 2 commits to go, this one included. Resolve the conflicts, "
                + "then continue.")
    }

    @Test func aStaleListIsNamedWithTheSafeWayOut() {
        let old = HaltedSequence(operation: .cherryPick, notApplied: [Self.two, Self.three], total: 2)
        #expect(
            ContinueWording.staleWarning(.cherryPick, old)
                == "Git still keeps the list of an earlier cherry-pick that stopped part-way: git did not apply 2 "
                + "commits, 1600000 Pick two and 3800000 Pick three. Its --continue, --skip and --abort would act on "
                + "that list \u{2014} resume it, or rewind HEAD to before it \u{2014} so Gitter won't continue, skip or "
                + "abort this cherry-pick.")
        #expect(
            ContinueWording.staleWayForward(.cherryPick, old)
                == "To finish this cherry-pick, first copy this command: `git cherry-pick \(Self.two.sha) "
                + "\(Self.three.sha)`. Then resolve its conflicts, run `git commit` in a terminal (it makes this "
                + "cherry-pick's commit and leaves the old list alone), then `git cherry-pick --quit` to forget the old "
                + "list, then the copied command. To drop this cherry-pick instead, run `git cherry-pick --quit` first "
                + "(it forgets the old list and this cherry-pick; the files stay as they are, to resolve or discard "
                + "here), then the copied command.")
        let reverts = HaltedSequence(operation: .revert, notApplied: [Self.two], total: 1)
        #expect(
            ContinueWording.staleWarning(.revert, reverts)
                == "Git still keeps the list of an earlier revert that stopped part-way: git did not apply 1 commit, "
                + "1600000 Pick two. Its --continue, --skip and --abort would act on that list \u{2014} resume it, or "
                + "rewind HEAD to before it \u{2014} so Gitter won't continue, skip or abort this revert.")
        // One commit in the old list (measured): `git commit` makes git forget it — no --quit step.
        #expect(
            ContinueWording.staleWayForward(.revert, reverts)
                == "To finish this revert, first copy this command: `git revert \(Self.two.sha)`. Then resolve its "
                + "conflicts and run `git commit` in a terminal: it makes this revert's commit, and git then forgets the "
                + "old list, which held one commit \u{2014} run the copied command after it. To drop this revert "
                + "instead, run `git revert --quit` first (it forgets the old list and this revert; the files stay as "
                + "they are, to resolve or discard here), then the copied command.")
        #expect(
            ContinueWording.staleReason(.cherryPick)
                == "Gitter won't continue, skip or abort this cherry-pick: git still keeps an earlier cherry-pick's or "
                + "revert's list, and its --continue, --skip or --abort would act on that list. The bar says how on.")
        #expect(
            ContinueWording.error(.staleSequence(old))
                == ContinueWording.staleReason(nil) + " Nothing was done.")
        #expect(
            ContinueWording.error(.notReady(.staleSequence(old)))
                == ContinueWording.staleReason(nil) + " Nothing was continued.")
        #expect(
            ContinueWording.error(.skipRefused(.staleSequence(old)))
                == ContinueWording.staleReason(nil) + " Nothing was skipped.")
    }

    // MARK: - A draft written for another commit (fix round 1, I1)

    @Test func aDraftWrittenElsewhereIsNamedAndBlocksTheButton() {
        let one = CommitRef(sha: "70de437000000000000000000000000000000000", subject: "Feature one")
        #expect(
            ContinueWording.foreignNote(writtenFor: one, operation: .rebase, current: Self.picked)
                == "This message was written for 70de437, not 9f8e7d6.")
        #expect(
            ContinueWording.foreignNote(writtenFor: nil, operation: .rebase, current: Self.picked)
                == "This message was written before the rebase stopped at 9f8e7d6.")
        #expect(
            ContinueWording.foreignNote(writtenFor: nil, operation: .merge, current: nil)
                == "This message was written before the merge began.")
        #expect(ContinueWording.useMessage(.rebase, current: Self.picked) == "Use 9f8e7d6\u{2019}s Message")
        #expect(ContinueWording.useMessage(.merge, current: nil) == "Use the Merge\u{2019}s Message")
        #expect(ContinueWording.keepMessage == "Keep This Message")
        #expect(
            ContinueWording.foreignReason(writtenFor: one, operation: .rebase, current: Self.picked)
                == "This message was written for 70de437, not 9f8e7d6. Use 9f8e7d6\u{2019}s message or keep this one "
                + "first.")
    }

    @Test func theSkipNoticeIsTheBriefsSentenceWithItsTail() {
        let stash = Stash(
            sha: String(repeating: "a", count: 40), index: 0, reflogSubject: "On main: Skipped by Gitter: 9f8e7d6 x",
            parents: ["p"], date: Date(timeIntervalSince1970: 0))
        #expect(
            ContinueWording.skipped(Self.picked, recorded: stash, then: nil)
                == "Skipped 9f8e7d6 — its changes are in the Stashes list")
        #expect(
            ContinueWording.skipped(Self.picked, recorded: stash, then: "Rebase finished.")
                == "Skipped 9f8e7d6 — its changes are in the Stashes list. Rebase finished.")
        #expect(ContinueWording.skipped(Self.picked, recorded: nil, then: nil) == "Skipped 9f8e7d6.")
        #expect(
            ContinueWording.skipped(Self.picked, recorded: nil, then: "Revert finished.")
                == "Skipped 9f8e7d6. Revert finished.")
    }

    @Test func aFailedSkipSaysTheCopyStays() {
        #expect(
            ContinueWording.skipFailed(.rebase, Self.picked, "fatal: nope", recorded: true)
                == "Couldn't skip 9f8e7d6. Git said: fatal: nope The copy Gitter made first stays in the Stashes "
                + "list.")
        #expect(
            ContinueWording.skipFailed(.rebase, Self.picked, "fatal: nope", recorded: false)
                == "Couldn't skip 9f8e7d6. Git said: fatal: nope")
    }

    // MARK: - Refusals

    @MainActor @Test func everyRefusalIsWorded() {
        #expect(
            ContinueWording.commitRefused(.rebase)
                == "A rebase stop is concluded with Continue Rebase, which makes the commit; Gitter doesn't commit "
                + "on its own there.")
        #expect(
            ContinueWording.movedOn(.cherryPick)
                == "The cherry-pick moved on since this was shown, so nothing was done. Look at it again.")
        #expect(
            ContinueWording.acknowledgementStale
                == "The staged files changed since you were asked, so nothing was continued. Continue again to see "
                + "what would be committed now.")
        #expect(
            ContinueWording.error(.operationMismatch(expected: .rebase, found: nil))
                == "No rebase is in progress any more, so nothing was done.")
        #expect(
            ContinueWording.error(.operationMismatch(expected: .rebase, found: .merge))
                == "A merge is in progress now, not a rebase, so nothing was done.")
        #expect(
            ContinueWording.error(.stoppedCommitChanged)
                == "The operation moved on to another commit since this was shown, so nothing was skipped.")
        #expect(
            ContinueWording.error(.emptyMessage)
                == "The commit message is empty once git removes its comment lines, so nothing was continued.")
        #expect(
            ContinueWording.error(.notReady(.unresolved(["a.txt"])))
                == "Resolve the conflict in \"a.txt\" first. Nothing was continued.")
        #expect(ContinueWording.error(.notReady(.otherStagedChanges([]))) == ContinueWording.acknowledgementStale)
        #expect(
            ContinueWording.error(.skipRefused(.needsCleanPaths(["a.txt"])))
                == "Stage or discard these first: \"a.txt\". Git can't put them back as they are. Nothing was skipped.")
        #expect(
            RepositoryStore.describe(OperationError.emptyMessage)
                == ContinueWording.error(.emptyMessage))
    }

    // MARK: - The composer's note

    @Test func aPickOrRevertSaysCommentLinesAreRemoved() {
        #expect(ContinueWording.commentNote("#") == "Lines starting with # are removed from the message.")
        #expect(ContinueWording.commentNote(";") == "Lines starting with ; are removed from the message.")
    }

    // MARK: - The note, updated (no terminal for a rebase)

    @Test func theRebaseNoteNoLongerSendsTheUserToATerminal() {
        for operation in [RepositoryOperation.merge, .cherryPick, .revert, .rebase, .squash] {
            for conflicts in [true, false] {
                #expect(!operation.note(hasConflicts: conflicts).contains("terminal"))
            }
        }
        #expect(!RepositoryOperation.rebase.amendBlockedHelp.contains("Commit the resolution"))
        #expect(RepositoryOperation.rebase.unstagingBlockedHelp.contains("Continue the rebase"))
    }

    // MARK: - Stash while a conflict is unresolved (backlog: no operation needed)

    @Test func stashActionsAreBlockedByAnyUnresolvedConflict() {
        #expect(StashWording.blockedByConflicts([], actions: false) == nil)
        #expect(
            StashWording.blockedByConflicts(["u.txt"], actions: false)
                == "Can't stash: \"u.txt\" has unresolved conflicts. Resolve them and stage the files first.")
        #expect(
            StashWording.blockedByConflicts(["u.txt", "v.txt"], actions: true)
                == "Stashes can't be applied, popped or dropped while \"u.txt\" and \"v.txt\" have unresolved "
                + "conflicts. Resolve them first.")
    }
}
