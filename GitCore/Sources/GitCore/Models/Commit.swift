import Foundation

public struct Commit: Sendable, Hashable, Identifiable {
    public let sha: String
    public let parents: [String]
    public let authorName: String
    public let authorEmail: String
    public let authorDate: Date
    public let summary: String
    /// Decorations as git prints them with %D, split on ", ": e.g. "HEAD -> main", "tag: v1.0", "origin/main".
    public let refs: [String]

    public var id: String { sha }
    public var shortSha: String { String(sha.prefix(7)) }
    public var isMerge: Bool { parents.count > 1 }

    public init(sha: String, parents: [String], authorName: String, authorEmail: String, authorDate: Date, summary: String, refs: [String]) {
        self.sha = sha
        self.parents = parents
        self.authorName = authorName
        self.authorEmail = authorEmail
        self.authorDate = authorDate
        self.summary = summary
        self.refs = refs
    }
}
