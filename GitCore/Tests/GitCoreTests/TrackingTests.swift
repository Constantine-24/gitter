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

    // MARK: - Push target

    /// (a) With no push configuration at all, `%(push:remotename)` is the upstream's remote,
    /// and `%(push:remoteref)` is empty — measured, and it is empty here on purpose: git only
    /// fills it from an explicit `remote.<name>.push` refspec.
    @Test func aPlainTrackingBranchPushesToItsUpstreamsRemote() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["branch", "--set-upstream-to=origin/main", "main"])

        let main = try await main(repo)
        #expect(main.pushRemote == "origin")
        #expect(main.pushRef == nil)
        #expect(main.upstreamRemote == "origin")
    }

    /// (b) `branch.<name>.pushRemote` sends a push somewhere other than where the branch
    /// fetches from. Reading the upstream's remote here would push to the wrong repository.
    @Test func aBranchPushRemoteOverridesTheUpstreamsRemote() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        let fork = try await repo.addEmptyRemote(named: "fork")
        defer { try? FileManager.default.removeItem(at: fork) }
        try await repo.git(["branch", "--set-upstream-to=origin/main", "main"])
        try await repo.git(["config", "branch.main.pushRemote", "fork"])

        let main = try await main(repo)
        #expect(main.upstreamRemote == "origin")
        #expect(main.pushRemote == "fork")
        #expect(main.pushRef == nil)
    }

    /// (c) `remote.pushDefault` does the same for every branch at once.
    @Test func remotePushDefaultOverridesTheUpstreamsRemote() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        let fork = try await repo.addEmptyRemote(named: "fork")
        defer { try? FileManager.default.removeItem(at: fork) }
        try await repo.git(["branch", "--set-upstream-to=origin/main", "main"])
        try await repo.git(["config", "remote.pushDefault", "fork"])

        let main = try await main(repo)
        #expect(main.upstreamRemote == "origin")
        #expect(main.pushRemote == "fork")
    }

    /// (e) A branch with no upstream at all still has a push target when `remote.pushDefault`
    /// is set — measured: `git push` publishes it without being told where.
    @Test func aBranchWithNoUpstreamStillHasAPushRemoteUnderPushDefault() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let fork = try await repo.addEmptyRemote(named: "fork")
        defer { try? FileManager.default.removeItem(at: fork) }
        try await repo.git(["config", "remote.pushDefault", "fork"])

        let feature = try #require(try await refs(repo).localBranches.first { $0.name == "feature" })
        #expect(feature.upstream == nil)
        #expect(feature.upstreamRemote == nil)
        #expect(feature.pushRemote == "fork")
        #expect(feature.tracking == .none)
    }

    /// (f) An upstream that is another local branch gives `.` for the push remote too, and `.`
    /// is not a remote.
    @Test func aLocalUpstreamGivesNoPushRemote() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "-c", "topic"])
        try await repo.git(["branch", "--set-upstream-to=main", "topic"])

        let topic = try #require(try await refs(repo).localBranches.first { $0.name == "topic" })
        #expect(topic.tracksLocalBranch)
        #expect(topic.pushRemote == nil)
        #expect(topic.pushRef == nil)
    }

    /// (g) The upstream's ref name differs from the branch's own name. The remote is still
    /// reported, but `%(push:remoteref)` stays empty — and under the default `push.default`
    /// (`simple`) git *refuses* a bare `git push` here. Nothing in the model may be read as
    /// "push to `refs/heads/main`".
    @Test func aDifferentlyNamedUpstreamKeepsTheRemoteButHasNoPushRef() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["switch", "-q", "-c", "topic"])
        try await repo.git(["branch", "--set-upstream-to=origin/main", "topic"])

        let topic = try #require(try await refs(repo).localBranches.first { $0.name == "topic" })
        #expect(topic.upstreamRemote == "origin")
        #expect(topic.upstreamRef == "refs/heads/main")
        #expect(topic.pushRemote == "origin")
        #expect(topic.pushRef == nil, "git fills push:remoteref only from a push refspec")
    }

    /// The only configuration that fills `pushRef`: an explicit `remote.<name>.push` refspec.
    /// Measured: a bare `git push` then really does write `refs/heads/prefix-main`.
    @Test func anExplicitPushRefspecFillsThePushRef() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: remote) }
        try await repo.git(["branch", "--set-upstream-to=origin/main", "main"])
        try await repo.git(["config", "remote.origin.push",
                            "refs/heads/*:refs/heads/prefix-*"])

        let main = try await main(repo)
        #expect(main.pushRemote == "origin")
        #expect(main.pushRef == "refs/heads/prefix-main")
        #expect(main.upstreamRef == "refs/heads/main", "the fetch side is unchanged")
    }

    // MARK: - Remotes

    /// `refs/remotes/up/stream/HEAD` is symbolic, exactly as `origin/HEAD` is, but the old rule
    /// looked for "HEAD" after the *first* slash — saw "stream/HEAD" — and listed it as a
    /// branch of `up/stream`.
    @Test func theSymbolicHeadOfASlashNamedRemoteIsNotABranch() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let remote = try await repo.addOriginWithFeatureBranch(named: "up/stream")
        defer { try? FileManager.default.removeItem(at: remote) }
        // Measured on git 2.54: the first fetch writes the remote's HEAD. Assert it is really
        // there, so this test cannot pass merely because the ref is missing.
        #expect(try await repo.symbolicRef("refs/remotes/up/stream/HEAD")
                == "refs/remotes/up/stream/main")

        let refs = try await refs(repo)
        let upstream = try #require(refs.remotes.first { $0.name == "up/stream" })
        #expect(refs.branches(of: upstream).map(\.name) == ["up/stream/feat/x", "up/stream/main"])
        #expect(refs.branchesWithoutRemote == [])
        #expect(!refs.remoteBranches.contains { $0.name.hasSuffix("/HEAD") })
    }

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
