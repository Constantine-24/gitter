import Foundation
import Testing

@testable import GitCore

/// `makeBranched()` with a local bare origin holding `main`, `feat/x` and `keep`, fetched, and a
/// local branch `b1` at `main` with no upstream (not checked out).
struct UpstreamFixture {
    let repo: TestRepo
    let origin: URL

    static func make() async throws -> UpstreamFixture {
        let repo = try await TestRepo.makeBranched()
        let origin = try await repo.addOriginWithFeatureBranch()
        try await repo.git(["push", "-q", "origin", "main:keep"])
        try await repo.git(["fetch", "-q", "origin"])
        try await repo.git(["branch", "b1", "main"])
        return UpstreamFixture(repo: repo, origin: origin)
    }

    func cleanUp() {
        repo.cleanUp()
        try? FileManager.default.removeItem(at: origin)
    }
}

extension TestRepo {
    /// Every value of `key`, in order (`config --get-all`); empty when it is not set.
    func configValues(_ key: String) async throws -> [String] {
        let data = try await git(["config", "--get-all", key], allowedExitCodes: [1])
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// The repository's own configuration, every line (`config --local --list`).
    func localConfig() async throws -> String {
        String(decoding: try await git(["config", "--local", "--list"]), as: UTF8.self)
    }
}

/// Asserts that the repository's configuration is exactly what `before` captured. A baseline
/// holding nothing would make the comparison vacuous, so it is refused.
func assertConfigUnchanged(
    _ repo: TestRepo, since before: String, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    guard !before.isEmpty else {
        Issue.record("the config baseline is empty, so comparing against it would prove nothing",
                     sourceLocation: sourceLocation)
        return
    }
    #expect(try await repo.localConfig() == before, "the configuration changed", sourceLocation: sourceLocation)
}

/// `GitRemoteAdminBackend.setUpstream` and `unsetUpstream` (B2 Task 2): the full ref name, the
/// read-back of what git wrote, and the refusals git makes — before git runs where Gitter can
/// tell.
@Suite struct UpstreamTests {
    let backend = CLIGitBackend()

    // MARK: - Set, change, unset

    /// Set to a remote branch: `branch.b1.remote` / `.merge` name it, git reads the upstream
    /// back as the same ref, and nothing else in the configuration changes.
    @Test func setsAnUpstreamToARemoteBranch() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let before = try await repo.localConfig()

        let result = try await backend.setUpstream(of: "b1", to: "refs/remotes/origin/keep", at: repo.root)

        #expect(result == SetUpstreamResult(wroteRebase: false))
        #expect(try await repo.configValues("branch.b1.remote") == ["origin"])
        #expect(try await repo.configValues("branch.b1.merge") == ["refs/heads/keep"])
        let upstream = try await repo.git(["for-each-ref", "--format=%(upstream)", "refs/heads/b1"])
        #expect(String(decoding: upstream, as: UTF8.self) == "refs/remotes/origin/keep\n")
        let added = try await repo.localConfig()
        #expect(added == before + "branch.b1.remote=origin\nbranch.b1.merge=refs/heads/keep\n")
    }

