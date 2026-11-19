import Foundation
import GitCore

/// Where a commit search is: nothing searched yet (an empty field), a search running — over the
/// rows of the one before, if any — landed, stopped, or failed with git's words.
enum SearchStatus: Equatable {
    case idle
    case searching
    case done
    case stopped
    case failed(String)
}

/// The window's commit search (F1): what the bar holds and the rows it shows. Its fields change
/// only through the transitions below, each of which keeps them coherent: rows only for the
/// search the bar asks for, landed or running again (the rows before stay until the new ones
/// land); none after Stop, a failure or with an empty field; and "out of date" only for a Code
/// search that runs or has landed — so a failure or Stop never stands beside it.
struct CommitSearchState: Equatable {
    /// The field's text as typed; the search itself trims it (`CommitSearch`).
    private(set) var query = ""
    private(set) var mode: CommitSearchMode = .messageAuthorOrID
    /// The rows shown: the last search that landed — kept while a new one runs, cleared by Stop,
    /// a failure and an empty field.
    private(set) var result: CommitSearchResult?
    private(set) var status: SearchStatus = .idle
    /// A Code search a ref change has overtaken: its rows stay, with Search Again (Code is not run
    /// again quietly). Cleared when a search starts, fails or is stopped.
    private(set) var isStale = false
    /// The result the user selected in the list during this search, if any: leaving reveals it
    /// while it is still the selection, even once it has left the rows (Ruling P10).
    private(set) var pickedResult: String?
    /// What History's walk started from when the running or landed read began — after the
    /// debounce, so a reload while a search still waits changes nothing. Nil until then.
    private(set) var readTips: SearchedHistoryTips?

    /// What the field and the mode ask for.
    var search: CommitSearch { CommitSearch(mode: mode, query: query) }

    mutating func edit(query: String) { self.query = query }
    mutating func edit(mode: CommitSearchMode) { self.mode = mode }

    /// A search starts (or waits out the debounce) over the rows before.
    mutating func begin() {
        status = .searching
        isStale = false
        readTips = nil
    }

    /// The field is empty: no rows, nothing searched.
    mutating func clear() {
        result = nil
        status = .idle
        isStale = false
        readTips = nil
    }

    /// The running search's read begins on the history `tips` describe.
    mutating func readStarted(on tips: SearchedHistoryTips?) {
        guard status == .searching else { return }
        readTips = tips
    }

    /// The other worktrees' HEADs, read after the read began: what it walked, as near as is known.
    mutating func adoptWorktreeHeads(_ heads: Set<String>) {
        readTips = readTips?.with(worktreeHeads: heads)
    }

    /// `result` lands — only the result of the search the bar asks for. Out of date stays: a
    /// Code search overtaken while it ran lands overtaken.
    mutating func land(_ result: CommitSearchResult) {
        guard result.search == search else { return }
        self.result = result
        status = .done
    }

    mutating func fail(_ words: String) {
        result = nil
        status = .failed(words)
        isStale = false
        readTips = nil
    }

    /// Stop: only a search that runs; its rows go. Whether anything stopped.
    mutating func stop() -> Bool {
        guard status == .searching else { return false }
        result = nil
        status = .stopped
        isStale = false
        readTips = nil
        return true
    }

    /// A Code search, running or landed, that history has overtaken.
    mutating func markStale() {
        guard mode == .code, status == .searching || status == .done else { return }
        isStale = true
    }

    mutating func pick(_ sha: String) { pickedResult = sha }
}

/// What History's and commit search's walk (`log --exclude=refs/stash --all`) starts from, and
/// the decorations its rows show: every ref but `refs/stash` (`RefCollection.walkedRefs`), HEAD's
/// commit and the branch HEAD is on, and the other worktrees' detached HEADs (measured, git 2.54:
/// `--all` walks those too, and no ref moves when one gains a commit). A reload that changes none
/// of these leaves every search's answer as it was (Rulings P11, P21) — unlike `RefCollection`,
/// which also carries what the configuration says (upstreams and their counts, push remotes,
/// worktrees, remote URLs). A worktree on a branch is covered by the branch; adding one on a
/// detached HEAD at a commit no other worktree's HEAD holds counts as a change.
struct SearchedHistoryTips: Equatable {
    let refs: [String: String]
    let head: String?
    let headBranch: String?
    /// Nil until the worktree state has been read: unknown, which no change is measured against.
    let worktreeHeads: Set<String>?

