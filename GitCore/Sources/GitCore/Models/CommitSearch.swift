import Foundation

/// What a commit search looks for in (F1). The mode says where the query is looked for; the
/// reads and their measured facts are documented on `GitBackend.searchCommits`.
public enum CommitSearchMode: String, Sendable, Hashable, CaseIterable {
    /// The message (subject or body), the author's name or email, or the start of the id.
    case messageAuthorOrID
    /// A changed path that contains the query.
    case file
    /// Text added or removed in a file's contents (git's `-S`).
    case code
}

/// A search: a mode and one literal phrase. `query` is stored without the whitespace and
/// newlines around it, so two searches that differ only there are equal.
public struct CommitSearch: Sendable, Hashable {
    public let mode: CommitSearchMode
    public let query: String

    public init(mode: CommitSearchMode, query: String) {
        self.mode = mode
        self.query = query.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var isEmpty: Bool { query.isEmpty }
}

/// What one search read found: the matching commits in History's order, and whether the list
/// was cut at the limit (there were more matches than it holds).
public struct CommitSearchResult: Sendable, Hashable {
    public let search: CommitSearch
    public let commits: [Commit]
    public let isCut: Bool

    public init(search: CommitSearch, commits: [Commit], isCut: Bool) {
        self.search = search
        self.commits = commits
        self.isCut = isCut
    }
}

public enum CommitSearchLimit {
    /// History's own cap (`HistoryDepth`, H1): a search lists at most this many matches.
    public static let rows = 50_000
}
