import Foundation
import Testing

@testable import GitCore

/// A configured fetch refspec whose destination is outside `refs/remotes/` turns every Gitter
/// fetch — the automatic one every ten minutes included — into a write to the user's own
/// branches and tags. Measured in the final review (`frqa/ia`): with
/// `remote.origin.fetch=+refs/heads/*:refs/heads/*` and HEAD on a branch the server does not
/// have, `git fetch --progress --no-prune --all` force-moved a diverged local `topic`
/// (`topic@{0}: fetch --progress --no-prune --all: forced-update`), leaving its commit on no
/// ref. git protects only the checked-out branch.
///
/// `fetch` now reads `git config --get-all remote.<name>.fetch` first and throws
/// `.unsafeFetchRefspec` **before git contacts anything** — proved by an upload-pack wrapper
/// that leaves a marker when it runs, and that is shown to leave one for a safe fetch.
@Suite struct UnsafeFetchRefspecTests {
    /// The fixture every test here shares: `origin` with `main` and `feat/x` (= `feature`), a
    /// local `feat/x` with a commit of its own (diverged from the server's), a local tag `v1`
    /// the server has a different `v1` for, and HEAD on `unpublished`, which the server does not
    /// have — the shape in which git's checked-out-branch protection protects nothing.
    private struct Fixture {
        let repo: TestRepo
        let origin: URL
        let marker: URL
        let localFeatX: String
        let localTag: String

        static func make() async throws -> Fixture {
            let repo = try await TestRepo.makeBranched()
            let origin = try await repo.addOriginWithFeatureBranch()
            try await repo.git(["push", "-q", "origin", "refs/heads/feature:refs/tags/v1"])
            try await repo.git(["switch", "-q", "-c", "feat/x", "main"])
            try repo.write("mine.txt", "only here\n")
            try await repo.commitAll("a commit only the local feat/x has")
            try await repo.git(["switch", "-q", "-c", "unpublished", "main"])
            let marker = try Self.installUploadPackMarker(for: "origin", origin: origin, in: repo)
            try await repo.git(["config", "remote.origin.uploadpack", marker.script.path])
            return Fixture(
                repo: repo, origin: origin, marker: marker.file,
                localFeatX: try await repo.revParse("refs/heads/feat/x"),
                localTag: try await repo.revParse("refs/tags/v1"))
        }

        /// A wrapper around `git upload-pack` that touches `file` first. It lives in the bare
        /// repository's directory, so the worktree snapshot does not see it.
        static func installUploadPackMarker(
            for remote: String, origin: URL, in repo: TestRepo
        ) throws -> (script: URL, file: URL) {
            let file = origin.appendingPathComponent("upload-pack-ran-\(remote)")
            let script = origin.appendingPathComponent("upload-pack-\(remote).sh")
            try "#!/bin/sh\ntouch '\(file.path)'\nexec git upload-pack \"$@\"\n"
                .write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: script.path)
            return (script, file)
        }

        var markerFired: Bool { FileManager.default.fileExists(atPath: marker.path) }

        func setFetchRefspecs(_ refspecs: [String], remote: String = "origin") async throws {
            try await repo.git(["config", "--unset-all", "remote.\(remote).fetch"], allowedExitCodes: [5])
            for refspec in refspecs {
                try await repo.git(["config", "--add", "remote.\(remote).fetch", refspec])
            }
        }