    init(_ snapshot: RepoSnapshot, worktreeHeads: Set<String>?) {
        refs = snapshot.refs.walkedRefs
        head = snapshot.status.headSha
        headBranch = snapshot.refs.localBranches.first(where: \.isHead)?.name
        self.worktreeHeads = worktreeHeads
    }

    private init(refs: [String: String], head: String?, headBranch: String?, worktreeHeads: Set<String>?) {
        self.refs = refs
        self.head = head
        self.headBranch = headBranch
        self.worktreeHeads = worktreeHeads
    }

    func with(worktreeHeads: Set<String>?) -> SearchedHistoryTips {
        SearchedHistoryTips(refs: refs, head: head, headBranch: headBranch, worktreeHeads: worktreeHeads)
    }

    /// Whether the walk now starts from anything other than it did at `recorded`. Worktree HEADs
    /// count only when both sides have read them.
    func hasMoved(since recorded: SearchedHistoryTips) -> Bool {
        if refs != recorded.refs || head != recorded.head || headBranch != recorded.headBranch { return true }
        guard let worktreeHeads, let before = recorded.worktreeHeads else { return false }
        return worktreeHeads != before
    }
}

/// What Find Commits (⌥⌘F) does now (spec, "Where it lives"): with search closed it opens it and
/// puts the keyboard in the field; with a query typed it only focuses the field; with an empty
/// field it leaves search again.
enum FindCommitsStep: Equatable {
    case openAndFocus
    case focus
    case leave
}

/// Commit search (F1): Find Commits opens a bar over the commit list column, and its results take
/// over the History list the way a comparison does — one at a time with it.
///
/// One search runs at a time (`searchTask`): typing waits `searchDebounce`, then reads with
/// `searchCommits`; a new query, a mode change, Stop, leaving, `open()` and `close()` cancel the one
/// before. A search lands only while it is still the one asked for — not cancelled, the same
/// repository (`generation`), the same query and mode. The old rows stay until the new ones land;
/// Stop and a failure clear them.
///
/// A result stands in for a History row: `commitForDetail` and `historyBlockedReason`'s merge check
/// look the commit up among the results, since a result can be older than the loaded rows. Leaving
/// reveals the result the user selected during the search, and any selected commit History hasn't
/// loaded (H1); a selection from before the search, never changed, stays where it was (Ruling P10).
///
/// Read-only: nothing here writes, takes a lock or goes through `mutate` or the network lane.
extension RepositoryStore {

    // MARK: - State

    /// Why Find Commits is off, or nil: with no repository, under a sheet, and in Resolve Conflicts'
    /// focus mode, which holds the window.
    var searchBlockedReason: String? {
        guard root != nil else { return SearchWording.noRepository }
        if activeSheet != nil { return SearchWording.blockedBySheet }
        if resolverFocus != nil { return SearchWording.blockedInFocusMode }
        return nil
    }

    /// Whether something is drawn over History and History is inert: a comparison, or search
    /// results — which exist only once the trimmed query is not empty. With an empty field the
    /// column shows History, live, under the bar (Ruling P14).
    var historyIsCovered: Bool { comparison != nil || showsSearchResults }

    /// Whether search results are drawn over History: search is open with a query.
    var showsSearchResults: Bool { commitSearch.map { !$0.search.isEmpty } ?? false }

    /// What the menu item does in the state search is in.
    var findCommitsStep: FindCommitsStep {
        guard let state = commitSearch else { return .openAndFocus }
        return state.search.isEmpty ? .leave : .focus
    }

