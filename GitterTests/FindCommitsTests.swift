import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// F1 Task 3: what Find Commits (⌥⌘F) does in each state — open and focus the field with search
/// closed, focus it with a query typed, leave with an empty field — and that it does nothing
/// where the menu item is off.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct FindCommitsTests {

    @Test func closedSearchOpensAndFocuses() async throws {
        let (repo, _, _) = try SearchStoreTests.fixes()
        defer { repo.remove() }
        let (store, cleanup) = await SearchStoreTests.opened(repo, backend: TestBackend())
        defer { cleanup() }
        #expect(store.findCommitsStep == .openAndFocus)
        var focused = 0
        store.findCommits { focused += 1 }
        #expect(store.commitSearch != nil)
        #expect(focused == 1)
    }

    @Test func aQueryKeepsSearchAndFocuses() async throws {
        let (repo, _, _) = try SearchStoreTests.fixes()
        defer { repo.remove() }
        let (store, cleanup) = await SearchStoreTests.opened(repo, backend: TestBackend())
        defer { cleanup() }
        await SearchStoreTests.search(store, "fix")
        #expect(store.findCommitsStep == .focus)
        var focused = 0
        store.findCommits { focused += 1 }
        #expect(store.commitSearch?.query == "fix")
        #expect(focused == 1)
    }

    @Test func anEmptyFieldLeavesSearchWithoutFocusing() async throws {
        let (repo, _, _) = try SearchStoreTests.fixes()
        defer { repo.remove() }
        let (store, cleanup) = await SearchStoreTests.opened(repo, backend: TestBackend())
        defer { cleanup() }
        store.openSearch()
        #expect(store.findCommitsStep == .leave)
        var focused = 0
        store.findCommits { focused += 1 }
        #expect(store.commitSearch == nil)
        #expect(focused == 0)
    }

    @Test func aBlankFieldCountsAsEmpty() async throws {
        let (repo, _, _) = try SearchStoreTests.fixes()
        defer { repo.remove() }
        let (store, cleanup) = await SearchStoreTests.opened(repo, backend: TestBackend())
        defer { cleanup() }
        store.openSearch()
        store.setSearchQuery("   ")
        #expect(store.findCommitsStep == .leave)
    }

    @Test func nothingHappensWhereSearchIsBlocked() async throws {
        let (repo, _, _) = try SearchStoreTests.fixes()
        defer { repo.remove() }
        let (store, cleanup) = await SearchStoreTests.opened(repo, backend: TestBackend())
        defer { cleanup() }
        store.activeSheet = .rename("main")
        #expect(store.searchBlockedReason != nil)
        var focused = 0
        store.findCommits { focused += 1 }
        #expect(store.commitSearch == nil)
        #expect(focused == 0)
    }

    // MARK: - What covers History (Ruling P14)

    @Test func anEmptyOrBlankQueryLeavesHistoryUncovered() async throws {
        let (repo, _, _) = try SearchStoreTests.fixes()
        defer { repo.remove() }
        let (store, cleanup) = await SearchStoreTests.opened(repo, backend: TestBackend())
        defer { cleanup() }
        #expect(!store.historyIsCovered)  // search closed
        store.openSearch()
        #expect(!store.historyIsCovered)
        store.setSearchQuery("   ")
        #expect(!store.historyIsCovered)
    }

    @Test func aQueryCoversHistoryAndClearingItUncovers() async throws {
        let (repo, _, _) = try SearchStoreTests.fixes()
        defer { repo.remove() }
        let (store, cleanup) = await SearchStoreTests.opened(repo, backend: TestBackend())
        defer { cleanup() }
        await SearchStoreTests.search(store, "fix")
        #expect(store.historyIsCovered)
        store.setSearchQuery("")
        #expect(!store.historyIsCovered)
    }

    @Test func aComparisonCoversHistory() async throws {
        let (repo, _, _) = try SearchStoreTests.fixes()
        defer { repo.remove() }
        let (store, cleanup) = await SearchStoreTests.opened(repo, backend: TestBackend())
        defer { cleanup() }
        try repo.git("branch", "other", "HEAD~1")
        await store.refresh()
        store.compare("refs/heads/other", "refs/heads/main")
        await waitUntilIdle(store)
        #expect(store.comparison != nil)
        #expect(store.historyIsCovered)
    }
}