    /// Change: the new remote branch replaces the old one, a nested name included.
    @Test func changesAnUpstream() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["branch", "-q", "--set-upstream-to=refs/remotes/origin/keep", "b1"])

        _ = try await backend.setUpstream(of: "b1", to: "refs/remotes/origin/feat/x", at: repo.root)

        #expect(try await repo.configValues("branch.b1.remote") == ["origin"])
        #expect(try await repo.configValues("branch.b1.merge") == ["refs/heads/feat/x"])
    }

    /// Unset removes `remote` and `merge` only: `rebase` and `pushRemote` stay, as git leaves
    /// them (R17).
    @Test func unsetKeepsRebaseAndPushRemote() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["branch", "-q", "--set-upstream-to=refs/remotes/origin/keep", "b1"])
        try await repo.git(["config", "branch.b1.rebase", "true"])
        try await repo.git(["config", "branch.b1.pushRemote", "origin"])

        try await backend.unsetUpstream(of: "b1", at: repo.root)

        #expect(try await repo.configValues("branch.b1.remote") == [])
        #expect(try await repo.configValues("branch.b1.merge") == [])
        #expect(try await repo.configValues("branch.b1.rebase") == ["true"])
        #expect(try await repo.configValues("branch.b1.pushremote") == ["origin"])
    }

    /// Unset on a branch with no upstream: git's own words, nothing changes.
    @Test func unsetWithNoUpstreamIsGitsWords() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let before = try await fixture.repo.localConfig()

        let error = await thrownError { try await backend.unsetUpstream(of: "b1", at: fixture.repo.root) }

        guard case .commandFailed(_, let stderr)? = error as? GitError else {
            Issue.record("expected git's words, got \(String(describing: error))")
            return
        }
        #expect(stderr.contains("has no upstream information"), "\(stderr)")
        try await assertConfigUnchanged(fixture.repo, since: before)
    }

    // MARK: - Refused (nothing written)

    /// Not fetched: the ref does not exist. Refused, nothing written.
    @Test func aRefThatWasNeverFetchedIsRefused() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let before = try await fixture.repo.localConfig()

        let error = await thrownError {
            _ = try await backend.setUpstream(of: "b1", to: "refs/remotes/origin/fresh", at: fixture.repo.root)
        }

        #expect(error as? UpstreamRefusal == .notFetched("refs/remotes/origin/fresh"))
        try await assertConfigUnchanged(fixture.repo, since: before)
    }

    /// The "Other" group: a ref under `refs/remotes/` no remote's refspec maps, and the
    /// symbolic `origin/HEAD`. Refused, nothing written.
    @Test(arguments: ["refs/remotes/ghost/x", "refs/remotes/origin/HEAD"])
    func aRefNoRemoteMapsIsRefused(ref: String) async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["update-ref", "refs/remotes/ghost/x", "main"])
        try await repo.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/main"])
        let before = try await repo.localConfig()

        let error = await thrownError { _ = try await backend.setUpstream(of: "b1", to: ref, at: repo.root) }

        #expect(error as? UpstreamRefusal == .notABranch(ref))
        try await assertConfigUnchanged(repo, since: before)
    }

    /// A tag, a short name or any other ref outside `refs/remotes/` and `refs/heads/` is never an
    /// upstream here: refused before git runs.
    @Test(arguments: ["refs/tags/v1", "origin/keep", "refs/notes/commits", "main"])
    func aRefOutsideRemoteTrackingIsRefusedBeforeGitRuns(ref: String) async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }

        let error = await thrownError { _ = try await git.backend.setUpstream(of: "b1", to: ref, at: fixture.repo.root) }

        #expect(error as? UpstreamRefusal == .notABranch(ref))
        git.assertNothingRan()
    }

    /// Two remotes whose refspecs map the same tracking namespace: git cannot say which remote
    /// the branch would track. Refused, nothing written.
    @Test func twoRemotesMappingTheSameNamespaceAreRefused() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["remote", "add", "o2", fixture.origin.path])
        try await repo.git(["config", "--replace-all", "remote.o2.fetch", "+refs/heads/*:refs/remotes/origin/*"])
        let before = try await repo.localConfig()

        let error = await thrownError {
            _ = try await backend.setUpstream(of: "b1", to: "refs/remotes/origin/keep", at: repo.root)
        }

        #expect(error as? UpstreamRefusal == .ambiguousNamespace("refs/remotes/origin/keep"))
        try await assertConfigUnchanged(repo, since: before)
    }

    /// A held `config.lock` (a concurrent git, R27): git's own words, nothing written.
    @Test func aHeldConfigLockIsGitsWords() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let before = try await repo.localConfig()
        let lock = repo.root.appendingPathComponent(".git/config.lock")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }

        let error = await thrownError {
            _ = try await backend.setUpstream(of: "b1", to: "refs/remotes/origin/keep", at: repo.root)
        }

        guard case .commandFailed(_, let stderr)? = error as? GitError else {
            Issue.record("expected git's words, got \(String(describing: error))")
            return
        }
        #expect(stderr.contains("could not lock config file"), "\(stderr)")
        try FileManager.default.removeItem(at: lock)
        try await assertConfigUnchanged(repo, since: before)
    }

    /// A branch name that is empty or an option: refused before git runs, for both.
    @Test(arguments: ["-x", ""])
    func aBadBranchNameIsRefusedBeforeGitRuns(name: String) async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }

        let set = await thrownError {
            _ = try await git.backend.setUpstream(of: name, to: "refs/remotes/origin/keep", at: fixture.repo.root)
        }
        let unset = await thrownError { try await git.backend.unsetUpstream(of: name, at: fixture.repo.root) }

        #expect(set as? BranchOperationError == .invalidName(name))
        #expect(unset as? BranchOperationError == .invalidName(name))
        git.assertNothingRan()
    }

    // MARK: - Names (RF5) and config (RF3)

    /// A tag and a local branch both called `origin/keep`: the short name is ambiguous to git
    /// (R17); the full ref still sets the remote branch.
    @Test func aTagAndABranchNamedLikeTheRemoteBranchDoNotShadowIt() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["tag", "origin/keep", "feature"])
        try await repo.git(["branch", "origin/keep", "feature"])

        _ = try await backend.setUpstream(of: "b1", to: "refs/remotes/origin/keep", at: repo.root)

        #expect(try await repo.configValues("branch.b1.remote") == ["origin"])
        #expect(try await repo.configValues("branch.b1.merge") == ["refs/heads/keep"])
    }

    /// `branch.autoSetupRebase=always|remote` makes git write `branch.<b>.rebase=true` too —
    /// over a `false` the user had (R17); `never` / `local` write nothing.
    @Test(arguments: [("always", true), ("remote", true), ("never", false), ("local", false)])
    func autoSetupRebaseIsReported(setting: String, writes: Bool) async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "branch.autoSetupRebase", setting])
        try await repo.git(["config", "branch.b1.rebase", "false"])

        let result = try await backend.setUpstream(of: "b1", to: "refs/remotes/origin/keep", at: repo.root)

        #expect(result.wroteRebase == writes)
        #expect(try await repo.configValues("branch.b1.rebase") == [writes ? "true" : "false"])
    }

    /// An upstream that already rebased: git writes `true` again, which is no news.
    @Test func aRebaseThatWasAlreadyTrueIsNotReported() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["config", "branch.autoSetupRebase", "always"])
        try await fixture.repo.git(["config", "branch.b1.rebase", "true"])

        let result = try await backend.setUpstream(of: "b1", to: "refs/remotes/origin/keep", at: fixture.repo.root)

        #expect(result.wroteRebase == false)
    }

    /// Overlapping refspecs (R18): with the default first, git reverse-maps
    /// `origin/x/keep` through it and writes `refs/heads/x/keep`, a server branch that does not
    /// exist. Read back and thrown, with what git wrote. With the more specific refspec first,
    /// git writes the expected `refs/heads/keep` and nothing is thrown.
    @Test(arguments: [true, false])
    func overlappingRefspecsAreReadBack(defaultFirst: Bool) async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let specific = "+refs/heads/*:refs/remotes/origin/x/*"
        if defaultFirst {
            try await repo.git(["config", "--add", "remote.origin.fetch", specific])
        } else {
            try await repo.git(["config", "--replace-all", "remote.origin.fetch", specific])
            try await repo.git(["config", "--add", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/*"])
        }
        try await repo.git(["fetch", "-q", "origin"])

        var thrown: Error?
        do {
            _ = try await backend.setUpstream(of: "b1", to: "refs/remotes/origin/x/keep", at: repo.root)
        } catch {
            thrown = error
        }
        let error = thrown

        if defaultFirst {
            #expect(error as? UpstreamRefusal == .mergeMismatch(expected: "refs/heads/keep", written: "refs/heads/x/keep"))
            #expect(try await repo.configValues("branch.b1.merge") == ["refs/heads/x/keep"], "git wrote it")
        } else {
            #expect(error == nil, "\(String(describing: error))")
            #expect(try await repo.configValues("branch.b1.merge") == ["refs/heads/keep"])
        }
    }

    /// A custom refspec alone: `origin/x/keep` is the server's `keep`, and that is expected.
    @Test func aCustomRefspecMapsBackToItsSource() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "--replace-all", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/x/*"])
        try await repo.git(["fetch", "-q", "origin"])

        _ = try await backend.setUpstream(of: "b1", to: "refs/remotes/origin/x/keep", at: repo.root)

        #expect(try await repo.configValues("branch.b1.merge") == ["refs/heads/keep"])
    }

    // MARK: - A local branch as the upstream (fix round 1)

    /// The picker offers local branches too (spec): git writes `remote = .` and the full
    /// `merge` (R17), and that is what is read back.
    @Test func setsALocalBranchAsTheUpstream() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["tag", "feature", "main"])  // a tag of the same name shadows nothing here

        let result = try await backend.setUpstream(of: "b1", to: "refs/heads/feature", at: repo.root)

        #expect(result == SetUpstreamResult(wroteRebase: false))
        #expect(try await repo.configValues("branch.b1.remote") == ["."])
        #expect(try await repo.configValues("branch.b1.merge") == ["refs/heads/feature"])
    }

    /// The branch itself: git only warns ("not setting branch 'b1' as its own upstream") and
    /// exits 0 with nothing written. Refused before git runs.
    @Test func aBranchIsNotItsOwnUpstream() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }

        let error = await thrownError { _ = try await git.backend.setUpstream(of: "b1", to: "refs/heads/b1", at: fixture.repo.root) }

        #expect(error as? UpstreamRefusal == .ownUpstream("b1"))
        git.assertNothingRan()
    }

    /// A local branch that does not exist, and a symbolic one: refused, nothing written.
    @Test func aMissingOrSymbolicLocalBranchIsRefused() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["symbolic-ref", "refs/heads/alias", "refs/heads/main"])
        let before = try await repo.localConfig()

        let missing = await thrownError { _ = try await backend.setUpstream(of: "b1", to: "refs/heads/nosuch", at: repo.root) }
        let symbolic = await thrownError { _ = try await backend.setUpstream(of: "b1", to: "refs/heads/alias", at: repo.root) }

        #expect(missing as? BranchOperationError == .noSuchBranch("nosuch"))
        #expect(symbolic as? UpstreamRefusal == .notABranch("refs/heads/alias"))
        try await assertConfigUnchanged(repo, since: before)
    }

    // MARK: - A failed write is read back (fix round 1, M3)

    /// git writes `branch.<b>.remote` and `.merge` one after the other; a failure between them
    /// leaves half. Staged with a wrapper that lets the real git write, takes `merge` away again
    /// and exits 1: the failure is read back and reported as what is there now.
    @Test func aSetThatFailedAfterWritingIsReportedAsWhatItLeft() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let git = try FailingAfterGit(after: "branch", runs: "config --unset branch.b1.merge")
        defer { git.cleanUp() }

        let error = await thrownError {
            _ = try await git.backend.setUpstream(of: "b1", to: "refs/remotes/origin/keep", at: fixture.repo.root)
        }

        guard case .upstreamChangedThenFailed(let branch, let remote, let merge, let words)? = error as? RemoteAdminPartial else {
            Issue.record("expected .upstreamChangedThenFailed, got \(String(describing: error))")
            return
        }
        #expect(branch == "b1")
        #expect(remote == "origin")
        #expect(merge == nil)
        #expect(words.contains("staged failure"), "\(words)")
    }

    /// The same for an unset that removed `remote` and not `merge`.
    @Test func anUnsetThatFailedAfterWritingIsReportedAsWhatItLeft() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["branch", "-q", "--set-upstream-to=refs/remotes/origin/keep", "b1"])
        let git = try FailingAfterGit(after: "branch", runs: "config branch.b1.merge refs/heads/keep")
        defer { git.cleanUp() }

        let error = await thrownError { try await git.backend.unsetUpstream(of: "b1", at: fixture.repo.root) }

        #expect(error as? RemoteAdminPartial == .upstreamChangedThenFailed(
            branch: "b1", remote: nil, merge: "refs/heads/keep", gitsWords: "error: staged failure"))
    }

    /// A failure that changed nothing (a lock held from the start — measured, nothing is written)
    /// stays git's words: the read-back finds the configuration as it was.
    @Test func anUnsetRefusedUnderAHeldLockIsGitsWords() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["branch", "-q", "--set-upstream-to=refs/remotes/origin/keep", "b1"])
        let before = try await repo.localConfig()
        let lock = repo.root.appendingPathComponent(".git/config.lock")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }

        let error = await thrownError { try await backend.unsetUpstream(of: "b1", at: repo.root) }

        guard case .commandFailed(_, let stderr)? = error as? GitError else {
            Issue.record("expected git's words, got \(String(describing: error))")
            return
        }
        #expect(stderr.contains("could not unset"), "\(stderr)")
        try FileManager.default.removeItem(at: lock)
        try await assertConfigUnchanged(repo, since: before)
    }

    // MARK: - git's own refusals, read

    /// When git refuses what Gitter's own check let through, its measured words (R17) are read
    /// into the same refusals; anything else stays git's words.
    @Test func gitsRefusalsAreReadIntoTheSameCases() {
        let ref = "refs/remotes/origin/keep"
        #expect(CLIGitBackend.upstreamRefusal(
            stderr: "fatal: the requested upstream branch 'refs/remotes/origin/keep' does not exist\nhint: …", ref: ref)
            == .notFetched(ref))
        #expect(CLIGitBackend.upstreamRefusal(
            stderr: "fatal: cannot set up tracking information; starting point 'refs/remotes/origin/keep' is not a branch", ref: ref)
            == .notABranch(ref))
        #expect(CLIGitBackend.upstreamRefusal(
            stderr: "fatal: not tracking: ambiguous information for ref 'refs/remotes/origin/keep'\nhint: …", ref: ref)
            == .ambiguousNamespace(ref))
        #expect(CLIGitBackend.upstreamRefusal(stderr: "error: could not lock config file .git/config: File exists", ref: ref) == nil)
    }

    /// The reverse mapping through a remote's refspecs: the most specific destination wins,
    /// a negative refspec matching the source unmaps it, and a bare source maps nothing.
    @Test func theExpectedMappingIsTheMostSpecificRefspec() {
        let both = ["+refs/heads/*:refs/remotes/origin/*", "+refs/heads/*:refs/remotes/origin/x/*"]
        #expect(CLIGitBackend.trackedSource(of: "refs/remotes/origin/x/keep", through: both) == "refs/heads/keep")
        #expect(CLIGitBackend.trackedSource(of: "refs/remotes/origin/keep", through: both) == "refs/heads/keep")
        #expect(CLIGitBackend.trackedSource(of: "refs/remotes/origin/a/b", through: [both[0]]) == "refs/heads/a/b")
        #expect(CLIGitBackend.trackedSource(
            of: "refs/remotes/origin/only", through: ["refs/heads/only:refs/remotes/origin/only"]) == "refs/heads/only")
        #expect(CLIGitBackend.trackedSource(
            of: "refs/remotes/origin/keep", through: [both[0], "^refs/heads/keep"]) == nil)
        #expect(CLIGitBackend.trackedSource(of: "refs/remotes/origin/keep", through: ["refs/heads/keep"]) == nil)
        #expect(CLIGitBackend.trackedSource(of: "refs/remotes/other/keep", through: both) == nil)
        #expect(CLIGitBackend.trackedSource(
            of: "refs/remotes/origin/p-keep-s", through: ["refs/heads/*:refs/remotes/origin/p-*-s"]) == "refs/heads/keep")
    }
}

/// The two helpers the suites above prove "nothing changed" with can fail.
@Suite struct UpstreamTestSupportTests {
    @Test func assertConfigUnchangedNoticesAChange() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let before = try await fixture.repo.localConfig()
        #expect(!before.isEmpty)
        try await fixture.repo.git(["config", "branch.b1.rebase", "true"])

        await withKnownIssue("the configuration changed") {
            try await assertConfigUnchanged(fixture.repo, since: before)
        }
        await withKnownIssue("an empty baseline proves nothing") {
            try await assertConfigUnchanged(fixture.repo, since: "")
        }
    }

    @Test func changedRefNamesNoticesAMovedACreatedAndADeletedRef() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let before = try await RepoState.capture(repo)
        #expect(TestRepo.changedRefNames(before.refs, before.refs).isEmpty)

        try await repo.git(["update-ref", "refs/heads/b1", "feature"])
        try await repo.git(["branch", "new", "main"])
        try await repo.git(["update-ref", "-d", "refs/remotes/origin/keep"])

        let after = try await RepoState.capture(repo)
        #expect(TestRepo.changedRefNames(before.refs, after.refs)
            == ["refs/heads/b1", "refs/heads/new", "refs/remotes/origin/keep"])
    }
}

/// A shell script standing in for `/usr/bin/git` that, the first time it is launched with the
/// subcommand `after`, runs the real command, then `runs` (a real git command in the same
/// directory), and exits 1 with `error: staged failure` — a git that failed after writing part
/// of what it was asked to. The fix round's M3 is staged with it.
struct FailingAfterGit {
    let directory: URL
    var wrapper: URL { directory.appendingPathComponent("git") }

    init(after subcommand: String, runs command: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-failing-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let marker = directory.appendingPathComponent("ran").path
        let script = "#!/bin/sh\n"
            + "if [ \"$1\" = '\(subcommand)' ] && [ ! -e '\(marker)' ]; then\n"
            + "  : > '\(marker)'\n  /usr/bin/git \"$@\" >/dev/null 2>&1\n"
            + "  /usr/bin/git \(command) || exit 97\n"
            + "  echo 'error: staged failure' >&2\n  exit 1\nfi\n"
            + "exec /usr/bin/git \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    }

    var backend: CLIGitBackend { CLIGitBackend(gitPath: wrapper.path) }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
