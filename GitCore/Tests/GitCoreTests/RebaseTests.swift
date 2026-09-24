import Foundation
import Testing

@testable import GitCore

/// `rebase(onto:at:)`: the "Rebase" half of a diverged pull, against a local bare origin and a
/// colleague who pushed to it. Every outcome is asserted against the repository git left
/// behind, never against what git printed or how it exited.
@Suite struct RebaseTests {
    /// A pull that needs integrating: two local commits on `main`, one commit the colleague
    /// pushed to `origin/main`, fetched. `conflicting` makes the colleague and the *second*
    /// local commit change the same line of `a.txt`, so the rebase stops half-way — after one
    /// commit has already been rewritten.
    struct Lab {
        let repo: TestRepo
        let origin: URL
        let colleague: TestRepo
        /// `main` before the rebase.
        let oldTip: String

        func cleanUp() {
            repo.cleanUp()
            colleague.cleanUp()
            try? FileManager.default.removeItem(at: origin)
        }
    }

    static func makeLab(conflicting: Bool = false) async throws -> Lab {
        let repo = try await TestRepo.makeBranched()
        let origin = try await repo.addOriginWithFeatureBranch()
        let colleague = try await repo.addColleague()
        try colleague.write(conflicting ? "a.txt" : "theirs.txt", "theirs\n")
        try await colleague.commitAll("their change")
        try await colleague.git(["push", "-q", "origin", "main"])

        try repo.write("l1.txt", "local one\n")
        try await repo.commitAll("local one")
        try repo.write(conflicting ? "a.txt" : "l2.txt", "mine\n")
        try await repo.commitAll("local two")
        try await repo.git(["fetch", "-q", "origin"])
        return Lab(repo: repo, origin: origin, colleague: colleague, oldTip: try await repo.headSha())
    }

    // MARK: - Rebased

    /// Both spellings a caller will use, and a full object name.
    @Test(arguments: ["origin/main", "refs/remotes/origin/main", "sha"])
    func aDivergedBranchIsRebasedOntoItsUpstream(spelling: String) async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        let upstreamTip = try await repo.revParse("origin/main")
        let upstream = spelling == "sha" ? upstreamTip : spelling
        let oldCommits = try await Self.commits(in: "origin/main@{1}..\(lab.oldTip)", repo)
        #expect(oldCommits.count == 2)

        let outcome = try await CLIGitBackend().rebase(onto: upstream, at: repo.root)

