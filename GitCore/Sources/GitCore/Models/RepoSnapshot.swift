import Foundation

public struct RepoSnapshot: Sendable, Hashable {
    public let root: URL
    public let status: WorkingCopyStatus
    public let refs: RefCollection
    public let commits: [Commit]
    public let graph: [GraphRow]         // same order/count as commits

    public init(root: URL, status: WorkingCopyStatus, refs: RefCollection, commits: [Commit], graph: [GraphRow]) {
        self.root = root
        self.status = status
        self.refs = refs
        self.commits = commits
        self.graph = graph
    }
}
