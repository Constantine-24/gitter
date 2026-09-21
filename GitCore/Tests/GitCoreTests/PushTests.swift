import Foundation
import Testing

@testable import GitCore

/// `GitRemoteBackend.push` against real git and real bare repositories in temp directories.
/// As in `FetchTests`, "the server" is a bare repository beside the working one and "the
/// colleague" is a second clone of it; no network host is contacted by anything here.
@Suite struct PushTests {
    // MARK: - Publishing, and pushing again

    /// Publishing a branch that has never been pushed: `.created`, the server has the ref, and
    /// `-u` wrote the upstream configuration so the badge has something to count against.
    @Test func publishesANewBranchAndSetsItsUpstream() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("topic.txt", "topic\n")
        try await repo.commitAll("topic")
        let tip = try await repo.headSha()
        #expect(try await repo.upstream(of: "topic") == nil, "nothing to publish otherwise")

        let result = try await CLIGitBackend().push(
            "topic", to: "origin", remoteRef: "refs/heads/topic", setUpstream: true,
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .created)
        #expect(try await repo.upstream(of: "topic") == "origin/topic")
        let server = try await RemoteState.capture(origin)
        #expect(server.refs.contains("refs/heads/topic\u{0}\(tip)"), "\(server.refs)")
    }

    /// The same push again, with nothing having moved: `=` / `[up to date]`, exit 0.
    @Test func pushingTwiceWithNothingNewIsUpToDate() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let backend = CLIGitBackend()
        _ = try await backend.push("main", to: "origin", remoteRef: "refs/heads/main",
                                   setUpstream: false, at: repo.root, progress: { _ in })
        let again = try await backend.push("main", to: "origin", remoteRef: "refs/heads/main",
                                           setUpstream: false, at: repo.root, progress: { _ in })
        #expect(again.outcome == .upToDate)
    }

    /// A new commit on a published branch: a fast-forward, and the two abbreviated shas git
    /// printed really are the ones the branch moved between.
    @Test func aNewCommitIsAFastForwardNamingBothShas() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let before = try await repo.headSha()
        try repo.write("next.txt", "next\n")
        try await repo.commitAll("next")
        let after = try await repo.headSha()

        let result = try await CLIGitBackend().push(
            "main", to: "origin", remoteRef: "refs/heads/main", setUpstream: false,
            at: repo.root, progress: { _ in })

        guard case .pushed(let from, let to) = result.outcome else {
            Issue.record("expected .pushed, got \(result.outcome)")
            return
        }
        #expect(!from.isEmpty && before.hasPrefix(from), "\(from) is not an abbreviation of \(before)")
        #expect(!to.isEmpty && after.hasPrefix(to), "\(to) is not an abbreviation of \(after)")
        #expect(try await RemoteState.capture(origin).refs.contains("refs/heads/main\u{0}\(after)"))
    }

    /// Where a branch pushes is not where it fetches from. With `branch.main.pushRemote=fork`
    /// the push must reach **fork**, and the upstream's own server must be byte-for-byte what
    /// it was — the failure this asserts against is a backend that quietly used `upstreamRemote`.
    @Test func pushesToThePushRemoteAndLeavesTheUpstreamsServerUntouched() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let fork = try await repo.addEmptyRemote(named: "fork")
        defer { try? FileManager.default.removeItem(at: fork) }

        try await repo.git(["branch", "--set-upstream-to=origin/main", "main"])
        try await repo.git(["config", "branch.main.pushRemote", "fork"])
        try repo.write("later.txt", "later\n")
        try await repo.commitAll("later")
        let tip = try await repo.headSha()

        let originBefore = try await RemoteState.capture(origin)
        #expect(!originBefore.refs.isEmpty)

        let result = try await CLIGitBackend().push(
            "main", to: "fork", remoteRef: "refs/heads/main", setUpstream: false,
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .created)
        #expect(try await RemoteState.capture(fork).refs.contains("refs/heads/main\u{0}\(tip)"))
        try await assertRemoteUnchanged(origin, since: originBefore)
    }

    // MARK: - Rejections, which are outcomes and not errors

    /// The colleague pushed first and this repository has never seen it: `(fetch first)`, exit
    /// 1 — and nothing changed anywhere, locally or on the server.
    @Test func aColleagueWhoPushedFirstIsAFetchFirstRejection() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        try colleague.write("colleague.txt", "theirs\n")
        try await colleague.commitAll("the colleague's commit")
        try await colleague.git(["push", "-q", "origin", "main"])

        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")

        let localBefore = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)

        let result = try await CLIGitBackend().push(
            "main", to: "origin", remoteRef: "refs/heads/main", setUpstream: false,
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .rejected(.fetchFirst))
        #expect(result.remoteMessages == [])
        try await assertRepoUnchanged(repo, since: localBefore, worktree: worktreeBefore)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// The same divergence after a fetch. Once the remote-tracking ref knows about the
    /// colleague's commit, git calls it `(non-fast-forward)` instead — a different word for the
    /// same problem, and the one the force-push offer is keyed on beside `fetch first`.
    @Test func theSameDivergenceAfterAFetchIsANonFastForwardRejection() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        try colleague.write("colleague.txt", "theirs\n")
        try await colleague.commitAll("the colleague's commit")
        try await colleague.git(["push", "-q", "origin", "main"])

        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")
        try await CLIGitBackend().fetch(remote: "origin", at: repo.root, progress: { _ in })

        let localBefore = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)

        let result = try await CLIGitBackend().push(
            "main", to: "origin", remoteRef: "refs/heads/main", setUpstream: false,
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .rejected(.nonFastForward))
        try await assertRepoUnchanged(repo, since: localBefore, worktree: worktreeBefore)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// A `pre-receive` hook that prints its reason and exits 1. The outcome is the server's
    /// refusal, its words come back as `remoteMessages` with git's `remote: ` prefix and the
    /// padding it pads the line out with both gone, and the server is untouched.
    @Test func aPreReceiveHookThatDeclinesIsARemoteRejectionCarryingItsWords() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try writeBareHook(origin, "pre-receive", """
            #!/bin/sh
            echo "policy: no pushes on fridays"
            exit 1

            """)

        try await repo.git(["switch", "-q", "-c", "hooky"])
        try repo.write("hooky.txt", "hooky\n")
        try await repo.commitAll("hooky")

        let serverBefore = try await RemoteState.capture(origin)
        let result = try await CLIGitBackend().push(
            "hooky", to: "origin", remoteRef: "refs/heads/hooky", setUpstream: false,
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .rejected(.remoteRejected("pre-receive hook declined")))
        #expect(result.remoteMessages == ["policy: no pushes on fridays"])
        #expect(try await repo.gitRefExists("refs/remotes/origin/hooky") == false)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// The other half of the decision to hang `remoteMessages` off every outcome rather than
    /// off `.rejected` alone: a **successful** push is where the hosting service's "create a
    /// pull request" URL arrives, and it arrives exactly the same way.
    @Test func aSuccessfulPushCarriesTheServersMessagesToo() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try writeBareHook(origin, "post-receive", """
            #!/bin/sh
            echo "Create a pull request for 'topic' on Example:"
            echo ""
            echo "   https://example.invalid/acme/p/pull/new/topic"

            """)

        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("topic.txt", "topic\n")
        try await repo.commitAll("topic")

        let result = try await CLIGitBackend().push(
            "topic", to: "origin", remoteRef: "refs/heads/topic", setUpstream: true,
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .created)
        #expect(result.remoteMessages == [
            "Create a pull request for 'topic' on Example:",
            "",
            "   https://example.invalid/acme/p/pull/new/topic",
        ])
    }

    // MARK: - What `-u` really writes, in a triangular setup

    /// Measured on git 2.54, and recorded here because it is a trap for whatever calls `push`
    /// with `setUpstream: true`: `-u` writes `branch.<name>.remote` — the **upstream** — and
    /// leaves `branch.<name>.pushremote` alone. In a triangular setup that silently repoints
    /// the branch at the repository it pushes to, so it now fetches from and counts against a
    /// different server than it did a moment ago.
    ///
    /// ```
    /// $ git config branch.tri.pushRemote fork     # upstream is origin/tri
    /// $ git push --porcelain --progress -u --end-of-options fork refs/heads/tri:refs/heads/tri
    /// branch 'tri' set up to track 'fork/tri'.
    /// $ git config --get-regexp '^branch\.tri\.'
    /// branch.tri.remote fork
    /// branch.tri.pushremote fork
    /// branch.tri.merge refs/heads/tri
    /// ```
    @Test func setUpstreamMovesTheUpstreamAndNotThePushRemote() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let fork = try await repo.addEmptyRemote(named: "fork")
        defer { try? FileManager.default.removeItem(at: fork) }

        try await repo.git(["switch", "-q", "-c", "tri"])
        try repo.write("tri.txt", "tri\n")
        try await repo.commitAll("tri")
        try await repo.git(["push", "-q", "origin", "refs/heads/tri:refs/heads/tri"])
        try await repo.git(["fetch", "-q", "origin"])
        try await repo.git(["branch", "--set-upstream-to=origin/tri", "tri"])
        try await repo.git(["config", "branch.tri.pushRemote", "fork"])
        #expect(try await repo.configValue("branch.tri.remote") == "origin")

        _ = try await CLIGitBackend().push(
            "tri", to: "fork", remoteRef: "refs/heads/tri", setUpstream: true,
            at: repo.root, progress: { _ in })

        #expect(try await repo.configValue("branch.tri.remote") == "fork",
                "-u moved the upstream, not the push remote")
        #expect(try await repo.configValue("branch.tri.pushremote") == "fork")
        #expect(try await repo.upstream(of: "tri") == "fork/tri")
    }

    // MARK: - Names refused before git runs

    /// A branch name git would misread, or one that would break the refspec in two. `:` is the
    /// one that is not merely cosmetic: `refs/heads/a:b:refs/heads/x` is a refspec with a
    /// destination nobody chose.
    @Test(arguments: ["-x", " -x", "", "   ", "a:b", ":"])
    func aBranchNamePushWouldMisreadIsRefusedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let before = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)

        await branchError {
            _ = try await CLIGitBackend().push(
                name, to: "origin", remoteRef: "refs/heads/main", setUpstream: false,
                at: repo.root, progress: { _ in })
        }

        try await assertRepoUnchanged(repo, since: before, worktree: worktreeBefore)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// The same three shapes `fetch` refuses, for the same measured reasons, through the same
    /// shared check.
    @Test(arguments: ["-x", " -x", "", "   ", "."])
    func aRemoteNamePushWouldMisreadIsRefusedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let before = try await RepoState.capture(repo)
        let serverBefore = try await RemoteState.capture(origin)

        let error = await remoteError {
            _ = try await CLIGitBackend().push(
                "main", to: name, remoteRef: "refs/heads/main", setUpstream: false,
                at: repo.root, progress: { _ in })
        }
        #expect(error == .noRemote)
        #expect(try await RepoState.capture(repo) == before)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// The destination is a full ref name and nothing else. A short name would land under
    /// whatever namespace the server guessed, a second `:` would make a refspec out of it, and
    /// a leading `+` or `-` is an option or a force marker rather than a ref.
    @Test(arguments: [
        "main", "heads/main", "refs/tags/v1", "refs/heads/", "", "+refs/heads/main",
        "-refs/heads/main", ":refs/heads/main", "refs/heads/a:b",
    ])
    func aDestinationThatIsNotAFullBranchRefIsRefusedBeforeGitRuns(ref: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let before = try await RepoState.capture(repo)
        let serverBefore = try await RemoteState.capture(origin)

        await branchError {
            _ = try await CLIGitBackend().push(
                "main", to: "origin", remoteRef: ref, setUpstream: false,
                at: repo.root, progress: { _ in })
        }
        #expect(try await RepoState.capture(repo) == before)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    // MARK: - Failures that are not rejections

    /// A remote git can read but that names nothing: no porcelain line at all, so the outcome
    /// cannot come from stdout and git's own diagnosis is thrown instead.
    @Test func aRemoteThatNamesNothingThrowsGitsDiagnosis() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let error = await remoteError {
            _ = try await CLIGitBackend().push(
                "main", to: "nosuch", remoteRef: "refs/heads/main", setUpstream: false,
                at: repo.root, progress: { _ in })
        }
        #expect(error == .repositoryNotFound)
    }

    /// A local branch that is not there: git exits 1 with `error: src refspec … does not match
    /// any` and prints no result line. `RemoteFailureParser` recognises nothing in that, so
    /// git's own words come back rather than an invented cause.
    @Test func aSourceBranchThatDoesNotExistThrowsGitsWords() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        var thrown: Error?
        do {
            _ = try await CLIGitBackend().push(
                "ghost", to: "origin", remoteRef: "refs/heads/ghost", setUpstream: false,
                at: repo.root, progress: { _ in })
        } catch {
            thrown = error
        }
        guard case .commandFailed(_, let stderr)? = thrown as? GitError else {
            Issue.record("expected GitError.commandFailed, got \(String(describing: thrown))")
            return
        }
        #expect(stderr.contains("src refspec refs/heads/ghost does not match any"), "\(stderr)")
        #expect(!(thrown is RemoteOperationError))
    }

    // MARK: - Progress

    /// `--progress` is on the vector because git prints none without a tty, and the segments
    /// arrive already trimmed of the padding git erases the previous line with.
    @Test func reportsProgressSegmentsWithGitsPaddingAlreadyTrimmed() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addEmptyRemote(named: "origin")
        defer { try? FileManager.default.removeItem(at: origin) }

        let segments = PushSegments()
        _ = try await CLIGitBackend().push(
            "main", to: "origin", remoteRef: "refs/heads/main", setUpstream: false,
            at: repo.root, progress: { segments.append($0) })

        let collected = segments.all
        #expect(collected.contains { $0.contains("objects") }, "\(collected)")
        #expect(collected.allSatisfy { $0 == $0.trimmingCharacters(in: .whitespaces) }, "\(collected)")
        #expect(collected.allSatisfy { !$0.isEmpty })
    }

    // MARK: - Cancellation

    /// Twenty pushes held open by a deliberately slow `receive-pack` and cancelled as soon as
    /// the transport is really running. Every one must throw `CancellationError` promptly; the
    /// repository must be sound afterwards, with no `*.lock` left behind and no orphaned
    /// transport.
    ///
    /// The wrapper is the push-side twin of `FetchTests`' slow `upload-pack`: a script set as
    /// `remote.origin.receivepack` that touches a marker file, sleeps, and only then `exec`s
    /// the real `git-receive-pack`. Verified on git 2.54 that the config is honoured for a
    /// plain path remote, so this needs no ssh and no server.
    ///
    /// The sleep's duration carries a random suffix so `pgrep -f` finds *this* test's
    /// grandchild and nothing else on the machine.
    @Test func twentyCancelledPushesAllEndAtOnceAndLeaveTheRepositorySound() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let marker = "53.\(UInt32.random(in: 100_000...999_999))"
        let script = ".git/slow-receive-pack.sh"
        let started = repo.root.appendingPathComponent(".git/slow-receive-pack.started")
        try repo.writeExecutable(
            script,
            """
            #!/bin/sh
            : > "\(started.path)"
            sleep \(marker)
            exec git-receive-pack "$@"

            """)
        try await repo.git([
            "config", "remote.origin.receivepack", repo.root.appendingPathComponent(script).path,
        ])

        try await repo.git(["switch", "-q", "-c", "slowly"])
        try repo.write("slowly.txt", "slowly\n")
        try await repo.commitAll("slowly")

        let before = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)
        let clock = ContinuousClock()

        for attempt in 0..<20 {
            try? FileManager.default.removeItem(at: started)
            let task = Task { () -> Error? in
                do {
                    _ = try await CLIGitBackend().push(
                        "slowly", to: "origin", remoteRef: "refs/heads/slowly", setUpstream: false,
                        at: repo.root, progress: { _ in })
                    return nil
                } catch {
                    return error
                }
            }

            // Cancelling a push that has not started would prove nothing, so wait for the
            // transport's own marker rather than for a duration.
            for _ in 0..<250 where !FileManager.default.fileExists(atPath: started.path) {
                try await Task.sleep(for: .milliseconds(20))
            }
            #expect(FileManager.default.fileExists(atPath: started.path),
                    "attempt \(attempt): the slow transport never started")

            let cancelledAt = clock.now
            task.cancel()
            let thrown = await task.value
            #expect(thrown is CancellationError, "attempt \(attempt): \(String(describing: thrown))")
            #expect(clock.now - cancelledAt < .seconds(3), "attempt \(attempt)")
        }

        var leftovers = try await processesMatching("sleep \(marker)")
        for _ in 0..<20 where !leftovers.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            leftovers = try await processesMatching("sleep \(marker)")
        }
        #expect(leftovers.isEmpty, "a slow transport outlived its cancel: \(leftovers)")

        #expect(try await repo.fsckComplaints() == "")
        #expect(repo.lockFiles() == [])
        try await assertRepoUnchanged(repo, since: before, worktree: worktreeBefore)
        // The wrapper sleeps *before* it execs `git-receive-pack`, so in this fixture the
        // server never heard about the push at all. That is a property of the fixture and not
        // a promise of the API: see `GitRemoteBackend.push` for why a cancelled push in general
        // says nothing about what reached the server.
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    // MARK: -

    /// Writes an executable hook into a **bare** repository's `hooks` directory. `TestRepo`'s
    /// `writeExecutable` works on a working repository; the server has no worktree.
    private func writeBareHook(_ bareURL: URL, _ name: String, _ contents: String) throws {
        let url = bareURL.appendingPathComponent("hooks/\(name)")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    }
}

/// A lock-protected collector for progress segments, which arrive on the pipe's background
/// queue while the call is still running and are read after it has returned.
private final class PushSegments: @unchecked Sendable {
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
