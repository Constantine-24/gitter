import Foundation
import GitCore
import Testing

@testable import Gitter

/// Every sentence the history actions put on screen (`HistoryWording`): the commit menu, the
/// cherry-pick / revert sheet, the rebase sheet, their notices and refusals, and the Stash and
/// Continue offer for them. Pure: no store, no git.
@MainActor @Suite struct HistoryWordingTests {

    static let a = CommitRef(sha: "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d", subject: "Add parser")
    static let b = CommitRef(sha: "2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e", subject: "Fix typo")
    static let c = CommitRef(sha: "3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f", subject: "Rename x")
    static let d = CommitRef(sha: "4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f70", subject: "Tidy up")
    static let e = CommitRef(sha: "5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f7081", subject: "Last one")
    static let head = "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432"
    static let target = "8e7d6c5b4a39281706f5e4d3c2b1a09876543210"

    static func pick(
        _ commits: [CommitRef], leftOut: [CommitRef] = [], mayDrop: [CommitRef] = [],
        headRef: String = "refs/heads/main"
    ) -> HistoryPlan {
        HistoryPlan(
            action: .cherryPick, head: head, commits: commits, leftOut: leftOut, mayDrop: mayDrop,
            headRef: headRef)
    }

    static func revert(_ commits: [CommitRef], headRef: String = "refs/heads/main") -> HistoryPlan {
        HistoryPlan(action: .revert, head: head, commits: commits, headRef: headRef)
    }

    static func rebase(
        replayed: [CommitRef], flattened: Int = 0, skipped: Int = 0, pushed: Int = 0,
        targetName: String = "refs/heads/feature", headRef: String = "refs/heads/main",
        head: String = head
    ) -> RebasePlan {
        RebasePlan(
            head: head, target: target, replayed: replayed, flattenedMerges: flattened,
            skippedAsApplied: skipped, alreadyPushed: pushed, targetName: targetName, headRef: headRef)
    }

    // MARK: - Names and lists

    @Test func aCommitIsItsShortShaAndSubject() {
        #expect(HistoryWording.commit(Self.a) == "1a2b3c4 Add parser")
    }

    /// Subjects are somebody else's text: a bidi override or an escape cannot rearrange the line.
    @Test func aSubjectIsMadePlain() {
        let odd = CommitRef(sha: Self.a.sha, subject: "Evil\u{1B}[31m red\u{202E}txet")
        #expect(!HistoryWording.commit(odd).contains("\u{1B}"))
        #expect(!HistoryWording.commit(odd).contains("\u{202E}"))
    }

