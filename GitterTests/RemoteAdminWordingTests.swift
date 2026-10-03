import Foundation
import GitCore
import Testing

@testable import Gitter

/// B2 Task 4: every sentence prune, clean-up, another branch's push and fast-forward, and
/// upstream put on screen (`RemoteAdminWording`) — above all the partial and unknown outcomes,
/// which must never read as "nothing happened". Pure: no store, no git.
@Suite struct RemoteAdminWordingTests {
    static let id1 = "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1"
    static let id2 = "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
    static let id3 = "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3"
    static let id4 = "d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4"
    static let g1 = RefTip(ref: "refs/remotes/origin/gone1", id: id1)
    static let g2 = RefTip(ref: "refs/remotes/origin/gone2", id: id2)
    static let g3 = RefTip(ref: "refs/remotes/origin/gone3", id: id3)
    static let g4 = RefTip(ref: "refs/remotes/origin/gone4", id: id4)

    // MARK: - The prune sheet

    @Test func theSheetSaysWhatGoesAndThatTheServerIsUntouched() {
        let plan = PrunePlan(remote: "origin", refs: [Self.g1, Self.g2], stranded: .none)
        #expect(RemoteAdminWording.pruneSheetTitle("origin") == "Prune \"origin\"")
        #expect(
            RemoteAdminWording.pruneSheetIntro(plan)
                == "These 2 remote-tracking branches are no longer on \"origin\". Pruning deletes them here; "
                + "nothing on the server changes.")
        let one = PrunePlan(remote: "origin", refs: [Self.g1], stranded: .none)
        #expect(RemoteAdminWording.pruneSheetIntro(one).hasPrefix("This remote-tracking branch is no longer on \"origin\"."))
        #expect(RemoteAdminWording.shortRef(Self.g1.ref) == "origin/gone1")
    }

    /// The union count, and how many of the listed commits are not shown.
    @Test func strandedCommitsAreCountedOnceAndNotCalledUnreachable() {
        #expect(RemoteAdminWording.stranded(.none) == "Every commit on them is also on a branch, tag or another remote.")
        let commits = (0..<20).map { CommitRef(sha: String(repeating: "\($0 % 10)", count: 40), subject: "c\($0)") }
        let many = StrandedCommits(count: 23, commits: commits, holders: [Self.g1.ref])
        #expect(
            RemoteAdminWording.stranded(many)
                == "23 commits would be on no branch, tag or other remote Gitter can see:")
        #expect(RemoteAdminWording.strandedMore(many) == "and 3 more, not listed")
        let one = StrandedCommits(count: 1, commits: [commits[0]], holders: [Self.g1.ref])
        #expect(RemoteAdminWording.stranded(one) == "1 commit would be on no branch, tag or other remote Gitter can see:")
        #expect(RemoteAdminWording.strandedMore(one) == nil)
        #expect(!RemoteAdminWording.stranded(many).contains("unreachable"))
    }

    /// Carried note 1: pruning the branch `<r>/HEAD` points at leaves it dangling, and a fetch
    /// does not repair it — the sheet must not promise that it does.
    @Test func aDanglingHEADIsNamedWithoutPromisingAFetchFixesIt() {
        let line = RemoteAdminWording.danglingHEAD(remote: "origin", target: Self.g1.ref)
        #expect(line == "\"origin/HEAD\" points at \"origin/gone1\", which this prunes: it will point at nothing, and a fetch does not repair it.")
        #expect(RemoteAdminWording.prunesHEADTarget(target: Self.g1.ref, refs: [Self.g1, Self.g2]))
        #expect(!RemoteAdminWording.prunesHEADTarget(target: "refs/remotes/origin/main", refs: [Self.g1]))
        #expect(!RemoteAdminWording.prunesHEADTarget(target: nil, refs: [Self.g1]))
    }

    @Test func keepNameProblemsAreWorded() {
        #expect(RemoteAdminWording.keepNameProblem(nil, duplicate: false) == nil)
        #expect(RemoteAdminWording.keepNameProblem(nil, duplicate: true) == "Another kept branch has this name.")
        #expect(RemoteAdminWording.keepNameProblem(.invalidBranchName("a..b"), duplicate: false) == "That is not a valid branch name.")
        #expect(
            RemoteAdminWording.keepNameProblem(.branchExists("gone1"), duplicate: false)
                == "A branch, tag or remote named \"gone1\" already exists.")
    }

    // MARK: - The prune notice: every deleted ref with its full id (promise 3)

    @Test func thePruneNoticeNamesEveryDeletedRefInFullAndTheKeptBranches() {
        let result = PruneResult(deleted: [Self.g1, Self.g2], skippedMoved: [], keptBranches: ["gone2"])
        let text = RemoteAdminWording.pruned(result, remote: "origin", headTarget: nil)
        #expect(
            text == "Pruned 2 remote-tracking branches of \"origin\". This is the only record of what they held:\n"
                + "origin/gone1 \(Self.id1)\n"
                + "origin/gone2 \(Self.id2)\n"
                + "Kept as a local branch: \"gone2\".\n"
                + "Bring one back with: git update-ref refs/remotes/origin/<branch> <id>")
    }

    /// RF1 and the failures: each ref named with the id the sheet showed and what happened to it;
    /// a cancelled delete is unknown, never "unchanged"; the dangling HEAD after the fact.
    @Test func everyPartialOutcomeHasItsOwnWords() {
        let result = PruneResult(
            deleted: [Self.g1], skippedMoved: [Self.g2], keptBranches: [],
            failed: [RefFailure(tip: Self.g3, gitsWords: "error: cannot lock ref")],
            outcomeUnknown: [Self.g4], notTried: [RefTip(ref: "refs/remotes/origin/gone5", id: Self.id1)])
        let text = RemoteAdminWording.pruned(result, remote: "origin", headTarget: Self.g1.ref)
        #expect(text.contains("origin/gone1 \(Self.id1)"))
        #expect(text.contains("Left alone, because it changed since the list was read: origin/gone2 (was \(Self.id2))."))
        #expect(text.contains("git refused to delete origin/gone3 (\(Self.id3)): error: cannot lock ref"))
        #expect(
            text.contains(
                "Stopped while deleting origin/gone4 (\(Self.id4)): whether it is gone is not known. Refresh to see."))
        #expect(text.contains("Not tried, because the prune was stopped: origin/gone5."))
        #expect(text.contains("\"origin/HEAD\" now points at nothing (it pointed at \"origin/gone1\"); a fetch does not repair it."))
        #expect(RemoteAdminWording.prunedNeedsReading(result))
        #expect(!RemoteAdminWording.prunedNeedsReading(PruneResult(deleted: [Self.g1], skippedMoved: [], keptBranches: [])))
    }

    /// The HEAD line only when its target was really deleted.
    @Test func theDanglingLineNeedsTheTargetDeleted() {
        let skipped = PruneResult(deleted: [Self.g2], skippedMoved: [Self.g1], keptBranches: [])
        #expect(!RemoteAdminWording.pruned(skipped, remote: "origin", headTarget: Self.g1.ref).contains("origin/HEAD"))
    }

    @Test func refusalsBeforeAnythingWasDeletedSaySo() {
        #expect(
            RemoteAdminWording.pruneFailure(RemoteAdminRefusal.strandedGrew, remote: "origin")
                == "More commits would be left on no branch, tag or remote than the sheet said — something changed "
                + "while it was open. Nothing was pruned. Prune again to see what would go now.")
        #expect(
            RemoteAdminWording.pruneFailure(RemoteAdminRefusal.branchExists("gone1"), remote: "origin")
                == "Couldn't keep \"gone1\": a branch, tag or remote has that name now. Nothing was pruned.")
        #expect(
            RemoteAdminWording.pruneFailure(
                RemoteAdminPartial.keptBranchesThenStopped(kept: ["a"], failedName: "b", gitsWords: "fatal: x"),
                remote: "origin")
                == "Created the kept branch \"a\", then couldn't create \"b\": fatal: x. Nothing was pruned; "
                + "\"a\" stays.")
        // A cancellation while the kept branches were being created: they may exist.
        #expect(
            RemoteAdminWording.pruneFailure(CancellationError(), remote: "origin")
                == "Stopped the prune before anything was deleted. A kept branch may have been created; the "
                + "branch list shows what is there.")
        #expect(
            RemoteAdminWording.pruneListFailure(RemoteAdminRefusal.noSuchRemote("origin"), remote: "origin")
                == RemoteAdminWording.remoteGone("origin"))
        #expect(
            RemoteAdminWording.pruneListFailure(RemoteAdminRefusal.unsafeRefspec("+refs/*:refs/*"), remote: "m")
                .hasPrefix("Gitter won't prune \"m\": its fetch refspec +refs/*:refs/* writes outside refs/remotes/"))
    }

    // MARK: - Ruling 11 and N2

    /// A name that is no configured remote: removed or renamed since the last refresh.
    @Test func anUnconfiguredRemoteReadsAsRemovedOrRenamed() {
        #expect(
            RemoteWording.failure(RemoteOperationError.noSuchRemote("vendor"), attempt: "push \"a\" to \"vendor\"", isWrite: true)
                == "Couldn't push \"a\" to \"vendor\": \"vendor\" is no longer a configured remote — it was removed "
                + "or renamed since the last refresh — so nothing was run.")
        #expect(
            RemoteAdminWording.remoteGone("vendor")
                == "\"vendor\" is no longer a configured remote — it was removed or renamed since the last refresh. "
                + "Nothing was run.")
    }

    /// N2: the no-URL refusal names a next step.
    @Test func theNoURLRefusalNamesANextStep() {
        #expect(
            RemoteWording.refused(.noURL("vendor"), branch: "main")
                == "\"main\" is set to push to \"vendor\", which has no URL configured. Give \"vendor\" a URL "
                + "(Edit the remote's URLs), or set branch.main.pushRemote to another remote in a terminal.")
    }

    // MARK: - Clean-up

    static let merged = GoneBranch(name: "done", tip: id1, upstream: "refs/remotes/origin/done", uniqueCommits: 0, checkedOutAt: nil)
    static let unmerged = GoneBranch(name: "wip", tip: id2, upstream: "refs/remotes/origin/wip", uniqueCommits: 2, checkedOutAt: nil)
    static let here = GoneBranch(name: "cur", tip: id3, upstream: "refs/heads/base", uniqueCommits: 0, checkedOutAt: "/w/repo")

    @Test func theRowsSayMergedOrHowManyOnlyHere() {
        #expect(RemoteAdminWording.goneRowDetail(Self.merged) == "tracked origin/done · merged")
        #expect(RemoteAdminWording.goneRowDetail(Self.unmerged) == "tracked origin/wip · 2 commits only here")
        #expect(RemoteAdminWording.goneRowDetail(Self.here) == "tracked base · merged")
        #expect(RemoteAdminWording.defaultTicked(Self.merged))
        #expect(!RemoteAdminWording.defaultTicked(Self.unmerged))
        #expect(!RemoteAdminWording.defaultTicked(Self.here))
        #expect(RemoteAdminWording.checkedOut(Self.here) == "Checked out at /w/repo, so git won't delete it.")
        #expect(RemoteAdminWording.checkedOut(Self.merged) == nil)
    }

    /// A1's unmerged warning, for a ticked "N only here" row.
    @Test func aTickedUnmergedRowGetsTheUnmergedWarning() {
        #expect(
            RemoteAdminWording.unmergedWarning(Self.unmerged)
                == "2 commits exist only on \"wip\". Deleting it leaves those commits on no branch, tag or remote: "
                + "only the reflog would still reach them.")
        #expect(RemoteAdminWording.unmergedWarning(Self.merged) == nil)
        #expect(RemoteAdminWording.cleanUpButton(1) == "Delete 1 Branch")
        #expect(RemoteAdminWording.cleanUpButton(3) == "Delete 3 Branches")
    }

    @Test func aCleanCleanUpNamesEveryTip() {
        let report = CleanUpReport(deleted: [
            .init(name: "done", tip: Self.id1, settingsLeft: []), .init(name: "wip", tip: Self.id2, settingsLeft: []),
        ])
        #expect(!report.hasProblems)
        #expect(
            RemoteAdminWording.cleanedUp(report)
                == "Deleted 2 branches whose upstream was gone:\n"
                + "done \(Self.id1)\n"
                + "wip \(Self.id2)\n"
                + "Recreate one with: git branch <name> <id>")
    }

    /// Ruling 2: deleted with its settings left (a held config.lock), not deleted for each
    /// reason, and git's words.
    @Test func everyHalfDoneCleanUpIsWorded() {
        let report = CleanUpReport(
            deleted: [.init(name: "done", tip: Self.id1, settingsLeft: ["branch.done.remote", "branch.done.merge"])],
            notDeleted: [
                .init(name: "moved", reason: .moved(now: Self.id3)),
                .init(name: "more", reason: .moreWouldGo(was: 0, now: 2)),
                .init(name: "gone", reason: .alreadyGone),
                .init(name: "elsewhere", reason: .checkedOut),
                .init(name: "wt", reason: .failed("error: cannot delete branch 'wt' used by worktree at '/w/x'")),
            ])
        #expect(report.hasProblems)
        let text = RemoteAdminWording.cleanedUp(report)
        #expect(text.hasPrefix("Deleted 1 branch whose upstream was gone:\ndone \(Self.id1)\n"))
        #expect(
            text.contains(
                "\"done\" was deleted, but its settings were left behind (branch.done.remote, branch.done.merge): "
                    + "another git process held the configuration. A new branch named \"done\" would inherit them. "
                    + "Remove them with: git config --remove-section branch.done"))
        #expect(text.contains("Not deleted:"))
        #expect(text.contains("\"moved\" changed since the list was read (it is at c3c3c3c)."))
        #expect(text.contains("\"more\" now has 2 commits only on it — the list said 0."))
        #expect(text.contains("\"gone\" is already gone."))
        #expect(text.contains("\"elsewhere\" is checked out in a worktree, so git won't delete it."))
        #expect(text.contains("\"wt\": error: cannot delete branch 'wt' used by worktree at '/w/x'"))
        let unread = CleanUpReport(deleted: [.init(name: "x", tip: Self.id1, settingsLeft: nil)])
        #expect(unread.hasProblems)
        #expect(
            RemoteAdminWording.cleanedUp(unread).contains(
                "\"x\" was deleted, but Gitter couldn't read back whether its settings (branch.x.*) were left "
                    + "behind. Check with: git config --get-regexp '^branch\\.x\\.'"))
        let none = CleanUpReport(deleted: [], notDeleted: [.init(name: "gone", reason: .alreadyGone)])
        #expect(RemoteAdminWording.cleanedUp(none).hasPrefix("No branch was deleted.\nNot deleted:"))
    }

    // MARK: - Fast-forward (carried note 3: the destination is the outcome's)

    @Test func theFastForwardNoticeTakesItsIDsFromTheOutcome() {
        #expect(
            RemoteAdminWording.fastForwarded(.fastForwarded(from: Self.id1, to: Self.id2), branch: "t", upstream: "origin/t")
                == "Fast-forwarded \"t\" to \"origin/t\" (a1a1a1a..b2b2b2b).")
        #expect(
            RemoteAdminWording.fastForwarded(.upToDate, branch: "t", upstream: "origin/t")
                == "\"t\" is already up to date with \"origin/t\".")
    }

    @Test func everyFastForwardRefusalSaysNothingMoved() {
        func words(_ error: Error) -> String {
            RemoteAdminWording.fastForwardFailure(error, branch: "t", upstream: "origin/t")
        }
        #expect(words(FastForwardRefusal.checkedOut(path: "/w/wt")) == "\"t\" is in use by the worktree at /w/wt — checked out, or being rebased or bisected there — so it was not moved.")
        #expect(words(FastForwardRefusal.noUpstream) == "\"t\" has no upstream Gitter can fast-forward it to. Nothing was moved.")
        #expect(words(FastForwardRefusal.ahead(2)) == "\"t\" has 2 commits \"origin/t\" doesn't and nothing new from it, so there is nothing to fast-forward. Nothing was moved.")
        #expect(words(FastForwardRefusal.diverged(ahead: 1, behind: 3)) == "\"t\" and \"origin/t\" have both moved on (1 commit of yours, 3 of theirs), so only a merge or a rebase could combine them. Check out \"t\" and pull. Nothing was moved.")
        #expect(words(FastForwardRefusal.moved) == "\"t\" changed since you chose Fast-Forward, so it was left where it is now. Try again.")
        // Unknown, never "nothing changed".
        #expect(
            words(RemoteAdminPartial.fastForwardOutcomeUnknown(branch: "t", from: Self.id1, to: Self.id2))
                == "Stopped while moving \"t\": it is at a1a1a1a or at b2b2b2b, and which is not known. Refresh to see.")
        #expect(words(GitError.commandFailed(exitCode: 128, stderr: "fatal: in 'preparing' phase, update aborted by the reference-transaction hook"))
            == "Couldn't fast-forward \"t\": fatal: in 'preparing' phase, update aborted by the reference-transaction hook")
    }

    // MARK: - Another branch's push

    /// A refused push of a branch that is not checked out: no Pull, no Force Push (both are for
    /// the branch HEAD is on).
    @Test func aRejectedPushOfAnotherBranchOffersFastForwardNotPull() {
        let banner = RemoteAdminWording.pushRejected(
            .rejected(.nonFastForward), branch: "t", remote: "origin", remoteMessages: [])
        #expect(
            banner == "\"origin\" has commits on \"t\" that this repository doesn't, so the push was refused and "
                + "nothing was pushed. Fast-forward \"t\" if it has no commits of its own; otherwise check it out "
                + "and pull.")
        #expect(RemoteAdminWording.pushRejected(.pushed(from: "a", to: "b"), branch: "t", remote: "origin", remoteMessages: []) == nil)
        #expect(
            RemoteAdminWording.pushRejected(.rejected(.remoteRejected("hook declined")), branch: "t", remote: "origin", remoteMessages: [])
                == RemoteWording.rejected(.rejected(.remoteRejected("hook declined")), branch: "t", remote: "origin", remoteMessages: []))
    }

    // MARK: - Upstream (carried note 7)

    @Test func theUpstreamSheetSaysWhatItTracksNow() {
        #expect(RemoteAdminWording.upstreamSheetTitle("t", current: nil) == "Set Upstream of \"t\"")
        #expect(RemoteAdminWording.upstreamSheetTitle("t", current: "origin/t") == "Change Upstream of \"t\"")
        #expect(RemoteAdminWording.upstreamNow(nil) == "It has no upstream now.")
        #expect(RemoteAdminWording.upstreamNow("origin/t") == "It tracks \"origin/t\" now.")
        #expect(RemoteAdminWording.shortUpstream("refs/remotes/origin/x") == "origin/x")
        #expect(RemoteAdminWording.shortUpstream("refs/heads/base") == "base")
    }

    @Test func setAndUnsetSayWhatGitWrote() {
        #expect(
            RemoteAdminWording.upstreamSet("t", to: "refs/remotes/origin/x", result: SetUpstreamResult(wroteRebase: false))
                == "\"t\" now tracks \"origin/x\".")
        #expect(
            RemoteAdminWording.upstreamSet("t", to: "refs/remotes/origin/x", result: SetUpstreamResult(wroteRebase: true))
                == "\"t\" now tracks \"origin/x\". git also set branch.t.rebase=true (branch.autoSetupRebase), so "
                + "pulling it rebases.")
        #expect(RemoteAdminWording.upstreamUnset("t", was: "origin/t") == "\"t\" no longer has an upstream (it tracked \"origin/t\").")
    }

    @Test func everyUpstreamRefusalAndPartialIsWorded() {
        func words(_ error: Error) -> String {
            RemoteAdminWording.upstreamFailure(error, branch: "t", ref: "refs/remotes/origin/x")
        }
        #expect(words(UpstreamRefusal.notFetched("refs/remotes/origin/x")) == "\"origin/x\" doesn't exist here — not fetched yet, or pruned. Nothing was changed.")
        #expect(words(UpstreamRefusal.notABranch("refs/remotes/stray/x")) == "\"stray/x\" is not a branch any remote fetches into, so git won't track it. Nothing was changed.")
        #expect(words(UpstreamRefusal.ambiguousNamespace("refs/remotes/origin/x")) == "Two remotes fetch into \"origin/x\", so git can't tell which remote \"t\" would track. Nothing was changed.")
        #expect(words(UpstreamRefusal.ownUpstream("refs/heads/t")) == "A branch can't track itself. Nothing was changed.")
        #expect(
            words(UpstreamRefusal.mergeMismatch(expected: "refs/heads/x", written: "refs/heads/y/x"))
                == "git set the upstream of \"t\", but to refs/heads/y/x on the server, not refs/heads/x: overlapping "
                + "fetch refspecs mapped it to another branch. Change the upstream again, or fix the refspecs in a "
                + "terminal.")
        #expect(
            words(RemoteAdminPartial.upstreamChangedThenFailed(branch: "t", remote: "origin", merge: nil, gitsWords: "error: could not lock config file"))
                == "Changing the upstream of \"t\" failed part-way: error: could not lock config file. Its configuration "
                + "now has branch.t.remote = origin and no branch.t.merge. Set or unset the upstream again.")
        #expect(
            words(RemoteAdminPartial.upstreamOutcomeUnknown(branch: "t"))
                == "Stopped while writing the upstream of \"t\": what its configuration holds now is not known. Refresh to see.")
        #expect(words(BranchOperationError.noSuchBranch("base")) == "There is no branch named \"base\" any more. Nothing was changed.")
        #expect(words(GitError.commandFailed(exitCode: 1, stderr: "error: could not lock config file .git/config")) == "Couldn't change the upstream of \"t\": error: could not lock config file .git/config")
    }
}
