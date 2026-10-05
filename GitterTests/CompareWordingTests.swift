import Foundation
import GitCore
import Testing

@testable import Gitter

/// B3 Task 4: every sentence comparing two branches puts on screen (`CompareWording`) — the bar,
/// the list's rows and groups, the changes header with its merge-base wording, the "moved since
/// this comparison" line, the refusals and the Compare Branches… sheet — for every state the
/// spec names: no shared history, criss-cross merges, 0/0, one side 0, more than 500, moved and
/// deleted. Pure: no store, no git.
@Suite struct CompareWordingTests {
    static let idA = "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d"
    static let idB = "5d6e7f8091a2b3c4d5e6f708192a3b4c5d6e7f80"
    static let base1 = "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432"
    static let base2 = "8e7d6c5b4a39281706f5e4d3c2b1a09876543210"

    static func commit(_ n: Int) -> Commit {
        Commit(
            sha: String(format: "%040x", n), parents: [], authorName: "A", authorEmail: "a@x",
            authorDate: Date(timeIntervalSince1970: 0), summary: "c\(n)", refs: [])
    }

    static func comparison(
        a: String = "refs/heads/main", b: String = "refs/heads/feature", idA: String = idA, idB: String = idB,
        onlyA: Int = 2, onlyB: Int = 3, bases: [String] = [base1]
    ) -> Comparison {
        Comparison(
            a: RefTip(ref: a, id: idA), b: RefTip(ref: b, id: idB), onlyA: onlyA, onlyB: onlyB,
            commitsOnlyA: (0..<min(onlyA, Comparison.listLimit)).map(commit),
            commitsOnlyB: (0..<min(onlyB, Comparison.listLimit)).map { commit(1000 + $0) },
            mergeBases: bases)
    }

    static func branch(_ name: String, _ sha: String) -> Branch {
        Branch(name: name, sha: sha, isHead: false, upstream: nil)
    }

    // MARK: - Names

    @Test func aRefIsNamedWithoutItsNamespace() {
        #expect(CompareWording.name("refs/heads/main") == "main")
        #expect(CompareWording.name("refs/heads/feature/login") == "feature/login")
        #expect(CompareWording.name("refs/remotes/origin/main") == "origin/main")
        #expect(CompareWording.quoted("refs/remotes/origin/main") == "\"origin/main\"")
    }

    /// A branch name is somebody else's text: a bidi override cannot rearrange the bar.
    @Test func aNameIsMadePlain() {
        #expect(!CompareWording.name("refs/heads/evil\u{202E}txt").contains("\u{202E}"))
    }

    // MARK: - The bar

