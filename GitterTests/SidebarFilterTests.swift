import GitCore
import Testing

@testable import Gitter

/// B3 Task 3: the sidebar's filter. `SidebarFilter.matches` is the whole rule — case- and
/// diacritic-insensitive substring matching where every whitespace-separated word must match, and
/// a remote branch also matches as `<remote>/<name>` — and `SidebarFilter.rows` is what the
/// sidebar draws from it: which rows, which groups, "No matches", the count VoiceOver reads.
/// Pure: no store, no git.
@Suite struct SidebarFilterTests {
    static let sha = "1111111111111111111111111111111111111111"

    static func local(_ name: String) -> Branch {
        Branch(name: name, sha: sha, isHead: false, upstream: nil)
    }

    static func remoteBranch(_ name: String) -> Branch {
        Branch(name: name, sha: sha, isHead: false, upstream: nil)
    }

    static func tag(_ name: String) -> GitCore.Tag {
        GitCore.Tag(name: name, sha: sha, isAnnotated: false)
    }

    static let origin = Remote(name: "origin", fetchURL: "/srv/o.git", pushURL: "/srv/o.git")
    static let fork = Remote(name: "fork", fetchURL: "/srv/f.git", pushURL: "/srv/f.git")
    static let empty = Remote(name: "empty", fetchURL: "/srv/e.git", pushURL: "/srv/e.git")

    static let refs = RefCollection(
        localBranches: [local("main"), local("feature/login"), local("Café-menu"), local("fix-ünïcode")],
        remoteBranches: [
            remoteBranch("origin/main"), remoteBranch("origin/feature/login"), remoteBranch("fork/experiment"),
            remoteBranch("stray/leftover"),
        ],
        tags: [tag("v1.0"), tag("release-2026")],
        remotes: [origin, fork, empty])

    // MARK: - matches

    @Test(arguments: ["", " ", "   ", "\t", "\n", " \t\n "])
    func anEmptyOrBlankQueryMatchesEverything(_ query: String) {
        #expect(SidebarFilter.matches("main", remote: nil, query: query))
        #expect(SidebarFilter.matches("feature/login", remote: "origin", query: query))
        #expect(!SidebarFilter.isFiltering(query))
    }

    @Test func aWordMatchesAnywhereInTheName() {
        #expect(SidebarFilter.matches("feature/login", remote: nil, query: "log"))
        #expect(SidebarFilter.matches("feature/login", remote: nil, query: "feature/l"))
        #expect(!SidebarFilter.matches("feature/login", remote: nil, query: "logout"))
        #expect(SidebarFilter.isFiltering("log"))
    }

    /// Every word must match — anywhere and in any order — and the blanks between them do not
    /// count, however many and of whatever kind.
    @Test func everyWordMustMatch() {
        #expect(SidebarFilter.matches("feature/login", remote: nil, query: "login feat"))
        #expect(SidebarFilter.matches("feature/login", remote: nil, query: "  feat \t login  "))
        #expect(!SidebarFilter.matches("feature/login", remote: nil, query: "feat main"))
    }

    @Test func caseIsIgnored() {
        #expect(SidebarFilter.matches("Feature/Login", remote: nil, query: "feature LOGIN"))
        #expect(SidebarFilter.matches("main", remote: nil, query: "MAIN"))
    }

    @Test func diacriticsAreIgnoredBothWays() {
        #expect(SidebarFilter.matches("Café-menu", remote: nil, query: "cafe"))
        #expect(SidebarFilter.matches("cafe-menu", remote: nil, query: "Café"))
        #expect(SidebarFilter.matches("fix-ünïcode", remote: nil, query: "UNICODE"))
    }

    @Test func nonASCIINamesMatch() {
        #expect(SidebarFilter.matches("исправление-ошибки", remote: nil, query: "ОШИБ"))
        #expect(SidebarFilter.matches("機能-ログイン", remote: nil, query: "ログ"))
        #expect(SidebarFilter.matches("emoji-🚀-launch", remote: nil, query: "🚀"))
        #expect(!SidebarFilter.matches("機能-ログイン", remote: nil, query: "ログアウト"))
    }

    /// A remote branch is `<remote>/<name>` as well as `<name>`: the remote's name, a slash and
    /// part of the branch's name match, and so does the remote's name alone.
    @Test func aRemoteBranchAlsoMatchesWithItsRemotesPrefix() {
        #expect(SidebarFilter.matches("feature/login", remote: "origin", query: "origin/feat"))
        #expect(SidebarFilter.matches("feature/login", remote: "origin", query: "origin login"))
        #expect(SidebarFilter.matches("feature/login", remote: "origin", query: "ORIGIN"))
        #expect(!SidebarFilter.matches("feature/login", remote: "origin", query: "fork/feat"))
        // A local branch has no prefix to match.
        #expect(!SidebarFilter.matches("feature/login", remote: nil, query: "origin/feat"))
    }

