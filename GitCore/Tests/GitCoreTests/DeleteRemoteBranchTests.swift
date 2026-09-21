import Foundation
import Testing

@testable import GitCore

/// `GitRemoteBackend.deleteRemoteBranch` — the second of the two operations that can destroy
/// commits on another machine, and the second to be leased.
///
/// It is a `git push` with an empty source side (`:refs/heads/<b>`), which is `push --delete`
/// spelled as data. The lease is what makes it answerable for: the sheet shows the branch's tip
/// on the server, and that sha goes into `--force-with-lease=refs/heads/<b>:<tip>`, so a branch
/// somebody pushed to while the sheet was open is refused by git rather than deleted.
@Suite struct DeleteRemoteBranchTests {
    /// The whole of what a successful delete does, on both sides. Measured on git 2.54, and
    /// each row is asserted below:
    ///
    /// ```
    /// -^I:refs/heads/topic^I[deleted]        EXIT=0
    /// ```
    ///
    /// - the ref is gone from the server;
    /// - **git removes the local `refs/remotes/origin/topic` too** — a delete prunes the one
    ///   tracking ref it is about, with no `--prune` anywhere (which is why Gitter's `fetch`
    ///   passing `--no-prune` does not contradict this);
    /// - the **local branch is untouched**, still at its own sha;
    /// - and so is its configuration: `branch.topic.remote` and `branch.topic.merge` are still
    ///   there, which is exactly what turns the branch's tracking into `[gone]`. Recorded for
    ///   Task 8: after this, `%(upstream:track)` reads `[gone]` and `topic@{upstream}` no
    ///   longer resolves.
    @Test func theRightTipDeletesTheBranchAndTheTrackingRefWithIt() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("topic.txt", "topic\n")
        try await repo.commitAll("topic")
        try await repo.git(["push", "-q", "-u", "origin", "refs/heads/topic:refs/heads/topic"])
        try await repo.git(["fetch", "-q", "origin"])
        try await repo.git(["switch", "-q", "main"])
        let tip = try await repo.revParse("refs/heads/topic")

        #expect(try await repo.gitRefExists("refs/remotes/origin/topic"))
        #expect(try await repo.configValue("branch.topic.remote") == "origin")

        let result = try await CLIGitBackend().deleteRemoteBranch(
            "topic", on: "origin", expectedTip: tip, at: repo.root)