    @Test func theBar() {
        let c = Self.comparison()
        #expect(CompareWording.barTitle(c) == "main ⇄ feature")
        #expect(
            CompareWording.barHelp(c)
                == "Comparing main (1a2b3c4) with feature (5d6e7f8): the commits only on each side, and the changes feature brings.")
        #expect(CompareWording.swapTitle == "Swap")
        #expect(CompareWording.swapHelp(c) == "Compare the other way round: the changes main brings to feature.")
        #expect(CompareWording.doneTitle == "Done")
        #expect(CompareWording.doneHelp == "Leave the comparison and go back to the history (Esc).")
        #expect(CompareWording.refreshTitle == "Refresh")
        #expect(CompareWording.refreshHelp == "Compare the two branches again, as they are now.")
    }

    @Test func aRemoteBranchWithItsLocalOne() {
        let c = Self.comparison(a: "refs/heads/main", b: "refs/remotes/origin/main")
        #expect(CompareWording.barTitle(c) == "main ⇄ origin/main")
        #expect(CompareWording.changesRow(c, fileCount: 1) == "Changes origin/main brings (1 file)")
    }

    // MARK: - The list

    @Test func theChangesRowCountsTheFiles() {
        let c = Self.comparison()
        #expect(CompareWording.changesRow(c, fileCount: 3) == "Changes feature brings (3 files)")
        #expect(CompareWording.changesRow(c, fileCount: 1) == "Changes feature brings (1 file)")
        #expect(CompareWording.changesRow(c, fileCount: 0) == "Changes feature brings (no files)")
        // Not read yet, or the read failed: no number rather than a wrong one.
        #expect(CompareWording.changesRow(c, fileCount: nil) == "Changes feature brings")
    }

    /// No merge base: no changes row (the files and diff would refuse), a line in its place.
    @Test func noSharedHistoryHasNoChangesRow() {
        let c = Self.comparison(bases: [])
        #expect(CompareWording.changesRow(c, fileCount: nil) == nil)
        #expect(CompareWording.noHistoryRow(c) == "No changes to show: main and feature share no history")
    }

    @Test func theGroups() {
        #expect(CompareWording.onlyOn("refs/heads/feature", count: 3) == "Only on feature (3)")
        #expect(CompareWording.onlyOn("refs/remotes/origin/main", count: 0) == "Only on origin/main (0)")
        #expect(CompareWording.noCommits == "None")
    }

    /// Past 500 the counts are exact and the lists are not: the rest is said, never negative.
    @Test func moreThanFiveHundred() {
        let c = Self.comparison(onlyA: 0, onlyB: 520)
        #expect(c.commitsOnlyB.count == 500)
        #expect(CompareWording.onlyOn(c.b.ref, count: c.onlyB) == "Only on feature (520)")
        #expect(CompareWording.notListed(total: c.onlyB, listed: c.commitsOnlyB.count) == "…and 20 more not listed")
        #expect(CompareWording.notListed(total: 1, listed: 1) == nil)
        #expect(CompareWording.notListed(total: 0, listed: 0) == nil)
        #expect(CompareWording.notListed(total: 3, listed: 5) == nil)
    }

    @Test func copyCommitIDIsTheOnlyRowItem() {
        #expect(CompareWording.copyCommitIDTitle == "Copy Commit ID")
    }

    // MARK: - The changes header

    @Test func oneMergeBase() {
        let c = Self.comparison()
        #expect(CompareWording.headerTitle(c) == "Changes feature brings")
        #expect(
            CompareWording.baseLine(c)
                == "From their merge base 9f8e7d6 to feature at 5d6e7f8, as git diff main...feature shows.")
        #expect(CompareWording.countsLine(c) == "feature has 3 commits main lacks; main has 2 feature lacks.")
        #expect(CompareWording.filesLine(c, fileCount: 4) == nil)
    }

    @Test func noSharedHistory() {
        let c = Self.comparison(bases: [])
        #expect(CompareWording.baseLine(c) == "main and feature share no history, so there are no changes to show.")
        #expect(CompareWording.noHistoryTitle == "No Shared History")
    }

    @Test func crissCrossMerges() {
        let c = Self.comparison(bases: [Self.base1, Self.base2])
        #expect(
            CompareWording.baseLine(c)
                == "2 merge bases — showing the first, as git diff does: from 9f8e7d6 to feature at 5d6e7f8.")
        #expect(CompareWording.baseLine(c).contains("2 merge bases — showing the first, as git diff does"))
    }

    @Test func theSameCommit() {
        let c = Self.comparison(idB: Self.idA, onlyA: 0, onlyB: 0, bases: [Self.idA])
        #expect(CompareWording.countsLine(c) == "main and feature are at the same commit.")
        #expect(CompareWording.changesRow(c, fileCount: 0) == "Changes feature brings (no files)")
        #expect(CompareWording.filesLine(c, fileCount: 0) == nil)
        #expect(CompareWording.noChangesTitle == "No Changes")
    }

    /// B is behind: an ancestor of A brings nothing.
    @Test func bHasNothingOfItsOwn() {
        let c = Self.comparison(onlyA: 4, onlyB: 0, bases: [Self.idB])
        #expect(CompareWording.countsLine(c) == "feature has no commits main lacks, so it brings no changes.")
    }

    /// A is behind: everything B has is new to A.
    @Test func aHasNothingOfItsOwn() {
        let c = Self.comparison(onlyA: 0, onlyB: 1, bases: [Self.idA])
        #expect(CompareWording.countsLine(c) == "feature has 1 commit main lacks; main has none feature lacks.")
    }

    @Test func singularCounts() {
        let c = Self.comparison(onlyA: 1, onlyB: 1)
        #expect(CompareWording.countsLine(c) == "feature has 1 commit main lacks; main has 1 feature lacks.")
    }

    /// A revert pair: commits on B, and nothing in all (R9).
    @Test func commitsThatCancelOut() {
        let c = Self.comparison(onlyA: 0, onlyB: 2)
        #expect(
            CompareWording.filesLine(c, fileCount: 0)
                == "Together its commits change no files: they are empty, or what they do cancels out, as a change and its revert do.")
        #expect(CompareWording.filesLine(c, fileCount: nil) == nil)
    }

    // MARK: - After a refresh

    @Test func currentWhenBothTipsAreWhereTheyWere() {
        let c = Self.comparison()
        let refs = RefCollection(
            localBranches: [Self.branch("main", Self.idA), Self.branch("feature", Self.idB)], remoteBranches: [],
            tags: [])
        let s = CompareWording.staleness(c, refs: refs)
        #expect(s.moved.isEmpty)
        #expect(s.deleted.isEmpty)
        #expect(s.isCurrent)
        #expect(CompareWording.staleLine(s) == nil)
        #expect(s.offersSwap)
        #expect(!s.offersRefresh)
    }

    @Test func movedSinceThisComparison() {
        let c = Self.comparison()
        let refs = RefCollection(
            localBranches: [Self.branch("main", Self.idA), Self.branch("feature", Self.base1)], remoteBranches: [],
            tags: [])
        let s = CompareWording.staleness(c, refs: refs)
        #expect(s.moved == ["refs/heads/feature"])
        #expect(s.deleted.isEmpty)
        #expect(CompareWording.staleLine(s) == "feature has moved since this comparison.")
        #expect(s.offersRefresh)
        #expect(s.offersSwap)
    }

    @Test func bothMoved() {
        let c = Self.comparison(a: "refs/heads/main", b: "refs/remotes/origin/main")
        let refs = RefCollection(
            localBranches: [Self.branch("main", Self.base1)], remoteBranches: [Self.branch("origin/main", Self.base2)],
            tags: [])
        let s = CompareWording.staleness(c, refs: refs)
        #expect(s.moved == ["refs/heads/main", "refs/remotes/origin/main"])
        #expect(CompareWording.staleLine(s) == "main and origin/main have moved since this comparison.")
    }

    /// A remote branch is found among the remote branches, not a local branch of the same name.
    @Test func aRemoteRefIsLookedUpAsRemote() {
        let c = Self.comparison(a: "refs/heads/main", b: "refs/remotes/origin/main")
        let refs = RefCollection(
            localBranches: [Self.branch("main", Self.idA), Self.branch("origin/main", Self.idB)], remoteBranches: [],
            tags: [])
        let s = CompareWording.staleness(c, refs: refs)
        #expect(s.deleted == ["refs/remotes/origin/main"])
    }

    /// A deleted branch: nothing to refresh or swap to — only Done.
    @Test func deletedSinceThisComparison() {
        let c = Self.comparison()
        let refs = RefCollection(localBranches: [Self.branch("main", Self.base1)], remoteBranches: [], tags: [])
        let s = CompareWording.staleness(c, refs: refs)
        #expect(s.moved == ["refs/heads/main", "refs/heads/feature"])
        #expect(s.deleted == ["refs/heads/feature"])
        #expect(CompareWording.staleLine(s) == "feature has been deleted since this comparison.")
        #expect(!s.offersRefresh)
        #expect(!s.offersSwap)

        let none = CompareWording.staleness(c, refs: .empty)
        #expect(CompareWording.staleLine(none) == "main and feature have been deleted since this comparison.")
    }

    // MARK: - Refusals

    @Test func theRefusals() {
        #expect(
            CompareWording.failure(CompareRefusal.notABranch("refs/tags/v1"))
                == "\"refs/tags/v1\" is not a branch, so it cannot be compared.")
        #expect(
            CompareWording.failure(CompareRefusal.missing("refs/heads/gone"))
                == "gone no longer exists, so the comparison could not be read.")
        #expect(CompareWording.failure(CompareRefusal.sameRef) == "Choose two different branches to compare.")
        #expect(
            CompareWording.failure(CompareRefusal.noMergeBase)
                == "These branches share no history, so there are no changes to show.")
        // Cannot happen through a `Comparison`; still worded as the unexpected failure it is.
        #expect(
            CompareWording.failure(BranchOperationError.invalidName("abc"))
                == "Gitter could not read the changes: an id it read was not a full commit id. Nothing was changed.")
        #expect(CompareWording.failure(GitError.launchFailed("/usr/bin/git")) == nil)
    }

    // MARK: - The Compare Branches… sheet

    @Test func theSheet() {
        #expect(CompareWording.sheetTitle == "Compare Branches")
        #expect(
            CompareWording.sheetExplanation
                == "See the commits only on each branch and the changes the second brings — what git diff A...B shows. Nothing is changed.")
        #expect(CompareWording.firstLabel == "Branch A")
        #expect(CompareWording.secondLabel == "Branch B — the changes it brings")
        #expect(CompareWording.compareButton == "Compare")
        #expect(CompareWording.chosen(nil) == "Nothing chosen")
        #expect(CompareWording.chosen("refs/remotes/origin/main") == "Chosen: origin/main")
        #expect(CompareWording.sheetBlocked(a: nil, b: "refs/heads/x") == "Choose a branch on each side.")
        #expect(CompareWording.sheetBlocked(a: "refs/heads/x", b: nil) == "Choose a branch on each side.")
        #expect(CompareWording.sheetBlocked(a: "refs/heads/x", b: "refs/heads/x") == "Choose two different branches.")
        #expect(CompareWording.sheetBlocked(a: "refs/heads/x", b: "refs/remotes/origin/x") == nil)
    }

    /// Full refs, local first; a query narrows them as the sidebar's filter does.
    @Test func thePickersOptions() {
        let refs = RefCollection(
            localBranches: [Self.branch("main", Self.idA), Self.branch("Café-menu", Self.idB)],
            remoteBranches: [Self.branch("origin/main", Self.idA), Self.branch("origin/login", Self.idB)], tags: [])
        #expect(
            CompareWording.pickerOptions(refs, query: "")
                == ["refs/heads/main", "refs/heads/Café-menu", "refs/remotes/origin/main", "refs/remotes/origin/login"])
        #expect(CompareWording.pickerOptions(refs, query: "main") == ["refs/heads/main", "refs/remotes/origin/main"])
        #expect(CompareWording.pickerOptions(refs, query: "cafe") == ["refs/heads/Café-menu"])
        #expect(CompareWording.pickerOptions(refs, query: "origin/ log") == ["refs/remotes/origin/login"])
        #expect(CompareWording.pickerOptions(refs, query: "zzz").isEmpty)
    }
}
