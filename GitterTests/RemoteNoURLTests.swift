import GitCore
import Testing

@testable import Gitter

/// B2 Task 3, fix round 1 (I1): a remote with no URL — listed since Task 3 so that it can be
/// given one — is offered for nothing that talks to a remote. git would use its **name as a
/// path** (measured: a nested checkout called `vendor` was fetched from, and had a branch
/// deleted by a push). Every reason below is what a menu item or a toolbar button shows.
@Suite struct RemoteNoURLTests {
    static let nourl = Remote(name: "vendor", fetchURL: nil, pushURL: nil)
    static let pushOnly = Remote(name: "po", fetchURL: nil, pushURL: "/srv/po.git")
    static let origin = Remote(name: "origin", fetchURL: "/srv/o.git", pushURL: "/srv/o.git")
    static let sha = "1111111111111111111111111111111111111111"

    static func gate(_ remotes: [Remote], branch: Branch? = nil) -> RemoteWording.Gate {
        RemoteWording.Gate(
            hasRepository: true, activity: nil, isMutating: false, operation: nil,
            isDetached: false, branch: branch, remotes: remotes)
    }

    static func branch(upstreamRemote: String? = nil, pushRemote: String? = nil) -> Branch {
        Branch(
            name: "main", sha: sha, isHead: true,
            upstream: upstreamRemote.map { "\($0)/main" },
            tracking: upstreamRemote == nil ? .none : .counts(ahead: 0, behind: 1),
            upstreamRemote: upstreamRemote, upstreamRef: upstreamRemote.map { _ in "refs/heads/main" },
            pushRemote: pushRemote)
    }

    // MARK: - The menus

    /// A remote row's Fetch, a remote branch's "Delete on <r>…" (a fetch, then a push), and the
    /// tag menu's push and delete items.
    @Test func theRemoteMenusGiveTheReason() {
        #expect(RemoteWording.fetchURLBlocked(Self.nourl) == RemoteWording.remoteHasNoURL("vendor"))
        #expect(RemoteWording.fetchURLBlocked(Self.pushOnly) == RemoteWording.remoteHasNoFetchURL("po"))
        #expect(RemoteWording.fetchURLBlocked(Self.origin) == nil)
        #expect(RemoteWording.pushURLBlocked(Self.nourl) == RemoteWording.remoteHasNoURL("vendor"))
        #expect(RemoteWording.pushURLBlocked(Self.pushOnly) == nil)
        #expect(RemoteWording.deleteOnRemoteURLBlocked(Self.nourl) == RemoteWording.remoteHasNoURL("vendor"))
        #expect(RemoteWording.deleteOnRemoteURLBlocked(Self.pushOnly) == RemoteWording.remoteHasNoFetchURL("po"))
        #expect(RemoteWording.deleteOnRemoteURLBlocked(Self.origin) == nil)

        let tags = RemoteWording.tagMenuRemotes([Self.nourl, Self.origin, Self.pushOnly])
        #expect(tags.push == ["origin", "po"])
        #expect(tags.delete == ["origin"], "a delete reads the tag on the remote first (ls-remote)")
    }

    // MARK: - The toolbar

    /// Fetch: a repository whose only remote has no URL has nothing to fetch from.
    @Test func fetchIsOffWithNoRemoteToFetchFrom() {
        #expect(RemoteWording.fetchBlocked(Self.gate([Self.nourl])) == RemoteWording.noRemoteToFetchFrom)
        #expect(RemoteWording.fetchBlocked(Self.gate([Self.nourl, Self.pushOnly])) == RemoteWording.noRemoteToFetchFrom)
        #expect(RemoteWording.fetchBlocked(Self.gate([Self.nourl, Self.origin])) == nil)
        #expect(RemoteWording.fetchBlocked(Self.gate([])) == RemoteWording.noRemotes)
    }

    /// Pull fetches the upstream's remote first.
    @Test func pullIsOffWhenTheUpstreamsRemoteHasNoURL() {
        let gate = Self.gate([Self.nourl, Self.origin], branch: Self.branch(upstreamRemote: "vendor"))
        #expect(RemoteWording.pullBlocked(gate) == RemoteWording.remoteHasNoURL("vendor"))
        let fine = Self.gate([Self.nourl, Self.origin], branch: Self.branch(upstreamRemote: "origin"))
        #expect(RemoteWording.pullBlocked(fine) == nil)
    }

    /// Push: a branch pushing to the no-URL remote is refused with that reason; Publish with
    /// nowhere to push to is off.
    @Test func pushAndPublishAreOffWithNowhereToPushTo() {
        let pushing = Self.gate([Self.nourl, Self.origin], branch: Self.branch(pushRemote: "vendor"))
        #expect(RemoteWording.pushBlocked(pushing) == RemoteWording.refused(.noURL("vendor"), branch: "main"))
        let publishing = Self.gate([Self.nourl], branch: Self.branch())
        #expect(RemoteWording.pushBlocked(publishing) == RemoteWording.noRemoteToPushTo)
        let fine = Self.gate([Self.nourl, Self.origin], branch: Self.branch())
        #expect(RemoteWording.pushBlocked(fine) == nil)
    }

    /// GitCore's own refusal, should anything reach it, in words.
    @Test func gitCoresRefusalIsWorded() {
        let words = RemoteWording.failure(RemoteOperationError.noURL("vendor"), attempt: "fetch from \"vendor\"", isWrite: false)
        #expect(words == "Couldn't fetch from \"vendor\": \"vendor\" has no URL for that, so nothing was run — git would have used the name as a path.")
    }
}
