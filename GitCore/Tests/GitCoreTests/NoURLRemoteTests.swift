import Foundation
import Testing

@testable import GitCore

/// `UpstreamFixture` plus a remote `vendor` configured with **no URL** (only a fetch refspec) and,
/// in the worktree, a nested repository that happens to be called `vendor` — a checkout or a
/// submodule of that name. git uses a no-URL remote's **name as a path** (fix round 1, I1,
/// measured): `git fetch vendor` fetched that directory's branches, and `git push vendor
/// :refs/heads/topic` deleted its `topic`. Plus `po`, a remote with only a push URL, whose fetch
/// side is the same hazard.
struct NoURLFixture {
    let upstream: UpstreamFixture
    let nested: URL
    var repo: TestRepo { upstream.repo }

    static func make() async throws -> NoURLFixture {
        let upstream = try await UpstreamFixture.make()
        let repo = upstream.repo
        try await repo.git(["config", "remote.vendor.fetch", "+refs/heads/*:refs/remotes/vendor/*"])
        try await repo.git(["config", "remote.po.pushurl", upstream.origin.path])
        let nested = repo.root.appendingPathComponent("vendor", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let runner = isolatedRunner()
        for arguments in [
            ["init", "-q", "-b", "main", "."], ["config", "user.email", "n@example.invalid"],
            ["config", "user.name", "N"], ["commit", "-q", "--allow-empty", "-m", "nested"],
            ["branch", "topic"], ["tag", "v9"],
        ] {
            _ = try await runner.run("/usr/bin/git", arguments, cwd: nested)
        }
        return NoURLFixture(upstream: upstream, nested: nested)
    }

    func cleanUp() { upstream.cleanUp() }
}

/// Fix round 1, I1: every network operation refuses a remote git has no URL for — before any
/// fetch, push or `ls-remote` runs — with `RemoteOperationError.noURL(remote)`. The only process
/// is the read of `git remote -v` that answers the question.
@Suite struct NoURLRemoteTests {
    let tip = "1111111111111111111111111111111111111111"

    /// Each operation, against the no-URL remote: refused, nothing fetched into this repository,
    /// nothing changed in the directory git would have used as the remote.
    @Test(arguments: ["fetch", "push", "forcePush", "deleteRemoteBranch", "pushTag", "deleteRemoteTag", "remoteTagID", "prunePlan"])
    func aRemoteWithNoURLIsRefusedBeforeGitTalksToIt(operation: String) async throws {
        let fixture = try await NoURLFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let nested = try await RemoteState.capture(fixture.nested)
        let before = try await RepoState.capture(repo)
        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        let backend = git.backend
        let root = repo.root

        let error = await thrownError {
            switch operation {
            case "fetch": try await backend.fetch(remote: "vendor", at: root, progress: { _ in })
            case "push": _ = try await backend.push("main", to: "vendor", remoteRef: "refs/heads/main", setUpstream: true, at: root, progress: { _ in })
            case "forcePush": _ = try await backend.forcePush("main", to: "vendor", remoteRef: "refs/heads/topic", expectedRemoteTip: tip, expectedLocalTip: tip, at: root, progress: { _ in })
            case "deleteRemoteBranch": _ = try await backend.deleteRemoteBranch("topic", on: "vendor", expectedTip: tip, at: root)
            case "pushTag": _ = try await backend.pushTag("v1", to: "vendor", at: root)
            case "deleteRemoteTag": try await backend.deleteRemoteTag("v9", on: "vendor", expecting: tip, at: root)
            case "remoteTagID": _ = try await backend.remoteTagID("v9", on: "vendor", at: root)
            default: _ = try await backend.prunePlan("vendor", at: root)
            }
        }

        #expect(error as? RemoteOperationError == .noURL("vendor"), "\(operation): \(String(describing: error))")
        #expect(git.launches.allSatisfy { ["remote", "config"].contains($0) }, "\(operation): \(git.launches)")
        #expect(!git.launches.isEmpty)
        #expect(try await RepoState.capture(repo) == before)
        try await assertRemoteUnchanged(fixture.nested, since: nested)
    }

    /// A remote with only a push URL has nothing to fetch from: its fetch side is the same name
    /// used as a path. Pushing through it is not refused.
    @Test func aPushOnlyRemoteIsRefusedForReadsOnly() async throws {
        let fixture = try await NoURLFixture.make()
        defer { fixture.cleanUp() }
        let root = fixture.repo.root
        let backend = CLIGitBackend()

        let fetch = await thrownError { try await backend.fetch(remote: "po", at: root, progress: { _ in }) }
        let read = await thrownError { _ = try await backend.remoteTagID("v1", on: "po", at: root) }
        #expect(fetch as? RemoteOperationError == .noURL("po"))
        #expect(read as? RemoteOperationError == .noURL("po"))

        let pushed = try await backend.pushTag("v1", to: "po", at: root)
        #expect(pushed == .pushed)
    }

    /// Fetch All (and so auto-fetch) skips a remote with no URL — `fetch --all` visited it and
    /// used its name as a path — and fetches the rest; nothing is thrown for the skip.
    @Test func fetchAllSkipsARemoteWithNoURL() async throws {
        let fixture = try await NoURLFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let nested = try await RemoteState.capture(fixture.nested)
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }
        try await colleague.git(["switch", "-q", "-c", "fresh"])
        _ = try await colleague.commit("f.txt", "f", "fresh")
        try await colleague.git(["push", "-q", "origin", "fresh"])

        try await CLIGitBackend().fetch(remote: nil, at: repo.root, progress: { _ in })

        #expect(try await repo.gitRefExists("refs/remotes/origin/fresh"))
        #expect(try await repo.refTips(under: "refs/remotes/vendor").isEmpty)
        try await assertRemoteUnchanged(fixture.nested, since: nested)
    }
}
