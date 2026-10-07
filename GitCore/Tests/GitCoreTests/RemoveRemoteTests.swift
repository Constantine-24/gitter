import Foundation
import Testing

@testable import GitCore

/// `PruneFixture` (origin's `gone1` and `gone2` held only by their tracking refs, sharing
/// `G1only`) plus a second remote `fork` with `main` fetched, a branch `b1` tracking
/// `origin/keep`, and a branch `onfork` tracking `fork/main`.
struct RemoveFixture {
    let prune: PruneFixture
    let fork: URL
    var repo: TestRepo { prune.repo }

    static func make() async throws -> RemoveFixture {
        let prune = try await PruneFixture.make()
        let repo = prune.repo
        let fork = try await repo.makeSecondServer(named: "fork")
        try await repo.git(["remote", "add", "fork", fork.path])
        try await repo.git(["fetch", "-q", "fork"])
        try await repo.git(["branch", "-q", "b1", "main"])
        try await repo.git(["branch", "-q", "--set-upstream-to=refs/remotes/origin/keep", "b1"])
        try await repo.git(["branch", "-q", "onfork", "main"])
        try await repo.git(["branch", "-q", "--set-upstream-to=refs/remotes/fork/main", "onfork"])
        return RemoveFixture(prune: prune, fork: fork)
    }

    func cleanUp() {
        prune.cleanUp()
        try? FileManager.default.removeItem(at: fork)
    }
}

/// `GitRemoteAdminBackend.removalImpact` and `removeRemote` (B2 Task 3): what `git remote
/// remove` deletes, strands and changes, computed as git computes it and compared again before
/// git runs; the kept branches first; and what a failed removal left (R23).
@Suite struct RemoveRemoteTests {
    let backend = CLIGitBackend()

    // MARK: - The impact

    /// The refs are every `refs/remotes/origin/` ref with its id; the stranded commits are one
    /// union over them (RF2: `gone2` holds `G1only` too, so per ref it would be 0 + 1, and `K`
    /// is held by `origin/keep` alone — `b1` tracks it but sits on `main`); the branch tracking
    /// origin loses its upstream; nothing is left behind.
    @Test func theImpactListsRefsTheUnionAndTheUpstreamsLost() async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let originRefs = try await repo.refTips(under: "refs/remotes/origin")
        #expect(originRefs.count >= 4)

        let impact = try await backend.removalImpact(of: "origin", at: repo.root)

