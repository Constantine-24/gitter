import GitCore
import Testing

@testable import Gitter

/// B2 Task 4: the menu items for prune, clean-up, another branch's push and fast-forward, and
/// upstream — their titles and the reasons a disabled one shows (`MenuReasons`), and the
/// prune sheet's default keep boxes. Pure: no store, no git.
@Suite struct RemoteAdminMenuTests {
    static let sha = "1111111111111111111111111111111111111111"
    static let origin = Remote(name: "origin", fetchURL: "/srv/o.git", pushURL: "/srv/o.git")
    static let nourl = Remote(name: "vendor", fetchURL: nil, pushURL: nil)
    static let pushOnly = Remote(name: "po", fetchURL: nil, pushURL: "/srv/po.git")

    static func gate(
        _ remotes: [Remote] = [origin], current: Branch? = nil, activity: RemoteActivity? = nil,
        isMutating: Bool = false, hasRepository: Bool = true
    ) -> RemoteWording.Gate {
        RemoteWording.Gate(
            hasRepository: hasRepository, activity: activity, isMutating: isMutating,
            operation: nil, isDetached: current == nil, branch: current, remotes: remotes)
    }

    /// A branch tracking `<remote>/<name>`, pushing there unless `pushRemote` says otherwise.
    static func branch(
        _ name: String, upstreamRemote: String? = "origin", tracking: Tracking = .counts(ahead: 0, behind: 0),
        pushRemote: String?? = .none, isHead: Bool = false
    ) -> Branch {
        Branch(
            name: name, sha: sha, isHead: isHead,
            upstream: upstreamRemote.map { "\($0)/\(name)" },
            tracking: upstreamRemote == nil ? .none : tracking,
            upstreamRemote: upstreamRemote,
            upstreamRef: upstreamRemote.map { _ in "refs/heads/\(name)" },
            pushRemote: pushRemote ?? upstreamRemote)
    }

    static let main = branch("main", isHead: true)

    // MARK: - Titles

    @Test func theTitlesNameWhatTheyActOn() {
        #expect(RemoteAdminWording.pruneTitle("origin") == "Prune \"origin\"…")
        #expect(RemoteAdminWording.cleanUpTitle == "Clean Up Gone Branches…")
        #expect(RemoteAdminWording.fastForwardTitle("topic") == "Fast-Forward \"topic\"")
        #expect(RemoteAdminWording.unsetUpstreamTitle == "Unset Upstream")
        #expect(RemoteAdminWording.upstreamTitle(Self.branch("topic")) == "Change Upstream…")
        #expect(RemoteAdminWording.upstreamTitle(Self.branch("topic", upstreamRemote: nil)) == "Set Upstream…")
    }

