import Foundation
import Testing

@testable import GitCore

/// `PushTarget.resolve` against every measured row of the design document's "Push target"
/// table, re-measured on git 2.54.0 (Apple Git-157) by Task 5.
///
/// The `Branch` values below are not invented: each one is what `RefParser` produces from the
/// `for-each-ref` line the row's configuration really printed. The measurement was made with
/// `LC_ALL=C`, `GIT_CONFIG_GLOBAL=/dev/null`, `GIT_CONFIG_NOSYSTEM=1`, in a repository with
/// three configured remotes (`origin`, `fork`, `fresh`) and the format
///
/// ```
/// %(refname:short)|up=[%(upstream:short)]|track=[%(upstream:track)]
/// |upremote=[%(upstream:remotename)]|upref=[%(upstream:remoteref)]
/// |pushremote=[%(push:remotename)]|pushref=[%(push:remoteref)]
/// ```
///
/// | # | printed | `Branch` |
/// |---|---|---|
/// | a | `up=[origin/main] upremote=[origin] upref=[refs/heads/main] pushremote=[origin] pushref=[]` | as below |
/// | b | `… pushremote=[fork] pushref=[]` (`branch.main.pushRemote=fork`) | |
/// | c | the **same** as b (`remote.pushDefault=fork`) | |
/// | d | everything empty | |
/// | e | `pushremote=[fork]`, everything else empty | |
/// | f | `up=[main] upremote=[.] upref=[refs/heads/main] pushremote=[.]` | `.` → nil, both sides |
/// | g | `up=[origin/main] upremote=[origin] upref=[refs/heads/main] pushremote=[origin] pushref=[]` on a branch called `topic` | |
/// | h | `pushref=[refs/heads/prefix-main]` (`remote.origin.push=refs/heads/*:refs/heads/prefix-*`) | |
/// | i | identical to a (`push.default=nothing` is invisible to `for-each-ref`) | |
/// | j | `pushremote=[fresh]` — a configured remote nothing was ever fetched from | |
/// | k | `pushremote=[nosuch]` — **not** a configured remote | |
/// | m | identical to d (`push.default=current` is invisible too) | |
/// | o | `up=[origin/goner] track=[[gone]] upref=[refs/heads/goner] pushremote=[origin]` | |
@Suite struct PushTargetTests {
    /// The three remotes the rows were measured with. `nosuch` is deliberately absent.
    private static let remotes = [
        Remote(name: "origin", fetchURL: "/tmp/origin.git", pushURL: "/tmp/origin.git"),
        Remote(name: "fork", fetchURL: "/tmp/fork.git", pushURL: "/tmp/fork.git"),
        Remote(name: "fresh", fetchURL: "/tmp/fresh.git", pushURL: "/tmp/fresh.git"),
    ]

    private static func branch(
        _ name: String, upstream: String? = nil, tracking: Tracking = .none,
        upstreamRemote: String? = nil, upstreamRef: String? = nil,
        pushRemote: String? = nil, pushRef: String? = nil
    ) -> Branch {
        Branch(name: name, sha: "1111111111111111111111111111111111111111", isHead: true,
               upstream: upstream, tracking: tracking, upstreamRemote: upstreamRemote,
               upstreamRef: upstreamRef, pushRemote: pushRemote, pushRef: pushRef)
    }

