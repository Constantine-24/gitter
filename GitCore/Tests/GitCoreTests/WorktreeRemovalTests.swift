import Foundation
import Testing

@testable import GitCore

/// `GitWorktreeBackend.removalCheck` and `removeWorktree` (B3 Task 2): Gitter's own check for
/// everything git's `worktree remove` deletes without asking (R20, R21), the check made again just
/// before git runs (RF1), git run with `status.showUntrackedFiles=normal` forced so it refuses a
/// file that appeared in between (R21, R24), and `list` read back afterwards.
///
/// Every refusal that guards a silent deletion is paired with a `withKnownIssue` control: raw git,
/// on the same worktree, really deletes what Gitter refused to.
@Suite struct WorktreeRemovalTests {

    /// A fixture with a clean linked worktree `wt` on branch `w`.
    private func fixtureWithWorktree() async throws -> (WorktreeFixture, TestRepo) {
        let fixture = try await WorktreeFixture.make()
        try await fixture.addOnNewBranch("wt", "w")
        return (fixture, fixture.repo(at: "wt"))
    }

    private func check(_ fixture: WorktreeFixture, _ name: String, limit: WorktreeWalkLimit = .standard) async throws -> WorktreeRemoval {
        try await fixture.backend.removalCheck(try await fixture.listed(name), at: fixture.repo.root, walkLimit: limit)
    }

    /// Raw `git worktree remove <path>` from main, any exit code: the unguarded form.
    private func rawRemove(_ fixture: WorktreeFixture, _ name: String) async throws {
        try await fixture.repo.git(["worktree", "remove", fixture.path(name)], allowedExitCodes: [128, 255])
    }

    // MARK: - A clean worktree

    /// Nothing refuses a clean worktree on a branch. Its ignored files are counted and named, the
    /// removal deletes them with the folder, the branch stays, and git is run once with
    /// `status.showUntrackedFiles=normal` forced, by the path `list` printed — never `prune`.
    @Test func aCleanBranchWorktreeIsRemovedWithItsIgnoredFilesAndItsBranchStays() async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        try wt.write(".build/out.o", "o\n")
        try wt.write(".build/deep/x.o", "x\n")
        try wt.write("a.log", "l\n")
        let branchTip = try await fixture.repo.revParse("refs/heads/w")

        let removal = try await check(fixture, "wt")