    /// The Find Commits menu item. `focusField` puts the keyboard in the bar's field (the window's
    /// view state, so it is handed in). Does nothing where `searchBlockedReason` says it is off.
    func findCommits(focusField: () -> Void) {
        guard searchBlockedReason == nil else { return }
        switch findCommitsStep {
        case .openAndFocus:
            openSearch()
            focusField()
        case .focus:
            focusField()
        case .leave:
            leaveSearch()
        }
    }

    // MARK: - Opening and typing

    /// Find Commits: opens search with an empty field and the default mode, or keeps the one that
    /// is open. A comparison ends — one in flight too — without revealing its selection: History
    /// stays under the search, and leaving the search reveals it.
    func openSearch() {
        guard searchBlockedReason == nil, !isClosed else { return }
        leaveComparison(revealingSelection: false)
        guard commitSearch == nil else { return }
        setCommitSearch(CommitSearchState())
    }

    /// The field's text changed: searches after the debounce. A text that leaves the search the
    /// same (blanks around it) while it runs or has landed runs nothing; an empty one shows no
    /// rows and runs nothing.
    func setSearchQuery(_ query: String) {
        guard var state = commitSearch, state.query != query else { return }
        let before = state.search
        state.edit(query: query)
        setCommitSearch(state)
        searchEdited(from: before)
    }

    /// The mode menu changed: searches the same text again in `mode`, after the debounce.
    func setSearchMode(_ mode: CommitSearchMode) {
        guard var state = commitSearch, state.mode != mode else { return }
        let before = state.search
        state.edit(mode: mode)
        setCommitSearch(state)
        searchEdited(from: before)
    }

    private func searchEdited(from before: CommitSearch) {
        guard let state = commitSearch else { return }
        if state.search == before, state.status == .searching || state.status == .done { return }
        startSearch(debounced: true)
    }

    // MARK: - In search

    /// Stop: the search running is cancelled and its rows go, so the field never stands over
    /// another query's rows; the status line says "Search stopped". Only while a search runs: a
    /// landed one keeps its rows. Search stays open, and editing the query or the mode searches
    /// again.
    func stopSearch() {
        guard var state = commitSearch, state.stop() else { return }
        cancelSearch()
        showRows(state)
    }

    /// Search Again: the same search, now, with no debounce — a stale Code search's button.
    func searchAgain() {
        guard commitSearch != nil else { return }
        startSearch(debounced: false)
    }

    /// A snapshot or the worktrees' state landed: when what History's walk starts from has moved
    /// since the read of a landed or running search began (`readTips`, `SearchedHistoryTips`), a
    /// Message, Author or ID or File search runs again, keeping its rows and the selection until
    /// the new rows land, and a Code search, which can take seconds, is only marked out of date.
    /// A search still waiting out the debounce reads the new history anyway, and a stopped or
    /// failed search and an empty field are left as they are.
    func historyChangedUnderSearch() {
        guard var state = commitSearch, !state.search.isEmpty,
            state.status == .done || state.status == .searching,
            let recorded = state.readTips, let current = searchedHistoryTips
        else { return }
        if recorded.worktreeHeads == nil, let heads = current.worktreeHeads {
            state.adoptWorktreeHeads(heads)
            setCommitSearch(state)
        }
        guard current.hasMoved(since: recorded) else { return }
        if state.mode == .code {
            state.markStale()
            setCommitSearch(state)
        } else {
            startSearch(debounced: false)
        }
    }

    /// What the walk starts from now: the snapshot's refs and HEAD, and the other worktrees'
    /// detached HEADs once their state has been read (an empty list is a read not made or failed).
    var searchedHistoryTips: SearchedHistoryTips? {
        guard let snapshot else { return nil }
        let worktrees = worktreeState.worktrees
        let heads = worktrees.isEmpty ? nil : Set(
            worktrees.filter { $0.branch == nil && $0.path != worktreeState.openPath }.compactMap(\.head))
        return SearchedHistoryTips(snapshot, worktreeHeads: heads)
    }