    /// Push for a branch with a push remote, Publish… (a sheet) for one with none, Re-publish for
    /// one whose upstream is gone — `PushTarget.resolve`, as for the toolbar.
    @Test func pushOrPublishIsDecidedByThePushTarget() {
        let remotes = [Self.origin]
        #expect(RemoteAdminWording.pushBranchTitle(Self.branch("topic"), remotes: remotes) == "Push \"topic\"")
        #expect(
            RemoteAdminWording.pushBranchTitle(Self.branch("topic", upstreamRemote: nil), remotes: remotes)
                == "Publish \"topic\"…")
        #expect(
            RemoteAdminWording.pushBranchTitle(Self.branch("topic", tracking: .gone), remotes: remotes)
                == "Re-publish \"topic\"")
    }

    // MARK: - Push another branch

    @Test func pushingAnotherBranchIsNotStoppedByHEAD() {
        let topic = Self.branch("topic", tracking: .counts(ahead: 2, behind: 0))
        // Detached HEAD, no current branch: pushing another branch does not touch HEAD.
        #expect(RemoteAdminWording.pushBranchBlocked(topic, gate: Self.gate()) == nil)
        #expect(RemoteAdminWording.pushBranchBlocked(topic, gate: Self.gate(isMutating: true)) == RemoteWording.mutationBusy)
        let lane = RemoteActivity(kind: .fetch, remote: "origin", progress: nil)
        #expect(RemoteAdminWording.pushBranchBlocked(topic, gate: Self.gate(activity: lane)) == RemoteWording.laneBusy(lane))
        #expect(RemoteAdminWording.pushBranchBlocked(topic, gate: Self.gate(hasRepository: false)) == RemoteWording.noRepository)
    }

    /// The push target's refusals and the no-URL remotes, as the toolbar words them.
    @Test func pushingAnotherBranchGivesThePushTargetsReason() {
        let toNoURL = Self.branch("topic", pushRemote: .some("vendor"))
        #expect(
            RemoteAdminWording.pushBranchBlocked(toNoURL, gate: Self.gate([Self.origin, Self.nourl]))
                == RemoteWording.refused(.noURL("vendor"), branch: "topic"))
        let unpublished = Self.branch("topic", upstreamRemote: nil)
        #expect(RemoteAdminWording.pushBranchBlocked(unpublished, gate: Self.gate([Self.nourl])) == RemoteWording.noRemoteToPushTo)
        #expect(RemoteAdminWording.pushBranchBlocked(unpublished, gate: Self.gate([])) == RemoteWording.noRemotes)
        #expect(RemoteAdminWording.pushBranchBlocked(unpublished, gate: Self.gate([Self.pushOnly])) == nil)
    }

    /// The branch HEAD is on keeps the toolbar's own push, and its reasons.
    @Test func theCurrentBranchUsesTheToolbarsReasons() {
        let gate = Self.gate(current: Self.main)
        #expect(RemoteAdminWording.pushBranchBlocked(Self.main, gate: gate) == RemoteWording.pushBlocked(gate))
    }

    // MARK: - Fast-forward

    @Test func fastForwardIsOffForTheCheckedOutBranch() {
        let gate = Self.gate(current: Self.main)
        #expect(RemoteAdminWording.fastForwardBlocked(Self.main, gate: gate) == RemoteAdminWording.fastForwardCurrent("main"))
        #expect(RemoteAdminWording.fastForwardCurrent("main").contains("Pull"))
    }

    /// Off up front when nothing could be fast-forwarded — no upstream, a gone one, one the
    /// branch is ahead of or has diverged from — and when its remote has no fetch URL; on when
    /// it is behind or level (the fetch may bring more).
    @Test func fastForwardSaysWhyNothingCouldMove() {
        let gate = Self.gate([Self.origin, Self.nourl])
        #expect(
            RemoteAdminWording.fastForwardBlocked(Self.branch("t", upstreamRemote: nil), gate: gate)
                == RemoteAdminWording.fastForwardNoUpstream("t"))
        #expect(
            RemoteAdminWording.fastForwardBlocked(Self.branch("t", tracking: .gone), gate: gate)
                == RemoteAdminWording.fastForwardUpstreamGone("t", upstream: "origin/t"))
        #expect(
            RemoteAdminWording.fastForwardBlocked(Self.branch("t", tracking: .counts(ahead: 2, behind: 0)), gate: gate)
                == RemoteAdminWording.fastForwardAhead("t", upstream: "origin/t", ahead: 2))
        #expect(
            RemoteAdminWording.fastForwardBlocked(Self.branch("t", tracking: .counts(ahead: 1, behind: 3)), gate: gate)
                == RemoteAdminWording.fastForwardDiverged("t", upstream: "origin/t", ahead: 1, behind: 3))
        #expect(
            RemoteAdminWording.fastForwardBlocked(Self.branch("t", upstreamRemote: "vendor"), gate: gate)
                == RemoteWording.remoteHasNoURL("vendor"))
        #expect(RemoteAdminWording.fastForwardBlocked(Self.branch("t", tracking: .counts(ahead: 0, behind: 2)), gate: gate) == nil)
        #expect(RemoteAdminWording.fastForwardBlocked(Self.branch("t"), gate: gate) == nil)
        #expect(RemoteAdminWording.fastForwardBlocked(Self.branch("t"), gate: Self.gate(isMutating: true)) == RemoteWording.mutationBusy)
    }

    /// A local upstream has nothing to fetch: no URL to need.
    @Test func aLocalUpstreamNeedsNoRemote() {
        let local = Branch(
            name: "t", sha: Self.sha, isHead: false, upstream: "base", tracking: .counts(ahead: 0, behind: 1),
            upstreamRemote: nil, upstreamRef: "refs/heads/base")
        #expect(RemoteAdminWording.fastForwardBlocked(local, gate: Self.gate([])) == nil)
    }

    // MARK: - Upstream

    @Test func unsetIsOffWithoutAnUpstream() {
        #expect(
            RemoteAdminWording.unsetUpstreamBlocked(Self.branch("t", upstreamRemote: nil), gate: Self.gate())
                == RemoteAdminWording.noUpstreamToUnset("t"))
        #expect(RemoteAdminWording.unsetUpstreamBlocked(Self.branch("t"), gate: Self.gate()) == nil)
        #expect(RemoteAdminWording.unsetUpstreamBlocked(Self.branch("t"), gate: Self.gate(isMutating: true)) == RemoteWording.mutationBusy)
        #expect(RemoteAdminWording.upstreamBlocked(Self.gate(isMutating: true)) == RemoteWording.mutationBusy)
        #expect(RemoteAdminWording.upstreamBlocked(Self.gate()) == nil)
    }

    // MARK: - Prune and clean-up

    /// Prune lists by fetching: a remote with no fetch URL is off, with the reason (Task 3's
    /// `fetchURLBlocked`); a busy lane too. Not stopped by HEAD or an operation.
    @Test func pruneNeedsAFetchURLAndTheLane() {
        #expect(RemoteAdminWording.pruneBlocked(Self.origin, gate: Self.gate()) == nil)
        #expect(RemoteAdminWording.pruneBlocked(Self.nourl, gate: Self.gate()) == RemoteWording.remoteHasNoURL("vendor"))
        #expect(RemoteAdminWording.pruneBlocked(Self.pushOnly, gate: Self.gate()) == RemoteWording.remoteHasNoFetchURL("po"))
        let lane = RemoteActivity(kind: .push, remote: "origin", progress: nil)
        #expect(RemoteAdminWording.pruneBlocked(Self.origin, gate: Self.gate(activity: lane)) == RemoteWording.laneBusy(lane))
        #expect(RemoteAdminWording.pruneBlocked(Self.origin, gate: Self.gate(hasRepository: false)) == RemoteWording.noRepository)
    }

    /// The Remotes menu offers a prune for every remote it can fetch from.
    @Test func theRemotesMenuPrunesWhatItCanFetch() {
        #expect(RemoteAdminWording.prunableRemotes([Self.nourl, Self.origin, Self.pushOnly]) == ["origin"])
        #expect(RemoteAdminWording.pruneMenuBlocked(Self.gate([Self.nourl])) == RemoteWording.noRemoteToFetchFrom)
        #expect(RemoteAdminWording.pruneMenuBlocked(Self.gate([])) == RemoteWording.noRemotes)
        #expect(RemoteAdminWording.pruneMenuBlocked(Self.gate()) == nil)
    }

    @Test func cleanUpIsOffOnlyWithoutARepositoryOrWhileAChangeRuns() {
        #expect(RemoteAdminWording.cleanUpBlocked(Self.gate()) == nil)
        #expect(RemoteAdminWording.cleanUpBlocked(Self.gate(isMutating: true)) == RemoteWording.mutationBusy)
        #expect(RemoteAdminWording.cleanUpBlocked(Self.gate(hasRepository: false)) == RemoteWording.noRepository)
    }

    // MARK: - Keep boxes (carried note 2)

    static let g1 = RefTip(ref: "refs/remotes/origin/gone1", id: "a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1")
    static let g2 = RefTip(ref: "refs/remotes/origin/gone2", id: "b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2")
    static let g3 = RefTip(ref: "refs/remotes/origin/gone3", id: "c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3")

    /// gone1's commits are all on gone2 (its tip is gone2's ancestor): keeping gone2 keeps them,
    /// so only gone2 and the unrelated gone3 are ticked.
    @Test func aHolderWhoseCommitsAnotherKeepsIsNotTicked() {
        let contains: (RefTip, RefTip) -> Bool = { outer, inner in outer == Self.g2 && inner == Self.g1 }
        #expect(
            RemoteAdminWording.defaultKeeps([Self.g1, Self.g2, Self.g3], contains: contains)
                == [Self.g2.ref, Self.g3.ref])
    }

    /// Two refs at the same commit keep the same commits: the first is ticked, not both.
    @Test func twoHoldersAtOneCommitTickTheFirst() {
        let twin = RefTip(ref: "refs/remotes/origin/twin", id: Self.g1.id)
        let contains: (RefTip, RefTip) -> Bool = { outer, inner in outer.id == inner.id }
        #expect(RemoteAdminWording.defaultKeeps([Self.g1, twin], contains: contains) == [Self.g1.ref])
    }

    @Test func unrelatedHoldersAreAllTicked() {
        #expect(
            RemoteAdminWording.defaultKeeps([Self.g1, Self.g2], contains: { _, _ in false })
                == [Self.g1.ref, Self.g2.ref])
    }

    /// Ruling 12: Keep All / Keep None set every box, and say which of the two would change
    /// anything (a squash-merge repository makes every pruned ref a holder, all ticked).
    @Test func keepAllAndKeepNoneSetEveryBox() {
        let refs = [Self.g1.ref, Self.g2.ref, Self.g3.ref]
        #expect(RemoteAdminWording.ticking(refs, all: true) == [Self.g1.ref: true, Self.g2.ref: true, Self.g3.ref: true])
        #expect(RemoteAdminWording.ticking(refs, all: false) == [Self.g1.ref: false, Self.g2.ref: false, Self.g3.ref: false])
        let some = [Self.g1.ref: true, Self.g2.ref: false]
        #expect(RemoteAdminWording.keepAllOffers(refs, ticked: some) == (all: true, none: true))
        #expect(RemoteAdminWording.keepAllOffers(refs, ticked: RemoteAdminWording.ticking(refs, all: true)) == (all: false, none: true))
        #expect(RemoteAdminWording.keepAllOffers(refs, ticked: [:]) == (all: true, none: false))
        #expect(RemoteAdminWording.keepCount(refs, ticked: some) == "Keeping 1 of 3.")
        #expect(RemoteAdminWording.keepCount(refs, ticked: [:]) == "Keeping none of 3: their commits will be on no branch.")
        #expect(RemoteAdminWording.keepProblemsSummary(0) == nil)
        #expect(RemoteAdminWording.keepProblemsSummary(1) == "One name to keep needs changing; it is marked in the list.")
        #expect(RemoteAdminWording.keepProblemsSummary(2) == "2 names to keep need changing; they are marked in the list.")
        #expect(RemoteAdminWording.keepAllTitle == "Keep All")
        #expect(RemoteAdminWording.keepNoneTitle == "Keep None")
    }

    /// The pruned branch's own name, or `<name>-kept` when a branch, tag or remote has it
    /// (compared ignoring case) — Ruling 1.
    @Test func theSuggestedNameIsTheBranchsOwnOrKept() {
        #expect(RemoteAdminWording.suggestedKeepName(for: Self.g1.ref, remote: "origin", taken: []) == "gone1")
        #expect(RemoteAdminWording.suggestedKeepName(for: Self.g1.ref, remote: "origin", taken: ["Gone1"]) == "gone1-kept")
        #expect(
            RemoteAdminWording.suggestedKeepName(for: Self.g1.ref, remote: "origin", taken: ["gone1", "gone1-kept"])
                == "gone1-kept-2")
        // A ref a custom refspec put elsewhere under refs/remotes/: the part after it.
        #expect(
            RemoteAdminWording.suggestedKeepName(for: "refs/remotes/mirror/feat/x", remote: "origin", taken: [])
                == "mirror/feat/x")
        #expect(RemoteAdminWording.suggestedKeepName(for: "refs/remotes/origin/feat/x", remote: "origin", taken: []) == "feat/x")
    }
}