    @Test func listsAreCappedAtThreeAndSayHowManyMore() {
        #expect(HistoryWording.commits([Self.a]) == "1a2b3c4 Add parser")
        #expect(
            HistoryWording.commits([Self.a, Self.b, Self.c])
                == "1a2b3c4 Add parser, 2b3c4d5 Fix typo, 3c4d5e6 Rename x")
        #expect(
            HistoryWording.commits([Self.a, Self.b, Self.c, Self.d, Self.e])
                == "1a2b3c4 Add parser, 2b3c4d5 Fix typo, 3c4d5e6 Rename x and 2 more")
        #expect(HistoryWording.names(["a", "b", "c", "d"]) == "a, b, c and 1 more")
        #expect(HistoryWording.names(["a"]) == "a")
    }

    @Test func countsSpellTheSingular() {
        #expect(HistoryWording.count(1) == "1 commit")
        #expect(HistoryWording.count(3) == "3 commits")
    }

    @Test func theBranchIsQuotedAndADetachedHeadSaysSo() {
        #expect(HistoryWording.branch(headRef: "refs/heads/main") == "\"main\"")
        #expect(HistoryWording.branch(headRef: "refs/heads/feature/x") == "\"feature/x\"")
        #expect(HistoryWording.branch(headRef: "") == "the detached HEAD")
    }

    @Test func aTargetIsItsBranchNameOrItsShortSha() {
        #expect(HistoryWording.target("refs/heads/feature") == "\"feature\"")
        #expect(HistoryWording.target("refs/remotes/origin/main") == "\"origin/main\"")
        #expect(HistoryWording.target(Self.target) == "8e7d6c5")
        #expect(HistoryWording.target("feature") == "\"feature\"")
    }

    @Test func theAttemptNamesTheActionAndItsCount() {
        #expect(HistoryWording.attempt(.cherryPick, count: 1) == "cherry-pick 1 commit")
        #expect(HistoryWording.attempt(.cherryPick, count: 3) == "cherry-pick 3 commits")
        #expect(HistoryWording.attempt(.revert, count: 2) == "revert 2 commits")
        #expect(HistoryWording.rebaseAttempt("refs/heads/feature") == "rebase onto \"feature\"")
        #expect(HistoryWording.rebaseAttempt(Self.target) == "rebase onto 8e7d6c5")
    }

    // MARK: - Menus

    @Test func theMenuTitlesCountTheSelection() {
        #expect(HistoryWording.menuTitle(.cherryPick, count: 1) == "Cherry-Pick Commit…")
        #expect(HistoryWording.menuTitle(.cherryPick, count: 3) == "Cherry-Pick 3 Commits…")
        #expect(HistoryWording.menuTitle(.revert, count: 1) == "Revert Commit…")
        #expect(HistoryWording.menuTitle(.revert, count: 2) == "Revert 2 Commits…")
    }

    @Test func theRebaseMenuTitleNamesWhatIsRebasedAndOntoWhat() {
        #expect(HistoryWording.rebaseMenuTitle(current: "main", onto: nil) == "Rebase \"main\" onto Here…")
        #expect(HistoryWording.rebaseMenuTitle(current: nil, onto: nil) == "Rebase Detached HEAD onto Here…")
        #expect(
            HistoryWording.rebaseMenuTitle(current: "main", onto: "feature")
                == "Rebase \"main\" onto \"feature\"…")
        #expect(
            HistoryWording.rebaseMenuTitle(current: "main", onto: "origin/main")
                == "Rebase \"main\" onto \"origin/main\"…")
    }

    @Test func theDisabledItemsSayWhy() {
        #expect(HistoryWording.rebaseNeedsOneCommit == "Rebase onto a commit needs exactly one commit selected.")
        #expect(HistoryWording.rebaseOntoHead == "HEAD is on this commit already.")
        #expect(
            HistoryWording.mergesInSelection
                == "Merge commits can't be cherry-picked or reverted. Leave them out of the selection.")
    }

    @Test func theDetailPaneSaysHowManyAreSelected() {
        #expect(HistoryWording.selectionLine(0) == nil)
        #expect(HistoryWording.selectionLine(1) == nil)
        #expect(HistoryWording.selectionLine(3) == "3 commits selected. Showing the first.")
    }

    // MARK: - The cherry-pick / revert sheet

    @Test func theSheetAsksAboutTheBranchAndTheCount() {
        #expect(
            HistoryWording.sheetTitle(Self.pick([Self.a, Self.b, Self.c]))
                == "Cherry-pick 3 commits onto \"main\"?")
        #expect(
            HistoryWording.sheetTitle(Self.pick([Self.a], headRef: ""))
                == "Cherry-pick 1 commit onto the detached HEAD?")
        #expect(HistoryWording.sheetTitle(Self.revert([Self.a, Self.b])) == "Revert 2 commits on \"main\"?")
    }

    @Test func theSheetSaysInWhichOrder() {
        #expect(
            HistoryWording.sheetOrder(Self.pick([Self.a, Self.b]))
                == "Each is applied on top of \"main\" as a new commit, oldest first:")
        #expect(
            HistoryWording.sheetOrder(Self.revert([Self.b, Self.a]))
                == "Each is undone by a new commit on \"main\", newest first:")
        // One commit has no order to speak of.
        #expect(HistoryWording.sheetOrder(Self.pick([Self.a])) == "It is applied on top of \"main\" as a new commit:")
        #expect(HistoryWording.sheetOrder(Self.revert([Self.a])) == "It is undone by a new commit on \"main\":")
    }

    @Test func leftOutCommitsAreNamed() {
        #expect(HistoryWording.leftOut(Self.pick([Self.a])) == nil)
        #expect(
            HistoryWording.leftOut(Self.pick([Self.a], leftOut: [Self.b, Self.c]))
                == "Left out, already on \"main\": 2b3c4d5 Fix typo, 3c4d5e6 Rename x.")
    }

    /// A prediction, wrong in both directions (Task 1): "may".
    @Test func mayDropIsAPredictionNotAPromise() {
        #expect(HistoryWording.mayDrop(Self.pick([Self.a])) == nil)
        #expect(
            HistoryWording.mayDrop(Self.pick([Self.a, Self.b], mayDrop: [Self.b]))
                == "May be skipped as already applied, since \"main\" has the same change: 2b3c4d5 Fix typo.")
    }

    @Test func theSheetSaysWhatHappensOnAStop() {
        #expect(
            HistoryWording.onStop
                == "If git stops on a commit (a conflict, say), the operation bar takes over: "
                + "resolve it and Continue, Skip that commit, or Abort.")
        #expect(HistoryWording.confirmButton(.cherryPick) == "Cherry-Pick")
        #expect(HistoryWording.confirmButton(.revert) == "Revert")
    }

    // MARK: - The rebase sheet

    @Test func theRebaseSheetAsksAboutTheBranchAndTheTarget() {
        #expect(HistoryWording.rebaseTitle(Self.rebase(replayed: [Self.a])) == "Rebase \"main\" onto \"feature\"?")
        #expect(
            HistoryWording.rebaseTitle(Self.rebase(replayed: [Self.a], targetName: Self.target, headRef: ""))
                == "Rebase the detached HEAD onto 8e7d6c5?")
    }

    @Test func theRebaseSummaryCountsWhatIsReplayed() {
        #expect(
            HistoryWording.rebaseSummary(Self.rebase(replayed: [Self.a]), incoming: nil)
                == "This commit is replayed onto \"feature\" as a new commit:")
        #expect(
            HistoryWording.rebaseSummary(Self.rebase(replayed: [Self.a, Self.b]), incoming: 4)
                == "These 2 commits are replayed onto \"feature\" as new commits, oldest first:")
    }

    @Test func aRebaseThatReplaysNothingSaysWhatHappensInstead() {
        let none = Self.rebase(replayed: [])
        #expect(
            HistoryWording.rebaseSummary(none, incoming: 0)
                == "\"main\" already contains \"feature\": nothing changes.")
        #expect(
            HistoryWording.rebaseSummary(none, incoming: 2)
                == "\"main\" moves straight forward to \"feature\" (2 commits): nothing is rewritten.")
        #expect(
            HistoryWording.rebaseSummary(none, incoming: nil)
                == "No commit is replayed: \"main\" already contains \"feature\" or moves straight "
                + "forward to it.")
        #expect(
            HistoryWording.rebaseSummary(Self.rebase(replayed: [], head: Self.target), incoming: nil)
                == "\"main\" already contains \"feature\": nothing changes.")
        #expect(
            HistoryWording.rebaseSummary(Self.rebase(replayed: [], skipped: 2), incoming: 3)
                == "No commit is replayed onto \"feature\".")
        #expect(
            HistoryWording.rebaseSummary(Self.rebase(replayed: [], flattened: 1), incoming: nil)
                == "No commit is replayed onto \"feature\".")
    }

    @Test func flattenedMergesAndSkippedCommitsAreCounted() {
        #expect(HistoryWording.flattened(0) == nil)
        #expect(
            HistoryWording.flattened(1)
                == "1 merge commit is dropped; the commits it merged are replayed in a line.")
        #expect(
            HistoryWording.flattened(3)
                == "3 merge commits are dropped; the commits they merged are replayed in a line.")
        let plan = Self.rebase(replayed: [Self.a])
        #expect(HistoryWording.skipped(0, plan) == nil)
        #expect(HistoryWording.skipped(1, plan) == "1 commit is skipped: \"feature\" already has its change.")
        #expect(HistoryWording.skipped(2, plan) == "2 commits are skipped: \"feature\" already has their changes.")
    }

    @Test func alreadyPushedCommitsAreAWarning() {
        #expect(HistoryWording.alreadyPushed(0) == nil)
        #expect(
            HistoryWording.alreadyPushed(1)
                == "1 of the commits this rewrites is already on a remote. Pushing afterwards needs a "
                + "force push, and anyone who has it must deal with the rewrite.")
        #expect(
            HistoryWording.alreadyPushed(3)
                == "3 of the commits this rewrites are already on a remote. Pushing afterwards needs a "
                + "force push, and anyone who has them must deal with the rewrite.")
    }

    @Test func theRebaseSheetSaysWhatHappensOnAStop() {
        #expect(
            HistoryWording.rebaseOnStop(Self.rebase(replayed: [Self.a]))
                == "If git stops on a commit (a conflict, say), the operation bar takes over: resolve "
                + "it and Continue, Skip that commit, or Abort to put \"main\" back as it was.")
        #expect(HistoryWording.rebaseButton == "Rebase")
    }

    // MARK: - Notices

    @Test func anAppliedPickSaysHowManyAndTheWayBack() {
        #expect(
            HistoryWording.applied(Self.pick([Self.a, Self.b, Self.c]), count: 3, dropped: [])
                == "Cherry-picked 3 commits onto \"main\". The reflog keeps where it was; to undo: "
                + "git reset --keep \(Self.head)")
        #expect(
            HistoryWording.applied(Self.pick([Self.a], headRef: ""), count: 1, dropped: [])
                == "Cherry-picked 1 commit onto the detached HEAD. The reflog keeps where it was; to "
                + "undo: git reset --keep \(Self.head)")
    }

    @Test func droppedCommitsAreNamed() {
        #expect(
            HistoryWording.applied(Self.pick([Self.a, Self.b]), count: 1, dropped: [Self.b])
                == "Cherry-picked 1 commit onto \"main\". Skipped as already applied: 2b3c4d5 Fix typo. "
                + "The reflog keeps where it was; to undo: git reset --keep \(Self.head)")
    }

    /// `.applied(count: 0, dropped: all)` is a valid result: nothing to undo, nothing "applied".
    @Test func aPickThatDroppedEverythingSaysNothingWasPicked() {
        let text = HistoryWording.applied(Self.pick([Self.a, Self.b]), count: 0, dropped: [Self.a, Self.b])
        #expect(
            text == "Nothing was cherry-picked: \"main\" already has the changes of 1a2b3c4 Add parser, "
                + "2b3c4d5 Fix typo.")
        #expect(!text.contains("reset"))
    }

    @Test func anAppliedRevertSaysHowManyAndTheWayBack() {
        #expect(
            HistoryWording.applied(Self.revert([Self.b, Self.a]), count: 2, dropped: [])
                == "Reverted 2 commits on \"main\". The reflog keeps where it was; to undo: "
                + "git reset --keep \(Self.head)")
    }

    @Test func aRebaseNoticeNamesOrigHeadAndTheOldTip() {
        let plan = Self.rebase(replayed: [Self.a])
        #expect(
            HistoryWording.rebaseNotice(.rebased, plan: plan)
                == "Rebased \"main\" onto \"feature\". The old tip, 9f8e7d6, is ORIG_HEAD for now; to "
                + "undo: git reset --keep \(Self.head)")
        #expect(HistoryWording.rebaseNotice(.fastForwarded, plan: plan) == "Fast-forwarded \"main\" to \"feature\".")
        #expect(
            HistoryWording.rebaseNotice(.upToDate, plan: plan)
                == "\"main\" already contains \"feature\"; nothing changed.")
        // A stop is A2's: the operation bar says it.
        #expect(HistoryWording.rebaseNotice(.conflicts, plan: plan) == nil)
    }

    @Test func anAlreadyRevertedCommitChangesNothing() {
        #expect(
            HistoryWording.alreadyReverted(Self.a, plan: Self.revert([Self.a]))
                == "Nothing to revert: \"main\" already undoes 1a2b3c4 Add parser. Nothing changed.")
    }

    /// Ruling 4: a signing failure or a refusing prepare-commit-msg hook — never "signing".
    @Test func aRevertLeftStagedSaysWhatGitSaidAndTheTwoWaysOn() {
        let words = "error: gpg failed to sign the data:\n(no gpg output)\nerror: failed to write commit object\nfatal: revert failed\n"
        let ready = HistoryWording.revertLeftStaged(gitsWords: words, messageInComposer: true)
        #expect(
            ready
                == "git could not make the revert commit. It said: error: gpg failed to sign the data: "
                + "(no gpg output) error: failed to write commit object fatal: revert failed. The "
                + "revert's changes are staged and its message is in the commit box: Commit them, or "
                + "Discard the staged changes.")
        let typed = HistoryWording.revertLeftStaged(gitsWords: "hook said no\n", messageInComposer: false)
        #expect(
            typed
                == "git could not make the revert commit. It said: hook said no. The revert's changes "
                + "are staged: write a message and Commit them, or Discard the staged changes.")
        #expect(!typed.lowercased().contains("signing"))
    }

    @Test func theRevertMessageIsGitsOwn() {
        #expect(
            HistoryWording.revertMessage(Self.a)
                == "Revert \"Add parser\"\n\nThis reverts commit \(Self.a.sha).")
        let reverted = CommitRef(sha: Self.b.sha, subject: "Revert \"Add parser\"")
        #expect(
            HistoryWording.revertMessage(reverted)
                == "Reapply \"Add parser\"\n\nThis reverts commit \(Self.b.sha).")
    }

    @Test func aFailureKeepsGitsWords() {
        #expect(
            HistoryWording.failed(.cherryPick, gitsWords: "fatal: bad\n")
                == "The cherry-pick failed. git said: fatal: bad")
        #expect(HistoryWording.failed(.revert, gitsWords: "") == "The revert failed.")
    }

    // MARK: - Refusals

    @Test func anOperationInProgressRefusesWithItsOwnSentence() {
        #expect(
            HistoryWording.refusal(.operationInProgress(.merge), action: .cherryPick, count: 3)
                == "Can't cherry-pick 3 commits: a merge is in progress. Commit or abort it first.")
        #expect(
            HistoryWording.rebaseRefusal(.operationInProgress(.cherryPick), target: "refs/heads/feature")
                == "Can't rebase onto \"feature\": a cherry-pick is in progress. Continue or abort it first.")
    }

    @Test func trackedChangesAreNamed() {
        #expect(
            HistoryWording.refusal(.trackedChanges(["a.txt"]), action: .revert, count: 1)
                == "Can't revert 1 commit: a.txt has uncommitted changes. Commit or stash them first.")
        #expect(
            HistoryWording.rebaseRefusal(.trackedChanges(["a", "b", "c", "d", "e"]), target: Self.target)
                == "Can't rebase onto 8e7d6c5: a, b, c and 2 more have uncommitted changes. Commit or "
                + "stash them first.")
    }

    @Test func mergeCommitsAndCommitsNotOnTheBranchAreNamed() {
        let merge = CommitRef(sha: Self.c.sha, subject: "Merge branch 'x'")
        #expect(
            HistoryWording.refusal(.mergeCommits([merge]), action: .cherryPick, count: 2)
                == "Can't cherry-pick 2 commits: 3c4d5e6 Merge branch 'x' is a merge commit, which "
                + "Gitter does not cherry-pick or revert. Leave it out of the selection.")
        #expect(
            HistoryWording.refusal(.mergeCommits([merge, merge]), action: .revert, count: 2)
                == "Can't revert 2 commits: 3c4d5e6 Merge branch 'x', 3c4d5e6 Merge branch 'x' are "
                + "merge commits, which Gitter does not cherry-pick or revert. Leave them out of the "
                + "selection.")
        #expect(
            HistoryWording.refusal(.notOnBranch([Self.a]), action: .revert, count: 1)
                == "Can't revert 1 commit: the current branch does not contain 1a2b3c4 Add parser, so "
                + "there is nothing to undo.")
    }

    @Test func nothingToApplyAndAnUnbornHead() {
        #expect(
            HistoryWording.refusal(.nothingToApply, action: .cherryPick, count: 2)
                == "Nothing to cherry-pick: the current branch already has every selected commit.")
        #expect(HistoryWording.refusal(.nothingToApply, action: .revert, count: 0) == "Nothing to revert: no commit is selected.")
        #expect(
            HistoryWording.refusal(.unbornHead, action: .cherryPick, count: 1)
                == "Can't cherry-pick 1 commit: the current branch has no commits yet.")
        #expect(
            HistoryWording.rebaseRefusal(.unbornHead, target: "refs/heads/feature")
                == "Can't rebase onto \"feature\": the current branch has no commits yet.")
    }

    /// The Ruling for Task 3: another commit, another branch at the same commit, or a detach —
    /// all "the branch changed while this was open".
    @Test func aBranchThatChangedWhileTheSheetWasOpenSaysSo() {
        #expect(
            HistoryWording.refusal(.headMoved, action: .cherryPick, count: 3)
                == "The branch changed while this was open, so nothing was cherry-picked. Ask again to "
                + "see what it would do now.")
        #expect(
            HistoryWording.refusal(.headMoved, action: .revert, count: 1)
                == "The branch changed while this was open, so nothing was reverted. Ask again to see "
                + "what it would do now.")
        #expect(
            HistoryWording.rebaseRefusal(.headMoved, target: "refs/heads/feature")
                == "The branch changed while this was open, so nothing was rebased. Ask again to see "
                + "what it would do now.")
    }

    @Test func aPlanThatChangedWhileTheSheetWasOpenSaysSo() {
        #expect(
            HistoryWording.refusal(.planChanged, action: .cherryPick, count: 3)
                == "What this would do changed while it was open, so nothing was cherry-picked. Ask "
                + "again to see what it would do now.")
        #expect(
            HistoryWording.rebaseRefusal(.planChanged, target: "refs/heads/feature")
                == "\"feature\" or the commits to replay changed while this was open, so nothing was "
                + "rebased. Ask again to see what it would do now.")
    }

    // MARK: - Stash and Continue

    @Test func trackedChangesOfferAStashThatReplansTheAction() {
        let action = PendingBranchAction.history(.cherryPick, [Self.a.sha, Self.b.sha])
        let offer = StashAndContinue.offer(forHistory: .trackedChanges(["f"]), action: action)
        #expect(
            offer
                == StashAndContinueOffer(
                    action: action, includeUntracked: false,
                    message: "Gitter: before cherry-picking 2 commits", refusal: .treeNotClean))
        let rebase = PendingBranchAction.rebaseOnto("refs/heads/feature")
        #expect(
            StashAndContinue.offer(forHistory: .trackedChanges(["f"]), action: rebase)?.message
                == "Gitter: before rebasing onto feature")
        #expect(
            StashWording.continueMessage(for: .rebaseOnto(Self.target))
                == "Gitter: before rebasing onto 8e7d6c5")
        #expect(
            StashWording.continueMessage(for: .history(.revert, [Self.a.sha]))
                == "Gitter: before reverting 1 commit")
    }

    @Test func noOtherHistoryRefusalOffersAStash() {
        let refusals: [HistoryRefusal] = [
            .operationInProgress(.merge), .mergeCommits([Self.a]), .notOnBranch([Self.a]),
            .nothingToApply, .unbornHead, .headMoved, .planChanged,
        ]
        for refusal in refusals {
            #expect(StashAndContinue.offer(forHistory: refusal, action: .history(.revert, [Self.a.sha])) == nil)
        }
    }

    /// A history refusal goes up with the offer; its sentence is the wording's.
    @Test func aRefusalCarriesItsOfferAndItsSentence() {
        let action = PendingBranchAction.history(.cherryPick, [Self.a.sha])
        let error = HistoryWording.error(HistoryRefusal.trackedChanges(["f"]), for: action)
        #expect((error as? RefusalWithStashOffer)?.offer.action == action)
        #expect(
            RepositoryStore.describe(error)
                == "Can't cherry-pick 1 commit: f has uncommitted changes. Commit or stash them first.")
        let plain = HistoryWording.error(HistoryRefusal.headMoved, for: .rebaseOnto("refs/heads/feature"))
        #expect(!(plain is RefusalWithStashOffer))
        #expect(
            RepositoryStore.describe(plain)
                == "The branch changed while this was open, so nothing was rebased. Ask again to see "
                + "what it would do now.")
    }

    /// git's refusal at the first commit (Ruling 6b) reads as the action that was refused, with
    /// the offer when a stash answers it.
    @Test func gitsRefusalAtTheFirstCommitNamesTheAction() {
        let action = PendingBranchAction.history(.revert, [Self.a.sha, Self.b.sha])
        let error = HistoryWording.error(
            BranchOperationError.wouldOverwrite(tracked: ["f"], untracked: []), for: action)
        #expect(error is RefusalWithStashOffer)
        #expect(
            RepositoryStore.describe(error)
                == "Can't revert 2 commits: your changes to f would be overwritten. Commit or move them first.")
        let git = GitError.commandFailed(exitCode: 1, stderr: "fatal: x")
        #expect(RepositoryStore.describe(HistoryWording.error(git, for: action)) == "fatal: x")
    }

    // MARK: - The staged revert's notice

    private static func snapshot(staged: Bool) -> RepoSnapshot {
        let file = FileStatus(
            path: "f.txt", originalPath: nil, staged: staged ? .modified : nil,
            unstaged: staged ? nil : .modified)
        return RepoSnapshot(
            root: URL(fileURLWithPath: "/nonexistent"),
            status: WorkingCopyStatus(
                headSha: head, branch: "main", upstream: nil, ahead: 0, behind: 0, files: [file]),
            refs: .empty, commits: [], graph: [])
    }

    /// "The revert's changes are staged …" is true until they are not: committed or discarded
    /// (nothing staged any more), and the notice goes with them.
    @Test func theStagedRevertNoticeEndsWhenNothingIsStaged() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        store.showStagedRevertNotice(Notice(text: "staged"))
        store.setSnapshot(Self.snapshot(staged: true))
        #expect(store.stickyNotice?.text == "staged")
        store.setSnapshot(Self.snapshot(staged: false))
        #expect(store.stickyNotice == nil)
    }

    /// Another sticky notice replaced it: that one is not the revert's to end.
    @Test func aReplacedStagedRevertNoticeIsLeftAlone() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        store.showStagedRevertNotice(Notice(text: "staged"))
        store.showStickyNotice(Notice(text: "other"))
        store.setSnapshot(Self.snapshot(staged: false))
        #expect(store.stickyNotice?.text == "other")
    }

    // MARK: - The pending action

    @Test func thePendingActionsSummariseThemselvesAndNeverStrandCommits() {
        let pick = PendingBranchAction.history(.cherryPick, [Self.a.sha, Self.b.sha])
        let rebase = PendingBranchAction.rebaseOnto("refs/remotes/origin/main")
        #expect(pick.summary == "cherry-pick 2 commits")
        #expect(rebase.summary == "rebase onto \"origin/main\"")
        #expect(!pick.canStrandCommits(leavingHeadAt: Self.head))
        #expect(!rebase.canStrandCommits(leavingHeadAt: Self.head))
    }
    // MARK: - History's depth (H1)

    @Test func theEndRowAndTheRevealNoticesReadAsPlanned() {
        #expect(HistoryWording.loadingOlder == "Loading older commits…")
        #expect(HistoryWording.startOfHistory == "Start of history")
        #expect(HistoryWording.notInHistory(shortSha: "1a2b3c4")
            == "1a2b3c4 isn't in the history list: no branch, tag or HEAD reaches it.")
        #expect(HistoryWording.beyondCap(shortSha: "1a2b3c4")
            == "1a2b3c4 is more than 50,000 commits back, past what the history list loads.")
    }
}
