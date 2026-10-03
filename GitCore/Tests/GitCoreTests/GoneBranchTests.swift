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