    /// The results list's selection write (`selectRows`, while the results cover History): a
    /// result now selected is the one the user picked, for leaving (Ruling P10).
    // internal (not private): used by RepositoryStore.swift's `selectRows`
    func notePickedResult() {
        guard var state = commitSearch, case .commit(let sha) = selection,
            state.result?.commits.contains(where: { $0.sha == sha }) == true
        else { return }
        state.pick(sha)
        setCommitSearch(state)
    }

    // MARK: - Leaving

    /// Esc, the close button, Find Commits with an empty field: back to History. The search
    /// running is cancelled. A selected commit stays selected. A result the user selected during
    /// the search is revealed (H1: loaded down to if History hasn't loaded it, and scrolled to), as
    /// Show in History does; so is any selected commit History hasn't loaded (one carried over from
    /// a comparison). A selection from before the search, never changed, is left where it was
    /// (Ruling P10).
    func leaveSearch() {
        endSearch(revealingSelection: true)
    }

    /// A result's Show in History: leaves search and reveals `sha` (H1), past the cap with the
    /// cap's notice, as a sidebar click does.
    func showInHistory(_ sha: String) {
        endSearch(revealingSelection: false)
        reveal(sha)
    }

    /// Ends search, if open, and cancels any search task. `revealingSelection`: whether a selected
    /// commit History hasn't loaded is revealed — not when the caller replaces the selection
    /// itself (a sidebar click, a comparison, Show in History).
    // internal (not private): used by +Compare.swift's `compare` and `selectFromSidebar`
    func endSearch(revealingSelection: Bool) {
        cancelSearch()
        guard let state = commitSearch else { return }
        // Cleared before the reveal, so its detail load reads the commit on its own
        // (`commitForDetail` no longer finds it among the results).
        setCommitSearch(nil)
        guard revealingSelection, case .commit(let sha) = selection else { return }
        let loaded = historyRows.isLoaded(sha)
        if state.pickedResult == sha, loaded {
            // Selected already and in History's rows: only scrolled to. `reveal` would select it
            // again, which blanks the diff being read and reads it again.
            setPendingReveal(sha)
        } else if state.pickedResult == sha || !loaded {
            reveal(sha)
        }
    }

    // MARK: - Running

    /// Starts the search the bar asks for, replacing any running one: after `searchDebounce` when
    /// `debounced`. An empty field runs nothing and shows no rows.
    private func startSearch(debounced: Bool) {
        cancelSearch()
        guard var state = commitSearch, let root, !isClosed else { return }
        let search = state.search
        guard !search.isEmpty else {
            state.clear()
            showRows(state)
            return
        }
        state.begin()
        setCommitSearch(state)
        let capturedGeneration = generation
        let debounce = debounced ? searchDebounce : .zero
        searchTask = Task {
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled, var reading = commitSearch, reading.search == search else { return }
            // The history this read walks: a reload from here on is measured against it.
            reading.readStarted(on: searchedHistoryTips)
            setCommitSearch(reading)
            let outcome: Result<CommitSearchResult, Error>
            do {
                outcome = .success(try await backend.searchCommits(search, limit: CommitSearchLimit.rows, at: root))
            } catch {
                outcome = .failure(error)
            }
            // Cancelled first: a cancelled read's `CancellationError` is never a failure, and a
            // query typed away and back (A, B, A) must not take the first A's rows.
            guard !Task.isCancelled, generation == capturedGeneration, !isClosed, var current = commitSearch,
                current.search == search
            else { return }
            switch outcome {
            case .success(let result):
                current.land(result)
            case .failure(let error as CommitSearchError):
                current.fail(SearchWording.failure(error))
            case .failure(let error):
                current.fail(Self.describe(error))
            }
            showRows(current)
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    /// Writes `state`, whose rows were replaced or cleared, and keeps the detail's header.
    private func showRows(_ state: CommitSearchState) {
        setCommitSearch(state)
        keepDetailHeader()
    }

    /// The rows were replaced or cleared: a selected commit only they described (a deep result)
    /// gets its own read (`detailCommit`), so its header never falls back to a bare id. The
    /// selection itself is left as it is.
    private func keepDetailHeader() {
        guard case .commit(let sha) = selection, commitForDetail(sha) == nil else { return }
        loadDetail()
    }
}
