import Foundation
import Testing

@testable import GitCore

/// `GitWorktreeBackend.addWorktree` (B3 Task 2): an existing local branch's short name, checked
/// to be `refs/heads/<name>` right before git runs (R17), at an absolute path checked by Gitter
/// (R16), then `list` read back whatever git's exit code (R19).
@Suite struct WorktreeAddTests {

    // MARK: - An existing branch

    @Test func anExistingBranchIsAddedAndReadBackOnThatBranch() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["branch", "feat"])
        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }

        let result = try await git.backend.addWorktree(path: fixture.path("wt"), branch: "feat", at: fixture.repo.root)

        guard case .added(let wt) = result else {
            Issue.record("expected .added, got \(result)")
            return
        }
        #expect(wt.path == fixture.listedPath("wt"))
        #expect(wt.branch == "refs/heads/feat")
        #expect(try await fixture.repo.revParse("refs/heads/feat") == wt.head)
        #expect(fixture.exists("wt/f.txt"))
        #expect(try await fixture.repo(at: "wt").symbolicRef("HEAD") == "refs/heads/feat")
        #expect(git.launches(startingWith: "worktree add").map { $0.components(separatedBy: " | ")[0] }
            == ["worktree add -q --end-of-options \(fixture.path("wt")) feat"])
    }

    // MARK: - RF2: paths

    /// A space, non-ASCII letters, `/tmp` for `/private/tmp`, an empty folder that is already
    /// there, and missing parent folders: all accepted, and read back by real path.
    @Test(arguments: ["wt with space", "wt-ünï", "existing-empty", "deep/er/wt"])
    func pathsGitAcceptsAreAdded(name: String) async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["branch", "feat"])
        if name == "existing-empty" {
            try FileManager.default.createDirectory(atPath: fixture.path(name), withIntermediateDirectories: true)
        }

        let result = try await fixture.backend.addWorktree(path: fixture.path(name), branch: "feat", at: fixture.repo.root)

        #expect(result == .added(try await fixture.listed(name)))
        #expect(fixture.exists("\(name)/f.txt"))
    }

    @Test func aTmpPathIsReadBackUnderPrivateTmp() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["branch", "feat"])
        let tmp = "/tmp/gitter-wt-\(UUID().uuidString)"
        defer { try? FileManager.default.removeItem(atPath: tmp) }

        let result = try await fixture.backend.addWorktree(path: tmp + "/wt", branch: "feat", at: fixture.repo.root)

        guard case .added(let wt) = result else {
            Issue.record("expected .added, got \(result)")
            return
        }
        #expect(wt.path == "/private" + tmp + "/wt")
        #expect(wt.branch == "refs/heads/feat")
    }

    /// Refused before `worktree add` runs: a relative path (git resolves it against its own
    /// working directory, R16); a folder that is not empty and a file (git refuses those itself);
    /// a path inside the main worktree or inside another worktree, however it is spelled (git
    /// accepts both, R16).
    @Test func pathsGitterRefusesAreRefusedBeforeGitRuns() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["branch", "feat"])
        try await fixture.addOnNewBranch("other", "o")
        try fixture.write("full/x.txt", "x\n")
        try fixture.write("afile", "x\n")
        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }
        let add = { (path: String) in
            await thrownError { _ = try await git.backend.addWorktree(path: path, branch: "feat", at: fixture.repo.root) }
        }

        #expect(await add("relative/wt") as? AddWorktreeRefusal == .pathNotAbsolute("relative/wt"))
        #expect(await add(fixture.path("full")) as? AddWorktreeRefusal == .pathExists(fixture.path("full")))
        #expect(await add(fixture.path("afile")) as? AddWorktreeRefusal == .pathExists(fixture.path("afile")))
        let insideMain = fixture.path("main/inner")
        #expect(await add(insideMain) as? AddWorktreeRefusal == .pathInsideWorktree(insideMain))
        let insideMainResolved = fixture.listedPath("main/inner2")
        #expect(await add(insideMainResolved) as? AddWorktreeRefusal == .pathInsideWorktree(insideMainResolved))
        let insideOther = fixture.path("other/sub/wt")
        #expect(await add(insideOther) as? AddWorktreeRefusal == .pathInsideWorktree(insideOther))
        let throughDots = fixture.path("x") + "/../main/inner3"
        #expect(await add(throughDots) as? AddWorktreeRefusal == .pathInsideWorktree(throughDots))

        #expect(git.launches(startingWith: "worktree add") == [])
        #expect(!fixture.exists("main/inner"))
        #expect(!fixture.exists("relative"))
        // The control: git itself accepts a path inside the main worktree (R16).
        try await fixture.repo.git(["worktree", "add", "-q", insideMain, "feat"])
        withKnownIssue("git adds a worktree inside the main one") {
            #expect(!fixture.exists("main/inner/f.txt"))
        }
    }

    // MARK: - Branches

    /// A branch checked out in a worktree, or held there by a rebase, is refused before
    /// `worktree add` runs, naming the worktree.
    @Test func aBranchInUseOrHeldByAnOperationIsRefusedBeforeGitRuns() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.addOnNewBranch("used", "u")
        try await fixture.addOnNewBranch("rebasing", "rb")
        let rebasing = fixture.repo(at: "rebasing")
        try rebasing.write("r.txt", "1\n")
        try await rebasing.commitAll("r1")
        try rebasing.write("r.txt", "2\n")
        try await rebasing.commitAll("r2")
        try await rebasing.git(["rebase", "-q", "-x", "false", "rb~1"], allowedExitCodes: [1])
        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }
        let add = { (branch: String) in
            await thrownError { _ = try await git.backend.addWorktree(path: fixture.path("new"), branch: branch, at: fixture.repo.root) }
        }

        #expect(await add("u") as? AddWorktreeRefusal == .branchInUse(path: fixture.listedPath("used")))
        #expect(await add("main") as? AddWorktreeRefusal == .branchInUse(path: realPath(fixture.repo.root.path)))
        guard case .branchHeldByOperation(let path) = await add("rb") as? AddWorktreeRefusal else {
            Issue.record("expected .branchHeldByOperation")
            return
        }
        #expect(realPath(path) == fixture.listedPath("rebasing"))
        #expect(git.launches(startingWith: "worktree add") == [])
        #expect(!fixture.exists("new"))
    }

    /// The negative control for every "nothing launched" above: a free branch does launch
    /// `worktree add` through the same wrapper.
    @Test func aFreeBranchDoesLaunchWorktreeAdd() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["branch", "feat"])
        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }

        _ = try await git.backend.addWorktree(path: fixture.path("wt"), branch: "feat", at: fixture.repo.root)

        withKnownIssue("git really ran") {
            #expect(git.launches(startingWith: "worktree add") == [])
        }
    }

    // MARK: - RF4: names (R17)

    /// A branch and a tag of one name: the branch is checked out, as git does it, and read back
    /// on it.
    @Test func aBranchAndATagOfOneNameGiveTheBranch() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["branch", "ex2"])
        try fixture.repo.write("t.txt", "t\n")
        try await fixture.repo.commitAll("t")
        try await fixture.repo.git(["tag", "ex2"])

        let result = try await fixture.backend.addWorktree(path: fixture.path("wt"), branch: "ex2", at: fixture.repo.root)

        guard case .added(let wt) = result else {
            Issue.record("expected .added, got \(result)")
            return
        }
        #expect(wt.branch == "refs/heads/ex2")
        #expect(try await fixture.repo.revParse("refs/heads/ex2") == wt.head)
        #expect(try await fixture.repo.revParse("refs/tags/ex2") != wt.head)
    }

    /// A name only a remote has, a tag's name, a full `refs/heads/` name and a symbolic branch
    /// are not "an existing local branch": refused before `worktree add` runs, and no branch is
    /// created. The control: raw git, given the remote-only name, creates a tracking branch (R17).
    @Test func aNameThatIsNotAPlainLocalBranchIsRefusedAndNoBranchIsCreated() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        let origin = fixture.base.appendingPathComponent("origin.git")
        try FileManager.default.createDirectory(at: origin, withIntermediateDirectories: true)
        _ = try await isolatedRunner().run("/usr/bin/git", ["init", "-q", "--bare", "-b", "main", "."], cwd: origin)
        try await fixture.repo.git(["remote", "add", "origin", origin.path])
        try await fixture.repo.git(["push", "-q", "origin", "main:refs/heads/r1"])
        try await fixture.repo.git(["fetch", "-q", "origin"])
        try await fixture.repo.git(["tag", "v1"])
        try await fixture.repo.git(["branch", "feat"])
        try await fixture.repo.git(["symbolic-ref", "refs/heads/alias", "refs/heads/feat"])
        try await fixture.repo.git(["config", "worktree.guessRemote", "true"])
        let before = try await fixture.branches()
        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }

        for name in ["r1", "v1", "refs/heads/feat", "alias", "nope"] {
            let error = await thrownError {
                _ = try await git.backend.addWorktree(path: fixture.path("wt"), branch: name, at: fixture.repo.root)
            }
            #expect(error as? AddWorktreeRefusal == .noSuchBranch(name), "\(name): \(String(describing: error))")
        }
        for name in ["-b", "", "@{-1}"] {
            let error = await thrownError {
                _ = try await git.backend.addWorktree(path: fixture.path("wt"), branch: name, at: fixture.repo.root)
            }
            #expect(error != nil, "\(name)")
        }

        #expect(git.launches(startingWith: "worktree add") == [])
        #expect(try await fixture.branches() == before)
        #expect(!fixture.exists("wt"))
        try await fixture.repo.git(["worktree", "add", "-q", "--no-guess-remote", fixture.path("raw"), "r1"])
        let afterRawGit = try await fixture.branches()
        withKnownIssue("git creates a tracking branch for a remote-only name (R17)") {
            #expect(afterRawGit == before)
        }
    }

    /// `worktree.guessRemote=true` changes nothing for an existing branch: no other branch is
    /// created.
    @Test func guessRemoteCreatesNoExtraBranch() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["branch", "feat"])
        try await fixture.repo.git(["config", "worktree.guessRemote", "true"])
        let before = try await fixture.branches()

        let result = try await fixture.backend.addWorktree(path: fixture.path("feat"), branch: "feat", at: fixture.repo.root)

        #expect(result == .added(try await fixture.listed("feat")))
        #expect(try await fixture.branches() == before)
    }

    // MARK: - RF3: failures half-way (R19)

    /// A `post-checkout` hook that fails: git exits with its code after the worktree is complete.
    /// Read back, it is there on the branch — with git's words.
    @Test func aFailingPostCheckoutHookGivesAddedWithError() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["branch", "feat"])
        try fixture.repo.writeExecutable(".git/hooks/post-checkout", "#!/bin/sh\necho hook says no >&2\nexit 3\n")

        let result = try await fixture.backend.addWorktree(path: fixture.path("wt"), branch: "feat", at: fixture.repo.root)

        guard case .addedWithError(let wt, let words) = result else {
            Issue.record("expected .addedWithError, got \(result)")
            return
        }
        #expect(wt.path == fixture.listedPath("wt"))
        #expect(wt.branch == "refs/heads/feat")
        #expect(words.contains("hook says no"), "\(words)")
        #expect(fixture.exists("wt/f.txt"))
    }

    /// A hook that leaves the new worktree on something else: git exits 0, and the read-back says
    /// it is not what was asked for.
    @Test func aWorktreeNotOnTheBranchAskedForIsUnexpected() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["branch", "feat"])
        // Once: the switch runs `post-checkout` again.
        try fixture.repo.writeExecutable(
            ".git/hooks/post-checkout",
            "#!/bin/sh\n[ -n \"$GITTER_TEST_HOOK\" ] && exit 0\nGITTER_TEST_HOOK=1 /usr/bin/git switch -q --detach\n")

        let result = try await fixture.backend.addWorktree(path: fixture.path("wt"), branch: "feat", at: fixture.repo.root)

        guard case .unexpected(let wt, _) = result else {
            Issue.record("expected .unexpected, got \(result)")
            return
        }
        #expect(wt?.path == fixture.listedPath("wt"))
        #expect(wt?.branch == nil)
    }

    /// Cancelled while git runs — here, after git has made the worktree: the outcome is read back
    /// outside the cancelled task, and the worktree that is there is reported, never "nothing
    /// happened". Not vacuous: uncancelled, the stalled launch exits 0 and this is `.added`.
    ///
    /// It waits for git to finish adding with no deadline of its own: a 60 s one stood here,
    /// which load could exceed, and then the test cancelled too early and failed for the wrong
    /// reason. A wait that never ends is the time limit's (`TimeLimitSupport.swift`).
    @Test(.timeLimit(.minutes(10))) func aCancelledAddIsReadBack() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["branch", "feat"])
        let git = try WorktreeLaunchLog(stallAfterAdd: true)
        defer { git.cleanUp() }
        let backend = git.backend
        let root = fixture.repo.root
        let path = fixture.path("wt")

        let call = CallUnderTest { () -> Result<AddWorktreeResult, Error> in
            do {
                return .success(try await backend.addWorktree(path: path, branch: "feat", at: root))
            } catch {
                return .failure(error)
            }
        }
        while !git.addFinished { try await Task.sleep(for: .milliseconds(20)) }
        call.cancel()
        guard let outcome = await call.value("the cancelled add") else { return }
        let result = try outcome.get()

        guard case .addedWithError(let wt, _) = result else {
            Issue.record("expected .addedWithError, got \(result)")
            return
        }
        #expect(wt.path == fixture.listedPath("wt"))
        #expect(wt.branch == "refs/heads/feat")
    }

    /// A required smudge filter that fails: git exits 128 and cleans the folder and its
    /// administrative entry up. Nothing is listed, so git's failure is thrown.
    @Test func aFailingSmudgeFilterIsAThrownFailureWithNoWorktreeLeft() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try fixture.repo.write(".gitattributes", "f.txt filter=bad\n")
        try await fixture.repo.commitAll("attributes")
        try await fixture.repo.git(["branch", "feat"])
        try await fixture.repo.git(["config", "filter.bad.smudge", "false"])
        try await fixture.repo.git(["config", "filter.bad.required", "true"])

        let error = await thrownError {
            _ = try await fixture.backend.addWorktree(path: fixture.path("wt"), branch: "feat", at: fixture.repo.root)
        }

        guard case .commandFailed(let code, let words) = error as? GitError else {
            Issue.record("expected GitError.commandFailed, got \(String(describing: error))")
            return
        }
        #expect(code == 128)
        #expect(words.contains("smudge filter bad failed"), "\(words)")
        #expect(try await !fixture.isListed("wt"))
        #expect(!fixture.exists("wt"))
    }
}
