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
    /// - `""` — means nothing, and git reads an empty remote as the current directory.
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

        let error = await remoteError {
            try await CLIGitBackend().fetch(remote: nil, at: repo.root, progress: { _ in })
        }
        #expect(error == .repositoryNotFound)
        #expect(try await repo.revParse("refs/remotes/origin/main") == theirs,
                "the good remote's refs moved even though the fetch failed")
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
        try repo.writeExecutable(
            script,
            """
            #!/bin/sh
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
        var running: [String] = []
        for _ in 0..<250 where running.isEmpty {
            running = try await processesMatching("sleep \(marker)")
            if running.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        }
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
        for _ in 0..<50 where !leftovers.isEmpty {
            try await Task.sleep(for: .milliseconds(20))
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
