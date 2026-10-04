import Foundation
import Testing

@testable import GitCore

/// `GitRemoteAdminBackend.goneBranches` (B2 Task 1, R9): local branches whose configured
/// upstream no longer exists.
@Suite struct GoneBranchTests {
    let backend = CLIGitBackend()

    /// `PruneFixture` (the server deleted `gone1` and `gone2`) plus local branches:
    /// - `gone1` tracking `origin/gone1`, holding `G1only`'s commit and one more of its own;
    /// - `onlocal` tracking the local `base`, which is then deleted (a `.` upstream gone);
    /// - `noremote` whose `branch.noremote.remote` names a remote that does not exist;
    /// - `tracked` tracking `origin/keep`, which is still there;
    /// - `plain`, with no upstream.
    /// Then the tracking refs of the deleted server branches are pruned.
    static func make() async throws -> (PruneFixture, extra: String) {
        let fixture = try await PruneFixture.make()
        let repo = fixture.repo
        try await repo.git(["branch", "-q", "--track", "gone1", PruneFixture.gone1Ref])
        try await repo.git(["switch", "-q", "gone1"])
        let extra = try await repo.commit("own.txt", "own", "own commit")
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["branch", "-q", "base", "main"])
        try await repo.git(["branch", "-q", "--track", "onlocal", "base"])
        try await repo.git(["branch", "-q", "-D", "base"])
        try await repo.git(["branch", "-q", "noremote", "main"])
        try await repo.git(["config", "branch.noremote.remote", "ghost"])
        try await repo.git(["config", "branch.noremote.merge", "refs/heads/noremote"])
        try await repo.git(["branch", "-q", "--track", "tracked", "refs/remotes/origin/keep"])
        try await repo.git(["branch", "-q", "--no-track", "plain", "main"])
        try await repo.git(["update-ref", "-d", PruneFixture.gone1Ref])
        try await repo.git(["update-ref", "-d", PruneFixture.gone2Ref])
        return (fixture, extra)
    }

    /// Remote and local (`.`) upstreams gone are listed; a missing remote, a live upstream and no
    /// upstream are not. `uniqueCommits` is the branch delete's own count.
    @Test func remoteAndLocalUpstreamsGoneAreListed() async throws {
        let (fixture, extra) = try await Self.make()
        defer { fixture.cleanUp() }
        let main = try await fixture.repo.revParse("main")

        let gone = try await backend.goneBranches(at: fixture.repo.root)

        #expect(gone == [
            GoneBranch(name: "gone1", tip: extra, upstream: PruneFixture.gone1Ref, uniqueCommits: 2, checkedOutAt: nil),
            GoneBranch(name: "onlocal", tip: main, upstream: "refs/heads/base", uniqueCommits: 0, checkedOutAt: nil),
        ])
    }

    /// RF5: a gone branch checked out here, or in another worktree, says where — git refuses to
    /// delete it there (R10).
    @Test func checkedOutAtNamesTheWorktree() async throws {
        let (fixture, _) = try await Self.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let linked = repo.root.deletingLastPathComponent()
            .appendingPathComponent("\(repo.root.lastPathComponent)-gone-wt", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: linked) }
        try await repo.git(["switch", "-q", "gone1"])
        try await repo.git(["worktree", "add", "-q", linked.path, "onlocal"])

        let gone = try await backend.goneBranches(at: repo.root)

        let paths = Dictionary(uniqueKeysWithValues: gone.map { ($0.name, $0.checkedOutAt) })
        #expect(gone.map(\.name) == ["gone1", "onlocal"])
        #expect(paths["gone1"]?.map(Self.real) == Self.real(repo.root.path))
        #expect(paths["onlocal"]?.map(Self.real) == Self.real(linked.path))
    }

    /// Ruling 2: another process holding `config.lock` changes nothing about the list.
    @Test func aHeldConfigLockChangesNothing() async throws {
        let (fixture, _) = try await Self.make()
        defer { fixture.cleanUp() }
        let expected = try await backend.goneBranches(at: fixture.repo.root)
        #expect(expected.count == 2)
        let lock = fixture.repo.root.appendingPathComponent(".git/config.lock")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }

        #expect(try await backend.goneBranches(at: fixture.repo.root) == expected)
    }

    /// Nothing gone: an empty list.
    @Test func nothingGoneIsAnEmptyList() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        try await repo.git(["branch", "-q", "--track", "x", "refs/remotes/origin/feat/x"])

        #expect(try await backend.goneBranches(at: repo.root) == [])
    }

    /// `/var` and `/private/var` are one directory on macOS; compare real paths.
    static func real(_ path: String) -> String {
        URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
    }
}