    /// Row (a): an ordinary tracking branch. `pushRef` is empty even though a bare `git push`
    /// writes `refs/heads/main`, so the destination is built from the branch's own name — never
    /// from `upstreamRef`, which under a `pushRemote` override names another repository.
    @Test func anOrdinaryTrackingBranchPushesToItsOwnNameOnItsPushRemote() {
        let main = Self.branch("main", upstream: "origin/main", upstreamRemote: "origin",
                               upstreamRef: "refs/heads/main", pushRemote: "origin")
        #expect(PushTarget.resolve(main, remotes: Self.remotes)
                == .push(remote: "origin", ref: "refs/heads/main"))
    }

    /// Rows (b) and (c): `branch.<name>.pushRemote` and `remote.pushDefault` both move the push
    /// to another repository and print exactly the same fields. The upstream still says
    /// `origin`, and it is not consulted.
    @Test(arguments: ["branch.main.pushRemote=fork", "remote.pushDefault=fork"])
    func aTriangularBranchPushesToItsPushRemoteAndNotToItsUpstreams(configuration: String) {
        let main = Self.branch("main", upstream: "origin/main", upstreamRemote: "origin",
                               upstreamRef: "refs/heads/main", pushRemote: "fork")
        #expect(PushTarget.resolve(main, remotes: Self.remotes)
                == .push(remote: "fork", ref: "refs/heads/main"), "\(configuration)")
    }

    /// Rows (d) and (m): no upstream and no push configuration. git would fall back to the
    /// implicit default remote under `push.default=current` (measured row m: it publishes to
    /// `origin`), and Gitter deliberately does not follow that fallback — Publish names the
    /// remote out loud instead of guessing one.
    @Test func aBranchWithNoPushRemoteIsUnpublished() {
        #expect(PushTarget.resolve(Self.branch("topicnoup"), remotes: Self.remotes) == .unpublished)
    }

    /// Row (e): a push target with **no upstream at all**. "Has an upstream" is not necessary
    /// for "has a push target".
    @Test func aBranchWithNoUpstreamButAPushDefaultIsStillPublished() {
        let topic = Self.branch("topicnoup", pushRemote: "fork")
        #expect(PushTarget.resolve(topic, remotes: Self.remotes)
                == .push(remote: "fork", ref: "refs/heads/topicnoup"))
    }

    /// Row (f): the upstream is another *local* branch. git prints `.` for both remote names
    /// and `RefParser` turns that into nil, because `.` is not a remote (`git remote add .` is
    /// refused). There is nowhere to push, so the branch is unpublished — "has an upstream" is
    /// not sufficient for "has a push target" either.
    @Test func aBranchTrackingALocalBranchIsUnpublished() {
        let localup = Self.branch("localup", upstream: "main", upstreamRemote: nil,
                                  upstreamRef: "refs/heads/main", pushRemote: nil)
        #expect(localup.tracksLocalBranch)
        #expect(PushTarget.resolve(localup, remotes: Self.remotes) == .unpublished)
    }

    /// Row (g), the one case that is refused rather than resolved: `topic` tracks `origin/main`,
    /// there is no explicit push refspec, and the push remote is the upstream's. Measured, a
    /// bare `git push` under the default `push.default=simple` answers `fatal: The upstream
    /// branch of your current branch does not match the name of your current branch.` Gitter
    /// refuses too, because either destination would surprise: `origin/topic` creates a branch
    /// nobody asked for while the badge goes on counting against `origin/main`, and
    /// `origin/main` publishes onto a branch of another name.
    @Test func aBranchWhoseUpstreamHasAnotherNameIsRefused() {
        let topic = Self.branch("topic", upstream: "origin/main", upstreamRemote: "origin",
                                upstreamRef: "refs/heads/main", pushRemote: "origin")
        #expect(PushTarget.resolve(topic, remotes: Self.remotes)
                == .refused(.upstreamNameDiffers(upstream: "origin/main")))
    }

    /// Row (h): the one configuration that fills `%(push:remoteref)`. Gitter honours it, or it
    /// would push somewhere the user's own `git push` would not.
    @Test func anExplicitPushRefspecDecidesTheDestination() {
        let main = Self.branch("main", upstream: "origin/main", upstreamRemote: "origin",
                               upstreamRef: "refs/heads/main", pushRemote: "origin",
                               pushRef: "refs/heads/prefix-main")
        #expect(PushTarget.resolve(main, remotes: Self.remotes)
                == .push(remote: "origin", ref: "refs/heads/prefix-main"))
    }

    /// Row (h) again, with the names disagreeing as in row (g): an explicit refspec answers the
    /// question row (g) is refused for, so it wins and there is nothing left to refuse.
    @Test func anExplicitPushRefspecSettlesTheNameThatWouldOtherwiseBeRefused() {
        let topic = Self.branch("topic", upstream: "origin/main", upstreamRemote: "origin",
                                upstreamRef: "refs/heads/main", pushRemote: "origin",
                                pushRef: "refs/heads/prefix-topic")
        #expect(PushTarget.resolve(topic, remotes: Self.remotes)
                == .push(remote: "origin", ref: "refs/heads/prefix-topic"))
    }

    /// Row (i): `push.default=nothing` makes a bare `git push` refuse, and `for-each-ref` prints
    /// exactly what row (a) printed. The model cannot see the difference and does not pretend to.
    @Test func pushDefaultNothingIsInvisibleAndChangesNothingHere() {
        let main = Self.branch("main", upstream: "origin/main", upstreamRemote: "origin",
                               upstreamRef: "refs/heads/main", pushRemote: "origin")
        #expect(PushTarget.resolve(main, remotes: Self.remotes)
                == .push(remote: "origin", ref: "refs/heads/main"))
    }

    /// Row (j): a configured remote nothing was ever fetched from is a perfectly good push
    /// target — it has no remote-tracking refs, which is not the question being asked.
    @Test func aRemoteNothingWasEverFetchedFromIsStillAPushTarget() {
        let main = Self.branch("main", upstream: "origin/main", upstreamRemote: "origin",
                               upstreamRef: "refs/heads/main", pushRemote: "fresh")
        #expect(PushTarget.resolve(main, remotes: Self.remotes)
                == .push(remote: "fresh", ref: "refs/heads/main"))
    }

    /// Row (k): `%(push:remotename)` need not name a *configured* remote — git prints whatever
    /// `branch.<name>.pushRemote` says and only fails later (`fatal: 'nosuch' does not appear to
    /// be a git repository`). The name is checked against the configured remotes here, so the
    /// user is told which name is wrong instead of being shown that sentence.
    @Test func aPushRemoteThatIsNotConfiguredIsRefusedByName() {
        let main = Self.branch("main", upstream: "origin/main", upstreamRemote: "origin",
                               upstreamRef: "refs/heads/main", pushRemote: "nosuch")
        #expect(PushTarget.resolve(main, remotes: Self.remotes)
                == .refused(.unknownRemote("nosuch")))
    }

    /// The unknown-remote check comes first, before the explicit refspec and before the
    /// name-disagreement refusal: a destination on a remote that does not exist is not a
    /// destination, whatever else is configured.
    @Test func anUnknownRemoteIsRefusedBeforeEveryOtherRule() {
        let withRefspec = Self.branch("main", upstream: "origin/main", upstreamRemote: "origin",
                                      upstreamRef: "refs/heads/main", pushRemote: "nosuch",
                                      pushRef: "refs/heads/prefix-main")
        #expect(PushTarget.resolve(withRefspec, remotes: Self.remotes)
                == .refused(.unknownRemote("nosuch")))

        let alsoNameMismatch = Self.branch("topic", upstream: "nosuch/main",
                                           upstreamRemote: "nosuch",
                                           upstreamRef: "refs/heads/main", pushRemote: "nosuch")
        #expect(PushTarget.resolve(alsoNameMismatch, remotes: Self.remotes)
                == .refused(.unknownRemote("nosuch")))
    }

    /// Row (o): a `[gone]` upstream still has a push remote, and the upstream ref it names is
    /// the branch's own name. It resolves to an ordinary push, which recreates the branch on the
    /// server — exactly what the user's own `git push` would do, to exactly the ref this branch
    /// has always tracked. "Gone" is a fact about the server, not a reason to refuse to write.
    @Test func aGoneUpstreamStillResolvesToItsPushRemote() {
        let goner = Self.branch("goner", upstream: "origin/goner", tracking: .gone,
                                upstreamRemote: "origin", upstreamRef: "refs/heads/goner",
                                pushRemote: "origin")
        #expect(PushTarget.resolve(goner, remotes: Self.remotes)
                == .push(remote: "origin", ref: "refs/heads/goner"))
    }

    /// The name-disagreement refusal is about the two *names*, so it applies to a `[gone]`
    /// upstream as much as to a live one: nothing about the ref having been deleted tells us
    /// which of the two destinations the user meant.
    @Test func aGoneUpstreamOfAnotherNameIsStillRefused() {
        let topic = Self.branch("topic", upstream: "origin/main", tracking: .gone,
                                upstreamRemote: "origin", upstreamRef: "refs/heads/main",
                                pushRemote: "origin")
        #expect(PushTarget.resolve(topic, remotes: Self.remotes)
                == .refused(.upstreamNameDiffers(upstream: "origin/main")))
    }

    /// The refusal in row (g) is specifically about the *upstream's* remote. When the push goes
    /// somewhere else (`branch.topic.pushRemote=fork`), `upstreamRef` describes a different
    /// repository and says nothing at all about the destination, so there is no disagreement to
    /// refuse over and the branch publishes under its own name on the push remote.
    @Test func adifferingUpstreamNameOnAnotherRemoteIsNotADisagreement() {
        let topic = Self.branch("topic", upstream: "origin/main", upstreamRemote: "origin",
                                upstreamRef: "refs/heads/main", pushRemote: "fork")
        #expect(PushTarget.resolve(topic, remotes: Self.remotes)
                == .push(remote: "fork", ref: "refs/heads/topic"))
    }

    /// Total, including for inputs no row produces: a remote-tracking branch (which `RefParser`
    /// gives no push fields at all) and an empty remote list both answer rather than trap.
    @Test func isTotalForInputsNoRowProduces() {
        let remoteBranch = Branch(name: "origin/main", sha: "2222222222222222222222222222222222222222",
                                  isHead: false, upstream: nil)
        #expect(PushTarget.resolve(remoteBranch, remotes: Self.remotes) == .unpublished)

        let main = Self.branch("main", upstream: "origin/main", upstreamRemote: "origin",
                               upstreamRef: "refs/heads/main", pushRemote: "origin")
        #expect(PushTarget.resolve(main, remotes: []) == .refused(.unknownRemote("origin")))
    }
}