        #expect(removal.refusals == [])
        #expect(removal.changes == WorktreeChanges.none)
        #expect(removal.ignored == IgnoredSummary(count: 2, topLevel: [".build/", "a.log"]))
        #expect(removal.stranded == .none)
        #expect(removal.worktree.path == fixture.listedPath("wt"))

        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }
        let kept = try await git.backend.removeWorktree(removal, keeping: [:], at: fixture.repo.root)

        #expect(kept == [])
        #expect(try await !fixture.isListed("wt"))
        #expect(!fixture.exists("wt"))
        #expect(try await fixture.repo.revParse("refs/heads/w") == branchTip)
        #expect(git.launches(startingWith: "worktree remove")
            == ["worktree remove --end-of-options \(fixture.listedPath("wt")) | 2 status.showUntrackedFiles normal core.fsmonitor false"])
        #expect(!git.launches.contains { $0.contains("prune") })
        // The control for every "nothing launched" in this suite: a removal does launch git
        // through the same wrapper.
        withKnownIssue("git really ran") {
            #expect(git.launches(startingWith: "worktree remove") == [])
        }
    }

    /// The topmost names of the ignored entries, at most ten, in git's order; the count is every
    /// entry `status` listed.
    @Test func theIgnoredSummaryCountsEveryEntryAndNamesTenTopLevelNames() async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        for n in 0..<12 { try wt.write("d\(n)/x.log", "l\n") }
        try wt.write("d0/y.log", "l\n")

        let removal = try await check(fixture, "wt")

        #expect(removal.ignored.count == 13)
        #expect(removal.ignored.topLevel == ["d0/", "d1/", "d10/", "d11/", "d2/", "d3/", "d4/", "d5/", "d6/", "d7/"])
        #expect(removal.refusals == [])
    }

    // MARK: - Refusals

    /// The main worktree is refused before anything else is read — from another worktree and from
    /// its own window — and `removeWorktree` throws the refusal with nothing launched.
    @Test func theMainWorktreeIsRefused() async throws {
        let (fixture, _) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        let main = try await fixture.backend.worktrees(at: fixture.repo.root)[0]

        let fromLinked = try await fixture.backend.removalCheck(main, at: URL(fileURLWithPath: fixture.path("wt")))
        let fromMain = try await fixture.backend.removalCheck(main, at: fixture.repo.root)

        #expect(fromLinked.refusals == [.isMain])
        #expect(fromLinked.changes == nil)
        #expect(fromMain.refusals == [.isMain, .isOpenHere])
        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }
        let error = await thrownError { _ = try await git.backend.removeWorktree(fromLinked, keeping: [:], at: fixture.repo.root) }
        #expect(error as? WorktreeRemovalRefusal == .isMain)
        #expect(git.launches == [])
    }

    /// The worktree this window has open — named by `/var/…`, listed as `/private/var/…` — is
    /// refused: git would remove it from under the app (R20).
    @Test func theWorktreeOpenHereIsRefused() async throws {
        let (fixture, _) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        let here = URL(fileURLWithPath: fixture.path("wt"))
        #expect(here.path != fixture.listedPath("wt"), "the window's path is the unresolved spelling")

        let removal = try await fixture.backend.removalCheck(try await fixture.listed("wt"), at: here)

        #expect(removal.refusals == [.isOpenHere])
        // The control: git removes the worktree it is run in, and exits 0 (R20).
        try await fixture.repo(at: "wt").git(["worktree", "remove", fixture.path("wt")])
        withKnownIssue("git removes the worktree it is run from") {
            #expect(fixture.exists("wt"))
        }
    }

    @Test func aLockedWorktreeIsRefusedWithItsReason() async throws {
        let (fixture, _) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["worktree", "lock", "--reason", "in use by CI", fixture.path("wt")])

        let removal = try await check(fixture, "wt")

        #expect(removal.refusals == [.locked(reason: "in use by CI")])
        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }
        let error = await thrownError { _ = try await git.backend.removeWorktree(removal, keeping: [:], at: fixture.repo.root) }
        #expect(error as? WorktreeRemovalRefusal == .locked(reason: "in use by CI"))
        #expect(git.launches == [])
    }

    /// A rebase, a merge with nothing to commit, or a bisect part-way through is refused: git
    /// removes the worktree and the operation's state with it (R20).
    @Test(arguments: ["rebase", "merge", "bisect"])
    func anOperationInProgressIsRefused(operation: String) async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        try wt.write("o.txt", "1\n")
        try await wt.commitAll("o1")
        try wt.write("o.txt", "2\n")
        try await wt.commitAll("o2")
        switch operation {
        case "rebase":
            try await wt.git(["rebase", "-q", "-x", "false", "w~1"], allowedExitCodes: [1])
        case "merge":
            try fixture.repo.write("m.txt", "m\n")
            try await fixture.repo.commitAll("m")
            try await wt.git(["merge", "-q", "--no-ff", "--no-commit", "-s", "ours", "main"])
        default:
            try await wt.git(["bisect", "start", "HEAD", "HEAD~2"])
        }

        let removal = try await check(fixture, "wt")

        #expect(removal.refusals == [.operationInProgress(operation)])
        #expect(removal.changes == WorktreeChanges.none, "nothing but the operation stops it")
        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }
        let error = await thrownError { _ = try await git.backend.removeWorktree(removal, keeping: [:], at: fixture.repo.root) }
        #expect(error as? WorktreeRemovalRefusal == .operationInProgress(operation))
        #expect(git.launches == [])
        #expect(fixture.exists("wt"))
        try await rawRemove(fixture, "wt")
        withKnownIssue("git removes a worktree mid-\(operation) (R20)") {
            #expect(fixture.exists("wt"))
        }
    }

    @Test func changesAreRefused() async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        try wt.write("f.txt", "changed\n")
        try wt.write("new.txt", "n\n")

        let removal = try await check(fixture, "wt")

        #expect(removal.refusals == [.changes(WorktreeChanges(staged: 0, unstaged: 1, untracked: 1, conflicted: 0))])
        #expect(removal.changes == WorktreeChanges(staged: 0, unstaged: 1, untracked: 1, conflicted: 0))
    }

    /// An edit to an assume-unchanged file is invisible to `status` and to git's own check, and
    /// `remove` deletes it (R21).
    @Test func anAssumeUnchangedEntryIsRefused() async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        try await wt.git(["update-index", "--assume-unchanged", "f.txt"])
        try wt.write("f.txt", "edit nobody can see\n")

        let removal = try await check(fixture, "wt")

        #expect(removal.changes == WorktreeChanges.none, "status cannot see the edit")
        #expect(removal.refusals == [.assumeUnchanged(["f.txt"])])
        try await rawRemove(fixture, "wt")
        withKnownIssue("git deletes an assume-unchanged edit (R21)") {
            #expect(fixture.exists("wt/f.txt"))
        }
    }

    /// The same for a skip-worktree file that is present; one that is absent (as sparse checkout
    /// leaves it) holds nothing to lose.
    @Test func aPresentSkipWorktreeFileIsRefusedAndAnAbsentOneIsNot() async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        try await wt.git(["update-index", "--skip-worktree", "g.txt", "f.txt"])
        try FileManager.default.removeItem(at: wt.root.appendingPathComponent("f.txt"))
        try wt.write("g.txt", "edit nobody can see\n")

        let removal = try await check(fixture, "wt")

        #expect(removal.changes == WorktreeChanges.none)
        #expect(removal.refusals == [.skipWorktreePresent(["g.txt"])])
        try await rawRemove(fixture, "wt")
        withKnownIssue("git deletes a skip-worktree edit (R21)") {
            #expect(fixture.exists("wt/g.txt"))
        }
    }

    /// A repository inside an ignored folder — history and all — is deleted by `remove` without a
    /// word (R21). Gitter walks the ignored folders for a `.git` and refuses.
    @Test func aRepositoryNestedInAnIgnoredFolderIsRefused() async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        let inner = TestRepo(root: wt.root.appendingPathComponent("build/inner"))
        try FileManager.default.createDirectory(at: inner.root, withIntermediateDirectories: true)
        try await inner.git(["init", "-q", "-b", "main"])
        try wt.write("build/out.o", "o\n")

        let removal = try await check(fixture, "wt")

        #expect(removal.changes == WorktreeChanges.none)
        #expect(removal.ignored == IgnoredSummary(count: 1, topLevel: ["build/"]))
        #expect(removal.refusals == [.nestedRepository(["build/inner"])])
        try await rawRemove(fixture, "wt")
        withKnownIssue("git deletes a repository nested in an ignored folder (R21)") {
            #expect(fixture.exists("wt/build/inner/.git"))
        }
    }

    /// Past the walk's cap — entries or time — a nested repository cannot be ruled out: refused.
    @Test func aWalkPastItsCapIsRefusedAsTooLargeToCheck() async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        for n in 0..<10 { try wt.write(".build/f\(n).o", "o\n") }

        let small = try await check(fixture, "wt", limit: WorktreeWalkLimit(entries: 5, seconds: 60))
        let quick = try await check(fixture, "wt", limit: WorktreeWalkLimit(entries: 1_000, seconds: 0))
        let standard = try await check(fixture, "wt")

        #expect(small.refusals == [.tooLargeToCheck])
        #expect(quick.refusals == [.tooLargeToCheck])
        #expect(standard.refusals == [], "the same tree within the cap is checked")
    }

    /// An ignored folder Gitter cannot read is not "no repository there" (carried note 4).
    @Test func anUnreadableIgnoredFolderIsRefused() async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        let sealed = wt.root.appendingPathComponent("build/sealed")
        try wt.write("build/sealed/x.o", "o\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealed.path) }

        let removal = try await check(fixture, "wt")

        #expect(removal.refusals.count == 1)
        guard case .unreadable(let path) = removal.refusals.first else {
            Issue.record("expected .unreadable, got \(removal.refusals)")
            return
        }
        #expect(path.hasSuffix("build/sealed"))
    }

    // MARK: - Fix round 1: what `status` cannot see (I1, I2, m7)

    /// A folder named `.git` — or `.GIT`, which APFS takes for the same name — anywhere in the
    /// worktree, a tracked folder included: `status` skips every such path component, so nothing
    /// in it is a change, and `remove` deletes it. The whole worktree is walked, and any `.git`
    /// entry but the worktree's own refuses.
    @Test(arguments: ["src/.git", "src/.GIT"])
    func aDotGitFolderInATrackedFolderIsRefused(dotGit: String) async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        try wt.write("src/a.txt", "a\n")
        try await wt.commitAll("src")
        try wt.write("\(dotGit)/precious.txt", "p\n")

        let removal = try await check(fixture, "wt")

        #expect(removal.changes == WorktreeChanges.none, "status cannot see it")
        #expect(removal.refusals == [.nestedRepository(["src"])])
        try await rawRemove(fixture, "wt")
        withKnownIssue("git deletes what is under a `.git` folder status skips") {
            #expect(fixture.exists("wt/\(dotGit)/precious.txt"))
        }
    }

    /// A real repository whose git directory is spelled `.GIT`, inside an ignored folder: git reads
    /// it (case-insensitive APFS), and `remove` deletes its history.
    @Test func aRepositoryWhoseGitDirectoryIsSpelledInCapitalsIsRefused() async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        let inner = TestRepo(root: wt.root.appendingPathComponent("build/inner"))
        try FileManager.default.createDirectory(at: inner.root, withIntermediateDirectories: true)
        try await inner.git(["init", "-q", "-b", "main"])
        try inner.write("x.txt", "x\n")
        try await inner.git(["add", "x.txt"])
        try await inner.git(["-c", "user.email=t@t", "-c", "user.name=T", "commit", "-qm", "inner history"])
        try FileManager.default.moveItem(
            at: inner.root.appendingPathComponent(".git"), to: inner.root.appendingPathComponent(".GIT"))
        // Not vacuous: git still reads the repository through `.GIT`.
        #expect(!(try await inner.git(["log", "--oneline"])).isEmpty)

        let removal = try await check(fixture, "wt")

        #expect(removal.refusals == [.nestedRepository(["build/inner"])])
        try await rawRemove(fixture, "wt")
        withKnownIssue("git deletes a repository spelled `.GIT` in an ignored folder") {
            #expect(fixture.exists("wt/build/inner/.GIT/HEAD"))
        }
    }

    /// A folder `status` cannot open — not an ignored one — is only a warning to git (exit 0), and
    /// the check refuses it rather than calling the worktree clean.
    @Test func anUnreadableFolderOutsideTheIgnoredOnesIsRefused() async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        let sealed = wt.root.appendingPathComponent("src/sealed")
        try wt.write("src/sealed/p.txt", "p\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: sealed.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sealed.path) }

        let removal = try await check(fixture, "wt")

        #expect(removal.refusals == [.unreadable(fixture.listedPath("wt") + "/src/sealed")])
        try await rawRemove(fixture, "wt")
        withKnownIssue("git calls it clean and deletes the tracked files around it") {
            #expect(fixture.exists("wt/f.txt"))
        }
    }

    /// The status reads look past the walk: an unreadable folder named by `status`'s warning.
    @Test func statusWarningsNameTheFoldersTheyCouldNotOpen() {
        let stderr = "warning: could not open directory 'src/sealed/': Permission denied\n"
            + "warning: could not open directory 'a b/c/': Permission denied\nwarning: something else\n"

        #expect(CLIGitBackend.unopenedFolders(in: stderr) == ["src/sealed", "a b/c"])
    }

    /// A `core.fsmonitor` hook that says nothing changed hides an edit to a tracked file from
    /// `status` and from git's own remove check. The check's reads, and the remove, run with
    /// `core.fsmonitor=false` forced.
    @Test func aLyingFsmonitorHookDoesNotHideAnEdit() async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        let hook = fixture.base.appendingPathComponent("fsmonitor.sh")
        try "#!/bin/sh\nprintf 'token\\0'\n".write(to: hook, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        try await fixture.repo.git(["config", "core.fsmonitor", hook.path])
        try await wt.git(["update-index", "--fsmonitor"])
        try await wt.git(["update-index", "--fsmonitor-valid", "f.txt"])
        try wt.write("f.txt", "an edit the hook hides\n")
        // Not vacuous: git's own status, trusting the hook, sees nothing.
        #expect(try await wt.git(["status", "--porcelain=v2", "-z"]).isEmpty)

        let removal = try await check(fixture, "wt")

        #expect(removal.refusals == [.changes(WorktreeChanges(staged: 0, unstaged: 1, untracked: 0, conflicted: 0))])
        try await rawRemove(fixture, "wt")
        withKnownIssue("git, trusting the hook, deletes the edit") {
            #expect(fixture.exists("wt/f.txt"))
        }
    }

    // MARK: - Fix round 1: a half-done remove (I3)

    /// git takes the worktree out of `list` and then cannot finish: a folder it cannot empty, or
    /// the folder replaced by a link after the check. Not a success — `removedWithLeftovers`, with
    /// git's words.
    @Test(arguments: ["undeletable", "symlink"])
    func aRemoveGitCouldNotFinishIsRemovedWithLeftovers(how: String) async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        let stuck = fixture.path("wt/build/x")
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stuck) }
        var swap: String?
        if how == "undeletable" {
            try wt.write("build/x/o.o", "o\n")
            try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: stuck)
        } else {
            swap = "mv '\(fixture.path("wt"))' '\(fixture.path("wt-real"))' && ln -s '\(fixture.path("wt-real"))' '\(fixture.path("wt"))'"
        }
        let removal = try await check(fixture, "wt")
        #expect(removal.refusals == [])
        let git = try WorktreeLaunchLog(beforeRemove: swap)
        defer { git.cleanUp() }

        let error = await thrownError { _ = try await git.backend.removeWorktree(removal, keeping: [:], at: fixture.repo.root) }

        guard case .removedWithLeftovers(let words, let kept) = error as? WorktreeRemovalPartial else {
            Issue.record("expected .removedWithLeftovers, got \(String(describing: error))")
            return
        }
        #expect(words.contains("failed to delete"), "\(words)")
        #expect(kept == [])
        #expect(try await !fixture.isListed("wt"))
        // The control: git's own exit says it failed, and the worktree has left `list` anyway.
        try await fixture.addOnNewBranch("wt2", "w2")
        try fixture.write("wt2/build/y/o.o", "o\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: fixture.path("wt2/build/y"))
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.path("wt2/build/y")) }
        try await fixture.repo.git(["worktree", "remove", fixture.path("wt2")], allowedExitCodes: [255])
        let stillListed = try await fixture.isListed("wt2")
        withKnownIssue("an unlisted worktree is not a removed one") {
            #expect(stillListed)
        }
    }

    /// A worktree whose folder is a link (to the real one) by the time of the check: refused,
    /// with nothing read through the link.
    @Test func aWorktreeFolderThatIsALinkIsRefused() async throws {
        let (fixture, _) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        try FileManager.default.moveItem(atPath: fixture.path("wt"), toPath: fixture.path("wt-real"))
        try FileManager.default.createSymbolicLink(atPath: fixture.path("wt"), withDestinationPath: fixture.path("wt-real"))

        let removal = try await check(fixture, "wt")

        #expect(removal.refusals == [.unreadable(fixture.listedPath("wt"))])
        #expect(removal.changes == nil)
    }

    // MARK: - Fix round 1: the walk (Ruling 5)

    @Test func theWalksCapIsHalfAMillionEntriesOrThreeSeconds() {
        #expect(WorktreeWalkLimit.standard == WorktreeWalkLimit(entries: 500_000, seconds: 3))
    }

    /// The walk gives up when its task is cancelled, rather than walking on to the cap.
    @Test func theWalkStopsWhenCancelled() async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        for n in 0..<5_000 {
            try Data().write(to: wt.root.appendingPathComponent("many-\(n).o"))
        }
        let folder = URL(fileURLWithPath: fixture.listedPath("wt"), isDirectory: true)

        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try CLIGitBackend.walkForNestedRepositories(in: folder, limit: .standard)
        }
        let error = await thrownError { _ = try await task.value }

        #expect(error is CancellationError)
    }

    // MARK: - A detached worktree's own commits (R22)

    /// Two commits only a detached worktree's HEAD holds are stranded by its removal — its HEAD
    /// reflog goes with it. Counted against every other worktree's HEAD, never this one's.
    @Test func aDetachedWorktreesOwnCommitsAreStranded() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.addRaw("det", ["--detach", "main"])
        let det = fixture.repo(at: "det")
        try det.write("d.txt", "1\n")
        try await det.commitAll("d1")
        let d1 = try await det.headSha()
        try det.write("d.txt", "2\n")
        try await det.commitAll("d2")
        let d2 = try await det.headSha()

        let removal = try await check(fixture, "det")

        #expect(removal.stranded.count == 2)
        #expect(removal.stranded.commits.map(\.sha) == [d2, d1])
        #expect(removal.stranded.holders == [fixture.listedPath("det")])
        #expect(removal.refusals == [])
        // The control: `--all` counts this worktree's HEAD as a holder, and says nothing is lost.
        let all = String(decoding: try await fixture.repo.git(["rev-list", "--count", d2, "--not", "--all"]), as: UTF8.self)
        withKnownIssue("`--all` includes the worktree being removed (R22)") {
            #expect(all.trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        }
    }

    /// Another worktree detached at the same commit holds it: nothing is stranded.
    @Test func anotherWorktreesHeadHoldsTheCommits() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.addRaw("det", ["--detach", "main"])
        let det = fixture.repo(at: "det")
        try det.write("d.txt", "1\n")
        try await det.commitAll("d1")
        try await fixture.addRaw("twin", ["--detach", try await det.headSha()])

        #expect(try await check(fixture, "det").stranded == .none)
    }

    /// With `keeping`, the branch is created at the worktree's HEAD before git removes it; without,
    /// no ref changes at all.
    @Test(arguments: [true, false])
    func aKeptBranchIsCreatedFirstAndNothingElseChanges(keep: Bool) async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.addRaw("det", ["--detach", "main"])
        let det = fixture.repo(at: "det")
        try det.write("d.txt", "1\n")
        try await det.commitAll("d1")
        try det.write("d.txt", "2\n")
        try await det.commitAll("d2")
        let d2 = try await det.headSha()
        let before = try await fixture.branches()
        let removal = try await check(fixture, "det")
        let keeping = keep ? [fixture.listedPath("det"): "saved"] : [:]
        // What `refs/heads/saved` holds at the moment `worktree remove` is handed to git.
        let atRemove = fixture.base.appendingPathComponent("saved-at-remove").path
        let git = try WorktreeLaunchLog(
            beforeRemove: "/usr/bin/git -C '\(fixture.repo.root.path)' rev-parse -q --verify refs/heads/saved > '\(atRemove)'")
        defer { git.cleanUp() }

        let kept = try await git.backend.removeWorktree(removal, keeping: keeping, at: fixture.repo.root)

        #expect(try await !fixture.isListed("det"))
        let savedAtRemove = try String(contentsOfFile: atRemove, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        if keep {
            #expect(savedAtRemove == d2, "the kept branch exists before git removes the worktree")
            #expect(kept == ["saved"])
            #expect(try await fixture.repo.revParse("refs/heads/saved") == d2)
            #expect(try await fixture.repo.symbolicRef("refs/heads/saved") == nil)
        } else {
            #expect(savedAtRemove == "")
            #expect(kept == [])
            #expect(try await fixture.branches() == before)
        }
    }

    /// A key that is not one of the removal's holders is refused before git runs.
    @Test func aKeepForSomethingElseIsRefusedBeforeGitRuns() async throws {
        let (fixture, _) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        let removal = try await check(fixture, "wt")
        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }

        let error = await thrownError {
            _ = try await git.backend.removeWorktree(removal, keeping: [fixture.listedPath("wt"): "saved"], at: fixture.repo.root)
        }

        #expect(error as? BranchOperationError == .invalidName(fixture.listedPath("wt")))
        #expect(git.launches == [])
        #expect(try await fixture.isListed("wt"))
    }

    // MARK: - RF1: changed since the sheet was drawn

    /// A commit, a lock or a rebase made after the check: the removal is refused with nothing
    /// created or removed, and `worktree remove` is never launched.
    @Test(arguments: ["commit", "lock", "rebase"])
    func aChangeAfterTheCheckIsRefusedAndNothingIsDeleted(change: String) async throws {
        let (fixture, wt) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        try wt.write("o.txt", "1\n")
        try await wt.commitAll("o1")
        try wt.write("o.txt", "2\n")
        try await wt.commitAll("o2")
        let removal = try await check(fixture, "wt")
        #expect(removal.refusals == [])

        switch change {
        case "commit":
            try wt.write("o.txt", "3\n")
            try await wt.commitAll("o3")
        case "lock":
            try await fixture.repo.git(["worktree", "lock", fixture.path("wt")])
        default:
            try await wt.git(["rebase", "-q", "-x", "false", "w~1"], allowedExitCodes: [1])
        }
        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }

        let error = await thrownError { _ = try await git.backend.removeWorktree(removal, keeping: [:], at: fixture.repo.root) }

        #expect(error as? WorktreeRemovalPartial == .changedSinceShown)
        #expect(git.launches(startingWith: "worktree remove") == [])
        #expect(try await fixture.isListed("wt"))
        #expect(fixture.exists("wt/o.txt"))
    }

    /// A worktree no longer listed has nothing to check.
    @Test func aWorktreeNoLongerListedIsChangedSinceShown() async throws {
        let (fixture, _) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        let wt = try await fixture.listed("wt")
        try await fixture.repo.git(["worktree", "remove", fixture.path("wt")])

        let error = await thrownError { _ = try await fixture.backend.removalCheck(wt, at: fixture.repo.root) }

        #expect(error as? WorktreeRemovalPartial == .changedSinceShown)
    }

    // MARK: - RF3: a file appears between the check and git (R21, R24)

    /// Under the user's `status.showUntrackedFiles=no`, an untracked file created after Gitter's
    /// last check — just before `worktree remove` starts — makes git refuse, because Gitter forces
    /// the setting back to `normal`; the file stays. The control: raw git, without the forced
    /// setting, deletes it.
    @Test func anUntrackedFileThatAppearsAfterTheCheckMakesGitRefuse() async throws {
        let (fixture, _) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["config", "status.showUntrackedFiles", "no"])
        let removal = try await check(fixture, "wt")
        #expect(removal.refusals == [])
        let late = fixture.path("wt") + "/late.txt"
        let git = try WorktreeLaunchLog(beforeRemove: "echo late > '\(late)'")
        defer { git.cleanUp() }

        let error = await thrownError { _ = try await git.backend.removeWorktree(removal, keeping: [:], at: fixture.repo.root) }

        guard case .refusedByGit(let words, let kept) = error as? WorktreeRemovalPartial else {
            Issue.record("expected .refusedByGit, got \(String(describing: error))")
            return
        }
        #expect(words.contains("contains modified or untracked files"), "\(words)")
        #expect(kept == [])
        #expect(FileManager.default.fileExists(atPath: late))
        #expect(try await fixture.isListed("wt"))

        // The control, on a second worktree under the same setting.
        try await fixture.addOnNewBranch("wt2", "w2")
        try fixture.write("wt2/late.txt", "late\n")
        try await rawRemove(fixture, "wt2")
        withKnownIssue("git deletes an untracked file under status.showUntrackedFiles=no (R21)") {
            #expect(fixture.exists("wt2/late.txt"))
        }
    }

    /// Cancelled while git would be removing: whether the worktree is gone is not known, and
    /// the error says so — never "nothing happened". Not vacuous: uncancelled, the stall ends and
    /// git removes the worktree, and nothing is thrown.
    @Test func aCancelledRemovalIsOutcomeUnknown() async throws {
        let (fixture, _) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        let removal = try await check(fixture, "wt")
        let started = fixture.base.appendingPathComponent("remove-started").path
        let git = try WorktreeLaunchLog(beforeRemove: "touch '\(started)'; /bin/sleep 30")
        defer { git.cleanUp() }
        let backend = git.backend
        let root = fixture.repo.root

        let task = Task { try await backend.removeWorktree(removal, keeping: [:], at: root) }
        let clock = ContinuousClock()
        let start = clock.now
        while !FileManager.default.fileExists(atPath: started), clock.now - start < .seconds(60) {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        let error = await thrownError { _ = try await task.value }

        #expect(error as? WorktreeRemovalPartial == .outcomeUnknown(keptBranches: []))
    }

    // MARK: - A missing worktree (R25)

    /// No folder: no changes, no walk, nothing refuses it. Removed by the path `list` printed,
    /// with `worktree remove` — `prune` is never launched.
    @Test func aMissingWorktreeIsRemovedByItsListedPath() async throws {
        let (fixture, _) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        try FileManager.default.removeItem(atPath: fixture.path("wt"))

        let removal = try await check(fixture, "wt")

        #expect(removal.worktree.isMissing)
        #expect(removal.changes == nil)
        #expect(removal.ignored == .none)
        #expect(removal.refusals == [])
        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }
        #expect(try await git.backend.removeWorktree(removal, keeping: [:], at: fixture.repo.root) == [])
        #expect(try await !fixture.isListed("wt"))
        #expect(git.launches(startingWith: "worktree remove")
            == ["worktree remove --end-of-options \(fixture.listedPath("wt")) | 2 status.showUntrackedFiles normal core.fsmonitor false"])
        #expect(!git.launches.contains { $0.contains("prune") }, "\(git.launches)")
        #expect(try await fixture.repo.revParse("refs/heads/w") != "")
    }

    @Test func aLockedMissingWorktreeIsRefused() async throws {
        let (fixture, _) = try await fixtureWithWorktree()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["worktree", "lock", "--reason", "on a disk", fixture.path("wt")])
        try FileManager.default.removeItem(atPath: fixture.path("wt"))

        let removal = try await check(fixture, "wt")

        #expect(removal.changes == nil)
        #expect(removal.refusals == [.locked(reason: "on a disk")])
        let git = try WorktreeLaunchLog()
        defer { git.cleanUp() }
        let error = await thrownError { _ = try await git.backend.removeWorktree(removal, keeping: [:], at: fixture.repo.root) }
        #expect(error as? WorktreeRemovalRefusal == .locked(reason: "on a disk"))
        #expect(git.launches == [])
        #expect(try await fixture.isListed("wt"))
    }
}
