import Foundation
import Testing

@testable import GitCore

extension TestRepo {
    /// A second local bare repository beside this one, holding this repository's `main` — a
    /// server for Add Remote and Edit URL to point at. The caller removes it.
    func makeSecondServer(named name: String) async throws -> URL {
        let server = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-\(name).git", isDirectory: true)
        try FileManager.default.createDirectory(at: server, withIntermediateDirectories: true)
        _ = try await isolatedRunner().run("/usr/bin/git", ["init", "-q", "--bare", "-b", "main", "."], cwd: server)
        try await git(["push", "-q", server.path, "main"])
        return server
    }

    /// Every ref under `prefix` and the id it holds, in ref order.
    func refTips(under prefix: String) async throws -> [RefTip] {
        let data = try await git(["for-each-ref", "--format=%(refname)%00%(objectname)", prefix])
        return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { line in
            let fields = line.split(separator: "\u{0}", maxSplits: 1)
            return fields.count == 2 ? RefTip(ref: String(fields[0]), id: String(fields[1])) : nil
        }
    }

    /// The remotes the snapshot lists — `RemoteParser` reading `git remote -v`.
    func listedRemotes() async throws -> [Remote] {
        try await CLIGitBackend().snapshot(at: root).refs.remotes
    }
}

/// `GitRemoteAdminBackend`'s remote management (B2 Task 3): names, URLs as written, add,
/// set-url, rename, and what a failed rename left. Local bare remotes only; a URL that names a
/// network host is only ever stored and read back, never contacted.
@Suite struct RemoteAdminTests {
    let backend = CLIGitBackend()

    // MARK: - Names (RF5)

