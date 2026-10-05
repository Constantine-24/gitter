import GitCore
import Testing

@testable import Gitter

/// B3 Task 4: "Compare with "<current>"" on a local or remote branch's menu, and Compare
/// Branches…: the titles, and why each is off — a detached HEAD, no current branch, a current
/// branch with no commits yet, the row being the current branch, fewer than two branches. Pure:
/// no store, no git.
@Suite struct CompareMenuTests {

    @Test func theTitles() {
        #expect(CompareWording.compareWithTitle(current: "main") == "Compare with \"main\"")
        #expect(CompareWording.compareWithTitle(current: nil) == "Compare with Current Branch")
        #expect(CompareWording.compareBranchesTitle == "Compare Branches…")
    }

    @Test func anotherBranchCanBeComparedWithTheCurrentOne() {
        #expect(
            CompareWording.compareWithBlocked(
                "refs/heads/feature", current: "main", currentHasCommits: true, isDetached: false) == nil)
        // The current branch's own remote branch: the harness's "a remote branch with its local one".
        #expect(
            CompareWording.compareWithBlocked(
                "refs/remotes/origin/main", current: "main", currentHasCommits: true, isDetached: false) == nil)
    }

    /// The same sentence as Switch's, so `MenuReasons` says it once.
    @Test func theCurrentBranchIsOff() {
        let reason = CompareWording.compareWithBlocked(
            "refs/heads/main", current: "main", currentHasCommits: true, isDetached: false)
        #expect(reason == "This is the branch you are on.")
        #expect(reason == RepositoryStore.currentBranchReason)
    }

    @Test func aDetachedHeadIsOff() {
        for ref in ["refs/heads/main", "refs/remotes/origin/main"] {
            #expect(
                CompareWording.compareWithBlocked(ref, current: nil, currentHasCommits: false, isDetached: true)
                    == "HEAD is detached, so there is no current branch to compare with.")
        }
    }

    @Test func noCurrentBranchIsOff() {
        #expect(
            CompareWording.compareWithBlocked("refs/heads/x", current: nil, currentHasCommits: false, isDetached: false)
                == "There is no current branch to compare with.")
    }

    @Test func aCurrentBranchWithNoCommitsIsOff() {
        #expect(
            CompareWording.compareWithBlocked(
                "refs/heads/x", current: "main", currentHasCommits: false, isDetached: false)
                == "\"main\" has no commits yet, so there is nothing to compare it with.")
    }

    /// A local branch named like a remote branch is not the current branch's remote branch.
    @Test func onlyTheCurrentBranchsOwnRefIsTheCurrentOne() {
        #expect(
            CompareWording.compareWithBlocked(
                "refs/remotes/main", current: "main", currentHasCommits: true, isDetached: false) == nil)
        #expect(
            CompareWording.compareWithBlocked(
                "refs/heads/heads/main", current: "main", currentHasCommits: true, isDetached: false) == nil)
    }

    @Test func compareBranchesNeedsTwoBranches() {
        #expect(CompareWording.compareBranchesBlocked(branchCount: 0) == "This repository has no branches to compare yet.")
        #expect(
            CompareWording.compareBranchesBlocked(branchCount: 1)
                == "Comparing needs two branches, and this repository has only one.")
        #expect(CompareWording.compareBranchesBlocked(branchCount: 2) == nil)
    }
}
