import Foundation

public struct RepoSnapshot: Sendable, Hashable {
    public let root: URL
    public let status: WorkingCopyStatus
    public let refs: RefCollection
    public let commits: [Commit]
    public let graph: [GraphRow]         // same order/count as commits
    /// The stash list, newest first (see `GitStashBackend.stashes`).
    public let stashes: [Stash]
    /// How many commits the history read asked for (`HistoryDepth`); `commits` holds at most
    /// this many.
    public let historyDepth: Int
    /// Whether `commits` reaches the start of history: git had no commit past `historyDepth`.
    public let historyIsComplete: Bool

    public init(
        root: URL, status: WorkingCopyStatus, refs: RefCollection, commits: [Commit], graph: [GraphRow],
        stashes: [Stash] = [], historyDepth: Int = HistoryDepth.page, historyIsComplete: Bool = true
    ) {
        self.root = root
        self.status = status
        self.refs = refs
        self.commits = commits
        self.graph = graph
        self.stashes = stashes
        self.historyDepth = historyDepth
        self.historyIsComplete = historyIsComplete
    }
}
