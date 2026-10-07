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
        #expect(try await repo.upstream(of: "topic") == .none, "nothing to publish otherwise")

        let result = try await CLIGitBackend().push(
            "topic", to: "origin", remoteRef: "refs/heads/topic", setUpstream: true,
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .created)
        #expect(try await repo.upstream(of: "topic") == .tracking("origin/topic"))
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

    /// **A push publishes the branch the user named and nothing else — tags included.**
    ///
    /// `push.followTags=true` is an ordinary line in many people's configuration, and measured
    /// on git 2.54 it makes *every* push in this milestone create annotated tags on the server
    /// beside the branch:
    ///
    /// ```
    /// *^Irefs/heads/main:refs/heads/main^I[new branch]
    /// *^Irefs/tags/annotated:refs/tags/annotated^I[new tag]
    /// ```
    ///
    /// Nothing in Gitter asked for that tag, no confirmation named it, and pushing tags is not
    /// in this milestone at all — so `--no-follow-tags` is on every push vector. It is a fact
    /// about the *server*, not about the result line, which is why the assertion is over the
    /// whole ref list.
    ///
    /// The key goes in the **repository's** config because the suite isolates the global one
    /// (`TestGitEnvironment`); `push.followTags` is read from either, so this is the same fact.
    @Test(arguments: [true, false])
    func aPushPublishesTheBranchAndNoTagEvenUnderFollowTags(setUpstream: Bool) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["config", "push.followTags", "true"])
        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("topic.txt", "topic\n")
        try await repo.commitAll("topic")
        try await repo.git(["tag", "-a", "annotated", "-m", "an annotated tag"])

        let before = try await RemoteState.capture(origin)
        #expect(!before.refs.contains("refs/tags/"), "\(before.refs)")

        let result = try await CLIGitBackend().push(
            "topic", to: "origin", remoteRef: "refs/heads/topic", setUpstream: setUpstream,
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .created)
        try await assertOnlyRefChanged(origin, since: before, isThe: "refs/heads/topic")
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
        #expect(try await repo.upstream(of: "tri") == .tracking("fork/tri"))
    }

    /// `-u` is **best-effort in git**, and its failure is invisible to anything that reads only
    /// the porcelain line. Measured on git 2.54 with `.git` and `.git/config` made unwritable:
    ///
    /// ```
    /// $ git push --porcelain --progress -u --end-of-options origin refs/heads/x:refs/heads/x
    /// To ../origin.git
    /// *	refs/heads/x:refs/heads/x	[new branch]
    /// Done
    /// EXIT=0
    /// stderr: error: could not lock config file .git/config: Permission denied
    ///         error: unable to write upstream branch configuration
    /// $ git config --get-regexp '^branch\.x\.'      # nothing
    /// ```
    ///
    /// The push really did go through, the `branch '…' set up to track '…'.` notice is simply
    /// absent, and the branch has no upstream — so the badge will never count against the
    /// server and a later Push will publish rather than update. Neither `error:` line has a
    /// `remote:` prefix, so `remoteMessages` drops both: on the old shape the whole failure
    /// vanished and the caller was told `.created`, which is true, beside an upstream that does
    /// not exist. Gitter reads the upstream back out of the configuration instead of trusting
    /// `-u`, and carries git's own words.
    @Test func anUpstreamGitCouldNotWriteIsReportedRatherThanAssumed() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("topic.txt", "topic\n")
        try await repo.commitAll("topic")

        let gitDirectory = repo.root.appendingPathComponent(".git")
        let configFile = gitDirectory.appendingPathComponent("config")
        // Restored before the repository is cleaned up (defers run in reverse), or the temp
        // directory could not be removed.
        defer {
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o755], ofItemAtPath: gitDirectory.path)
            try? FileManager.default.setAttributes(
                [.posixPermissions: 0o644], ofItemAtPath: configFile.path)
        }
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o444], ofItemAtPath: configFile.path)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o555], ofItemAtPath: gitDirectory.path)

        let result = try await CLIGitBackend().push(
            "topic", to: "origin", remoteRef: "refs/heads/topic", setUpstream: true,
            at: repo.root, progress: { _ in })

        // The push itself succeeded — that is the whole difficulty.
        #expect(result.outcome == .created)
        let tip = try await repo.headSha()
        #expect(try await RemoteState.capture(origin).refs.contains("refs/heads/topic\u{0}\(tip)"))
        // And the upstream it was asked to write is not there.
        #expect(result.upstream == .notSet)
        #expect(result.errorLines.contains {
            $0.contains("unable to write upstream branch configuration")
        }, "\(result.errorLines)")
        #expect(result.remoteMessages == [], "git's own errors are not the server talking")
        #expect(try await repo.upstream(of: "topic") == .none)
    }

    /// The same read-back on the path that works: `-u` really did write the configuration, so
    /// the answer is `true` — without which the test above would pass against a field that is
    /// always `false`.
    @Test func anUpstreamGitDidWriteIsReportedAsSet() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("topic.txt", "topic\n")
        try await repo.commitAll("topic")

        let result = try await CLIGitBackend().push(
            "topic", to: "origin", remoteRef: "refs/heads/topic", setUpstream: true,
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .created)
        #expect(result.upstream == .set)
        #expect(result.errorLines == [])
        #expect(try await repo.upstream(of: "topic") == .tracking("origin/topic"))
    }

    /// **"git did not write it" and "Gitter could not read it back" are different sentences,
    /// and `Bool?` could only say one of them.**
    ///
    /// The field used to answer `false` for both, documented as "not confirmed". But the two
    /// states call for opposite wording: one is *the branch is not tracking what you asked
    /// for*, the other is *the branch may well be tracking it and this could not be checked* —
    /// and here the upstream really **is** written, so `false` was a false statement about the
    /// repository.
    ///
    /// Reached with a client-side `reference-transaction` hook, which git runs when the push
    /// updates `refs/remotes/origin/topic` — after `-u` has written the configuration — and
    /// which leaves `.git/config` unparseable. `git config --get` then exits **128** with
    /// `fatal: bad config line …`, which is neither a value nor the "key not set" exit 1.
    @Test func anUpstreamThatCannotBeReadBackIsUnknownAndNotUnset() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("topic.txt", "topic\n")
        try await repo.commitAll("topic")
        try repo.writeExecutable(".git/hooks/reference-transaction", """
            #!/bin/sh
            [ "$1" = committed ] && printf '\\n[bad\\n' >> .git/config
            exit 0
            """)

        let result = try await CLIGitBackend().push(
            "topic", to: "origin", remoteRef: "refs/heads/topic", setUpstream: true,
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .created)
        // The baseline that makes `.unknown` mean something: git really did write the upstream,
        // read off the file rather than through a `git config` that can no longer parse it. So
        // the old `false` was not merely unhelpful, it was untrue.
        let config = try String(
            contentsOf: repo.root.appendingPathComponent(".git/config"), encoding: .utf8)
        #expect(config.contains("[branch \"topic\"]"), "\(config)")
        #expect(config.contains("remote = origin"), "\(config)")

        #expect(result.upstream == .unknown)
    }

    /// The question was not asked, so there is no answer to give: `.notRequested` rather than
    /// `.notSet`, which would read as "the upstream is wrong" for every ordinary push.
    @Test func aPushThatWasNotAskedToSetAnUpstreamReportsNothingAboutOne() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try repo.write("later.txt", "later\n")
        try await repo.commitAll("later")

        let result = try await CLIGitBackend().push(
            "main", to: "origin", remoteRef: "refs/heads/main", setUpstream: false,
            at: repo.root, progress: { _ in })

        #expect(result.upstream == .notRequested)
    }

    /// A push the server refused wrote no upstream and was never going to, so there is nothing
    /// to report about one either — the banner is about the refusal.
    @Test func aRejectedPushReportsNothingAboutTheUpstreamItDidNotWrite() async throws {
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

        let result = try await CLIGitBackend().push(
            "main", to: "origin", remoteRef: "refs/heads/main", setUpstream: true,
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .rejected(.fetchFirst))
        #expect(result.upstream == .notRequested)
        // git's own summary of the failure is carried, and it is not the server's words.
        #expect(result.errorLines.contains { $0.contains("failed to push some refs") },
                "\(result.errorLines)")
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

    /// A name that is no configured remote: refused before git runs (Ruling 11, B2 Task 4) —
    /// git would read it as a path. It used to reach git, print no porcelain line and come back
    /// as git's own diagnosis (`.repositoryNotFound`).
    @Test func aRemoteThatIsNotConfiguredIsRefusedBeforeGitRuns() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let error = await remoteError {
            _ = try await CLIGitBackend().push(
                "main", to: "nosuch", remoteRef: "refs/heads/main", setUpstream: false,
                at: repo.root, progress: { _ in })
        }
        #expect(error == .noSuchRemote("nosuch"))
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

    /// A **local** `pre-push` hook that says no. Measured on git 2.54, and the third shape that
    /// reaches the "no result line" path:
    ///
    /// ```
    /// $ git push --porcelain --progress --end-of-options origin refs/heads/hooky:refs/heads/hooky
    /// stdout: (empty)
    /// stderr: pre-push: not today
    ///         error: failed to push some refs to '../origin.git'
    /// EXIT=1
    /// ```
    ///
    /// Nothing about it is a `remote:` line, because no server was ever spoken to — the hook
    /// runs on this machine, before the transport. So the words survive into the thrown error
    /// rather than into `remoteMessages`, and the outcome must never be a success: a caller
    /// that read this as `.upToDate` would tell the user their work is on the server when the
    /// server has not heard of it.
    @Test func aLocalPrePushHookThatDeclinesIsAnErrorCarryingItsWords() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "hooky"])
        try repo.write("hooky.txt", "hooky\n")
        try await repo.commitAll("hooky")
        try repo.writeExecutable(".git/hooks/pre-push", """
            #!/bin/sh
            echo "pre-push: not today" >&2
            exit 1

            """)

        let localBefore = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)

        var thrown: Error?
        do {
            _ = try await CLIGitBackend().push(
                "hooky", to: "origin", remoteRef: "refs/heads/hooky", setUpstream: false,
                at: repo.root, progress: { _ in })
        } catch {
            thrown = error
        }

        guard case .commandFailed(let code, let stderr)? = thrown as? GitError else {
            Issue.record("expected GitError.commandFailed, got \(String(describing: thrown))")
            return
        }
        #expect(code == 1, "git's own status, not an assumed one")
        #expect(stderr.contains("pre-push: not today"), "\(stderr)")
        #expect(try await repo.gitRefExists("refs/remotes/origin/hooky") == false)
        try await assertRepoUnchanged(repo, since: localBefore, worktree: worktreeBefore)
        try await assertRemoteUnchanged(origin, since: serverBefore)
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

    /// Sets `remote.origin.receivepack` to a script that touches `started`, sleeps
    /// `sleep <marker>` and only then `exec`s the real `git-receive-pack` — the push-side twin
    /// of `FetchTests`' slow `upload-pack`. Verified on git 2.54 that the config is honoured for
    /// a plain path remote, so this needs no ssh and no server. Returns the `sleep`'s pattern.
    ///
    /// The marker is written by the process that `exec`s into `sleep`, so the `sleep` is a member
    /// of the push's process group before the test can see the marker. (The wrapper used to write
    /// it and *then* fork `sleep`: a SIGTERM to the group landing in that window reached the
    /// shell but not the child it was forking, and the orphaned `sleep` held stderr open for its
    /// whole length — measured once at 53.2 s under load.) The sleep outlasts the ten-minute
    /// time limit, and its random suffix lets `ownProcesses(matching:)` find *this* test's
    /// grandchild alone.
    static func installSlowReceivePack(in repo: TestRepo, started: URL) async throws -> String {
        let marker = "66\(UInt32.random(in: 0...9)).\(UInt32.random(in: 100_000...999_999))"
        let script = ".git/slow-receive-pack.sh"
        try repo.writeExecutable(
            script,
            """
            #!/bin/sh
            /bin/sh -c ': > "$1"; exec sleep "$2"' sh "\(started.path)" "\(marker)"
            exec git-receive-pack "$@"

            """)
        try await repo.git([
            "config", "remote.origin.receivepack", repo.root.appendingPathComponent(script).path,
        ])
        return "sleep \(marker)"
    }

    /// Waits for a push's slow transport to be really running: cancelling a push that has not
    /// started would prove nothing, so it waits for the transport's own marker rather than for
    /// a duration.
    static func waitForSlowTransport(_ started: URL, _ attempt: Int, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        for _ in 0..<250 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(FileManager.default.fileExists(atPath: started.path),
                "attempt \(attempt): the slow transport never started", sourceLocation: sourceLocation)
    }

    /// No process matches `pattern` any more, polled for up to two seconds: a transport's
    /// `sleep` is reaped by launchd after its parent shell died, which is not instantaneous.
    static func expectNoTransportLeft(_ pattern: String, sourceLocation: SourceLocation = #_sourceLocation)
        async throws
    {
        var leftovers = try ownProcesses(matching: pattern)
        for _ in 0..<20 where !leftovers.isEmpty {
            try await Task.sleep(for: .milliseconds(100))
            leftovers = try ownProcesses(matching: pattern)
        }
        #expect(leftovers.isEmpty, "a slow transport outlived its cancel: \(leftovers)", sourceLocation: sourceLocation)
    }

    /// Twenty pushes held open by a deliberately slow `receive-pack` and cancelled as soon as
    /// the transport is really running. Every one must throw `CancellationError`; the
    /// repository must be sound afterwards, with no `*.lock` left behind and no orphaned
    /// transport.
    ///
    /// That the cancel ended each push, rather than the push ending by itself once the
    /// wrapper's sleep ran out, is the time limit's: the sleep outlasts it. A `< 20 s` per
    /// attempt on the test's clock stood here, which load could exceed; the control is
    /// `aPushTheCancelDidNotStopIsReportedOnceTheTestIsCancelled`. Since Task 7's fix round the
    /// runner itself also kills an orphaned transport (its escalation outlives git's reap), so
    /// neither the bound nor the limit would notice one: the process check for the `sleep`, and the
    /// lock, fsck and state checks below, are what prove the child is gone and the
    /// repositories intact.
    @Test(.timeLimit(.minutes(10))) func twentyCancelledPushesAllEndAtOnceAndLeaveTheRepositorySound() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let started = repo.root.appendingPathComponent(".git/slow-receive-pack.started")
        let sleep = try await Self.installSlowReceivePack(in: repo, started: started)

        try await repo.git(["switch", "-q", "-c", "slowly"])
        try repo.write("slowly.txt", "slowly\n")
        try await repo.commitAll("slowly")

        let before = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)
        let root = repo.root

        for attempt in 0..<20 {
            try? FileManager.default.removeItem(at: started)
            let call = CallUnderTest { () -> Error? in
                do {
                    _ = try await CLIGitBackend().push(
                        "slowly", to: "origin", remoteRef: "refs/heads/slowly", setUpstream: false,
                        at: root, progress: { _ in })
                    return nil
                } catch {
                    return error
                }
            }
            try await Self.waitForSlowTransport(started, attempt)

            call.cancel()
            guard let thrown = await call.value("attempt \(attempt)") else {
                // The wrapper's `sleep` outlasts the limit: SIGKILLed with git's whole group.
                _ = try? killOwnGroups(matching: sleep)
                return
            }
            #expect(thrown is CancellationError, "attempt \(attempt): \(String(describing: thrown))")
        }

        try await Self.expectNoTransportLeft(sleep)

        #expect(try await repo.fsckComplaints() == "")
        #expect(repo.lockFiles() == [])
        try await assertRepoUnchanged(repo, since: before, worktree: worktreeBefore)
        // The wrapper sleeps *before* it execs `git-receive-pack`, so in this fixture the
        // server never heard about the push at all. That is a property of the fixture and not
        // a promise of the API: see `GitRemoteBackend.push` for why a cancelled push in general
        // says nothing about what reached the server.
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// The control for the test above's hang guard: a push the cancel did not stop — here, one
    /// never cancelled — is still waiting on the wrapper's sleep when the time limit cancels the
    /// test, and the test reports it. The limit is stood in for by a waiting task this test
    /// cancels (`TimeLimitSupport.swift`); then the push is cancelled for real, and nothing is
    /// left behind.
    @Test(.timeLimit(.minutes(10))) func aPushTheCancelDidNotStopIsReportedOnceTheTestIsCancelled() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let started = repo.root.appendingPathComponent(".git/slow-receive-pack.started")
        let sleep = try await Self.installSlowReceivePack(in: repo, started: started)
        try await repo.git(["switch", "-q", "-c", "slowly"])
        try repo.write("slowly.txt", "slowly\n")
        try await repo.commitAll("slowly")
        let serverBefore = try await RemoteState.capture(origin)
        let root = repo.root

        let call = CallUnderTest { () -> Error? in
            do {
                _ = try await CLIGitBackend().push(
                    "slowly", to: "origin", remoteRef: "refs/heads/slowly", setUpstream: false,
                    at: root, progress: { _ in })
                return nil
            } catch {
                return error
            }
        }
        try await Self.waitForSlowTransport(started, 0)

        await withKnownIssue("the push is not cancelled, so it waits on the wrapper's sleep") {
            let waiter = Task { await call.value("the push") }
            try? await Task.sleep(for: .milliseconds(300))
            waiter.cancel()
            let thrown = await waiter.value
            #expect(thrown == nil, "the push came back: \(String(describing: thrown))")
        } matching: { $0.isNeverCameBack }

        call.cancel()
        guard let thrown = await call.value("the push, cancelled for real") else {
            _ = try? killOwnGroups(matching: sleep)
            return
        }
        #expect(thrown is CancellationError)
        try await Self.expectNoTransportLeft(sleep)
        try await assertRemoteUnchanged(origin, since: serverBefore)
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