/// `remoteHEADTarget` and `branchConfigKeys` (B2 Task 4): the two reads the app's prune and
/// clean-up sheets need to say what git leaves behind.
@Suite struct LeftBehindReadTests {
    let backend = CLIGitBackend()

    /// `<remote>/HEAD`'s target, in full; nil once it is gone, and nil while it dangles.
    @Test func theRemoteHEADTargetIsReadInFull() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["symbolic-ref", "refs/remotes/origin/HEAD", PruneFixture.gone1Ref])

        #expect(try await backend.remoteHEADTarget(of: "origin", at: repo.root) == PruneFixture.gone1Ref)

        try await repo.git(["update-ref", "--no-deref", "-d", PruneFixture.gone1Ref])
        #expect(try await backend.remoteHEADTarget(of: "origin", at: repo.root) == nil, "dangling")

        try await repo.git(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"])
        #expect(try await backend.remoteHEADTarget(of: "origin", at: repo.root) == nil, "none")
    }

    /// Only `refs/remotes/<remote>/HEAD` itself: a ref beneath it, or another remote's HEAD, is
    /// not the answer; a name git would read as an option is refused before git runs.
    @Test func onlyThatRemotesOwnHEADCounts() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        _ = try? await repo.git(["symbolic-ref", "--delete", "refs/remotes/origin/HEAD"], allowedExitCodes: [1])
        try await repo.git(["symbolic-ref", "refs/remotes/other/HEAD", PruneFixture.gone2Ref])

        #expect(try await backend.remoteHEADTarget(of: "origin", at: repo.root) == nil)
        #expect(try await backend.remoteHEADTarget(of: "other", at: repo.root) == PruneFixture.gone2Ref)
        let refused = await thrownError { _ = try await backend.remoteHEADTarget(of: "-x", at: repo.root) }
        #expect(refused as? RemoteOperationError == .noRemote)
    }

    /// Ruling 2, R27: `branch -D` under a `config.lock` another process holds deletes the branch,
    /// exits 0 and leaves its section — read back here, exactly; without the lock nothing is left.
    @Test func aDeleteUnderAHeldConfigLockLeavesTheSectionAndItIsRead() async throws {
        let (fixture, extra) = try await GoneBranchTests.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        #expect(try await backend.branchConfigKeys(of: "gone1", at: repo.root) == ["branch.gone1.remote", "branch.gone1.merge"])

        let lock = repo.root.appendingPathComponent(".git/config.lock")
        try Data().write(to: lock)
        try await backend.forceDeleteBranch("gone1", expectedTip: extra, at: repo.root)
        try FileManager.default.removeItem(at: lock)

        #expect(try await repo.gitRefExists("refs/heads/gone1") == false)
        #expect(try await backend.branchConfigKeys(of: "gone1", at: repo.root) == ["branch.gone1.remote", "branch.gone1.merge"])

        let main = try await repo.revParse("onlocal")
        try await backend.forceDeleteBranch("onlocal", expectedTip: main, at: repo.root)
        #expect(try await backend.branchConfigKeys(of: "onlocal", at: repo.root) == [])
    }

    /// A dotted branch name is its own section: `x` does not own `branch.x.y.remote`.
    @Test func aDottedNameIsItsOwnSection() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["config", "branch.x.remote", "origin"])
        try await repo.git(["config", "branch.x.pushRemote", "fork"])
        try await repo.git(["config", "branch.x.y.remote", "o2"])

        #expect(try await backend.branchConfigKeys(of: "x", at: repo.root) == ["branch.x.remote", "branch.x.pushremote"])
        #expect(try await backend.branchConfigKeys(of: "x.y", at: repo.root) == ["branch.x.y.remote"])
        let refused = await thrownError { _ = try await backend.branchConfigKeys(of: "-x", at: repo.root) }
        #expect(refused as? BranchOperationError == .invalidName("-x"))
    }
}
