import Foundation
import Testing

@testable import GitCore

/// The remotes themselves — read from a real repository through `CLIGitBackend.snapshot`,
/// not from a hand-written fixture.
@Suite struct TrackingTests {
    private let backend = CLIGitBackend()

    private func refs(_ repo: TestRepo) async throws -> RefCollection {
        try await backend.snapshot(at: repo.root).refs
    }

    // MARK: - Remotes

    @Test func remotesCarryBothURLs() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }

        let refs = try await refs(repo)
        #expect(refs.remoteNames == ["origin"])
        let origin = try #require(refs.remotes.first)
        #expect(origin.fetchURL == remote.path)
        #expect(origin.pushURL == remote.path)
    }

    /// The whole point of reading `git remote -v`: a remote nothing has been fetched from has
    /// no `refs/remotes/<name>/…` at all, and used to be invisible.
    @Test func aRemoteWithNothingFetchedIsStillListed() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["remote", "add", "empty", "/tmp/nothing-was-fetched.git"])

        let refs = try await refs(repo)
        #expect(refs.remoteNames == ["empty", "origin"])
        let empty = try #require(refs.remotes.first { $0.name == "empty" })
        #expect(refs.branches(of: empty).isEmpty)
    }

    /// `git remote add up/stream` is refused while `up` exists ("is a subset of existing
    /// remote"), but writing the config directly gets both, and then `up/stream/main` must
    /// belong to `up/stream` — the longest matching name — and not to `up`.
    @Test func aRemoteNameThatIsAPrefixOfAnotherDoesNotStealItsBranches() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch(named: "up/stream")
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["config", "--add", "remote.up.url", "/tmp/up.git"])
        try await repo.git(["config", "--add", "remote.up.fetch", "+refs/heads/*:refs/remotes/up/*"])

        let refs = try await refs(repo)
        #expect(refs.remoteNames == ["up", "up/stream"])
        let upstream = try #require(refs.remotes.first { $0.name == "up/stream" })
        let up = try #require(refs.remotes.first { $0.name == "up" })
        #expect(refs.branches(of: upstream).map(\.name).contains("up/stream/main"))
        #expect(refs.branches(of: up).isEmpty)
        let main = try #require(refs.remoteBranches.first { $0.name == "up/stream/main" })
        #expect(refs.remote(of: main)?.name == "up/stream")
    }

    @Test func aRemoteBranchWhoseRemoteIsGoneIsStillReachable() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["update-ref", "refs/remotes/ghost/x", "main"])

        let refs = try await refs(repo)
        let ghost = try #require(refs.remoteBranches.first { $0.name == "ghost/x" })
        #expect(refs.remote(of: ghost) == nil)
        #expect(refs.branchesWithoutRemote.map(\.name) == ["ghost/x"])
        #expect(!refs.remoteNames.contains("ghost"))
    }

    @Test func aRepositoryWithNoRemotesHasNone() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        let refs = try await refs(repo)
        #expect(refs.remotes == [])
        #expect(refs.remoteNames == [])
        #expect(refs.branchesWithoutRemote == [])
    }
}