        #expect(result.outcome == .deleted)
        #expect(result.upstreamWasSet == nil)
        #expect(try await bareGit(
            origin, ["rev-parse", "--verify", "-q", "refs/heads/topic"], allowedExitCodes: [1]
        ).isEmpty, "the branch is still on the server")
        #expect(try await repo.gitRefExists("refs/remotes/origin/topic") == false,
                "git removes the tracking ref a delete is about")
        #expect(try await repo.revParse("refs/heads/topic") == tip, "the local branch moved")
        #expect(try await repo.configValue("branch.topic.remote") == "origin")
        #expect(try await repo.configValue("branch.topic.merge") == "refs/heads/topic")
        // And that is what `[gone]` is made of: the configuration still names an upstream, and
        // the ref it names is not there. Read through `%(upstream:track)`, which is where
        // `RefParser` reads it and where Task 8's badge will.
        //
        // Not through `TestRepo.upstream(of:)`, which cannot tell this state from a branch with
        // no upstream at all: `rev-parse --abbrev-ref --symbolic-full-name topic@{upstream}`
        // exits 128 for both and, for a `[gone]` upstream only, **echoes the argument back** —
        // so the helper answers `"topic@{upstream}"` rather than `nil` (measured on git 2.54).
        let track = try await repo.git(
            ["for-each-ref", "--format=%(upstream:track)", "refs/heads/topic"])
        #expect(String(decoding: track, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines) == "[gone]")
    }

    /// **A delete removes the one branch the sheet named and creates nothing.**
    ///
    /// The most surprising of the three: a push whose only refspec *deletes* a ref still
    /// follows tags. Measured on git 2.54 with `push.followTags=true`:
    ///
    /// ```
    /// -^I:refs/heads/doomed^I[deleted]
    /// *^Irefs/tags/annotated:refs/tags/annotated^I[new tag]
    /// ```
    ///
    /// So a confirmation that said "the branch will be deleted" would have been followed by a
    /// tag appearing on the server. `--no-follow-tags` is on this vector too.
    @Test func aDeleteRemovesTheBranchAndCreatesNoTagEvenUnderFollowTags() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["config", "push.followTags", "true"])
        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("topic.txt", "topic\n")
        try await repo.commitAll("topic")
        try await repo.git(["push", "-q", "origin", "refs/heads/topic:refs/heads/topic"])
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["tag", "-a", "annotated", "-m", "an annotated tag"])
        let tip = try await repo.revParse("refs/heads/topic")

        let before = try await RemoteState.capture(origin)
        #expect(!before.refs.contains("refs/tags/"), "\(before.refs)")

        let result = try await CLIGitBackend().deleteRemoteBranch(
            "topic", on: "origin", expectedTip: tip, at: repo.root)

        #expect(result.outcome == .deleted)
        try await assertOnlyRefChanged(origin, since: before, isThe: "refs/heads/topic")
    }

    /// The stale case, which is what the lease is for: somebody pushed to the branch while the
    /// sheet was open, so the commits the sheet counted are not the commits that would be lost.
    ///
    /// The result line has a source side git writes as the literal `(delete)` rather than as
    /// nothing — measured, and different from the successful delete's empty one:
    ///
    /// ```
    /// !^I(delete):refs/heads/topic^I[rejected] (stale info)
    /// ```
    ///
    /// so this also pins that `PushPorcelainParser` reads both shapes.
    @Test func aStaleTipIsRefusedAndTheBranchIsStillOnTheServer() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("topic.txt", "topic\n")
        try await repo.commitAll("topic")
        try await repo.git(["push", "-q", "origin", "refs/heads/topic:refs/heads/topic"])
        try await repo.git(["fetch", "-q", "origin"])
        try await repo.git(["switch", "-q", "main"])
        // What the sheet showed.
        let sheetTip = try await repo.revParse("refs/heads/topic")

        // …and then the colleague pushed to it.
        try await colleague.git(["fetch", "-q", "origin"])
        try await colleague.git(["switch", "-q", "-c", "topic", "origin/topic"])
        try colleague.write("theirs.txt", "theirs\n")
        try await colleague.commitAll("the colleague's commit on topic")
        try await colleague.git(["push", "-q", "origin", "refs/heads/topic:refs/heads/topic"])

        let localBefore = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)

        let result = try await CLIGitBackend().deleteRemoteBranch(
            "topic", on: "origin", expectedTip: sheetTip, at: repo.root)

        #expect(result.outcome == .rejected(.staleLease))
        #expect(try await bareGit(origin, ["rev-parse", "refs/heads/topic"])
                != sheetTip, "the fixture did not move the branch")
        try await assertRepoUnchanged(repo, since: localBefore, worktree: worktreeBefore)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// Deleting the branch the server's own HEAD points at. Measured on git 2.54 against a bare
    /// repository, which refuses by default:
    ///
    /// ```
    /// !^I:refs/heads/main^I[remote rejected] (deletion of the current branch prohibited)
    /// remote: error: By default, deleting the current branch is denied, because the next
    /// remote: 'git clone' won't result in any file checked out, causing confusion.
    /// …
    /// remote: error: refusing to delete the current branch: refs/heads/main
    /// ```
    ///
    /// So it is a `.remoteRejected`, not a `.staleLease` — the lease matched perfectly — and
    /// the server's explanation comes back in `remoteMessages` for the banner to quote. It is
    /// configuration (`receive.denyDeleteCurrent`) rather than a law, which is why Gitter asks
    /// the server instead of refusing by itself.
    @Test func deletingTheRemotesOwnDefaultBranchIsTheServersRefusal() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        #expect(try await bareGit(origin, ["symbolic-ref", "HEAD"]) == "refs/heads/main")
        let tip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])
        let serverBefore = try await RemoteState.capture(origin)

        let result = try await CLIGitBackend().deleteRemoteBranch(
            "main", on: "origin", expectedTip: tip, at: repo.root)

        #expect(result.outcome
                == .rejected(.remoteRejected("deletion of the current branch prohibited")))
        #expect(result.remoteMessages.contains {
            $0.contains("refusing to delete the current branch")
        }, "\(result.remoteMessages)")
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// A branch that is not on the server at all. The lease names a sha and the ref holds
    /// nothing, so git answers `[rejected] (stale info)` — measured — and Gitter reports the
    /// refusal rather than inventing a cheerful "already gone". Somebody else deleted it, and
    /// that is a fact the user should be told rather than have smoothed over.
    @Test func aBranchThatIsNotOnTheRemoteIsAStaleLease() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let tip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])
        let serverBefore = try await RemoteState.capture(origin)

        let result = try await CLIGitBackend().deleteRemoteBranch(
            "nosuch", on: "origin", expectedTip: tip, at: repo.root)

        #expect(result.outcome == .rejected(.staleLease))
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// A `pre-receive` hook that declines the deletion, which is how a hosting service protects
    /// a branch. The server's words come back beside the refusal.
    @Test func aPreReceiveHookThatDeclinesADeletionLeavesTheBranchThere() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("topic.txt", "topic\n")
        try await repo.commitAll("topic")
        try await repo.git(["push", "-q", "origin", "refs/heads/topic:refs/heads/topic"])
        try await repo.git(["switch", "-q", "main"])
        let tip = try await repo.revParse("refs/heads/topic")

        try writeBareHook(origin, "pre-receive", """
            #!/bin/sh
            echo "policy: this branch is protected"
            exit 1

            """)

        let serverBefore = try await RemoteState.capture(origin)
        let result = try await CLIGitBackend().deleteRemoteBranch(
            "topic", on: "origin", expectedTip: tip, at: repo.root)

        #expect(result.outcome == .rejected(.remoteRejected("pre-receive hook declined")))
        #expect(result.remoteMessages == ["policy: this branch is protected"])
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    // MARK: - Refused before git runs

    /// The same rule as `forcePush`: only a full object name is a lease, and every other shape
    /// is refused before git is launched. `deleteRemoteBranch` is where it matters most — the
    /// operation has no undo on the server at all — so the proof that git never ran is the same
    /// three-way one: repository unchanged, server unchanged, and a local `pre-push` hook that
    /// would have fired left no marker.
    @Test(arguments: [
        "", "   ",
        "1234567",
        "1234567890ABCDEF1234567890ABCDEF12345678",
        "1234567890abcdef1234567890abcdef1234567",
        "1234567890abcdef1234567890abcdef1234567g",
        "refs/heads/topic", "HEAD",
        "0000000000000000000000000000000000000000",
    ])
    func aLeaseThatIsNotAFullObjectNameIsRefusedBeforeGitRuns(tip: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("topic.txt", "topic\n")
        try await repo.commitAll("topic")
        try await repo.git(["push", "-q", "origin", "refs/heads/topic:refs/heads/topic"])
        try await repo.git(["fetch", "-q", "origin"])
        try await repo.git(["switch", "-q", "main"])

        let marker = repo.root.appendingPathComponent(".git/pre-push-ran")
        try repo.writeExecutable(".git/hooks/pre-push", """
            #!/bin/sh
            : > "\(marker.path)"

            """)

        let localBefore = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)

        let error = await remoteError {
            _ = try await CLIGitBackend().deleteRemoteBranch(
                "topic", on: "origin", expectedTip: tip, at: repo.root)
        }
        #expect(error == .invalidLease(tip))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "git ran")
        try await assertRepoUnchanged(repo, since: localBefore, worktree: worktreeBefore)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// A branch name that would break the refspec in two — `refs/heads/a:b` is a refspec with a
    /// destination nobody chose — or that git would read as an option. Refused before git runs,
    /// by the same check `push` uses on its source side.
    @Test(arguments: ["-x", " -x", "", "   ", "a:b", ":"])
    func aBranchNameTheDeleteWouldMisreadIsRefusedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let before = try await RepoState.capture(repo)
        let serverBefore = try await RemoteState.capture(origin)
        let tip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])

        await branchError {
            _ = try await CLIGitBackend().deleteRemoteBranch(
                name, on: "origin", expectedTip: tip, at: repo.root)
        }
        #expect(try await RepoState.capture(repo) == before)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    @Test(arguments: ["-x", " -x", "", "   ", "."])
    func aRemoteNameTheDeleteWouldMisreadIsRefusedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let serverBefore = try await RemoteState.capture(origin)
        let tip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])

        let error = await remoteError {
            _ = try await CLIGitBackend().deleteRemoteBranch(
                "main", on: name, expectedTip: tip, at: repo.root)
        }
        #expect(error == .noRemote)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }
}