        #expect(impact.remote == "origin")
        #expect(impact.refs == originRefs)
        let keep = try await repo.revParse("refs/remotes/origin/keep")
        #expect(impact.stranded.count == 3)
        #expect(impact.stranded.commits == [
            CommitRef(sha: keep, subject: "K"),
            CommitRef(sha: fixture.prune.gone2, subject: "G2only"),
            CommitRef(sha: fixture.prune.gone1, subject: "G1only"),
        ])
        #expect(impact.stranded.holders == [PruneFixture.gone1Ref, PruneFixture.gone2Ref, "refs/remotes/origin/keep"])
        #expect(try await backend.stranded(by: [PruneFixture.gone1Ref], at: repo.root) == .none, "per ref, gone1 strands nothing")
        #expect(impact.upstreamOf == ["b1"])
        #expect(impact.pushRedirects == [])
        #expect(impact.leftBehind == [])
    }

    /// The impact is exactly what git does: removing the remote deletes `impact.refs` and
    /// nothing else under `refs/remotes/`, and leaves `impact.leftBehind`. Under a custom
    /// refspec (R23: it deletes only what its refspecs map, `elsewhere/keep` included), a
    /// negative refspec, a ref another remote's refspec maps, and a ref made by hand.
    @Test(arguments: ["default", "custom", "negative", "shared"])
    func theImpactIsWhatGitDeletes(shape: String) async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["update-ref", "refs/remotes/origin/handmade", "main"])
        switch shape {
        case "custom":
            try await repo.git(["config", "--replace-all", "remote.origin.fetch", "+refs/heads/main:refs/remotes/origin/main"])
            try await repo.git(["config", "--add", "remote.origin.fetch", "+refs/heads/keep:refs/remotes/elsewhere/keep"])
            try await repo.git(["fetch", "-q", "origin"])
        case "negative":
            try await repo.git(["config", "--add", "remote.origin.fetch", "^refs/heads/gone1"])
        case "shared":
            try await repo.git(["config", "--add", "remote.fork.fetch", "+refs/heads/keep:refs/remotes/origin/keep"])
        default: break
        }
        let before = try await repo.refTips(under: "refs/remotes")

        let impact = try await backend.removalImpact(of: "origin", at: repo.root)
        #expect(!impact.refs.isEmpty)
        try await backend.removeRemote(impact, keeping: [:], at: repo.root)

        // Asked ref by ref, a symbolic one by `symbolic-ref`: git can leave `origin/HEAD`
        // dangling (its target deleted, itself not mapped), and `for-each-ref` hides a dangling
        // ref (measured).
        var deleted: [RefTip] = []
        var left: [String] = []
        for tip in before {
            let symbolic = try await repo.symbolicRef(tip.ref) != nil
            let resolves = try await repo.gitRefExists(tip.ref)
            let there = symbolic || resolves
            if !there { deleted.append(tip) } else if tip.ref.hasPrefix("refs/remotes/origin/") { left.append(tip.ref) }
        }
        #expect(deleted == impact.refs, "\(shape)")
        #expect(left.filter { shape != "shared" || $0 != "refs/remotes/origin/keep" } == impact.leftBehind, "\(shape)")
        switch shape {
        case "custom":
            #expect(impact.refs.map(\.ref).contains("refs/remotes/elsewhere/keep"))
            #expect(impact.leftBehind.contains("refs/remotes/origin/gone1"))
            #expect(impact.leftBehind.contains("refs/remotes/origin/handmade"))
            #expect(impact.leftBehind.contains("refs/remotes/origin/HEAD"), "left dangling, not deleted")
        case "negative":
            #expect(impact.leftBehind == ["refs/remotes/origin/gone1"])
        case "shared":
            #expect(!impact.refs.map(\.ref).contains("refs/remotes/origin/keep"))
            #expect(impact.leftBehind.isEmpty)
        default:
            #expect(impact.refs.map(\.ref).contains("refs/remotes/origin/handmade"))
            #expect(impact.leftBehind.isEmpty)
        }
    }

    /// A branch tracking `fork` that pushes to `origin` (`pushRemote`) silently starts pushing to
    /// `fork` once `origin` is removed (R23); one pushing to `origin` only because of
    /// `remote.pushDefault` falls back to its upstream's remote, or to nothing.
    @Test func pushRedirectsAreNamedWithWhereEachPushGoesAfterwards() async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "branch.onfork.pushRemote", "origin"])

        let pushRemote = try await backend.removalImpact(of: "origin", at: repo.root)
        #expect(pushRemote.pushRedirects == [PushRedirect(branch: "onfork", nowPushesTo: "fork")])

        try await repo.git(["config", "--unset", "branch.onfork.pushRemote"])
        try await repo.git(["config", "remote.pushDefault", "origin"])
        try await repo.git(["branch", "-q", "elsewhere", "main"])
        try await repo.git(["config", "branch.elsewhere.pushRemote", "fork"])
        let pushDefault = try await backend.removalImpact(of: "origin", at: repo.root)

        // Every local branch pushes to origin through `pushDefault` but `elsewhere`, whose own
        // `pushRemote` wins: `onfork` goes to its upstream's remote, the rest nowhere.
        #expect(pushDefault.pushRedirects == [
            PushRedirect(branch: "b1", nowPushesTo: nil),
            PushRedirect(branch: "feature", nowPushesTo: nil),
            PushRedirect(branch: "main", nowPushesTo: nil),
            PushRedirect(branch: "onfork", nowPushesTo: "fork"),
        ])
        #expect(pushDefault.upstreamOf == ["b1"])

        // git agrees about `onfork` once origin is gone.
        try await backend.removeRemote(pushDefault, keeping: [:], at: repo.root)
        let push = try await repo.git(["for-each-ref", "--format=%(push:remotename)", "refs/heads/onfork"])
        #expect(String(decoding: push, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "fork")
    }

    /// git unsets only the repository's own settings: a `remote.pushDefault` from another scope
    /// (here the worktree's, `extensions.worktreeConfig`; measured the same for the global one)
    /// is kept, and the branch goes on pushing to the removed remote's name. The impact says so,
    /// and git agrees once the remote is gone.
    @Test func aPushSettingOutsideTheRepositorysOwnConfigurationSurvives() async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "extensions.worktreeConfig", "true"])
        try await repo.git(["config", "--worktree", "remote.pushDefault", "origin"])
        try await repo.git(["config", "branch.onfork.pushRemote", "origin"])

        let impact = try await backend.removalImpact(of: "origin", at: repo.root)

        #expect(impact.pushRedirects.first { $0.branch == "onfork" } == PushRedirect(branch: "onfork", nowPushesTo: "origin"))
        #expect(impact.pushRedirects.first { $0.branch == "main" } == PushRedirect(branch: "main", nowPushesTo: "origin"))
        try await backend.removeRemote(impact, keeping: [:], at: repo.root)
        for branch in ["onfork", "main"] {
            let push = try await repo.git(["for-each-ref", "--format=%(push:remotename)", "refs/heads/\(branch)"])
            #expect(String(decoding: push, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "origin", "\(branch)")
        }
    }

    /// Unknown remotes are refused by name; a name that is an option, before git runs.
    @Test func anUnknownRemoteIsRefused() async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let root = fixture.repo.root

        #expect(await thrownError { _ = try await backend.removalImpact(of: "nosuch", at: root) } as? RemoteAdminRefusal
            == .noSuchRemote("nosuch"))
        let gone = RemovalImpact(remote: "nosuch", refs: [], stranded: .none, upstreamOf: [], pushRedirects: [], leftBehind: [])
        #expect(await thrownError { try await backend.removeRemote(gone, keeping: [:], at: root) } as? RemoteAdminRefusal
            == .noSuchRemote("nosuch"))

        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        let option = RemovalImpact(remote: "-x", refs: [], stranded: .none, upstreamOf: [], pushRedirects: [], leftBehind: [])
        #expect(await thrownError { _ = try await git.backend.removalImpact(of: "-x", at: root) } as? RemoteOperationError == .noRemote)
        #expect(await thrownError { try await git.backend.removeRemote(option, keeping: [:], at: root) } as? RemoteOperationError == .noRemote)
        git.assertNothingRan()
    }

    // MARK: - The removal

    /// Removed: the refs, the section and the branch settings go; `branch.<b>.rebase` stays; the
    /// kept branch is created **before** git removes anything, at the id the sheet showed, and
    /// holds the commits that would otherwise have been stranded.
    @Test func aKeptBranchIsCreatedBeforeTheRemoval() async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "branch.b1.rebase", "true"])
        let impact = try await backend.removalImpact(of: "origin", at: repo.root)
        let git = try GitLaunchLog()
        defer { git.cleanUp() }

        try await git.backend.removeRemote(impact, keeping: [PruneFixture.gone2Ref: "kept-g2"], at: repo.root)

        #expect(try await repo.revParse("refs/heads/kept-g2") == fixture.prune.gone2)
        #expect(try await repo.refTips(under: "refs/remotes/origin").isEmpty)
        #expect(try await repo.configValues("remote.origin.url").isEmpty)
        #expect(try await repo.configValues("branch.b1.remote").isEmpty)
        #expect(try await repo.configValues("branch.b1.rebase") == ["true"])
        #expect(try await repo.configValues("branch.kept-g2.remote").isEmpty, "a kept branch tracks nothing")
        let launches = git.launches
        let created = try #require(launches.firstIndex(of: "branch"))
        let removed = try #require(launches.lastIndex(of: "remote"))
        #expect(created < removed, "\(launches)")
        #expect(try await backend.stranded(by: [], at: repo.root) == .none)
    }

    /// RF1: anything the sheet did not show — a ref that moved or appeared, a branch that took an
    /// upstream or a push remote on the remote since — refuses the removal, with nothing created,
    /// unset or deleted.
    @Test(arguments: ["moved", "appeared", "upstream", "pushRemote", "pushDefault"])
    func anImpactThatChangedIsRefusedWithNothingRemoved(change: String) async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let impact = try await backend.removalImpact(of: "origin", at: repo.root)
        switch change {
        case "moved": try await repo.git(["update-ref", "refs/remotes/origin/keep", "main"])
        case "appeared": try await repo.git(["update-ref", "refs/remotes/origin/new", "main"])
        case "upstream": try await repo.git(["branch", "-q", "--set-upstream-to=refs/remotes/origin/keep", "onfork"])
        case "pushRemote": try await repo.git(["config", "branch.onfork.pushRemote", "origin"])
        default: try await repo.git(["config", "remote.pushDefault", "origin"])
        }
        let config = try await repo.localConfig()
        let state = try await RepoState.capture(repo)

        let error = await thrownError {
            try await backend.removeRemote(impact, keeping: [PruneFixture.gone2Ref: "kept-g2"], at: repo.root)
        }

        #expect(error as? RemoteAdminRefusal == .impactChanged)
        try await assertConfigUnchanged(repo, since: config)
        #expect(try await RepoState.capture(repo) == state)
    }

    /// A kept ref must be one the sheet listed; a taken name is refused before anything is
    /// created or removed.
    @Test func aKeptRefOrNameTheSheetCouldNotHaveShownIsRefused() async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let impact = try await backend.removalImpact(of: "origin", at: repo.root)
        let config = try await repo.localConfig()
        let state = try await RepoState.capture(repo)

        let unlisted = await thrownError {
            try await backend.removeRemote(impact, keeping: ["refs/remotes/fork/main": "kept"], at: repo.root)
        }
        let taken = await thrownError {
            try await backend.removeRemote(impact, keeping: [PruneFixture.gone2Ref: "feature"], at: repo.root)
        }

        #expect(unlisted as? BranchOperationError == .invalidName("refs/remotes/fork/main"))
        #expect(taken as? RemoteAdminRefusal == .branchExists("feature"))
        try await assertConfigUnchanged(repo, since: config)
        #expect(try await RepoState.capture(repo) == state)
    }

    /// RF4: with `packed-refs.lock` held git unsets every branch setting naming the remote, then
    /// fails to delete the refs and keeps the section (R23, exit 1). Read back and described —
    /// the kept branch with it — and removing again finishes the job.
    @Test func aRemovalUnderAHeldPackedRefsLockIsHalfDoneAndCanBeFinished() async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "branch.onfork.pushRemote", "origin"])
        try await repo.git(["pack-refs", "--all"])
        let impact = try await backend.removalImpact(of: "origin", at: repo.root)
        let lock = repo.root.appendingPathComponent(".git/packed-refs.lock")
        try Data().write(to: lock)

        let error = await thrownError {
            try await backend.removeRemote(impact, keeping: [PruneFixture.gone2Ref: "kept-g2"], at: repo.root)
        }
        try FileManager.default.removeItem(at: lock)

        guard case .removeHalfDone(let left)? = error as? RemoteAdminPartial else {
            Issue.record("expected .removeHalfDone, got \(String(describing: error))")
            return
        }
        #expect(left.remote == "origin")
        #expect(left.stillConfigured)
        #expect(left.refsLeft == impact.refs)
        #expect(left.refsDeleted.isEmpty)
        #expect(Set(left.configRemoved) == ["branch.b1.remote", "branch.b1.merge", "branch.onfork.pushremote"])
        #expect(left.keptBranches == ["kept-g2"])
        #expect(left.gitsWords.contains("packed-refs.lock"), "\(left.gitsWords)")
        #expect(try await repo.revParse("refs/heads/kept-g2") == fixture.prune.gone2)

        let again = try await backend.removalImpact(of: "origin", at: repo.root)
        try await backend.removeRemote(again, keeping: [:], at: repo.root)
        #expect(try await repo.refTips(under: "refs/remotes/origin").isEmpty)
        #expect(try await repo.configValues("remote.origin.url").isEmpty)
    }

    /// Cancelled while git removes (stopped in the `reference-transaction` hook, R25): what git
    /// left is not known — never "nothing changed" — and the kept branch, created before git
    /// ran, is named. The hook's process is stopped with git.
    @Test func aCancelledRemovalIsOfUnknownOutcome() async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let impact = try await backend.removalImpact(of: "origin", at: repo.root)
        let marker = repo.root.appendingPathComponent("hook-started")
        let sleep = "sleep 47.\(Int.random(in: 100_000...999_999))"
        try repo.writeExecutable(".git/hooks/reference-transaction", """
            #!/bin/sh
            [ "$1" = prepared ] || exit 0
            grep -q 'refs/remotes/origin/' || exit 0
            touch '\(marker.path)'
            exec \(sleep)
            """)
        let backend = self.backend
        let root = repo.root
        let task = Task { try await backend.removeRemote(impact, keeping: [PruneFixture.gone2Ref: "kept-g2"], at: root) }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        try #require(FileManager.default.fileExists(atPath: marker.path), "the hook never ran")
        task.cancel()

        let error = await thrownError { try await task.value }

        #expect(error as? RemoteAdminPartial == .removeOutcomeUnknown(remote: "origin", keptBranches: ["kept-g2"]))
        #expect(try ownProcesses(matching: sleep).isEmpty)
    }

    /// Fix round 1, m1: what the read-back compares against is read **before** the kept branches
    /// are created, so a read that fails after one was created cannot leave it unreported.
    /// Staged with a git that refuses the repository's config read once a `branch` has run.
    @Test func noReadAfterTheKeptBranchesCanLoseThem() async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let impact = try await backend.removalImpact(of: "origin", at: repo.root)
        let git = try ScriptedGit(before: """
            [ "$1" = branch ] && : > "$DIR/branched"
            if [ "$1" = config ] && [ "$2" = --local ] && [ -e "$DIR/branched" ]; then
              echo 'fatal: staged read failure' >&2; exit 128
            fi
            """)
        defer { git.cleanUp() }

        try await git.backend.removeRemote(impact, keeping: [PruneFixture.gone2Ref: "kept-g2"], at: repo.root)

        #expect(try await repo.revParse("refs/heads/kept-g2") == fixture.prune.gone2)
        #expect(try await repo.configValues("remote.origin.url").isEmpty)
    }

    /// Fix round 1, m2: the refs git will delete are compared with the sheet's once more, from
    /// the state read right before git runs — a ref that appears after the impact was re-read is
    /// refused, not deleted. Staged with a git that adds `origin/late` as that state is read.
    @Test func aRefThatAppearsJustBeforeGitRunsIsRefused() async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let impact = try await backend.removalImpact(of: "origin", at: repo.root)
        let git = try ScriptedGit(before: """
            if [ "$1" = config ] && [ "$2" = --local ] && [ ! -e "$DIR/added" ]; then
              : > "$DIR/added"; /usr/bin/git update-ref refs/remotes/origin/late refs/heads/main
            fi
            """)
        defer { git.cleanUp() }

        let error = await thrownError { try await git.backend.removeRemote(impact, keeping: [PruneFixture.gone2Ref: "kept-g2"], at: repo.root) }

        #expect(error as? RemoteAdminRefusal == .impactChanged)
        #expect(try await repo.gitRefExists("refs/remotes/origin/late"))
        #expect(try await repo.configValues("remote.origin.url") == [fixture.prune.origin.path])
        #expect(!(try await repo.gitRefExists("refs/heads/kept-g2")), "a refusal creates nothing")
    }

    /// With `config.lock` held git changes nothing (R23, exit 128): git's words, and the
    /// repository as it was.
    @Test func aRemovalUnderAHeldConfigLockChangesNothingAndIsGitsWords() async throws {
        let fixture = try await RemoveFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let impact = try await backend.removalImpact(of: "origin", at: repo.root)
        let config = try await repo.localConfig()
        let state = try await RepoState.capture(repo)
        let lock = repo.root.appendingPathComponent(".git/config.lock")
        try Data().write(to: lock)

        let error = await thrownError { try await backend.removeRemote(impact, keeping: [:], at: repo.root) }
        try FileManager.default.removeItem(at: lock)

        guard case .commandFailed(_, let stderr)? = error as? GitError else {
            Issue.record("expected git's words, got \(String(describing: error))")
            return
        }
        #expect(stderr.contains("could not unset"), "\(stderr)")
        try await assertConfigUnchanged(repo, since: config)
        #expect(try await RepoState.capture(repo) == state)
    }
}

/// A shell script standing in for `/usr/bin/git`: runs `before` (with `$DIR` its own directory
/// for markers), then the real git. For staging what another process does at a given moment.
struct ScriptedGit {
    let directory: URL
    var wrapper: URL { directory.appendingPathComponent("git") }

    init(before: String) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-scripted-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let script = "#!/bin/sh\nDIR='\(directory.path)'\n\(before)\nexec /usr/bin/git \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    }

    var backend: CLIGitBackend { CLIGitBackend(gitPath: wrapper.path) }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
