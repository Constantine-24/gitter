import Foundation
import Testing

@testable import GitCore

/// Ahead/behind, the upstream's remote, and the remotes themselves — read from a real
/// repository through `CLIGitBackend.snapshot`, not from a hand-written fixture.
@Suite struct TrackingTests {
    private let backend = CLIGitBackend()

    private func refs(_ repo: TestRepo) async throws -> RefCollection {
        try await backend.snapshot(at: repo.root).refs
    }

    private func main(_ repo: TestRepo) async throws -> Branch {
        try #require(try await refs(repo).localBranches.first { $0.name == "main" })
    }

    // MARK: - Tracking

    @Test func aLevelBranchIsZeroAheadZeroBehind() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["branch", "--set-upstream-to=origin/main", "main"])

        let main = try await main(repo)
        #expect(main.tracking == .counts(ahead: 0, behind: 0))
        #expect(main.upstream == "origin/main")
        #expect(main.upstreamRemote == "origin")
        #expect(main.upstreamRef == "refs/heads/main")
    }

    @Test func oneLocalCommitIsOneAhead() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["branch", "--set-upstream-to=origin/main", "main"])
        try repo.write("ahead.txt", "ahead\n")
        try await repo.commitAll("one ahead")

        #expect(try await main(repo).tracking == .counts(ahead: 1, behind: 0))
    }

    @Test func aRemoteOnlyCommitIsBehind() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["branch", "--set-upstream-to=origin/main", "main"])
        // Move the remote-tracking ref forward without moving `main`: the same shape a fetch
        // that brought down someone else's commit leaves behind.
        try await repo.git(["update-ref", "refs/remotes/origin/main", "feature"])

        #expect(try await main(repo).tracking == .counts(ahead: 0, behind: 1))
    }

    @Test func divergenceIsCountedOnBothSides() async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["branch", "--set-upstream-to=origin/main", "main"])
        try await repo.git(["update-ref", "refs/remotes/origin/main", "feature"])

        #expect(try await main(repo).tracking == .counts(ahead: 1, behind: 1))
    }

    /// The upstream ref is gone (pruned elsewhere) while the configuration still names it.
    @Test func aDeletedUpstreamRefIsGone() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["branch", "--set-upstream-to=origin/main", "main"])
        try await repo.git(["update-ref", "-d", "refs/remotes/origin/main"])

        let main = try await main(repo)
        #expect(main.tracking == .gone)
        // Measured: git still reports the configured remote and ref for a gone upstream.
        #expect(main.upstreamRemote == "origin")
        #expect(main.upstreamRef == "refs/heads/main")
    }

    @Test func aBranchWithNoUpstreamHasNoTracking() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        let feature = try #require(try await refs(repo).localBranches.first { $0.name == "feature" })
        #expect(feature.tracking == .none)
        #expect(feature.upstream == nil)
        #expect(feature.upstreamRemote == nil)
        #expect(feature.upstreamRef == nil)
        #expect(feature.tracksLocalBranch == false)
    }

    /// `git branch --set-upstream-to=main topic` makes git report the remote as ".", which is
    /// not a remote at all — `git remote add .` is refused outright. It must never reach push.
    @Test func anUpstreamThatIsALocalBranchIsNotARemote() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "-c", "topic"])
        try await repo.git(["branch", "--set-upstream-to=main", "topic"])
        try repo.write("t.txt", "t\n")
        try await repo.commitAll("topic commit")

        let topic = try #require(try await refs(repo).localBranches.first { $0.name == "topic" })
        #expect(topic.upstream == "main")
        #expect(topic.upstreamRemote == nil, "\".\" is not a remote name")
        #expect(topic.upstreamRef == "refs/heads/main")
        #expect(topic.tracksLocalBranch)
        #expect(topic.tracking == .counts(ahead: 1, behind: 0))
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
