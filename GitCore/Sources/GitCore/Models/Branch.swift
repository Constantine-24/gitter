import Foundation

public struct Branch: Sendable, Hashable, Identifiable {
    /// Short name: "main" for local, "origin/main" for remote.
    public let name: String
    public let sha: String
    public let isHead: Bool
    public let upstream: String?

    public var id: String { name }

    public init(name: String, sha: String, isHead: Bool, upstream: String?) {
        self.name = name
        self.sha = sha
        self.isHead = isHead
        self.upstream = upstream
    }
}

public struct Tag: Sendable, Hashable, Identifiable {
    public let name: String
    public let sha: String
    public let isAnnotated: Bool

    public var id: String { name }

    public init(name: String, sha: String, isAnnotated: Bool) {
        self.name = name
        self.sha = sha
        self.isAnnotated = isAnnotated
    }
}

public struct RefCollection: Sendable, Hashable {
    public let localBranches: [Branch]
    public let remoteBranches: [Branch]   // excludes symbolic "origin/HEAD"
    public let tags: [Tag]

    public var remoteNames: [String] {
        Set(remoteBranches.map { branch in
            branch.name.split(separator: "/").first.map(String.init) ?? ""
        })
        .filter { !$0.isEmpty }
        .sorted()
    }

    public init(localBranches: [Branch], remoteBranches: [Branch], tags: [Tag]) {
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
        self.tags = tags
    }

    public static let empty = RefCollection(localBranches: [], remoteBranches: [], tags: [])
}
