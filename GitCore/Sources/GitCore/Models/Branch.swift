import Foundation

public struct Branch: Sendable, Hashable, Identifiable {
    /// Short name: "main" for local, "origin/main" for remote.
    public let name: String
    public let sha: String
    public let isHead: Bool
    public let upstream: String?
    /// How far this branch is ahead of and behind its upstream. Always `.none` for a
    /// remote-tracking branch, which has no upstream of its own.
    public let tracking: Tracking
    /// The remote the upstream lives on, or nil when there is no upstream — or when the
    /// upstream is another *local* branch, which git reports as the remote ".". "." is not a
    /// remote (`git remote add .` is refused), so it is never handed to push as one.
    public let upstreamRemote: String?
    /// The upstream's full name on that remote, e.g. "refs/heads/main".
    public let upstreamRef: String?

    public var id: String { name }

    /// The upstream is another local branch: an upstream ref, but no remote to push it to.
    public var tracksLocalBranch: Bool {
        upstream != nil && upstreamRemote == nil && upstreamRef != nil
    }

    public init(name: String, sha: String, isHead: Bool, upstream: String?,
                tracking: Tracking = .none, upstreamRemote: String? = nil,
                upstreamRef: String? = nil) {
        self.name = name
        self.sha = sha
        self.isHead = isHead
        self.upstream = upstream
        self.tracking = tracking
        self.upstreamRemote = upstreamRemote
        self.upstreamRef = upstreamRef
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
    public let remotes: [Remote]

    /// The configured remotes, in git's order. Derived from `git remote -v` rather than from
    /// the remote branches' names: a name may contain a slash, and a remote nothing has been
    /// fetched from has no branches to derive it from at all.
    public var remoteNames: [String] { remotes.map(\.name) }

    /// The remote a remote-tracking branch belongs to: the configured remote with the longest
    /// matching `"<name>/"` prefix, so `up/stream/main` belongs to `up/stream` and not to `up`.
    /// `nil` when no configured remote matches — a hand-made `refs/remotes/ghost/x`, say.
    public func remote(of remoteBranch: Branch) -> Remote? {
        remotes
            .filter { remoteBranch.name.hasPrefix($0.name + "/") }
            .max { $0.name.count < $1.name.count }
    }

    /// The remote-tracking branches that belong to `remote`, in `remoteBranches` order.
    public func branches(of remote: Remote) -> [Branch] {
        remoteBranches.filter { self.remote(of: $0) == remote }
    }

    /// Remote-tracking branches no configured remote claims. They are still shown, grouped on
    /// their own, rather than dropped: the refs — and the commits they hold — are real.
    public var branchesWithoutRemote: [Branch] {
        remoteBranches.filter { remote(of: $0) == nil }
    }

    public init(localBranches: [Branch], remoteBranches: [Branch], tags: [Tag],
                remotes: [Remote] = []) {
        self.localBranches = localBranches
        self.remoteBranches = remoteBranches
        self.tags = tags
        self.remotes = remotes
    }

    /// A copy carrying the configured remotes. `for-each-ref` cannot know them, so the
    /// snapshot reads `git remote -v` beside it and joins the two here.
    public func with(remotes: [Remote]) -> RefCollection {
        RefCollection(localBranches: localBranches, remoteBranches: remoteBranches,
                      tags: tags, remotes: remotes)
    }

    public static let empty = RefCollection(localBranches: [], remoteBranches: [], tags: [])
}
