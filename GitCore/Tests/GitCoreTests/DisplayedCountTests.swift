import Testing

@testable import GitCore

/// The counts the toolbar may draw beside "Push" and "Pull": `PushTarget.aheadCountToDisplay`
/// and `PullPlan.behindCountToDisplay`.
///
/// **`Branch.tracking` is measured against the upstream, and a push does not always go there.**
/// Reproduced in Task 9's review: with `branch.main.pushRemote=fork` (row b) the toolbar read
/// "Push ↑1" — the ahead count against `origin/main` — while `git push --dry-run` said
/// "Everything up-to-date" against `fork`. A count is only drawn when the push goes to exactly
/// the ref it was measured against.
@Suite struct DisplayedCountTests {
    private static let remotes = [
        Remote(name: "origin", fetchURL: "/tmp/origin.git", pushURL: "/tmp/origin.git"),
        Remote(name: "fork", fetchURL: "/tmp/fork.git", pushURL: "/tmp/fork.git"),
    ]

    private static func branch(
        _ name: String = "main", upstream: String? = "origin/main",
        tracking: Tracking = .counts(ahead: 1, behind: 2),
        upstreamRemote: String? = "origin", upstreamRef: String? = "refs/heads/main",
        pushRemote: String? = "origin", pushRef: String? = nil
    ) -> Branch {
        Branch(name: name, sha: "1111111111111111111111111111111111111111", isHead: true,
               upstream: upstream, tracking: tracking, upstreamRemote: upstreamRemote,
               upstreamRef: upstreamRef, pushRemote: pushRemote, pushRef: pushRef)
    }

    // MARK: - Push

    /// Row (a): the push goes to the upstream itself, so its ahead count is what a push sends.
    @Test func aPlainTrackingBranchShowsItsAheadCount() {
        #expect(PushTarget.aheadCountToDisplay(for: Self.branch(), remotes: Self.remotes) == 1)
    }

    /// Rows (b) and (c): the push goes to `fork`, the count is against `origin/main`.
    @Test func aTriangularBranchShowsNoAheadCount() {
        let main = Self.branch(pushRemote: "fork")
        #expect(PushTarget.resolve(main, remotes: Self.remotes)
                == .push(remote: "fork", ref: "refs/heads/main"))
        #expect(PushTarget.aheadCountToDisplay(for: main, remotes: Self.remotes) == nil)
    }

    /// Row (h): an explicit refspec pushes to another ref on the same remote than the one the
    /// count was measured against.
    @Test func aPushToAnotherRefOnTheSameRemoteShowsNoAheadCount() {
        let main = Self.branch(pushRef: "refs/heads/prefix-main")
        #expect(PushTarget.aheadCountToDisplay(for: main, remotes: Self.remotes) == nil)
    }

    /// Row (f): counts against a local branch say nothing about any server.
    @Test func aBranchTrackingALocalBranchShowsNoAheadCount() {
        let local = Self.branch(upstream: "main2", upstreamRemote: nil, pushRemote: nil)
        #expect(local.tracksLocalBranch)
        #expect(PushTarget.aheadCountToDisplay(for: local, remotes: Self.remotes) == nil)
    }

    @Test func aGoneUpstreamShowsNoAheadCount() {
        let goner = Self.branch(tracking: .gone)
        #expect(PushTarget.aheadCountToDisplay(for: goner, remotes: Self.remotes) == nil)
    }

    /// A disabled Push must not carry a count either: rows (g) and (k).
    @Test func aRefusedTargetShowsNoAheadCount() {
        let topic = Self.branch("topic")
        #expect(PushTarget.resolve(topic, remotes: Self.remotes)
                == .refused(.upstreamNameDiffers(upstream: "origin/main")))
        #expect(PushTarget.aheadCountToDisplay(for: topic, remotes: Self.remotes) == nil)

        let unknown = Self.branch(pushRemote: "nosuch")
        #expect(PushTarget.aheadCountToDisplay(for: unknown, remotes: Self.remotes) == nil)
    }

    @Test func anUnpublishedBranchShowsNoAheadCount() {
        let main = Self.branch(pushRemote: nil)
        #expect(PushTarget.aheadCountToDisplay(for: main, remotes: Self.remotes) == nil)
    }

    @Test(arguments: [Tracking.none, .counts(ahead: 0, behind: 3), .counts(ahead: -1, behind: 0)])
    func nothingAheadShowsNoAheadCount(tracking: Tracking) {
        let main = Self.branch(tracking: tracking)
        #expect(PushTarget.aheadCountToDisplay(for: main, remotes: Self.remotes) == nil)
    }

    // MARK: - Pull

    /// A pull fetches the upstream's remote and counts against the upstream, so the behind
    /// count is right even for a triangular branch.
    @Test(arguments: ["origin", "fork"])
    func aBranchBehindItsRemoteUpstreamShowsItsBehindCount(pushRemote: String) {
        #expect(PullPlan.behindCountToDisplay(for: Self.branch(pushRemote: pushRemote)) == 2)
    }

    @Test func aBranchTrackingALocalBranchShowsNoBehindCount() {
        let local = Self.branch(upstream: "main2", upstreamRemote: nil, pushRemote: nil)
        #expect(PullPlan.behindCountToDisplay(for: local) == nil)
    }

    @Test(arguments: [Tracking.none, .gone, .counts(ahead: 3, behind: 0),
                      .counts(ahead: 0, behind: -1)])
    func nothingBehindShowsNoBehindCount(tracking: Tracking) {
        #expect(PullPlan.behindCountToDisplay(for: Self.branch(tracking: tracking)) == nil)
    }
}
