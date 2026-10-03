import Foundation

public struct Branch: Sendable, Hashable, Identifiable {
    /// Short name: "main" for local, "origin/main" for remote.
    public let name: String
    public let sha: String
    public let isHead: Bool
    public let upstream: String?
    /// How far this branch is ahead of and behind **its upstream** — which is not necessarily
    /// anything on a remote: when `tracksLocalBranch` is true the counts are against another
    /// *local* branch, and when `pushRemote` differs from `upstreamRemote` they are against a
    /// repository the branch does not push to. A badge must say "ahead of `<upstream>`", never
    /// "ahead of the remote". Always `.none` for a remote-tracking branch, which has no
    /// upstream of its own.
    public let tracking: Tracking
    /// The remote the upstream lives on, or nil when there is no upstream — or when the
    /// upstream is another *local* branch, which git reports as the remote ".". "." is not a
    /// remote (`git remote add .` is refused), so it is never handed to push as one.
    public let upstreamRemote: String?
    /// The upstream's full name on that remote, e.g. "refs/heads/main".
    public let upstreamRef: String?
    /// Where a `git push` of this branch would go — `%(push:remotename)`, which is **not**
    /// `upstreamRemote`: `branch.<name>.pushRemote` and `remote.pushDefault` send the push to
    /// a different repository than the one the branch fetches from, and `remote.pushDefault`
    /// gives a push target even to a branch with no upstream at all. With neither configured
    /// it equals `upstreamRemote`. nil when git named no remote — and, as for
    /// `upstreamRemote`, when git said "." (a local upstream), which is not a remote.
    ///
    /// nil does **not** mean git would refuse to push: with no explicit configuration git
    /// falls back to the implicit default remote (measured: `origin`, and under
    /// `push.default=current` a bare `git push` of an upstreamless branch publishes it there).
    /// Gitter does not follow that fallback — a branch with no `pushRemote` is unpublished and
    /// goes through Publish, which names the remote explicitly.
    public let pushRemote: String?
    /// The ref `git push` would write **on that remote**, e.g. "refs/heads/main" —
    /// `%(push:remoteref)`.
    ///
    /// Measured on git 2.54: this is non-nil **only** when a `remote.<name>.push` refspec is
    /// configured. For an ordinary tracking branch it is nil even though a bare `git push`
    /// would happily write `refs/heads/<name>`, and it stays nil in the case where git
    /// *refuses* (`push.default=simple` with an upstream whose name differs). So nil says
    /// nothing either way, and the destination must never be inferred from `upstreamRef`:
    /// that is where the branch fetches from, which under a `pushRemote` override is a
    /// different repository entirely.
    public let pushRef: String?

    public var id: String { name }

    /// The upstream is another local branch: an upstream ref, but no remote to push it to.
    public var tracksLocalBranch: Bool {
        upstream != nil && upstreamRemote == nil && upstreamRef != nil
    }

    public init(name: String, sha: String, isHead: Bool, upstream: String?,
                tracking: Tracking = .none, upstreamRemote: String? = nil,
                upstreamRef: String? = nil, pushRemote: String? = nil,
                pushRef: String? = nil) {
        self.name = name
        self.sha = sha
        self.isHead = isHead
        self.upstream = upstream
        self.tracking = tracking
        self.upstreamRemote = upstreamRemote
        self.upstreamRef = upstreamRef
        self.pushRemote = pushRemote
        self.pushRef = pushRef
    }
}

public struct Tag: Sendable, Hashable, Identifiable {
    public let name: String
    /// What the tag points at in the history: the commit (or tree, or blob) an annotated tag
    /// peels to — all the way, through a tag of a tag (B18) — and the object itself for a
    /// lightweight one. This is the row a tag pill belongs to.
    public let sha: String
    public let isAnnotated: Bool
    /// What `refs/tags/<name>` holds: the **tag object** for an annotated tag, the commit for a
    /// lightweight one. The id a compare-and-delete must name (B19) and the one a restore
    /// recreates the identical tag from.
    public let objectID: String
    /// The tag object's tagger name; nil for a lightweight tag, which has no tagger (and for an
    /// annotated tag written without one).
    public let tagger: String?
    /// The tag object's date (`%(taggerdate)`); nil for a lightweight tag — never the commit's
    /// date, which `%(creatordate)` would report in its place (B18).
    public let date: Date?
    /// The tag message's subject (its first paragraph on one line); nil for a lightweight tag —
    /// never the commit's subject, which `%(contents:subject)` reports for one (B18). Empty for
    /// an annotated tag with an empty message.
    public let subject: String?

    public var id: String { name }

    /// `objectID` defaults to `sha`, which is right for a lightweight tag only; the parser
    /// always passes it.
    public init(
        name: String, sha: String, isAnnotated: Bool, objectID: String? = nil,
        tagger: String? = nil, date: Date? = nil, subject: String? = nil
    ) {
        self.name = name
        self.sha = sha
        self.isAnnotated = isAnnotated
        self.objectID = objectID ?? sha
        self.tagger = tagger
        self.date = date
        self.subject = subject
    }
}

public struct RefCollection: Sendable, Hashable {
    public let localBranches: [Branch]
    public let remoteBranches: [Branch]   // excludes symbolic refs such as "origin/HEAD"
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