        #expect(outcome == .rebased)
        #expect(try await repo.currentBranch() == "main")
        // The old tip is where git says it is, for anyone who wants it back.
        #expect(try await repo.revParse("ORIG_HEAD") == lab.oldTip)
        // The upstream is now underneath, and the history on top of it is a straight line.
        #expect(try await repo.revParse("HEAD~2") == upstreamTip)
        let merges = try await repo.git(["rev-list", "--merges", "HEAD"])
        #expect(merges.isEmpty)
        // The local commits are *new* objects carrying the same subjects and the same changes.
        let newCommits = try await Self.commits(in: "origin/main..HEAD", repo)
        #expect(newCommits.map(\.subject) == oldCommits.map(\.subject))
        #expect(Set(newCommits.map(\.sha)).isDisjoint(with: oldCommits.map(\.sha)))
        #expect(newCommits.map(\.patch) == oldCommits.map(\.patch))
        #expect(!newCommits[0].patch.isEmpty)
    }

    /// Nothing local to replay and something to bring in: git moves the branch to the
    /// upstream's tip without rewriting anything. Its own words for it are "Successfully
    /// rebased", but no commit was rewritten, and the sheet must not say one was.
    @Test func aBranchWithNothingLocalIsFastForwarded() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        try await repo.git(["reset", "-q", "--hard", "origin/main~1"])
        let before = try await repo.headSha()

        let outcome = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)

        #expect(outcome == .fastForwarded)
        #expect(try await repo.headSha() == (try await repo.revParse("origin/main")))
        #expect(try await repo.parents(of: "HEAD") == [before])
        #expect(try await repo.currentBranch() == "main")
    }

    /// A local commit whose change the upstream already has is dropped (git: "skipped
    /// previously applied commit"), so HEAD lands exactly on the upstream's tip — as it does
    /// for a fast-forward. It is not one: the old tip is not an ancestor of the new one, a
    /// commit is off the branch, and "fast-forwarded" would hide that.
    @Test func aDroppedAlreadyAppliedCommitIsRebasedNotFastForwarded() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        try await repo.git(["reset", "-q", "--hard", "origin/main~1"])
        try repo.write("theirs.txt", "theirs\n")
        try await repo.commitAll("the same change, made here")

        let outcome = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)

        #expect(outcome == .rebased)
        #expect(try await repo.headSha() == (try await repo.revParse("origin/main")))
    }

    /// "The upstream is already an ancestor" is not the same as "nothing to do". Measured on
    /// git 2.54: a branch whose own history holds a merge commit is *flattened* by a plain
    /// rebase — the merge commit is dropped and the commits under it replayed — even when the
    /// upstream is already underneath. HEAD moves, so this is `.rebased`.
    @Test func aMergeCommitAboveTheUpstreamIsFlattened() async throws {
        let repo = try await TestRepo.makeAlreadyMerged()
        defer { repo.cleanUp() }
        let before = try await repo.headSha()
        #expect(try await repo.parents(of: "HEAD").count == 2)

        let outcome = try await CLIGitBackend().rebase(onto: "feature", at: repo.root)

        #expect(outcome == .rebased)
        #expect(try await repo.headSha() != before)
        let merges = try await repo.git(["rev-list", "--merges", "HEAD"])
        #expect(merges.isEmpty)
    }

    // MARK: - Up to date

    /// git: "Current branch main is up to date." Both shapes of it — the upstream behind the
    /// branch, and the two at the same commit — and nothing at all is written.
    @Test(arguments: ["ahead", "level"])
    func anUpstreamAlreadyUnderneathIsUpToDate(shape: String) async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        if shape == "ahead" {
            try await repo.git(["reset", "-q", "--hard", "origin/main"])
            try repo.write("l3.txt", "ahead\n")
            try await repo.commitAll("ahead only")
        } else {
            try await repo.git(["reset", "-q", "--hard", "origin/main"])
        }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let outcome = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)

        #expect(outcome == .upToDate)
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    // MARK: - Refusals over uncommitted work

    /// Stricter than a merge: a change to a file the rebase never touches refuses it too.
    @Test(arguments: ["unstaged", "staged", "both"])
    func anyUncommittedChangeRefusesTheRebase(kind: String) async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        try repo.write("keep.txt", "edited\n")
        if kind != "unstaged" { try await repo.git(["add", "keep.txt"]) }
        if kind == "both" { try repo.write("l1.txt", "edited too\n") }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            _ = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)
        }

        #expect(error == .treeNotClean)
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// `rebase.autoStash=true` is git's own way round that refusal, and measured on git 2.54
    /// it takes it silently: "Created autostash", the rebase, "Applied autostash", exit 0. That
    /// is `--autostash` — forbidden in this package — reached from the user's configuration.
    /// Gitter refuses before git runs, and the vector's `--no-autostash` would make git refuse
    /// too (see the next test, which gets past Gitter's check).
    @Test func aConfiguredAutoStashDoesNotGetRoundTheRefusal() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        try await repo.git(["config", "rebase.autoStash", "true"])
        try repo.write("keep.txt", "edited\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            _ = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)
        }

        #expect(error == .treeNotClean)
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.gitRefExists("refs/stash") == false)
    }

    /// The race Gitter's own check cannot close: a change made *after* it and before git
    /// runs. A wrapper standing in for `/usr/bin/git` makes that change the moment it is asked
    /// to rebase, then execs the real git — so Gitter's check saw a clean tree and git did not.
    /// Under `rebase.autoStash=true` git would stash the change, rebase, and re-apply it
    /// (measured). The vector's `--no-autostash` makes git's own refusal authoritative: it is
    /// made by the process that rebases, at the moment it rebases, and nothing moves.
    @Test func aChangeMadeAfterGittersCheckIsStillRefusedUnderAutoStash() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        try await repo.git(["config", "rebase.autoStash", "true"])
        let wrapper = repo.root.deletingLastPathComponent()
            .appendingPathComponent("git-dirtying-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: wrapper) }
        let script = """
            #!/bin/sh
            if [ "$1" = rebase ]; then printf 'edited late\\n' > keep.txt; fi
            exec /usr/bin/git "$@"
            """
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        #expect(try repo.fileContents("keep.txt") != "edited late\n")

        let error = await branchError {
            _ = try await CLIGitBackend(gitPath: wrapper.path).rebase(onto: "origin/main", at: repo.root)
        }

        #expect(error == .treeNotClean)
        #expect(try await repo.headSha() == lab.oldTip)
        #expect(try await repo.currentBranch() == "main")
        #expect(try await repo.gitRefExists("refs/stash") == false)
        #expect(try await CLIGitBackend().operationInProgress(at: repo.root) == nil)
        // The late change is where the user left it: not stashed, not re-applied, not lost.
        #expect(try repo.fileContents("keep.txt") == "edited late\n")
    }

    /// **Stricter than git, deliberately.** A submodule with uncommitted content is ignored by
    /// git's own check (measured on git 2.54: it rebases, and leaves the submodule as it was,
    /// with or without `submodule.recurse`). Gitter's `git diff --quiet` sees it and refuses.
    /// Submodules are outside this milestone; refusing is the answer that cannot lose work.
    @Test func aDirtySubmoduleRefusesTheRebaseAlthoughGitWouldNot() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        let sub = try await TestRepo.makeBranched()
        defer { sub.cleanUp() }
        try await repo.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", sub.root.path, "sub"])
        try await repo.git(["commit", "-q", "-m", "adds a submodule"])
        let file = try #require(try FileManager.default.contentsOfDirectory(atPath: sub.root.path)
            .filter { $0.hasSuffix(".txt") }.sorted().first)
        try repo.write("sub/\(file)", "dirty inside the submodule\n")
        #expect(try await repo.git(["status", "--porcelain"]).isEmpty == false)
        let state = try await RepoState.capture(repo)

        let error = await branchError {
            _ = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)
        }

        #expect(error == .treeNotClean)
        #expect(try await RepoState.capture(repo) == state)
        #expect(try repo.fileContents("sub/\(file)") == "dirty inside the submodule\n")
    }

    /// An untracked file is not uncommitted work in git's sense and does not refuse the
    /// rebase; it is left exactly where it was.
    @Test func anUntrackedFileDoesNotRefuseAndSurvives() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        try repo.write("scratch.txt", "mine alone\n")

        let outcome = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)

        #expect(outcome == .rebased)
        #expect(try repo.fileContents("scratch.txt") == "mine alone\n")
    }

    /// …unless the upstream brings a file of the same name. Then the checkout that starts the
    /// rebase refuses under its own header, and nothing moves.
    @Test func anUntrackedFileTheUpstreamWouldOverwriteRefuses() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        try repo.write("theirs.txt", "mine, untracked\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            _ = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)
        }

        #expect(error == .wouldOverwrite(tracked: [], untracked: ["theirs.txt"]))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await CLIGitBackend().operationInProgress(at: repo.root) == nil)
    }

    // MARK: - Conflicts

    /// Stops on the second local commit, one already rewritten. The snapshot reports the
    /// existing `.rebase` operation, HEAD is detached, `main` itself has not moved — and the
    /// existing abort puts everything back.
    @Test func aConflictLeavesARebaseInProgressThatAbortUndoes() async throws {
        let lab = try await Self.makeLab(conflicting: true)
        defer { lab.cleanUp() }
        let repo = lab.repo
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let backend = CLIGitBackend()

        let outcome = try await backend.rebase(onto: "origin/main", at: repo.root)

        #expect(outcome == .conflicts)
        let snapshot = try await backend.snapshot(at: repo.root)
        #expect(snapshot.status.operationInProgress == .rebase)
        #expect(try await repo.gitFileExists("rebase-merge"))
        #expect(try await repo.gitFileExists("rebase-apply") == false)
        #expect(snapshot.status.branch == nil)  // detached for the duration
        #expect(!(try await repo.unmergedEntries()).isEmpty)
        #expect(try await repo.revParse("refs/heads/main") == lab.oldTip)

        try await backend.abort(.rebase, at: repo.root)

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await backend.operationInProgress(at: repo.root) == nil)
    }

    /// `rebase.backend=apply` keeps its state in `rebase-apply/` instead; the existing
    /// detection sees that as a rebase too, and the outcome is still read back correctly.
    @Test func aConflictUnderTheApplyBackendIsStillConflicts() async throws {
        let lab = try await Self.makeLab(conflicting: true)
        defer { lab.cleanUp() }
        let repo = lab.repo
        try await repo.git(["config", "rebase.backend", "apply"])

        let outcome = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)

        #expect(outcome == .conflicts)
        #expect(try await repo.gitFileExists("rebase-apply"))
        #expect(try await CLIGitBackend().operationInProgress(at: repo.root) == .rebase)
        try await CLIGitBackend().abort(.rebase, at: repo.root)
        #expect(try await repo.headSha() == lab.oldTip)
    }

    // MARK: - Stopped part-way, whatever git printed

    /// A rebase that stops *after* it has started can print text shaped exactly like a
    /// refusal. Here the second local commit deletes `y.txt` that the first one added, and an
    /// untracked `y.txt` sits in the worktree: replaying the first commit trips over it
    /// ("untracked working tree files would be overwritten") — with `rebase-merge/` already in
    /// place and HEAD detached. That is a stopped rebase, not a refusal that changed nothing.
    @Test func anOverwriteRefusalPrintedMidRebaseIsAStopNotARefusal() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        try repo.write("y.txt", "added\n")
        try await repo.commitAll("adds y")
        try await repo.git(["rm", "-q", "y.txt"])
        try await repo.git(["commit", "-q", "-m", "removes y"])
        try repo.write("y.txt", "mine, untracked\n")
        let tip = try await repo.headSha()
        let backend = CLIGitBackend()

        let outcome = try await backend.rebase(onto: "origin/main", at: repo.root)

        #expect(outcome == .conflicts)
        #expect(try await backend.operationInProgress(at: repo.root) == .rebase)
        #expect(try await repo.gitFileExists("rebase-merge"))
        #expect(try await repo.currentBranch() == nil)
        #expect(try await repo.revParse("refs/heads/main") == tip)
        #expect(try repo.fileContents("y.txt") == "mine, untracked\n")
        try await backend.abort(.rebase, at: repo.root)
        #expect(try await repo.headSha() == tip)
    }

    /// git echoes the stopped commit's subject ("Could not apply 1a2b3c… <subject>"), so a
    /// subject that reads like a refusal is on stderr beside the conflict. It is still a
    /// conflict.
    @Test func aRefusalShapedCommitSubjectOnAConflictIsAStopNotARefusal() async throws {
        let lab = try await Self.makeLab(conflicting: true)
        defer { lab.cleanUp() }
        let repo = lab.repo
        try await repo.git(["commit", "-q", "--amend", "-m", "error: cannot rebase: You have unstaged changes."])
        let tip = try await repo.headSha()
        let backend = CLIGitBackend()

        let outcome = try await backend.rebase(onto: "origin/main", at: repo.root)

        #expect(outcome == .conflicts)
        #expect(try await backend.operationInProgress(at: repo.root) == .rebase)
        #expect(!(try await repo.unmergedEntries()).isEmpty)
        #expect(try await repo.revParse("refs/heads/main") == tip)
    }

    /// `.conflicts` means *stopped*, and a stop needs no conflict: a commit that cannot be
    /// signed (`commit.gpgSign=true` with a `gpg.program` that fails) stops the rebase with
    /// nothing unmerged. The rebase is in progress all the same, and that is the outcome.
    @Test func aRebaseStoppedWithoutAConflictIsStillStopped() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        try await repo.git(["config", "commit.gpgSign", "true"])
        try await repo.git(["config", "gpg.program", "/bin/false"])
        let backend = CLIGitBackend()

        let outcome = try await backend.rebase(onto: "origin/main", at: repo.root)

        #expect(outcome == .conflicts)
        #expect(try await backend.operationInProgress(at: repo.root) == .rebase)
        #expect(try await repo.unmergedEntries().isEmpty)
        #expect(try await repo.revParse("refs/heads/main") == lab.oldTip)
        try await backend.abort(.rebase, at: repo.root)
        #expect(try await repo.headSha() == lab.oldTip)
    }

    // MARK: - Another operation in progress

    /// git's own answer here would be the *tree* refusal ("You have unstaged changes." /
    /// "additionally, your index contains…" — measured), which names the wrong problem. The
    /// operation guard answers first and names the right one.
    @Test func aMergeInProgressRefusesAndChangesNothing() async throws {
        let repo = try await TestRepo.makeConflicting()
        defer { repo.cleanUp() }
        _ = try await CLIGitBackend().merge("feature", mode: .alwaysMergeCommit, at: repo.root)
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        #expect(try await repo.gitFileExists("MERGE_HEAD"))

        let error = await branchError {
            _ = try await CLIGitBackend().rebase(onto: "feature", at: repo.root)
        }

        #expect(error == .operationInProgress("merging"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.gitFileExists("MERGE_HEAD"))
    }

    @Test func aRebaseInProgressRefusesASecondOne() async throws {
        let lab = try await Self.makeLab(conflicting: true)
        defer { lab.cleanUp() }
        let repo = lab.repo
        _ = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let error = await branchError {
            _ = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)
        }

        #expect(error == .operationInProgress("rebasing"))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    // MARK: - What reaches git

    /// A ref name or a full object name, and nothing else: the same guard `commits(in:notIn:)`
    /// uses, before git runs. `origin/main~1` would be accepted by git (measured) and rebase
    /// onto a commit nobody chose.
    @Test(arguments: ["", "  ", "-x", " -x", "origin/main~1", "origin/main^", "a..b", "HEAD@{1}",
                      "origin/main:a.txt", ".origin/main", "origin/main."])
    func aRevisionIsRefusedBeforeGitRuns(upstream: String) async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let state = try await RepoState.capture(lab.repo)
        let worktree = worktreeSnapshot(lab.repo)

        let error = await branchError {
            _ = try await CLIGitBackend().rebase(onto: upstream, at: lab.repo.root)
        }

        #expect(error == .invalidName(upstream))
        try await assertRepoUnchanged(lab.repo, since: state, worktree: worktree)
    }

    /// Anything git refuses that Gitter has no words for comes back in git's.
    @Test func aNameThatResolvesToNothingIsGitsOwnWords() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }

        await #expect {
            _ = try await CLIGitBackend().rebase(onto: "origin/nosuch", at: lab.repo.root)
        } throws: { error in
            guard case GitError.commandFailed(_, let stderr) = error else { return false }
            return stderr.contains("invalid upstream 'origin/nosuch'")
        }
    }

    @Test func aPreRebaseHookRefusalIsGitsOwnWordsAndChangesNothing() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        try repo.writeExecutable(".git/hooks/pre-rebase", "#!/bin/sh\necho no thanks >&2\nexit 1\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect {
            _ = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)
        } throws: { error in
            guard case GitError.commandFailed(_, let stderr) = error else { return false }
            return stderr.contains("The pre-rebase hook refused to rebase.")
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// A hook's words are the hook's, whatever they look like. One that prints git's own
    /// dirty-tree sentence and says no must not come back as `.treeNotClean` — the tree is
    /// clean, and "commit or stash your changes" would send the user after changes that do not
    /// exist. git names the hook on the line after (`The pre-rebase hook refused to rebase.`,
    /// measured on git 2.54), and only a hook's refusal carries that line: git's own dirty-tree
    /// check runs before the hook, and when it refuses the hook never runs (also measured).
    @Test func aPreRebaseHookPrintingARefusalIsStillTheHooksRefusal() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        try repo.writeExecutable(
            ".git/hooks/pre-rebase",
            "#!/bin/sh\necho 'error: cannot rebase: You have unstaged changes.' >&2\nexit 1\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect {
            _ = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)
        } throws: { error in
            guard case GitError.commandFailed(_, let stderr) = error else { return false }
            return stderr.contains("error: cannot rebase: You have unstaged changes.")
                && stderr.contains("The pre-rebase hook refused to rebase.")
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// `rebase.updateRefs=true` would make git move every *other* local branch that points
    /// into the commits being rewritten — measured on git 2.54, "Updated the following refs
    /// with --update-refs: refs/heads/side". The vector carries `--no-update-refs`, which
    /// defeats the setting: `side` stays exactly where it was.
    @Test func aConfiguredUpdateRefsDoesNotMoveABranchInsideTheRewrittenRange() async throws {
        let lab = try await Self.makeLab()
        defer { lab.cleanUp() }
        let repo = lab.repo
        try await repo.git(["branch", "side", "HEAD~1"])
        try await repo.git(["config", "rebase.updateRefs", "true"])
        let sideBefore = try await repo.revParse("side")
        #expect(sideBefore != (try await repo.revParse("origin/main")))

        let outcome = try await CLIGitBackend().rebase(onto: "origin/main", at: repo.root)

        #expect(outcome == .rebased)
        #expect(try await repo.revParse("side") == sideBefore)
        // Non-vacuous: the commit `side` names *was* rewritten, so git had a reason to move it.
        #expect(try await repo.revParse("HEAD~1") != sideBefore)
    }

    // MARK: - Support

    struct CommitFacts: Equatable {
        let sha: String
        let subject: String
        /// The change the commit makes, without its header — what a rewrite must preserve.
        let patch: String
    }

    /// The commits in `range`, oldest first.
    static func commits(in range: String, _ repo: TestRepo) async throws -> [CommitFacts] {
        let shas = String(
            decoding: try await repo.git(["rev-list", "--reverse", range]), as: UTF8.self
        ).split(separator: "\n").map(String.init)
        var facts: [CommitFacts] = []
        for sha in shas {
            let patch = String(
                decoding: try await repo.git(["show", "--format=", "--no-color", sha]), as: UTF8.self)
            facts.append(CommitFacts(sha: sha, subject: try await repo.subject(of: sha), patch: patch))
        }
        return facts
    }
}
