import Testing

@testable import Gitter

/// N1 Task 2: the sidebar's new sentences, pinned.
@Suite struct SidebarWordingTests {
    @Test func theSectionAndStashWords() {
        #expect(SidebarWording.recent == "Recent")
        #expect(SidebarWording.showAllStashes(23) == "Show All 23 Stashes")
        #expect(SidebarWording.showFewerStashes == "Show Fewer Stashes")
    }

    @Test func everySectionHasItsTitle() {
        #expect(SidebarSection.allCases.map(SidebarWording.title) == ["Recent", "Branches", "Worktrees", "Stashes", "Remotes", "Tags"])
    }

    @Test func aFolderReadsItsBranchCount() {
        #expect(SidebarWording.folderAccessibility("feature", count: 12) == "Branch folder feature, 12 branches")
        #expect(SidebarWording.folderAccessibility("fix", count: 1) == "Branch folder fix, 1 branch")
    }

    @Test func foldedCountsAreNumbersExceptForRecent() {
        #expect(SidebarWording.foldedCount(.recent, count: 5) == nil)
        for section in SidebarSection.allCases where section != .recent {
            #expect(SidebarWording.foldedCount(section, count: 7) == "7")
        }
    }

    @Test func sectionsRoundTripThroughTheirRawValue() {
        #expect(SidebarSection.allCases.map(\.rawValue) == ["recent", "branches", "worktrees", "stashes", "remotes", "tags"])
    }
}