    /// Every problem a remote's name can have, against a repository holding `origin`, a remote
    /// with no URL (`nourl`) and a nested name (`up/stream`).
    @Test func eachNameProblemIsNamed() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "remote.nourl.fetch", "+refs/heads/*:refs/remotes/nourl/*"])
        try await repo.git(["remote", "add", "up/stream", "/nowhere/us.git"])

        let cases: [(String, RemoteNameProblem?)] = [
            ("", .empty), ("   ", .empty),
            ("-x", .invalid), ("-", .invalid), (".", .invalid), ("..", .invalid), ("a..b", .invalid),
            ("x.lock", .invalid), ("trail/", .invalid), ("/lead", .invalid), ("a b", .invalid),
            ("a:b", .invalid), ("a~b", .invalid), ("a@{b", .invalid), ("a*b", .invalid), ("a\u{7}b", .invalid),
            ("a\u{0}b", .invalid), (" origin", .invalid),
            ("HEAD", .reserved), ("@", .reserved),
            ("origin", .exists), ("Origin", .exists), ("nourl", .exists), ("UP/stream", .exists),
            ("origin/sub", .nested("origin")), ("ORIGIN/sub", .nested("origin")), ("up", .nested("up/stream")),
            ("up/stream/x", .nested("up/stream")),
            ("upstream", nil), ("ok-name", nil), ("Ok.Name_1", nil), ("ü", nil), ("up/stream2", nil), ("team/one", nil),
        ]
        for (name, expected) in cases {
            let problem = try await backend.remoteNameProblem(name, at: repo.root)
            #expect(problem == expected, "\(name.debugDescription)")
        }
    }

    /// A name with a problem is refused by Add Remote with nothing written — a leading `-` and
    /// an empty name before git runs at all.
    @Test func addRefusesANameWithAProblem() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let before = try await repo.localConfig()

        for (name, problem) in [("origin", RemoteNameProblem.exists), ("origin/x", .nested("origin")), ("HEAD", .reserved), ("a..b", .invalid)] {
            let error = await thrownError { try await backend.addRemote(name, url: fixture.origin.path, at: repo.root) }
            #expect(error as? RemoteAdminRefusal == .nameProblem(problem), "\(name)")
        }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        for (name, problem) in [("-x", RemoteNameProblem.invalid), ("", .empty)] {
            let error = await thrownError { try await git.backend.addRemote(name, url: fixture.origin.path, at: repo.root) }
            #expect(error as? RemoteAdminRefusal == .nameProblem(problem), "\(name)")
        }
        git.assertNothingRan()
        try await assertConfigUnchanged(repo, since: before)
    }

    /// git's own refusals of a name, measured (R19, R21, R22), read into the same refusals.
    @Test func gitsNameRefusalsAreReadIntoTheSameCases() {
        #expect(RemoteFailureParser.remoteAdminRefusal(stderr: "error: remote origin already exists.", name: "origin")
            == .nameProblem(.exists))
        #expect(RemoteFailureParser.remoteAdminRefusal(stderr: "fatal: 'a..b' is not a valid remote name", name: "a..b")
            == .nameProblem(.invalid))
        #expect(RemoteFailureParser.remoteAdminRefusal(
            stderr: "fatal: remote name 'u/sub' is a subset of existing remote 'u'", name: "u/sub") == .nameProblem(.nested("u")))
        #expect(RemoteFailureParser.remoteAdminRefusal(
            stderr: "fatal: remote name 'up' is a superset of existing remote 'up/stream'", name: "up") == .nameProblem(.nested("up/stream")))
        #expect(RemoteFailureParser.remoteAdminRefusal(stderr: "error: No such remote: 'nosuch'", name: "nosuch")
            == .noSuchRemote("nosuch"))
        #expect(RemoteFailureParser.remoteAdminRefusal(stderr: "error: No such remote 'nosuch'", name: "nosuch")
            == .noSuchRemote("nosuch"))
        #expect(RemoteFailureParser.remoteAdminRefusal(
            stderr: "warning: remote.origin.url has multiple values\nfatal: could not set 'remote.origin.url' to '/x.git'", name: "origin")
            == .severalURLs)
        #expect(RemoteFailureParser.remoteAdminRefusal(
            stderr: "error: could not lock config file .git/config: File exists", name: "origin") == nil)
    }

    // MARK: - URLs

    /// A URL Gitter does not write is refused before git runs, by Add Remote and Edit URL alike,
    /// for the fetch and the push URL.
    @Test(arguments: ["ext::sh -c touch% /tmp/pwned", "EXT::sh", "-oProxyCommand=x", "-", "", "   ", "/srv/a\nb.git", "/srv/a\tb.git"])
    func anUnsafeURLIsRefusedBeforeGitRuns(url: String) async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let before = try await repo.localConfig()
        let git = try GitLaunchLog()
        defer { git.cleanUp() }

        let add = await thrownError { try await git.backend.addRemote("second", url: url, at: repo.root) }
        let fetch = await thrownError { try await git.backend.setURLs(of: "origin", fetch: url, push: .unchanged, at: repo.root) }
        let push = await thrownError {
            try await git.backend.setURLs(of: "origin", fetch: fixture.origin.path, push: .set(url), at: repo.root)
        }

        #expect(add as? RemoteAdminRefusal == .unsafeURL)
        #expect(fetch as? RemoteAdminRefusal == .unsafeURL)
        #expect(push as? RemoteAdminRefusal == .unsafeURL)
        git.assertNothingRan()
        try await assertConfigUnchanged(repo, since: before)
    }

    /// Add writes the URL and the default refspec and fetches nothing; Gitter's own fetch then
    /// fetches from the local bare.
    @Test func addFetchesNothingAndAFetchAfterItDoes() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let second = try await repo.makeSecondServer(named: "second")
        defer { try? FileManager.default.removeItem(at: second) }
        let server = try await RemoteState.capture(second)

        try await backend.addRemote("second", url: second.path, at: repo.root)

        #expect(try await repo.configValues("remote.second.url") == [second.path])
        #expect(try await repo.configValues("remote.second.fetch") == ["+refs/heads/*:refs/remotes/second/*"])
        #expect(try await repo.refTips(under: "refs/remotes/second").isEmpty, "add fetched")
        #expect(try await repo.listedRemotes().contains(Remote(name: "second", fetchURL: second.path, pushURL: second.path)))
        try await assertRemoteUnchanged(second, since: server)

        try await backend.fetch(remote: "second", at: repo.root, progress: { _ in })
        #expect(try await repo.gitRefExists("refs/remotes/second/main"))
    }

    /// RF3: a repository-local `url.<base>.insteadOf` rewrites the configured URL. `remoteURLs`
    /// reports the URL as written, and the rewritten one only as where git connects; Edit URL
    /// writes what it is given. The rewrite points at the local bare, so the fetch through it
    /// proves the rewrite is real without leaving the machine.
    @Test func theConfiguredURLIsReportedAsWrittenAndTheRewrittenOneSeparately() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let written = "https://example.invalid/o/r.git"
        try await repo.git(["config", "url.\(fixture.origin.path).insteadOf", written])

        try await backend.setURLs(of: "origin", fetch: written, push: .unchanged, at: repo.root)
        let urls = try await backend.remoteURLs("origin", at: repo.root)

        #expect(urls == RemoteURLs(fetch: [written], push: [], effectiveFetch: fixture.origin.path))
        #expect(try await repo.configValues("remote.origin.url") == [written])
        // What `git remote -v` — and so the snapshot — shows is the rewritten URL: the reason an
        // Edit URL sheet must not be pre-filled from it (R20).
        #expect(try await repo.listedRemotes().first { $0.name == "origin" }?.fetchURL == fixture.origin.path)
        try await backend.fetch(remote: "origin", at: repo.root, progress: { _ in })
        #expect(try await repo.configValues("remote.origin.url") == [written])
    }

    /// A URL with no rewrite: the effective one is the configured one.
    @Test func aURLWithNoRewriteIsItsOwnEffectiveURL() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }

        let urls = try await backend.remoteURLs("origin", at: fixture.repo.root)

        #expect(urls == RemoteURLs(fetch: [fixture.origin.path], push: [], effectiveFetch: fixture.origin.path))
    }

    /// Edit URL sets the fetch URL and a push URL; a second push URL replaces the first; a nil
    /// push URL leaves it as it is.
    @Test func setsTheFetchAndThePushURL() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let second = try await repo.makeSecondServer(named: "second")
        defer { try? FileManager.default.removeItem(at: second) }

        try await backend.setURLs(of: "origin", fetch: fixture.origin.path, push: .set(second.path), at: repo.root)
        #expect(try await repo.configValues("remote.origin.url") == [fixture.origin.path])
        #expect(try await repo.configValues("remote.origin.pushurl") == [second.path])
        #expect(try await backend.remoteURLs("origin", at: repo.root).push == [second.path])

        try await backend.setURLs(of: "origin", fetch: second.path, push: .set("/srv/third.git"), at: repo.root)
        #expect(try await repo.configValues("remote.origin.url") == [second.path])
        #expect(try await repo.configValues("remote.origin.pushurl") == ["/srv/third.git"])

        try await backend.setURLs(of: "origin", fetch: fixture.origin.path, push: .unchanged, at: repo.root)
        #expect(try await repo.configValues("remote.origin.url") == [fixture.origin.path])
        #expect(try await repo.configValues("remote.origin.pushurl") == ["/srv/third.git"])
    }

    /// Several `url` values — or several `pushurl` values when a push URL is being set — make a
    /// plain `set-url` fail (R22): refused, nothing written. `remoteURLs` shows them all.
    @Test func severalURLsAreRefused() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "--add", "remote.origin.url", "/srv/elsewhere.git"])
        let before = try await repo.localConfig()

        let error = await thrownError { try await backend.setURLs(of: "origin", fetch: "/srv/new.git", push: .unchanged, at: repo.root) }

        #expect(error as? RemoteAdminRefusal == .severalURLs)
        try await assertConfigUnchanged(repo, since: before)
        #expect(try await backend.remoteURLs("origin", at: repo.root).fetch == [fixture.origin.path, "/srv/elsewhere.git"])

        try await repo.git(["config", "--unset-all", "remote.origin.url"])
        try await repo.git(["config", "remote.origin.url", fixture.origin.path])
        try await repo.git(["config", "--add", "remote.origin.pushurl", "/srv/p1.git"])
        try await repo.git(["config", "--add", "remote.origin.pushurl", "/srv/p2.git"])
        let beforePush = try await repo.localConfig()
        let push = await thrownError {
            try await backend.setURLs(of: "origin", fetch: "/srv/new.git", push: .set("/srv/p3.git"), at: repo.root)
        }
        #expect(push as? RemoteAdminRefusal == .severalURLs)
        try await assertConfigUnchanged(repo, since: beforePush)
    }

    /// A remote that is not configured is refused by name; a name that is an option, before git
    /// runs.
    @Test func anUnknownRemoteIsRefused() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let root = fixture.repo.root

        #expect(await thrownError { _ = try await backend.remoteURLs("nosuch", at: root) } as? RemoteAdminRefusal == .noSuchRemote("nosuch"))
        #expect(await thrownError { try await backend.setURLs(of: "nosuch", fetch: "/srv/x.git", push: .unchanged, at: root) } as? RemoteAdminRefusal
            == .noSuchRemote("nosuch"))
        #expect(await thrownError { try await backend.renameRemote("nosuch", to: "other", at: root) } as? RemoteAdminRefusal
            == .noSuchRemote("nosuch"))

        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        #expect(await thrownError { _ = try await git.backend.remoteURLs("-x", at: root) } as? RemoteOperationError == .noRemote)
        #expect(await thrownError { try await git.backend.setURLs(of: "-x", fetch: "/srv/x.git", push: .unchanged, at: root) } as? RemoteOperationError == .noRemote)
        #expect(await thrownError { try await git.backend.renameRemote("-x", to: "other", at: root) } as? RemoteOperationError == .noRemote)
        git.assertNothingRan()
    }

    // MARK: - A remote with no URL (R22)

    /// A remote configured with no URL is listed — `fetchURL == nil` — has no URLs and no
    /// effective one (git would use its name as a path), and Edit URL gives it one.
    @Test func aRemoteWithNoURLIsListedAndGivenOne() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "remote.nourl.fetch", "+refs/heads/*:refs/remotes/nourl/*"])

        #expect(try await repo.listedRemotes().contains(Remote(name: "nourl", fetchURL: nil, pushURL: nil)))
        #expect(try await backend.remoteURLs("nourl", at: repo.root) == RemoteURLs(fetch: [], push: [], effectiveFetch: nil))

        try await backend.setURLs(of: "nourl", fetch: fixture.origin.path, push: .unchanged, at: repo.root)

        #expect(try await repo.listedRemotes().contains(
            Remote(name: "nourl", fetchURL: fixture.origin.path, pushURL: fixture.origin.path)))
        #expect(try await repo.configValues("remote.nourl.fetch") == ["+refs/heads/*:refs/remotes/nourl/*"])
    }

    /// An empty `url` (R20: `remote add` stores `""`) is listed like a remote with no URL, its
    /// configured value shown as written and no effective URL claimed.
    @Test func anEmptyURLIsListedWithNoURL() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["remote", "add", "emp", ""])

        #expect(try await repo.listedRemotes().contains(Remote(name: "emp", fetchURL: nil, pushURL: nil)))
        #expect(try await backend.remoteURLs("emp", at: repo.root) == RemoteURLs(fetch: [""], push: [], effectiveFetch: nil))

        // Fix round 1, m6: and Edit URL gives it one (`set-url` replaces the empty value).
        try await backend.setURLs(of: "emp", fetch: fixture.origin.path, push: .unchanged, at: repo.root)
        #expect(try await repo.configValues("remote.emp.url") == [fixture.origin.path])
        #expect(try await repo.listedRemotes().contains(
            Remote(name: "emp", fetchURL: fixture.origin.path, pushURL: fixture.origin.path)))
    }

    // MARK: - Clearing a push URL (fix round 1, I3)

    /// `.clear` removes every `pushurl` — the remote pushes to its fetch URL again — and with
    /// none configured it writes nothing.
    @Test func clearsThePushURL() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await backend.setURLs(of: "origin", fetch: fixture.origin.path, push: .set("/srv/p.git"), at: repo.root)
        #expect(try await repo.configValues("remote.origin.pushurl") == ["/srv/p.git"])

        try await backend.setURLs(of: "origin", fetch: fixture.origin.path, push: .clear, at: repo.root)

        #expect(try await repo.configValues("remote.origin.pushurl").isEmpty)
        #expect(try await backend.remoteURLs("origin", at: repo.root).push == [])
        #expect(try await repo.listedRemotes().contains(
            Remote(name: "origin", fetchURL: fixture.origin.path, pushURL: fixture.origin.path)))

        let before = try await repo.localConfig()
        try await backend.setURLs(of: "origin", fetch: fixture.origin.path, push: .clear, at: repo.root)
        try await assertConfigUnchanged(repo, since: before)
    }

    /// Several `pushurl` values are shown read-only, so clearing them is refused like setting
    /// them; a clear git refuses (a held `config.lock`, measured exit 255, nothing written) is
    /// read back and stays git's words.
    @Test func aClearIsRefusedOnSeveralPushURLsAndReadBackWhenGitFails() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "--add", "remote.origin.pushurl", "/srv/p1.git"])
        try await repo.git(["config", "--add", "remote.origin.pushurl", "/srv/p2.git"])
        let several = try await repo.localConfig()
        let refused = await thrownError {
            try await backend.setURLs(of: "origin", fetch: fixture.origin.path, push: .clear, at: repo.root)
        }
        #expect(refused as? RemoteAdminRefusal == .severalURLs)
        try await assertConfigUnchanged(repo, since: several)

        try await repo.git(["config", "--unset-all", "remote.origin.pushurl"])
        try await repo.git(["config", "remote.origin.pushurl", "/srv/p1.git"])
        let before = try await repo.localConfig()
        let lock = repo.root.appendingPathComponent(".git/config.lock")
        try Data().write(to: lock)
        let error = await thrownError {
            try await backend.setURLs(of: "origin", fetch: fixture.origin.path, push: .clear, at: repo.root)
        }
        try FileManager.default.removeItem(at: lock)
        guard case .commandFailed(_, let stderr)? = error as? GitError else {
            Issue.record("expected git's words, got \(String(describing: error))")
            return
        }
        #expect(stderr.contains("could not lock config file"), "\(stderr)")
        try await assertConfigUnchanged(repo, since: before)
    }

    // MARK: - A remote whose name extends another's (fix round 1, I2)

    /// `origin.bak` is not `origin`: a key is `remote.<name>.<variable>`, and a variable holds no
    /// dot. Measured: with both configured and `packed-refs.lock` held, the half-done rename of
    /// `origin` named `origin` as still configured.
    @Test func aRemoteNamedLikeAnotherWithASuffixIsNotTakenForIt() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["remote", "add", "origin.bak", fixture.origin.path])
        try await repo.git(["pack-refs", "--all"])
        let lock = repo.root.appendingPathComponent(".git/packed-refs.lock")
        try Data().write(to: lock)

        let error = await thrownError { try await backend.renameRemote("origin", to: "up", at: repo.root) }
        try FileManager.default.removeItem(at: lock)

        guard case .renameHalfDone(let left)? = error as? RemoteAdminPartial else {
            Issue.record("expected .renameHalfDone, got \(String(describing: error))")
            return
        }
        #expect(left.configured == ["up"])
        let bak = [CLIGitBackend.ConfigEntry(key: "remote.origin.bak.url", value: "/srv/b.git")]
        #expect(!CLIGitBackend.configures("origin", bak))
        #expect(CLIGitBackend.configures("origin.bak", bak))
    }

    /// The app's pickers, gates and push target read only remotes with a URL: a no-URL remote
    /// leaves a repository that has no other remote "with no remotes", and a branch pushing to
    /// it refused as before (it was not listed at all until B2).
    @Test func aRemoteWithNoURLIsNotSomewhereToPushOrFetch() {
        let nourl = Remote(name: "nourl", fetchURL: nil, pushURL: nil)
        let origin = Remote(name: "origin", fetchURL: "/srv/o.git", pushURL: "/srv/o.git")
        let pushOnly = Remote(name: "po", fetchURL: nil, pushURL: "/srv/p.git")
        #expect(!nourl.hasURL)
        #expect(origin.hasURL && pushOnly.hasURL)
        let refs = RefCollection(localBranches: [], remoteBranches: [], tags: [], remotes: [nourl, origin, pushOnly])
        #expect(refs.remotesWithURL == [origin, pushOnly])
        #expect(refs.remotes == [nourl, origin, pushOnly])
        let branch = Branch(name: "topic", sha: "1111111111111111111111111111111111111111", isHead: true,
                            upstream: nil, tracking: .none, upstreamRemote: nil, upstreamRef: nil,
                            pushRemote: "nourl", pushRef: nil)
        #expect(PushTarget.resolve(branch, remotes: refs.remotes) == .refused(.noURL("nourl")))
        #expect(!nourl.canFetch && !nourl.canPush)
        #expect(!pushOnly.canFetch && pushOnly.canPush)
        #expect(origin.canFetch && origin.canPush)
    }

    // MARK: - Rename (R21)

    /// Rename moves every ref the default refspec maps with its id, and every branch setting
    /// naming the remote; a custom refspec writing elsewhere, and what it fetched, are left as
    /// they were. `branch.<b>.rebase` stays.
    @Test func renameMovesRefsAndSettingsAndLeavesACustomRefspec() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["branch", "-q", "--set-upstream-to=refs/remotes/origin/keep", "b1"])
        try await repo.git(["config", "branch.b1.pushRemote", "origin"])
        try await repo.git(["config", "branch.b1.rebase", "true"])
        try await repo.git(["config", "remote.pushDefault", "origin"])
        try await repo.git(["config", "--add", "remote.origin.fetch", "+refs/heads/main:refs/remotes/elsewhere/main"])
        try await repo.git(["fetch", "-q", "origin"])
        let before = try await repo.refTips(under: "refs/remotes/origin")
        let elsewhere = try await repo.refTips(under: "refs/remotes/elsewhere")
        #expect(!before.isEmpty && !elsewhere.isEmpty)

        try await backend.renameRemote("origin", to: "upstream", at: repo.root)

        let moved = try await repo.refTips(under: "refs/remotes/upstream")
        #expect(moved.map { $0.ref.replacingOccurrences(of: "/upstream/", with: "/origin/") } == before.map(\.ref))
        #expect(moved.map(\.id) == before.map(\.id))
        #expect(try await repo.refTips(under: "refs/remotes/origin").isEmpty)
        #expect(try await repo.refTips(under: "refs/remotes/elsewhere") == elsewhere)
        #expect(try await repo.configValues("branch.b1.remote") == ["upstream"])
        #expect(try await repo.configValues("branch.b1.pushRemote") == ["upstream"])
        #expect(try await repo.configValues("remote.pushDefault") == ["upstream"])
        #expect(try await repo.configValues("branch.b1.rebase") == ["true"])
        #expect(try await repo.configValues("remote.upstream.fetch")
            == ["+refs/heads/*:refs/remotes/upstream/*", "+refs/heads/main:refs/remotes/elsewhere/main"])
        #expect(try await repo.configValues("remote.origin.url").isEmpty)
    }

    /// The new name is checked as Add checks one, nested-in-itself included; nothing is written.
    @Test func renameRefusesANewNameWithAProblem() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["remote", "add", "other", "/srv/other.git"])
        let before = try await repo.localConfig()
        let refs = try await RepoState.capture(repo)

        for (name, problem) in [("other", RemoteNameProblem.exists), ("origin", .exists), ("origin/sub", .nested("origin")),
                                ("@", .reserved), ("-x", .invalid), ("", .empty)] {
            let error = await thrownError { try await backend.renameRemote("origin", to: name, at: repo.root) }
            #expect(error as? RemoteAdminRefusal == .nameProblem(problem), "\(name)")
        }
        try await assertConfigUnchanged(repo, since: before)
        #expect(try await RepoState.capture(repo) == refs)
    }

    /// RF4: with `packed-refs.lock` held — what a concurrent fetch holds — git renames the
    /// section, then fails to move the refs and leaves the refspec and the branch settings
    /// naming the old remote (R21). The failure is read back and described; renaming the new
    /// name back restores exactly the state before, and the rename then succeeds.
    @Test func aRenameUnderAHeldPackedRefsLockIsHalfDoneAndCanBeUndone() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["branch", "-q", "--set-upstream-to=refs/remotes/origin/keep", "b1"])
        try await repo.git(["config", "branch.b1.pushRemote", "origin"])
        try await repo.git(["pack-refs", "--all"])
        let configBefore = try await repo.localConfig()
        let refsBefore = try await RepoState.capture(repo)
        let originRefs = try await repo.refTips(under: "refs/remotes/origin").map(\.ref)
        #expect(!originRefs.isEmpty)
        let lock = repo.root.appendingPathComponent(".git/packed-refs.lock")
        try Data().write(to: lock)

        let error = await thrownError { try await backend.renameRemote("origin", to: "up", at: repo.root) }
        try FileManager.default.removeItem(at: lock)

        guard case .renameHalfDone(let left)? = error as? RemoteAdminPartial else {
            Issue.record("expected .renameHalfDone, got \(String(describing: error))")
            return
        }
        #expect(left.old == "origin" && left.new == "up")
        #expect(left.configured == ["up"])
        #expect(left.refspecsStillOld == ["+refs/heads/*:refs/remotes/origin/*"])
        #expect(Set(left.configStillNamingOld) == ["branch.b1.remote", "branch.b1.pushremote"])
        #expect(left.refsUnderOld == originRefs)
        #expect(left.refsUnderNew.isEmpty)
        #expect(left.gitsWords.contains("packed-refs.lock"), "\(left.gitsWords)")

        try await backend.renameRemote("up", to: "origin", at: repo.root)
        try await assertConfigUnchanged(repo, since: configBefore)
        #expect(try await RepoState.capture(repo) == refsBefore)

        try await backend.renameRemote("origin", to: "up", at: repo.root)
        #expect(try await repo.configValues("branch.b1.remote") == ["up"])
        #expect(try await repo.refTips(under: "refs/remotes/up").count == originRefs.count)
    }

    /// Cancelled while git renames (stopped in the `reference-transaction` hook, R25): the
    /// outcome is not known — never "nothing changed" — and the hook is stopped with git.
    @Test func aCancelledRenameIsOfUnknownOutcome() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let marker = repo.root.appendingPathComponent("hook-started")
        let sleep = "sleep 47.\(Int.random(in: 100_000...999_999))"
        try repo.writeExecutable(".git/hooks/reference-transaction", """
            #!/bin/sh
            [ "$1" = prepared ] || exit 0
            touch '\(marker.path)'
            exec \(sleep)
            """)
        let backend = self.backend
        let root = repo.root
        let task = Task { try await backend.renameRemote("origin", to: "up", at: root) }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(FileManager.default.fileExists(atPath: marker.path), "the hook never ran")
        task.cancel()

        let error = await thrownError { try await task.value }

        #expect(error as? RemoteAdminPartial == .renameOutcomeUnknown(old: "origin", new: "up"))
        #expect(try await processesMatching(sleep).isEmpty)
    }

    /// With `config.lock` held git renames nothing (R21, exit 1): the read-back finds the
    /// repository as it was, so the failure is git's words, not a half-done state.
    @Test func aRenameUnderAHeldConfigLockChangesNothingAndIsGitsWords() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let before = try await repo.localConfig()
        let refs = try await RepoState.capture(repo)
        let lock = repo.root.appendingPathComponent(".git/config.lock")
        try Data().write(to: lock)

        let error = await thrownError { try await backend.renameRemote("origin", to: "up", at: repo.root) }
        try FileManager.default.removeItem(at: lock)

        guard case .commandFailed(_, let stderr)? = error as? GitError else {
            Issue.record("expected git's words, got \(String(describing: error))")
            return
        }
        #expect(stderr.contains("could not lock config file"), "\(stderr)")
        try await assertConfigUnchanged(repo, since: before)
        #expect(try await RepoState.capture(repo) == refs)
    }
}

/// The helper the suites above prove "nothing fetched" and "nothing left" with can fail: it sees
/// a ref made under the prefix, so an `isEmpty` on it is not vacuous.
@Suite struct RemoteAdminTestSupportTests {
    @Test func refTipsSeesARefUnderThePrefix() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        #expect(try await repo.refTips(under: "refs/remotes/second").isEmpty)
        try await repo.git(["update-ref", "refs/remotes/second/main", "main"])

        let tips = try await repo.refTips(under: "refs/remotes/second")
        let main = try await repo.revParse("main")

        #expect(tips == [RefTip(ref: "refs/remotes/second/main", id: main)])
        await withKnownIssue("a ref is there") {
            let again = try await repo.refTips(under: "refs/remotes/second")
            #expect(again.isEmpty)
        }
    }
}
