import Foundation
import Testing

@testable import GitCore

/// `GitRemoteBackend.fetch` against real git and real bare repositories in temp directories.
/// No network host is contacted by anything in this file: "the server" is a bare repository
/// beside the working one, and "the colleague" is a second clone of it.
@Suite struct FetchTests {
    // MARK: - What a fetch does, and what it does not

    /// The whole point of fetch, and the whole point of it being *not* a pull: the
    /// remote-tracking ref catches up with the server and the local branch does not move one
    /// commit. Nothing in the worktree changes either.
    @Test func bringsTheColleaguesCommitToTheTrackingRefAndLeavesTheLocalBranchAlone() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        try colleague.write("colleague.txt", "theirs\n")
        try await colleague.commitAll("the colleague's commit")
        try await colleague.git(["push", "-q", "origin", "main"])
        let theirs = try await colleague.headSha()

        let localBefore = try await repo.headSha()
        let trackingBefore = try await repo.revParse("refs/remotes/origin/main")
        let worktreeBefore = worktreeSnapshot(repo)
        #expect(trackingBefore != theirs, "nothing to fetch, so this test would prove nothing")

        try await CLIGitBackend().fetch(remote: "origin", at: repo.root, progress: { _ in })

        #expect(try await repo.revParse("refs/remotes/origin/main") == theirs)
        #expect(try await repo.headSha() == localBefore)
        #expect(try await repo.revParse("refs/heads/main") == localBefore)
        assertWorktreeUnchanged(repo, since: worktreeBefore)
    }

    /// A fetch is a read of the server. It must leave the bare repository byte-for-byte what
    /// the colleague left — no ref moved, no HEAD retargeted — because everything later in this
    /// milestone that *does* write to the server is checked with this same assertion, and an
    /// assertion that cannot fail is worth nothing.
    @Test func leavesTheServerExactlyAsItFoundIt() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        try colleague.write("colleague.txt", "theirs\n")
        try await colleague.commitAll("the colleague's commit")
        try await colleague.git(["push", "-q", "origin", "main"])

        let serverBefore = try await RemoteState.capture(origin)
        try await CLIGitBackend().fetch(remote: "origin", at: repo.root, progress: { _ in })
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// `fetch(remote: nil)` is `--all`: every configured remote, not just the branch's own.
    /// Two remotes, two different things to discover, one call.
    @Test func fetchingEveryRemoteUpdatesBothOfThem() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let mirror = try await repo.addEmptyRemote(named: "mirror")
        defer { try? FileManager.default.removeItem(at: mirror) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        try colleague.write("colleague.txt", "theirs\n")
        try await colleague.commitAll("the colleague's commit")
        try await colleague.git(["push", "-q", "origin", "main"])
        let theirs = try await colleague.headSha()

        try await colleague.git(["remote", "add", "mirror", mirror.path])
        try await colleague.git(["push", "-q", "mirror", "refs/heads/main:refs/heads/extra"])

        #expect(try await repo.revParse("refs/remotes/origin/main") != theirs)
        #expect(try await repo.localBranches() == ["feature", "main"])

        try await CLIGitBackend().fetch(remote: nil, at: repo.root, progress: { _ in })

        #expect(try await repo.revParse("refs/remotes/origin/main") == theirs)
        #expect(try await repo.revParse("refs/remotes/mirror/extra") == theirs)
    }

    // MARK: - Pruning, which this fetch never does

    /// The "no `--prune`" promise is not kept by leaving the flag out: pruning is a *config*,
    /// and `fetch.prune=true` is one of the first things people put in their `~/.gitconfig`.
    /// Measured on git 2.54, in a repository where the colleague deleted a branch on the server:
    ///
    /// ```
    /// $ git -c fetch.prune=true fetch --progress --end-of-options origin
    /// From /…/origin
    ///  - [deleted]         (none)     -> origin/feat/x
    /// ```
    ///
    /// — and with `fetch.pruneTags=true` alongside it, ` - [deleted] (none) -> v1` as well: a
    /// local tag, gone, with no confirmation and no ref left to the commit it named. Four keys
    /// reach this (`fetch.prune`, `remote.<name>.prune`, and the two `pruneTags` twins), from
    /// the global config as readily as from the repository's, so the only defence is on the
    /// command line. `--no-prune` is it, and it covers the tags too: measured, `--no-prune`
    /// with both `prune` and `pruneTags` set keeps the branch *and* the tag, because a tag is
    /// only pruned when pruning happens at all (`fetch.pruneTags=true` on its own prunes
    /// nothing). `--no-prune-tags` exists and is accepted, here and with `--all`, but it would
    /// be a second flag saying what the first already said.
    ///
    /// The configuration is set in the *repository* rather than globally because the suite runs
    /// with the developer's global config shut out — see `TestGitEnvironment`.
    @Test(arguments: [
        (["fetch.prune"], "origin"),
        (["remote.origin.prune"], "origin"),
        (["fetch.prune", "fetch.pruneTags"], "origin"),
        (["fetch.prune", "fetch.pruneTags"], String?.none),
    ] as [([String], String?)])
    func aPruneConfigurationNeverDeletesTheUsersRefs(keys: [String], remote: String?) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        for key in keys { try await repo.git(["config", key, "true"]) }
        // The colleague deletes the branch on the server, which is the only way to reach the
        // state that tempts a prune: pushing the deletion from this repository would drop its
        // own remote-tracking ref on the spot, and the fetch would have nothing left to prune.
        try await colleague.git(["push", "-q", "origin", ":refs/heads/feat/x"])

        // Baselines that can fail: the tracking ref and the tag are really here, and the
        // server really has lost the branch, so a prune had something to delete.
        #expect(try await repo.revParse("refs/remotes/origin/feat/x") != "")
        #expect(try await repo.revParse("refs/tags/v1") != "")
        let serverRefs = try await RemoteState.capture(origin).refs
        #expect(!serverRefs.contains("refs/heads/feat/x"), "\(serverRefs)")

        try await CLIGitBackend().fetch(remote: remote, at: repo.root, progress: { _ in })

        #expect(try await repo.gitRefExists("refs/remotes/origin/feat/x"),
                "the remote-tracking ref was pruned behind the user's back")
        #expect(try await repo.gitRefExists("refs/tags/v1"), "the local tag was pruned")
    }

    // MARK: - Progress

    /// git prints no progress at all without a tty, so `--progress` is on the command line and
    /// this is what proves it: at least one segment about objects, and every segment already
    /// stripped of the padding spaces git uses to erase the longer line before it.
    @Test func reportsProgressSegmentsWithGitsPaddingAlreadyTrimmed() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        try colleague.write("colleague.txt", "theirs\n")
        try await colleague.commitAll("the colleague's commit")
        try await colleague.git(["push", "-q", "origin", "main"])

        let segments = Segments()
        try await CLIGitBackend().fetch(
            remote: "origin", at: repo.root, progress: { segments.append($0) })

        let collected = segments.all
        #expect(collected.contains { $0.contains("objects") }, "\(collected)")
        #expect(collected.allSatisfy { $0 == $0.trimmingCharacters(in: .whitespaces) }, "\(collected)")
        #expect(collected.allSatisfy { !$0.isEmpty })
    }

    // MARK: - Names refused before git runs

    /// A remote name is an argument, not a pathspec, and three shapes are refused before git is
    /// launched at all. Measured on git 2.54, each for its own reason:
    ///
    /// - `-x` — git answers `fatal: strange pathname '-x' blocked`, so it is not a *hole*; it is
    ///   refused here anyway, with the same rule every other name in this package gets, so the
    ///   user is told which name was bad instead of being shown that sentence.
    /// - `""` — git **exits 0 and does nothing**: measured, `git fetch --progress
    ///   --end-of-options ""` prints not one word on stdout or stderr, writes an *empty*
    ///   `FETCH_HEAD` and moves no ref. It does not read the empty name as the current
    ///   directory, which this comment used to claim — `git fetch .` is the loud version, with
    ///   a `From .` line and a 44-byte `FETCH_HEAD`. A quiet false success is the worse of the
    ///   two, and `FETCH_HEAD`'s absence below catches both.
    /// - `"."` — git **accepts** it: `git fetch .` prints `From .`, fetches this repository's own
    ///   HEAD into `FETCH_HEAD` and exits 0. That is the one that has to be stopped here, because
    ///   git will not stop it, and `FETCH_HEAD` is what the test below checks.
    @Test(arguments: ["-x", "", "   ", "."])
    func aRemoteNameGitWouldMisreadIsRefusedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        // `addOriginWithFeatureBranch` fetches once, so `FETCH_HEAD` is already there; removing
        // it is what makes its absence below evidence rather than coincidence.
        try? FileManager.default.removeItem(at: repo.root.appendingPathComponent(".git/FETCH_HEAD"))
        #expect(try await repo.gitFileExists("FETCH_HEAD") == false)

        let before = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)

        let error = await remoteError {
            try await CLIGitBackend().fetch(remote: name, at: repo.root, progress: { _ in })
        }
        #expect(error == .noRemote)

        // `FETCH_HEAD` is the evidence that git never ran: it is the one thing even a fetch
        // that changes no ref writes, and `git fetch .` writes it.
        #expect(try await repo.gitFileExists("FETCH_HEAD") == false)
        try await assertRepoUnchanged(repo, since: before, worktree: worktreeBefore)
    }

    /// A name git *can* read but that names nothing: git's own diagnosis comes back, not a
    /// Gitter invention.
    ///
    /// Measured on git 2.54: `git fetch nosuch` and a configured remote whose path holds no
    /// repository print **the same sentence** — `fatal: '<name-or-path>' does not appear to be a
    /// git repository`. The wording therefore cannot tell them apart, so this is *not* mapped to
    /// `.noRemote`; it is `.repositoryNotFound`, which is what both cases really are. `.noRemote`
    /// is reserved for the names refused above, where Gitter knows the answer without asking.
    @Test func anUnknownRemoteIsGitsOwnDiagnosis() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let before = try await RepoState.capture(repo)
        let error = await remoteError {
            try await CLIGitBackend().fetch(remote: "nosuch", at: repo.root, progress: { _ in })
        }
        #expect(error == .repositoryNotFound)
        #expect(error != .noRemote)
        #expect(try await RepoState.capture(repo) == before)
    }

    // MARK: - A partial fetch is still a failure, and it still changed things

    /// `--all` with one good remote and one that is not a repository: measured on git 2.54, git
    /// exits **1** (not the 128 a single-remote failure gives), the good remote's refs are
    /// **already updated**, and stderr carries both the `From …` success block and
    /// `error: could not fetch <name>`.
    ///
    /// `fetch` therefore throws — a partial fetch is a failed fetch — and the throw says nothing
    /// about what did get through. That is the whole reason its doc comment forbids a caller
    /// from reporting a failed fetch as "nothing changed": this test is the case that would make
    /// such a report a lie.
    ///
    /// **And it throws git's words, not a diagnosis.** A diagnosed cause —
    /// `.repositoryNotFound`, which is what this used to throw — is a statement about *the*
    /// operation, and here there were several: it is false for every remote that succeeded,
    /// and it drops the one fact only git has, which is *which* remote failed. A sentence built
    /// from it ("the repository could not be found") is wrong in a way the user cannot see
    /// through. Git's own stderr names the loser and shows the successes, so that is what comes
    /// back. A single-remote fetch is still diagnosed — see
    /// `anUnknownRemoteIsGitsOwnDiagnosis`, where there is only one operation to speak about.
    @Test func aPartialFetchOfEveryRemoteThrowsAlthoughSomeRefsMoved() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        try colleague.write("colleague.txt", "theirs\n")
        try await colleague.commitAll("the colleague's commit")
        try await colleague.git(["push", "-q", "origin", "main"])
        let theirs = try await colleague.headSha()

        // A local path that holds no repository — no network, no host, no waiting.
        let missing = repo.root.deletingLastPathComponent()
            .appendingPathComponent("\(repo.root.lastPathComponent)-gone.git")
        try await repo.git(["remote", "add", "broken", missing.path])

        var thrown: Error?
        do {
            try await CLIGitBackend().fetch(remote: nil, at: repo.root, progress: { _ in })
        } catch {
            thrown = error
        }

        guard case .commandFailed(let code, let stderr)? = thrown as? GitError else {
            Issue.record("expected GitError.commandFailed, got \(String(describing: thrown))")
            return
        }
        #expect(code == 1, "a partial --all exits 1, not the 128 of a single-remote failure")
        #expect(stderr.contains("error: could not fetch broken"), "\(stderr)")
        #expect(stderr.contains("From "), "the successful remote's block is part of git's words")
        #expect(!(thrown is RemoteOperationError))
        #expect(try await repo.revParse("refs/remotes/origin/main") == theirs,
                "the good remote's refs moved even though the fetch failed")
    }

    /// The predicate that tells the two apart, on the fixtures rather than through git: a line
    /// that *begins* `error: could not fetch ` is git saying it gave up on one remote out of
    /// several. `remote:` lines are the server's own output and say nothing about this fetch —
    /// a hook is free to print anything at all, including that sentence.
    @Test(arguments: [
        (
            """
            From /tmp/gitter-test-1234-origin
               cd39b56..7fdb355  main       -> origin/main
            fatal: '/tmp/nope' does not appear to be a git repository
            error: could not fetch broken

            """, true
        ),
        ("error: could not fetch broken\n", true),
        // The server echoing the phrase, and the phrase inside a longer line: neither is git
        // reporting a remote it skipped.
        ("remote: error: could not fetch broken\n", false),
        ("hint: error: could not fetch broken\n", false),
        (
            """
            fatal: 'nosuch' does not appear to be a git repository
            fatal: Could not read from remote repository.

            """, false
        ),
        ("", false),
    ])
    func gitSaysWhenItGaveUpOnOneRemoteOfSeveral(stderr: String, expected: Bool) {
        #expect(RemoteFailureParser.reportsARemoteThatCouldNotBeFetched(stderr: stderr) == expected)
    }

    // MARK: - Cancellation

    /// A fetch held open by a deliberately slow transport, cancelled: it must end at once, and
    /// the repository must be exactly as sound afterwards as it was before.
    ///
    /// The slow transport is the design document's: a shell script set as
    /// `remote.origin.uploadpack` that sleeps and only then `exec`s the real `git-upload-pack`.
    /// Verified on git 2.54 that the config is honoured for a plain path remote, so this needs
    /// no ssh and no server.
    ///
    /// The sleep's duration carries a random suffix so `pgrep -f` can find *this* test's
    /// grandchild and nothing else on the machine — a developer's own `sleep 47` must neither
    /// fail this test nor satisfy it.
    ///
    /// Four things are asserted after the cancel, and each is a way this could have gone wrong:
    /// the call threw `CancellationError` promptly, the object store is sound, no `*.lock` was
    /// left anywhere under `.git`, and the slow transport's process is gone rather than orphaned.
    @Test func cancellingASlowFetchEndsAtOnceAndLeavesTheRepositorySound() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        try colleague.write("colleague.txt", "theirs\n")
        try await colleague.commitAll("the colleague's commit")
        try await colleague.git(["push", "-q", "origin", "main"])

        let marker = "47.\(UInt32.random(in: 100_000...999_999))"
        let script = ".git/slow-upload-pack.sh"
        let started = repo.root.appendingPathComponent(".git/slow-upload-pack.started")
        // The script touches a file before it sleeps, so "has the transport started?" is a
        // `stat` rather than a `pgrep`. That is not tidiness: polling `pgrep -f` every 20 ms
        // spawns a process that walks the whole process table fifty times a second, and Swift
        // Testing runs suites in parallel — the load that produced was enough to push
        // `StreamingRunnerTests.theKillGracePeriodIsHonoured`, which allows itself 750 ms of
        // slack, past its bound in roughly one full-suite run in five. `pgrep` is still what
        // answers "is it really running" and "did it outlive the cancel", but twice, not fifty
        // times.
        try repo.writeExecutable(
            script,
            """
            #!/bin/sh
            : > "\(started.path)"
            sleep \(marker)
            exec git-upload-pack "$@"

            """)
        try await repo.git([
            "config", "remote.origin.uploadpack", repo.root.appendingPathComponent(script).path,
        ])

        let before = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)

        let clock = ContinuousClock()
        let task = Task { () -> Error? in
            do {
                try await CLIGitBackend().fetch(
                    remote: "origin", at: repo.root, progress: { _ in })
                return nil
            } catch {
                return error
            }
        }

        // Wait for the transport to really be running before cancelling: without this the test
        // could pass by cancelling a fetch that had not started, which proves nothing.
        for _ in 0..<250 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let running = try await processesMatching("sleep \(marker)")
        #expect(!running.isEmpty, "the slow transport never started, so the cancel proves nothing")

        let cancelledAt = clock.now
        task.cancel()
        let thrown = await task.value
        let elapsed = clock.now - cancelledAt

        #expect(thrown is CancellationError, "\(String(describing: thrown))")
        #expect(elapsed < .seconds(3), "\(elapsed)")

        // The pipes only reach EOF once every process holding them has closed them, so the
        // grandchild is already dead by the time the call returns; the short wait is about it
        // being *reaped* by launchd after its parent shell died, which is not instantaneous.
        var leftovers = try await processesMatching("sleep \(marker)")
        for _ in 0..<20 where !leftovers.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            leftovers = try await processesMatching("sleep \(marker)")
        }
        #expect(leftovers.isEmpty, "the slow transport outlived the cancel: \(leftovers)")

        #expect(try await repo.fsckComplaints() == "")
        #expect(repo.lockFiles() == [])
        try await assertRepoUnchanged(repo, since: before, worktree: worktreeBefore)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }
}

/// A lock-protected collector for the progress segments, which arrive on the pipe's background
/// queue while the call is still running and are read after it has returned.
private final class Segments: @unchecked Sendable {
    private let lock = NSLock()
    private var segments: [String] = []

    func append(_ segment: String) {
        lock.lock()
        defer { lock.unlock() }
        segments.append(segment)
    }

    var all: [String] {
        lock.lock()
        defer { lock.unlock() }
        return segments
    }
}
