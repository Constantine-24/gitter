import Foundation
import Testing

@testable import GitCore

/// `remotesFetchingNoTags` (B1 Task 4, fix round 1): which remotes `remote.<r>.tagOpt=--no-tags`
/// keeps from bringing a deleted tag back on the next fetch — so the Delete Tag sheet does not
/// claim they will (B22). One local config read, no network.
@Suite struct TagFetchOptionTests {

    @Test func noRemoteSetToFetchNoTagsNamesNone() async throws {
        let (repo, origin) = try await TagRemoteTests.makeRepo()
        defer { TagRemoteTests.cleanUp(repo, origin) }
        #expect(try await CLIGitBackend().remotesFetchingNoTags(at: repo.root) == [])
    }

    /// The subsection keeps its case and its dots; git's last value wins, as it does for the
    /// fetch itself; `--tags` is not "no tags".
    @Test func theRemotesSetToNoTagsAreNamedAndTheLastValueWins() async throws {
        let (repo, origin) = try await TagRemoteTests.makeRepo()
        defer { TagRemoteTests.cleanUp(repo, origin) }
        try await repo.git(["config", "remote.origin.tagOpt", "--no-tags"])
        try await repo.git(["config", "remote.My.Dot.tagOpt", "--tags"])
        try await repo.git(["config", "--add", "remote.My.Dot.tagopt", "--no-tags"])
        try await repo.git(["config", "remote.other.tagOpt", "--no-tags"])
        try await repo.git(["config", "--add", "remote.other.tagOpt", "--tags"])
        #expect(try await CLIGitBackend().remotesFetchingNoTags(at: repo.root) == ["My.Dot", "origin"])
    }

    /// What the sentence rests on, through Gitter's own fetch: a tag deleted here comes back
    /// from a remote that still has it — and does not under `tagOpt=--no-tags` (B22).
    @Test(arguments: [false, true])
    func aDeletedTagComesBackOnTheNextFetchUnlessTheRemoteFetchesNoTags(noTags: Bool) async throws {
        let (repo, origin) = try await TagRemoteTests.makeRepo()
        defer { TagRemoteTests.cleanUp(repo, origin) }
        #expect(try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root) == .pushed)
        let id = try #require(try await repo.tagObject("ann"))
        try await repo.git(["update-ref", "-d", "refs/tags/ann", id])
        if noTags { try await repo.git(["config", "remote.origin.tagOpt", "--no-tags"]) }

        try await CLIGitBackend().fetch(remote: "origin", at: repo.root, progress: { _ in })

        #expect(try await repo.tagObject("ann") == (noTags ? nil : id))
    }
}
