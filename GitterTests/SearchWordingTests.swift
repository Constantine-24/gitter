import Foundation
import GitCore
import Testing

@testable import Gitter

/// F1 Task 2: every sentence commit search puts on screen (`SearchWording`) — the menu item, the
/// modes' names and prompts, the status line for each state, the out-of-date line, the row menu's
/// item and the close button — pinned to the spec's copy. Pure: no store, no git.
@Suite struct SearchWordingTests {

    static func commit(_ n: Int) -> Commit {
        Commit(
            sha: String(format: "%040x", n), parents: [], authorName: "A", authorEmail: "a@x",
            authorDate: Date(timeIntervalSince1970: 0), summary: "c\(n)", refs: [])
    }

    /// A state in `status`, reached the way the store reaches it (its transitions); `.idle` has
    /// an empty field, every other status the query "fix".
    static func state(
        _ status: SearchStatus, mode: CommitSearchMode = .messageAuthorOrID, commits: Int = 0, isCut: Bool = false,
        isStale: Bool = false
    ) -> CommitSearchState {
        var state = CommitSearchState()
        state.edit(mode: mode)
        guard status != .idle else { return state }
        state.edit(query: "fix")
        state.begin()
        switch status {
        case .done:
            let search = CommitSearch(mode: mode, query: "fix")
            state.land(CommitSearchResult(search: search, commits: (0..<commits).map(commit), isCut: isCut))
        case .stopped: _ = state.stop()
        case .failed(let words): state.fail(words)
        case .idle, .searching: break
        }
        if isStale { state.markStale() }
        #expect(state.status == status)
        return state
    }

    @Test func theMenuTheBarAndTheButtons() {
        #expect(SearchWording.menuTitle == "Find Commits…")
        #expect(SearchWording.barAccessibility == "Find Commits")
        #expect(SearchWording.closeSearch == "Close Search")
        #expect(SearchWording.modeAccessibility == "Search Mode")
        #expect(SearchWording.stop == "Stop")
        #expect(SearchWording.searchAgain == "Search Again")
        #expect(SearchWording.showInHistory == "Show in History")
    }

    @Test func everyModeHasItsNameAndPrompt() {
        #expect(CommitSearchMode.allCases.map(SearchWording.name) == ["Message, Author or ID", "File", "Code"])
        #expect(
            CommitSearchMode.allCases.map(SearchWording.prompt) == ["Message, author or ID", "File path or name", "Code text"])
    }

    /// Grouped in every locale the test host may run in: the count is English copy.
    @Test func countsAreGrouped() {
        #expect(SearchWording.count(0) == "0 commits")
        #expect(SearchWording.count(1) == "1 commit")
        #expect(SearchWording.count(2) == "2 commits")
        #expect(SearchWording.count(999) == "999 commits")
        #expect(SearchWording.count(1000) == "1,000 commits")
        #expect(SearchWording.count(12345) == "12,345 commits")
    }

    @Test func theStatusLineForEachState() {
        #expect(SearchWording.statusLine(Self.state(.idle)) == nil)
        #expect(SearchWording.statusLine(Self.state(.searching)) == "Searching…")
        #expect(SearchWording.statusLine(Self.state(.stopped)) == "Search stopped")
        #expect(SearchWording.statusLine(Self.state(.failed("fatal: bad revision"))) == "fatal: bad revision")
        #expect(SearchWording.statusLine(Self.state(.done, commits: 0)) == "No commits match")
        #expect(SearchWording.statusLine(Self.state(.done, commits: 1)) == "1 commit")
        #expect(SearchWording.statusLine(Self.state(.done, commits: 12)) == "12 commits")
    }

    /// A cut result says so instead of its count.
    @Test func aCutResultSaysItIsCut() {
        #expect(SearchWording.cut == "Showing the newest 50,000 matches")
        #expect(SearchWording.statusLine(Self.state(.done, commits: 3, isCut: true)) == "Showing the newest 50,000 matches")
    }

    /// Searching keeps the old rows (`result`), but the line says what is happening now.
    @Test func searchingOverOldRowsSaysSearching() {
        var state = Self.state(.done, commits: 2)
        state.begin()
        #expect(state.result != nil)
        #expect(SearchWording.statusLine(state) == "Searching…")
    }

    /// The out-of-date line: only while the search is stale.
    @Test func theStaleLine() {
        #expect(SearchWording.stale == "History has changed since this search")
        #expect(SearchWording.staleLine(Self.state(.done, mode: .code, commits: 2, isStale: true)) == SearchWording.stale)
        #expect(SearchWording.staleLine(Self.state(.done, mode: .code, commits: 2)) == nil)
    }

    /// A failure is drawn in the error style, whole; VoiceOver says what it is first. A partial
    /// clone's missing contents are worded (Ruling P20), not git's lazy-fetch lines.
    @Test func failures() {
        #expect(SearchWording.failedAccessibility("fatal: x") == "Search failed: fatal: x")
        #expect(
            SearchWording.failure(.contentsNotDownloaded(gitsWords: "fatal: could not fetch"))
                == "This repository is a partial clone that hasn't downloaded the contents this search needs, "
                + "and searching never downloads anything.")
    }

    /// The state keeps its fields coherent (final review): a failure or Stop clears "out of date",
    /// out of date is for Code only, a result lands only for the search the bar asks for, and Stop
    /// acts only on a search that runs.
    @Test func theStateKeepsItselfCoherent() {
        var stale = Self.state(.searching, mode: .code, isStale: true)
        #expect(stale.isStale)
        stale.fail("fatal: x")
        #expect(!stale.isStale && stale.result == nil)
        #expect(SearchWording.staleLine(stale) == nil)

        var stopped = Self.state(.searching, mode: .code, isStale: true)
        let didStop = stopped.stop()
        #expect(didStop)
        #expect(!stopped.isStale && stopped.status == .stopped)

        var landed = Self.state(.done, commits: 2)
        let stoppedLanded = landed.stop()
        #expect(!stoppedLanded, "a landed search is not stopped")
        #expect(landed.status == .done && landed.result?.commits.count == 2)
        landed.markStale()
        #expect(!landed.isStale, "out of date is Code's only")

        var other = Self.state(.searching)
        other.land(CommitSearchResult(search: CommitSearch(mode: .messageAuthorOrID, query: "else"), commits: [], isCut: false))
        #expect(other.status == .searching && other.result == nil, "another search's result does not land")
    }

    @Test func theBlockedReasons() {
        #expect(SearchWording.noRepository == RemoteWording.noRepository)
        #expect(SearchWording.blockedBySheet == StashWording.blockedBySheet)
        #expect(SearchWording.blockedInFocusMode == "Leave Resolve Conflicts first.")
    }
}