        func cleanUp() {
            repo.cleanUp()
            try? FileManager.default.removeItem(at: origin)
        }
    }

    static let unsafe = [
        "+refs/heads/*:refs/heads/*",
        "refs/heads/feat/x:refs/heads/feat/x",
        "+refs/tags/*:refs/tags/*",
        "+refs/*:refs/*",
    ]

    /// Not vacuous: the fixture really is dangerous. git itself, run with the refspec Gitter
    /// refuses, moves the local branch (or the tag) and runs upload-pack.
    @Test(arguments: ["+refs/heads/*:refs/heads/*", "+refs/tags/*:refs/tags/*"])
    func gitItselfWouldMoveTheLocalRef(refspec: String) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        try await fixture.setFetchRefspecs(["+refs/heads/*:refs/remotes/origin/*", refspec])

        try await fixture.repo.git(["fetch", "-q", "--no-prune", "origin"])

        #expect(fixture.markerFired)
        let featX = try await fixture.repo.revParse("refs/heads/feat/x")
        let tag = try await fixture.repo.revParse("refs/tags/v1")
        #expect(featX != fixture.localFeatX || tag != fixture.localTag, "the fixture is not dangerous, so the refusal tests prove nothing")
    }

    @Test(arguments: unsafe)
    func aNamedRemoteWithAnUnsafeRefspecIsRefusedBeforeGitRuns(refspec: String) async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        try await fixture.setFetchRefspecs(["+refs/heads/*:refs/remotes/origin/*", refspec])
        let state = try await RepoState.capture(fixture.repo)
        let worktree = worktreeSnapshot(fixture.repo)

        let error = await remoteError {
            try await CLIGitBackend().fetch(remote: "origin", at: fixture.repo.root, progress: { _ in })
        }

        #expect(error == .unsafeFetchRefspec(remote: "origin", refspec: refspec))
        #expect(!fixture.markerFired, "git contacted the remote")
        try await assertRepoUnchanged(fixture.repo, since: state, worktree: worktree)
        #expect(try await fixture.repo.revParse("refs/heads/feat/x") == fixture.localFeatX)
        #expect(try await fixture.repo.revParse("refs/tags/v1") == fixture.localTag)
    }

    /// The same fixture with the default refspec, plus a negative one, a bare source and an
    /// empty destination: the fetch runs (the marker fires) and no local ref moves.
    @Test func aSafeRefspecFetchesAndTheMarkerFires() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        try await fixture.setFetchRefspecs([
            "+refs/heads/*:refs/remotes/origin/*", "^refs/heads/nothing", "refs/heads/main",
            "refs/heads/feat/x:",
        ])

        try await CLIGitBackend().fetch(remote: "origin", at: fixture.repo.root, progress: { _ in })

        #expect(fixture.markerFired)
        #expect(try await fixture.repo.revParse("refs/heads/feat/x") == fixture.localFeatX)
        #expect(try await fixture.repo.revParse("refs/tags/v1") == fixture.localTag)
    }

    /// `--all`: the unsafe remote is skipped, every other remote is still fetched (one by one),
    /// and the skip is thrown afterwards. Not a no-op, and the doc comment says so.
    @Test func fetchAllSkipsTheUnsafeRemoteFetchesTheRestAndSaysSo() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let mirror = try await fixture.repo.addEmptyRemote(named: "mirror")
        defer { try? FileManager.default.removeItem(at: mirror) }
        try await fixture.repo.git(["push", "-q", "mirror", "refs/heads/feature:refs/heads/feat/x"])
        let mirrorMarker = try Fixture.installUploadPackMarker(
            for: "mirror", origin: mirror, in: fixture.repo)
        try await fixture.repo.git(["config", "remote.mirror.uploadpack", mirrorMarker.script.path])
        try await fixture.setFetchRefspecs(["+refs/heads/*:refs/heads/*"], remote: "mirror")
        // Something for origin's fetch to bring, so "the rest were fetched" is observable.
        let colleague = try await fixture.repo.addColleague()
        defer { colleague.cleanUp() }
        try colleague.write("c.txt", "theirs\n")
        try await colleague.commitAll("the colleague's commit")
        try await colleague.git(["push", "-q", "origin", "main"])
        let theirs = try await colleague.headSha()

        let error = await remoteError {
            try await CLIGitBackend().fetch(remote: nil, at: fixture.repo.root, progress: { _ in })
        }

        #expect(error == .unsafeFetchRefspec(remote: "mirror", refspec: "+refs/heads/*:refs/heads/*"))
        #expect(!FileManager.default.fileExists(atPath: mirrorMarker.file.path), "mirror was contacted")
        #expect(fixture.markerFired, "origin was not fetched")
        #expect(try await fixture.repo.revParse("refs/remotes/origin/main") == theirs)
        #expect(try await fixture.repo.revParse("refs/heads/feat/x") == fixture.localFeatX)
        #expect(try await fixture.repo.currentBranch() == "unpublished")
    }

    /// `remote.<name>.skipFetchAll=true` keeps a remote out of `--all` in git itself, so its
    /// refspec is not a reason to refuse — and `--all` runs as before.
    @Test func anUnsafeRemoteThatFetchAllSkipsAnywayIsNotReported() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let mirror = try await fixture.repo.addEmptyRemote(named: "mirror")
        defer { try? FileManager.default.removeItem(at: mirror) }
        try await fixture.setFetchRefspecs(["+refs/heads/*:refs/heads/*"], remote: "mirror")
        try await fixture.repo.git(["config", "remote.mirror.skipFetchAll", "true"])

        try await CLIGitBackend().fetch(remote: nil, at: fixture.repo.root, progress: { _ in })

        #expect(fixture.markerFired)
        #expect(try await fixture.repo.revParse("refs/heads/feat/x") == fixture.localFeatX)
    }

    /// Adds a safe remote `name` with `main` on it and an upload-pack marker, and returns the
    /// bare repository and the marker's file.
    private static func addMarkedRemote(
        _ name: String, to fixture: Fixture
    ) async throws -> (bare: URL, marker: URL) {
        let bare = try await fixture.repo.addEmptyRemote(named: name)
        try await fixture.repo.git(["push", "-q", name, "refs/heads/main:refs/heads/main"])
        let marker = try Fixture.installUploadPackMarker(for: name, origin: bare, in: fixture.repo)
        try await fixture.repo.git(["config", "remote.\(name).uploadpack", marker.script.path])
        return (bare, marker.file)
    }

    /// `skipFetchAll` on a **safe** remote: `--all` never fetches it, so neither may the
    /// one-by-one fallback an unsafe remote elsewhere forces (re-review: `fork`'s marker fired
    /// on every tick). `third` is still fetched and `origin`'s skip is still thrown.
    @Test func theFallbackLeavesOutASafeRemoteThatFetchAllSkips() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let fork = try await Self.addMarkedRemote("fork", to: fixture)
        defer { try? FileManager.default.removeItem(at: fork.bare) }
        let third = try await Self.addMarkedRemote("third", to: fixture)
        defer { try? FileManager.default.removeItem(at: third.bare) }
        try await fixture.repo.git(["config", "remote.fork.skipFetchAll", "true"])
        try await fixture.setFetchRefspecs(["+refs/heads/*:refs/heads/*"])

        let error = await remoteError {
            try await CLIGitBackend().fetch(remote: nil, at: fixture.repo.root, progress: { _ in })
        }

        #expect(error == .unsafeFetchRefspec(remote: "origin", refspec: "+refs/heads/*:refs/heads/*"))
        #expect(FileManager.default.fileExists(atPath: third.marker.path), "third was not fetched")
        #expect(!FileManager.default.fileExists(atPath: fork.marker.path), "fork was fetched")
        #expect(!fixture.markerFired, "origin was contacted")
        #expect(try await fixture.repo.revParse("refs/heads/feat/x") == fixture.localFeatX)
    }

    /// The control: the same remotes with nothing unsafe run the plain `--all`, and git itself
    /// leaves `fork` out — the behaviour the fallback above has to match.
    @Test func plainFetchAllLeavesOutASafeRemoteThatSkipsIt() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        let fork = try await Self.addMarkedRemote("fork", to: fixture)
        defer { try? FileManager.default.removeItem(at: fork.bare) }
        let third = try await Self.addMarkedRemote("third", to: fixture)
        defer { try? FileManager.default.removeItem(at: third.bare) }
        try await fixture.repo.git(["config", "remote.fork.skipFetchAll", "true"])

        try await CLIGitBackend().fetch(remote: nil, at: fixture.repo.root, progress: { _ in })

        #expect(FileManager.default.fileExists(atPath: third.marker.path), "third was not fetched")
        #expect(!FileManager.default.fileExists(atPath: fork.marker.path), "fork was fetched")
        #expect(fixture.markerFired, "origin was not fetched")
    }

    /// `--all` where every remote is unsafe: nothing is contacted at all.
    @Test func fetchAllWithOnlyUnsafeRemotesContactsNothing() async throws {
        let fixture = try await Fixture.make()
        defer { fixture.cleanUp() }
        try await fixture.setFetchRefspecs(["+refs/*:refs/*"])
        let state = try await RepoState.capture(fixture.repo)

        let error = await remoteError {
            try await CLIGitBackend().fetch(remote: nil, at: fixture.repo.root, progress: { _ in })
        }

        #expect(error == .unsafeFetchRefspec(remote: "origin", refspec: "+refs/*:refs/*"))
        #expect(!fixture.markerFired)
        #expect(try await RepoState.capture(fixture.repo) == state)
    }
}
