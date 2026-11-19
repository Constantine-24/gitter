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

/// The window's commit search (F1): what the bar holds and the rows it shows.
struct CommitSearchState: Equatable {
    /// The field's text as typed; the search itself trims it (`CommitSearch`).
    var query: String
    var mode: CommitSearchMode
    /// The rows shown: the last search that landed — kept while a new one runs, cleared by Stop,
    /// a failure and an empty field.
    var result: CommitSearchResult?
    var status: SearchStatus
    /// A Code search a ref change has overtaken: its rows stay, with Search Again (Code is not run
    /// again quietly). Cleared when a search starts.
    var isStale: Bool
    /// The selection when search opened: leaving reveals a result only if the user selected it
    /// during the search (Ruling P10) — History otherwise comes back as it was.
    var selectionWhenOpened: Selection

    init(
        query: String = "", mode: CommitSearchMode = .messageAuthorOrID, result: CommitSearchResult? = nil,
        status: SearchStatus = .idle, isStale: Bool = false, selectionWhenOpened: Selection = .workingCopy
    ) {
        self.query = query
        self.mode = mode
        self.result = result
        self.status = status
        self.isStale = isStale
        self.selectionWhenOpened = selectionWhenOpened
    }

    /// What the field and the mode ask for.
    var search: CommitSearch { CommitSearch(mode: mode, query: query) }
}

/// What a commit search's walk (`log --exclude=refs/stash --all`) starts from, and the decorations
/// its rows show: each local and remote-tracking branch's tip, each tag's commit, HEAD's commit
/// and the branch HEAD is on. A reload that changes none of these leaves every search's answer as
/// it was (Ruling P11) — unlike `RefCollection`, which also carries what the configuration says
/// (upstreams and their counts, push remotes, worktrees, remote URLs).
struct SearchedHistoryTips: Equatable {
    let branches: [String: String]
    let remoteBranches: [String: String]
    let tags: [String: String]
    let head: String?
    let headBranch: String?

    init(_ snapshot: RepoSnapshot) {
        func tips(_ pairs: [(String, String)]) -> [String: String] {
            Dictionary(pairs, uniquingKeysWith: { first, _ in first })
        }
        branches = tips(snapshot.refs.localBranches.map { ($0.name, $0.sha) })
        remoteBranches = tips(snapshot.refs.remoteBranches.map { ($0.name, $0.sha) })
        tags = tips(snapshot.refs.tags.map { ($0.name, $0.sha) })
        head = snapshot.status.headSha
        headBranch = snapshot.refs.localBranches.first(where: \.isHead)?.name
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
/// with a result selected that History hasn't loaded reveals it (H1), as Done on a comparison does.
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
    var historyIsCovered: Bool {
        comparison != nil || commitSearch.map { !$0.search.isEmpty } ?? false
    }

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
        // After the comparison's end, which may have moved the selection off its changes row.
        setCommitSearch(CommitSearchState(selectionWhenOpened: selection))
    }

    /// The field's text changed: searches after the debounce. A text that leaves the search the
    /// same (blanks around it) while it runs or has landed runs nothing; an empty one shows no
    /// rows and runs nothing.
    func setSearchQuery(_ query: String) {
        guard var state = commitSearch, state.query != query else { return }
        let before = state.search
        state.query = query
        setCommitSearch(state)
        searchEdited(from: before)
    }

    /// The mode menu changed: searches the same text again in `mode`, after the debounce.
    func setSearchMode(_ mode: CommitSearchMode) {
        guard var state = commitSearch, state.mode != mode else { return }
        let before = state.search
        state.mode = mode
        setCommitSearch(state)
        searchEdited(from: before)
    }

    private func searchEdited(from before: CommitSearch) {
        guard let state = commitSearch else { return }
        if state.search == before, state.status == .searching || state.status == .done { return }
        startSearch(debounced: true)
    }

    // MARK: - In search

    /// Stop: the search running is cancelled and the rows go, so the field never stands over
    /// another query's rows; the status line says "Search stopped". Search stays open, and
    /// editing the query or the mode searches again.
    func stopSearch() {
        guard var state = commitSearch, !state.search.isEmpty else { return }
        cancelSearch()
        state.result = nil
        state.status = .stopped
        state.isStale = false
        setCommitSearch(state)
        keepDetailHeader()
    }

    /// Search Again: the same search, now, with no debounce — a stale Code search's button.
    func searchAgain() {
        guard commitSearch != nil else { return }
        startSearch(debounced: false)
    }

    /// A reload that moved a branch, a tag or HEAD (`loadSnapshot`, `SearchedHistoryTips`): a landed
    /// or running Message, Author or ID or File search runs again, keeping its rows and the
    /// selection until the new rows land; a Code search, which can take seconds, is only marked out
    /// of date. A stopped or failed search, and an empty field, are left as they are.
    func historyChangedUnderSearch() {
        guard var state = commitSearch, !state.search.isEmpty,
            state.status == .done || state.status == .searching
        else { return }
        if state.mode == .code {
            state.isStale = true
            setCommitSearch(state)
        } else {
            startSearch(debounced: false)
        }
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
        let pickedResult =
            selection != state.selectionWhenOpened && state.result?.commits.contains { $0.sha == sha } == true
        if pickedResult || !historyRows.isLoaded(sha) {
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
        state.isStale = false
        guard !search.isEmpty else {
            state.result = nil
            state.status = .idle
            setCommitSearch(state)
            keepDetailHeader()
            return
        }
        state.status = .searching
        setCommitSearch(state)
        let capturedGeneration = generation
        let debounce = debounced ? searchDebounce : .zero
        searchTask = Task {
            if debounce > .zero {
                try? await Task.sleep(for: debounce)
            }
            guard !Task.isCancelled else { return }
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
                current.result = result
                current.status = .done
            case .failure(let error):
                current.result = nil
                current.status = .failed(Self.describe(error))
            }
            setCommitSearch(current)
            keepDetailHeader()
        }
    }

    private func cancelSearch() {
        searchTask?.cancel()
        searchTask = nil
    }

    /// The rows were replaced or cleared: a selected commit only they described (a deep result)
    /// gets its own read (`detailCommit`), so its header never falls back to a bare id. The
    /// selection itself is left as it is.
    private func keepDetailHeader() {
        guard case .commit(let sha) = selection, commitForDetail(sha) == nil else { return }
        loadDetail()
    }
}
