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

    /// Task 9's second review: `git remote set-url --push origin fork2.git` on a branch level
    /// with `fork2` drew "Push ↑1" while `git push --dry-run` answered "Everything up-to-date".
    /// The count is against `refs/remotes/origin/main`, which only a *fetch* from `origin`'s
    /// fetch URL updates; a push goes to the push URL. Same remote name and ref, different
    /// repository — so no count.
    @Test func aRemoteThatPushesToAnotherURLShowsNoAheadCount() {
        let remotes = [Remote(name: "origin", fetchURL: "/tmp/origin.git", pushURL: "/tmp/fork2.git")]
        #expect(PushTarget.resolve(Self.branch(), remotes: remotes)
                == .push(remote: "origin", ref: "refs/heads/main"))
        #expect(PushTarget.aheadCountToDisplay(for: Self.branch(), remotes: remotes) == nil)
    }

    /// The control for the test above: a `pushurl` spelled out but equal to the fetch URL is
    /// the ordinary case, and the count stands.
    @Test func aRemoteWhosePushURLEqualsItsFetchURLShowsItsAheadCount() {
        let remotes = [Remote(name: "origin", fetchURL: "/tmp/origin.git", pushURL: "/tmp/origin.git")]
        #expect(PushTarget.aheadCountToDisplay(for: Self.branch(), remotes: remotes) == 1)
    }

    /// Either URL missing means the two cannot be shown to be the same repository. A remote
    /// with no push URL is not one `git remote -v` prints for an ordinary remote (it prints the
    /// fetch URL as the push URL), and a remote with no fetch URL has no remote-tracking refs
    /// a fetch keeps current — so a count there would be a guess. Nil, not the ahead count.
    @Test(arguments: [(String?.none, String?.some("/tmp/origin.git")),
                      (String?.some("/tmp/origin.git"), String?.none),
                      (String?.none, String?.none)])
    func aRemoteMissingAURLShowsNoAheadCount(fetchURL: String?, pushURL: String?) {
        let remotes = [Remote(name: "origin", fetchURL: fetchURL, pushURL: pushURL)]
        #expect(PushTarget.aheadCountToDisplay(for: Self.branch(), remotes: remotes) == nil)
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
