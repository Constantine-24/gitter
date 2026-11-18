import Foundation
import GitCore
import Testing

@testable import Gitter

/// N1 Task 2: the sidebar's layout without views — Recent, prefix folders and the stash limit.
@Suite struct SidebarLayoutTests {
    static let sha = "1111111111111111111111111111111111111111"

    static func branch(_ name: String, head: Bool = false) -> Branch {
        Branch(name: name, sha: sha, isHead: head, upstream: nil)
    }

    static func date(_ n: Int) -> Date { Date(timeIntervalSince1970: TimeInterval(1_700_000_000 + n)) }

    static func stash(_ index: Int, sha: String? = nil) -> Stash {
        Stash(sha: sha ?? String(format: "%040x", index + 1), index: index,
              reflogSubject: "On main: s\(index)", parents: [], date: date(-index))
    }

    static func names(_ branches: [Branch]) -> [String] { branches.map(\.name) }

    // MARK: - recent

    @Test func currentBranchComesFirstEvenWithoutSwitches() {
        let local = [Self.branch("a"), Self.branch("main", head: true), Self.branch("b")]
        let recent = SidebarLayout.recent(local, activity: .none)
        #expect(Self.names(recent).first == "main")
    }

    @Test func switchTargetsFollowNewestFirst() {
        let local = [Self.branch("main", head: true), Self.branch("a"), Self.branch("b"), Self.branch("c")]
        let activity = BranchActivity(switchTargets: ["c", "a", "c", "b"], tipDates: [:])
        #expect(Self.names(SidebarLayout.recent(local, activity: activity)) == ["main", "c", "a", "b"])
    }

    @Test func aGoneOrRenamedTargetIsSkipped() {
        let local = [Self.branch("main", head: true), Self.branch("renamed")]
        let activity = BranchActivity(switchTargets: ["old-name", "main"], tipDates: ["renamed": Self.date(5), "main": Self.date(1)])
        let names = Self.names(SidebarLayout.recent(local, activity: activity))
        #expect(names == ["main", "renamed"])
        #expect(!names.contains("old-name"))
    }

    @Test func freeSlotsFillByTipDateThenName() {
        let local = [Self.branch("main", head: true), Self.branch("b"), Self.branch("A"), Self.branch("c"), Self.branch("d")]
        let activity = BranchActivity(switchTargets: [], tipDates: [
            "b": Self.date(5), "A": Self.date(5), "c": Self.date(9), "d": Self.date(1), "main": Self.date(100),
        ])
        #expect(Self.names(SidebarLayout.recent(local, activity: activity)) == ["main", "c", "A", "b", "d"])
    }

    @Test func neverMoreThanFive() {
        let local = (0..<12).map { Self.branch("b\($0)", head: $0 == 0) }
        let activity = BranchActivity(switchTargets: (0..<12).map { "b\($0)" }, tipDates: [:])
        #expect(SidebarLayout.recent(local, activity: activity).count == 5)
        #expect(SidebarLayout.recent(local, activity: .none).count == 5)
    }

    @Test func detachedHeadStartsWithTheLatestSwitch() {
        let local = [Self.branch("main"), Self.branch("fix/b"), Self.branch("other")]
        let activity = BranchActivity(switchTargets: ["HEAD~0", "fix/b", "main"], tipDates: [:])
        let names = Self.names(SidebarLayout.recent(local, activity: activity))
        #expect(Array(names.prefix(2)) == ["fix/b", "main"])
    }

    @Test func aSmallRepositoryListsEveryBranch() {
        let local = [Self.branch("main", head: true), Self.branch("a"), Self.branch("b")]
        #expect(SidebarLayout.recent(local, activity: .none).count == 3)
    }

    @Test func noLocalBranchGivesNoRecent() {
        #expect(SidebarLayout.recent([], activity: BranchActivity(switchTargets: ["x"], tipDates: [:])).isEmpty)
    }

    // MARK: - tree

    @Test func sharedPrefixesBecomeFolders() {
        let local = ["feature/a", "feature/b", "fix/c", "main"].map { Self.branch($0) }
        let tree = SidebarLayout.tree(local)
        #expect(tree.folders.map(\.prefix) == ["feature"])
        #expect(Self.names(tree.folders[0].branches) == ["feature/a", "feature/b"])
        #expect(Self.names(tree.plain) == ["fix/c", "main"])
    }

    @Test func nestedNamesUseTheFirstSegment() {
        let tree = SidebarLayout.tree([Self.branch("feature/ui/x"), Self.branch("feature/y")])
        #expect(tree.folders.map(\.prefix) == ["feature"])
        #expect(tree.plain.isEmpty)
        #expect(SidebarLayout.leafName("feature/ui/x", in: "feature") == "ui/x")
        #expect(SidebarLayout.leafName("feature/y", in: "feature") == "y")
    }

    @Test func prefixesDifferingInCaseAreSeparate() {
        let tree = SidebarLayout.tree(["Feature/a", "feature/b", "feature/c"].map { Self.branch($0) })
        #expect(tree.folders.map(\.prefix) == ["feature"])
        #expect(tree.folders[0].branches.count == 2)
        #expect(Self.names(tree.plain) == ["Feature/a"])
    }

    @Test func foldersSortCaseInsensitively() {
        let tree = SidebarLayout.tree(["zeta/a", "zeta/b", "Alpha/a", "Alpha/b", "beta/a", "beta/b"].map { Self.branch($0) })
        #expect(tree.folders.map(\.prefix) == ["Alpha", "beta", "zeta"])
    }

    // MARK: - stashes

    @Test func fiveOrFewerHaveNothingHidden() {
        let all = (0..<5).map { Self.stash($0) }
        let result = SidebarLayout.stashes(all, showAll: false, selected: nil)
        #expect(result.rows == all)
        #expect(result.hidden == 0)
    }

    @Test func moreThanFiveShowTheNewestFive() {
        let all = (0..<23).map { Self.stash($0) }
        let result = SidebarLayout.stashes(all, showAll: false, selected: nil)
        #expect(result.rows == Array(all.prefix(5)))
        #expect(result.hidden == 18)
    }

    @Test func showAllShowsEverything() {
        let all = (0..<23).map { Self.stash($0) }
        let result = SidebarLayout.stashes(all, showAll: true, selected: nil)
        #expect(result.rows == all)
        #expect(result.hidden == 0)
    }

    @Test func anOlderSelectedStashIsAppended() {
        let all = (0..<23).map { Self.stash($0) }
        let result = SidebarLayout.stashes(all, showAll: false, selected: all[7].sha)
        #expect(result.rows == Array(all.prefix(5)) + [all[7]])
        #expect(result.hidden == 17)
    }

    @Test func aSelectedStashAmongTheNewestIsNotRepeated() {
        let all = (0..<23).map { Self.stash($0) }
        let result = SidebarLayout.stashes(all, showAll: false, selected: all[2].sha)
        #expect(result.rows == Array(all.prefix(5)))
        #expect(result.hidden == 18)
    }

    @Test func anUnknownSelectionChangesNothing() {
        let all = (0..<8).map { Self.stash($0) }
        let result = SidebarLayout.stashes(all, showAll: false, selected: "nope")
        #expect(result.rows.count == 5 && result.hidden == 3)
    }
}