    // MARK: - rows

    @Test func notFilteringShowsEverythingAsBefore() {
        let rows = SidebarFilter.rows(Self.refs, deletedTags: [], query: " ")
        #expect(!rows.isFiltering)
        #expect(rows.localBranches.map(\.name) == Self.refs.localBranches.map(\.name))
        // Every configured remote keeps its group, the empty one too.
        #expect(rows.remoteGroups.map(\.remote.name) == ["origin", "fork", "empty"])
        #expect(rows.remoteGroups.first?.branches.map(\.name) == ["origin/main", "origin/feature/login"])
        #expect(rows.otherBranches.map(\.name) == ["stray/leftover"])
        #expect(rows.tags.map(\.name) == ["v1.0", "release-2026"])
    }

    /// A remote group shows only with a match; a section with none says "No matches".
    @Test func filteringNarrowsEverySectionButKeepsThem() {
        let rows = SidebarFilter.rows(Self.refs, deletedTags: [], query: "login")
        #expect(rows.isFiltering)
        #expect(rows.localBranches.map(\.name) == ["feature/login"])
        #expect(rows.remoteGroups.map(\.remote.name) == ["origin"])
        #expect(rows.remoteGroups.first?.branches.map(\.name) == ["origin/feature/login"])
        #expect(rows.otherBranches.isEmpty)
        #expect(rows.tags.isEmpty)
        #expect(rows.showsBranches && rows.showsRemotes && rows.showsTags)
        #expect(!rows.branchesHaveNoMatches)
        #expect(!rows.remotesHaveNoMatches)
        #expect(rows.tagsHaveNoMatches)
        #expect(rows.matchCount == 2)
    }

    @Test func theRemotesNameFindsItsBranchesAndOnlyThem() {
        let rows = SidebarFilter.rows(Self.refs, deletedTags: [], query: "fork/")
        #expect(rows.localBranches.isEmpty)
        #expect(rows.branchesHaveNoMatches)
        #expect(rows.remoteGroups.map(\.remote.name) == ["fork"])
        #expect(rows.remoteGroups.first?.branches.map(\.name) == ["fork/experiment"])
        #expect(rows.matchCount == 1)
    }

    /// A ref no configured remote claims is matched by its whole name.
    @Test func theOtherGroupMatchesByItsWholeName() {
        let rows = SidebarFilter.rows(Self.refs, deletedTags: [], query: "stray/left")
        #expect(rows.otherBranches.map(\.name) == ["stray/leftover"])
        #expect(rows.remoteGroups.isEmpty)
        #expect(!rows.remotesHaveNoMatches)
    }

    @Test func tagsAndDeletedTagsAreFiltered() {
        let receipt = TagReceipt(name: "v0.9-old", objectID: Self.sha, target: Self.sha)
        let other = TagReceipt(name: "nightly", objectID: Self.sha, target: Self.sha)
        let rows = SidebarFilter.rows(Self.refs, deletedTags: [receipt, other], query: "V")
        #expect(rows.tags.map(\.name) == ["v1.0"])
        #expect(rows.deletedTags == [receipt])
        let none = SidebarFilter.rows(Self.refs, deletedTags: [receipt], query: "zzz")
        #expect(none.tagsHaveNoMatches && none.branchesHaveNoMatches && none.remotesHaveNoMatches)
        #expect(none.matchCount == 0)
    }

    /// A section that has nothing to filter is not drawn at all, as before.
    @Test func aSectionWithNothingInItStaysHidden() {
        let bare = RefCollection(localBranches: [Self.local("main")], remoteBranches: [], tags: [], remotes: [])
        let rows = SidebarFilter.rows(bare, deletedTags: [], query: "x")
        #expect(rows.showsBranches)
        #expect(!rows.showsRemotes)
        #expect(!rows.showsTags)
        #expect(!rows.remotesHaveNoMatches && !rows.tagsHaveNoMatches)
    }

    // MARK: - expansion, wording

    /// Expanded while filtering whatever the user left it as; their choice is what shows again
    /// once the filter is cleared — it was never written over.
    @Test func aRemoteGroupIsExpandedWhileFiltering() {
        #expect(SidebarFilter.isExpanded(stored: false, query: "log"))
        #expect(SidebarFilter.isExpanded(stored: true, query: "log"))
        #expect(!SidebarFilter.isExpanded(stored: false, query: ""))
        #expect(SidebarFilter.isExpanded(stored: true, query: "  "))
    }

    @Test func theWordsVoiceOverAndTheEmptySectionSay() {
        #expect(SidebarFilter.noMatches == "No matches")
        #expect(SidebarFilter.prompt == "Filter")
        #expect(SidebarFilter.announcement(matches: 0) == "No matches")
        #expect(SidebarFilter.announcement(matches: 1) == "1 match")
        #expect(SidebarFilter.announcement(matches: 12) == "12 matches")
    }
}
