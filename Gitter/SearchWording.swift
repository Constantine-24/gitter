import Foundation
import GitCore

/// Every sentence commit search puts on screen (F1): the Find Commits menu item, the bar's mode
/// names and field prompts, its status line, the out-of-date line with Search Again, the result
/// row's Show in History and the close button. Pure, so `SearchWordingTests` pins each one.
enum SearchWording {

    // MARK: - Menu and bar

    static let menuTitle = "Find Commits…"
    /// The search bar's accessibility label (Ruling P2).
    static let barAccessibility = "Find Commits"
    /// The mode menu's accessibility label.
    static let modeAccessibility = "Search Mode"
    /// The close button's title, help and accessibility label.
    static let closeSearch = "Close Search"

    /// The mode menu's item for `mode`.
    static func name(_ mode: CommitSearchMode) -> String {
        switch mode {
        case .messageAuthorOrID: "Message, Author or ID"
        case .file: "File"
        case .code: "Code"
        }
    }

    /// The field's prompt while `mode` is chosen.
    static func prompt(_ mode: CommitSearchMode) -> String {
        switch mode {
        case .messageAuthorOrID: "Message, author or ID"
        case .file: "File path or name"
        case .code: "Code text"
        }
    }

    // MARK: - Status line

    static let searching = "Searching…"
    static let stop = "Stop"
    static let stopped = "Search stopped"
    static let noMatches = "No commits match"
    /// A result cut at `CommitSearchLimit.rows`.
    static let cut = "Showing the newest \(grouped(CommitSearchLimit.rows)) matches"

    /// `1 commit`, `12,345 commits`.
    static func count(_ n: Int) -> String {
        n == 1 ? "1 commit" : "\(grouped(n)) commits"
    }

    /// `n` with its thousands grouped as the copy is written, whatever the user's locale.
    private static func grouped(_ n: Int) -> String {
        n.formatted(.number.locale(Locale(identifier: "en_US")))
    }

    /// The line under the bar: nil with nothing searched (an empty field); "Searching…" while a
    /// search runs, over the rows it will replace; after one has landed, its count, "No commits
    /// match", or the cut; "Search stopped"; or git's words after a failure.
    static func statusLine(_ state: CommitSearchState) -> String? {
        switch state.status {
        case .idle: return nil
        case .searching: return searching
        case .stopped: return stopped
        case .failed(let message): return message
        case .done:
            guard let result = state.result else { return nil }
            if result.isCut { return cut }
            return result.commits.isEmpty ? noMatches : count(result.commits.count)
        }
    }

    // MARK: - Out of date

    static let stale = "History has changed since this search"
    static let searchAgain = "Search Again"

    /// The out-of-date line beside the status line, with Search Again: only for a Code search a
    /// ref change has overtaken (Code is not run again quietly).
    static func staleLine(_ state: CommitSearchState) -> String? {
        state.isStale ? stale : nil
    }

    // MARK: - Row menu

    static let showInHistory = "Show in History"

    // MARK: - Blocked reasons

    static let noRepository = RemoteWording.noRepository
    static let blockedBySheet = StashWording.blockedBySheet
    static let blockedInFocusMode = "Leave Resolve Conflicts first."
}
