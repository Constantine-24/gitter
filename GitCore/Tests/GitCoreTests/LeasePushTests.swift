import Foundation
import Testing

@testable import GitCore

/// `GitRemoteBackend.forcePush` — the one operation in Gitter that can destroy commits on
/// another machine, and the lease that stands between it and that.
///
/// The milestone's promise ("Gitter never discards uncommitted work or commits without a
/// confirmation that names what will be lost") rests here on a single mechanism: the sha the
/// confirmation sheet showed is handed to git as `--force-with-lease=<remoteRef>:<sha>`, so a
/// remote that moved while the sheet was open is refused by **git**, not by a re-read that
/// could race. Most of this suite is that refusal, from every angle it can be reached.
///
/// As everywhere in this milestone, "the server" is a bare repository beside the working one
/// and "the colleague" is a second clone of it. Nothing here contacts a network host.
@Suite struct LeasePushTests {
    // MARK: - The lease that matches

    /// The straightforward case, asserted all the way down: the outcome is `.forced` naming
    /// both shas, the server's branch is the local tip, the colleague's commit is **off** that
    /// branch — and is still an object in the server's store, because a force push moves a ref
    /// and does not collect garbage.
    @Test func theRightTipForcesThePushAndTakesTheColleaguesCommitOffTheBranch() async throws {
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

        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")
        let ours = try await repo.headSha()

        let segments = LeaseSegments()
        let result = try await CLIGitBackend().forcePush(
            "main", to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: theirs,
            expectedLocalTip: try await repo.headSha(),
            at: repo.root, progress: { segments.append($0) })

        guard case .forced(let from, let to) = result.outcome else {
            Issue.record("expected .forced, got \(result.outcome)")
            return
        }
        #expect(!from.isEmpty && theirs.hasPrefix(from), "\(from) is not an abbreviation of \(theirs)")
        #expect(!to.isEmpty && ours.hasPrefix(to), "\(to) is not an abbreviation of \(ours)")
        #expect(result.upstream == .notRequested, "a force push never asks for an upstream")

        #expect(try await RemoteState.capture(origin).refs.contains("refs/heads/main\u{0}\(ours)"))
        let reachable = try await bareGit(origin, ["rev-list", "refs/heads/main"])
        #expect(!reachable.contains(theirs), "the colleague's commit is still on the branch")
        #expect(try await bareGit(origin, ["rev-parse", "--verify", "-q", theirs]) == theirs,
                "the commit that was taken off the branch is no longer in the object store")
        // `--progress` is on the vector for the same reason it is on `push`'s: without a tty
        // git prints none, and the sheet's spinner would never say anything.
        #expect(!segments.all.isEmpty)
    }

    /// A leased push that turns out to be an ordinary fast-forward — the remote is exactly at
    /// the lease and the local branch is ahead of it. Measured on git 2.54: the porcelain flag
    /// is a **space**, not `+`, and the summary is `<from>..<to>` with two dots:
    ///
    /// ```
    ///  ^Irefs/heads/main:refs/heads/main^Ib2f68ac..b1ba1f6
    /// ```
    ///
    /// So the outcome is `.pushed`, and saying `.forced` here would be Gitter telling the user
    /// commits were discarded when none were. The truthful answer is git's own.
    @Test func aLeasedPushThatIsReallyAFastForwardIsPushedAndNotForced() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let remoteTip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])
        try repo.write("later.txt", "later\n")
        try await repo.commitAll("later")
        let ours = try await repo.headSha()

        let result = try await CLIGitBackend().forcePush(
            "main", to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: remoteTip,
            expectedLocalTip: try await repo.headSha(),
            at: repo.root, progress: { _ in })

        guard case .pushed(let from, let to) = result.outcome else {
            Issue.record("expected .pushed, got \(result.outcome)")
            return
        }
        #expect(remoteTip.hasPrefix(from) && ours.hasPrefix(to))
        #expect(try await RemoteState.capture(origin).refs.contains("refs/heads/main\u{0}\(ours)"))
    }

    /// **A leased force push moves the one branch the sheet named and creates nothing else.**
    ///
    /// The lease is a claim about one ref, and the confirmation behind it counts what that one
    /// ref would lose. Measured on git 2.54, `push.followTags=true` makes this vector publish
    /// annotated tags too:
    ///
    /// ```
    ///  ^Irefs/heads/main:refs/heads/main^Ie14f0f6..985b548
    /// *^Irefs/tags/annot2:refs/tags/annot2^I[new tag]
    /// ```
    ///
    /// No sheet named that tag. `--no-follow-tags` is on this vector for the same reason it is
    /// on `push`'s, and the claim is checked against the server's whole ref list.
    @Test func aForcePushMovesTheBranchAndCreatesNoTagEvenUnderFollowTags() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["config", "push.followTags", "true"])
        let remoteTip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])
        try repo.write("later.txt", "later\n")
        try await repo.commitAll("later")
        try await repo.git(["tag", "-a", "annotated", "-m", "an annotated tag"])

        let before = try await RemoteState.capture(origin)
        #expect(!before.refs.contains("refs/tags/"), "\(before.refs)")

        _ = try await CLIGitBackend().forcePush(
            "main", to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: remoteTip,
            expectedLocalTip: try await repo.headSha(),
            at: repo.root, progress: { _ in })

        try await assertOnlyRefChanged(origin, since: before, isThe: "refs/heads/main")
    }

    // MARK: - The lease that does not match

    /// **The heart of the task.** The sheet read the remote tip; the colleague pushed again
    /// while it was open; the user pressed Force Push. git refuses on the lease, and the
    /// server is byte-for-byte what the colleague left.
    @Test func aColleagueWhoPushesAgainBetweenTheSheetAndThePushIsRefused() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        try colleague.write("first.txt", "first\n")
        try await colleague.commitAll("the colleague's first commit")
        try await colleague.git(["push", "-q", "origin", "main"])
        // What the sheet would have shown.
        let sheetTip = try await colleague.headSha()

        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")

        // …and then, while the sheet was open:
        try colleague.write("second.txt", "second\n")
        try await colleague.commitAll("the colleague's second commit")
        try await colleague.git(["push", "-q", "origin", "main"])

        let localBefore = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)

        let result = try await CLIGitBackend().forcePush(
            "main", to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: sheetTip,
            expectedLocalTip: try await repo.headSha(),
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .rejected(.staleLease))
        try await assertRepoUnchanged(repo, since: localBefore, worktree: worktreeBefore)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// A tip that was **never** the remote's — a local-only commit's sha. The same refusal,
    /// which is what makes the lease a statement about the server rather than about anything
    /// this repository happens to hold.
    @Test func aTipThatWasNeverTheRemotesIsStale() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")
        let neverOnTheServer = try await repo.headSha()
        let serverBefore = try await RemoteState.capture(origin)

        let result = try await CLIGitBackend().forcePush(
            "main", to: "origin", remoteRef: "refs/heads/main",
            expectedRemoteTip: neverOnTheServer,
            expectedLocalTip: try await repo.headSha(), at: repo.root, progress: { _ in })

        #expect(result.outcome == .rejected(.staleLease))
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// The remote branch was **deleted** while the sheet was open. Measured on git 2.54: the
    /// lease names a sha, the ref holds nothing, and git answers with the same
    /// `[rejected] (stale info)` as any other mismatch — it does **not** recreate the branch.
    ///
    /// ```
    /// !^Irefs/heads/topic:refs/heads/topic^I[rejected] (stale info)
    /// ```
    ///
    /// That is the right answer and worth a test of its own: a force push that silently
    /// recreated a branch somebody had just deleted would be Gitter undoing their work.
    @Test func aRemoteBranchDeletedWhileTheSheetWasOpenIsStale() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("topic.txt", "topic\n")
        try await repo.commitAll("topic")
        try await repo.git(["push", "-q", "origin", "refs/heads/topic:refs/heads/topic"])
        let sheetTip = try await repo.headSha()

        // Somebody deletes it on the server, and we commit again.
        try await bareGit(origin, ["update-ref", "-d", "refs/heads/topic"])
        try repo.write("more.txt", "more\n")
        try await repo.commitAll("more")

        let serverBefore = try await RemoteState.capture(origin)
        let result = try await CLIGitBackend().forcePush(
            "topic", to: "origin", remoteRef: "refs/heads/topic", expectedRemoteTip: sheetTip,
            expectedLocalTip: try await repo.headSha(),
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .rejected(.staleLease))
        #expect(try await bareGit(
            origin, ["rev-parse", "--verify", "-q", "refs/heads/topic"], allowedExitCodes: [1]
        ).isEmpty, "the branch was put back")
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    // MARK: - The lease depends on the sha, and on nothing else

    /// The lease is the sha the sheet showed, so the state of `refs/remotes/origin/main` — which
    /// Gitter's own auto-fetch rewrites — must make no difference at all. Three starting
    /// points, one outcome: the tracking ref deleted, the tracking ref stale (it is, by
    /// default, because nothing fetched after the colleague pushed), and a fetch run first so
    /// it is bang up to date.
    ///
    /// This is the test that would fail if the implementation ever grew a bare
    /// `--force-with-lease`, which leases against exactly that ref.
    @Test(arguments: ["delete the tracking ref", "leave it stale", "fetch first"])
    func theLeaseIgnoresTheLocalTrackingRefEntirely(preparation: String) async throws {
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

        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")
        let ours = try await repo.headSha()

        switch preparation {
        case "delete the tracking ref":
            try await repo.git(["update-ref", "-d", "refs/remotes/origin/main"])
            #expect(try await repo.gitRefExists("refs/remotes/origin/main") == false)
        case "fetch first":
            try await CLIGitBackend().fetch(remote: "origin", at: repo.root, progress: { _ in })
            #expect(try await repo.revParse("refs/remotes/origin/main") == theirs)
        default:
            // The default state: the tracking ref still names the commit before the colleague's.
            #expect(try await repo.revParse("refs/remotes/origin/main") != theirs)
        }

        let result = try await CLIGitBackend().forcePush(
            "main", to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: theirs,
            expectedLocalTip: try await repo.headSha(),
            at: repo.root, progress: { _ in })

        guard case .forced = result.outcome else {
            Issue.record("expected .forced for \(preparation), got \(result.outcome)")
            return
        }
        #expect(try await RemoteState.capture(origin).refs.contains("refs/heads/main\u{0}\(ours)"))
    }

    /// The mirror image, and the measurement that justifies spelling the sha out. A background
    /// fetch between the sheet and the push updates `origin/main` to the colleague's newest
    /// commit; the lease still names the older sha; git refuses.
    ///
    /// Measured on git 2.54, the same fixture with a **bare** `--force-with-lease` — the flag
    /// this package forbids — instead:
    ///
    /// ```
    /// $ git push --porcelain --progress --force-with-lease --end-of-options origin \
    ///       refs/heads/main:refs/heads/main
    /// +   refs/heads/main:refs/heads/main   a975d70...20d319d (forced update)
    /// EXIT=0
    /// ```
    ///
    /// — exit 0, and the colleague's commit gone from the server's branch. The bare form leases
    /// against whatever the last fetch left behind, so Gitter's own auto-fetch would have armed
    /// the very force push the lease exists to stop. That is why the sha is explicit, and this
    /// test is the property that difference produces.
    @Test func aFetchBetweenTheSheetAndThePushDoesNotRescueAStaleLease() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        try colleague.write("first.txt", "first\n")
        try await colleague.commitAll("the colleague's first commit")
        try await colleague.git(["push", "-q", "origin", "main"])
        let sheetTip = try await colleague.headSha()

        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")

        try colleague.write("second.txt", "second\n")
        try await colleague.commitAll("the colleague's second commit")
        try await colleague.git(["push", "-q", "origin", "main"])

        // The auto-fetch fires while the sheet is open.
        try await CLIGitBackend().fetch(remote: "origin", at: repo.root, progress: { _ in })
        let newest = try await colleague.headSha()
        #expect(try await repo.revParse("refs/remotes/origin/main") == newest,
                "the fetch really did move the tracking ref past the sheet's sha")

        let serverBefore = try await RemoteState.capture(origin)
        let result = try await CLIGitBackend().forcePush(
            "main", to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: sheetTip,
            expectedLocalTip: try await repo.headSha(),
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .rejected(.staleLease))
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// The lease names the **destination on the server**, not the local branch. The fixture
    /// makes the difference visible: the server holds `other` and `mine` at different commits,
    /// and the push sends local `mine` to `refs/heads/other`.
    ///
    /// Leasing on `other`'s tip forces; leasing on `mine`'s tip — which is what a backend that
    /// wrote `--force-with-lease=refs/heads/<branch>:…` would have sent — is stale. Without
    /// both halves the test passes for a backend that leases against the wrong ref.
    @Test func theLeaseNamesTheDestinationRefAndNotTheLocalBranch() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        // `other` and `mine` on the server, at two different commits.
        try await repo.git(["switch", "-q", "-c", "other"])
        try repo.write("other.txt", "other\n")
        try await repo.commitAll("other")
        try await repo.git(["push", "-q", "origin", "refs/heads/other:refs/heads/other"])
        let otherTip = try await repo.headSha()

        try await repo.git(["switch", "-q", "-c", "mine", "main"])
        try repo.write("mine.txt", "mine\n")
        try await repo.commitAll("mine")
        try await repo.git(["push", "-q", "origin", "refs/heads/mine:refs/heads/mine"])
        let mineTip = try await repo.headSha()
        #expect(otherTip != mineTip)

        try repo.write("mine2.txt", "mine again\n")
        try await repo.commitAll("mine again")
        let ours = try await repo.headSha()

        // Leasing the *local branch's* counterpart on the server is refused…
        let serverBefore = try await RemoteState.capture(origin)
        let wrong = try await CLIGitBackend().forcePush(
            "mine", to: "origin", remoteRef: "refs/heads/other", expectedRemoteTip: mineTip,
            expectedLocalTip: try await repo.headSha(),
            at: repo.root, progress: { _ in })
        #expect(wrong.outcome == .rejected(.staleLease))
        try await assertRemoteUnchanged(origin, since: serverBefore)

        // …and leasing the destination's own tip goes through.
        let right = try await CLIGitBackend().forcePush(
            "mine", to: "origin", remoteRef: "refs/heads/other", expectedRemoteTip: otherTip,
            expectedLocalTip: try await repo.headSha(),
            at: repo.root, progress: { _ in })
        guard case .forced = right.outcome else {
            Issue.record("expected .forced, got \(right.outcome)")
            return
        }
        let after = try await RemoteState.capture(origin)
        #expect(after.refs.contains("refs/heads/other\u{0}\(ours)"))
        #expect(after.refs.contains("refs/heads/mine\u{0}\(mineTip)"), "`mine` was not the target")
    }

    // MARK: - The commit the sheet showed, on the local side

    /// **The lease pins what the server loses; the local tip pins what it gets.** The sheet
    /// counts the commits the server has that *this* commit lacks, so a push that sent the
    /// branch by name would send whatever the branch points at when the button is pressed — and
    /// a `git reset --hard <older>` in a terminal while the sheet was up would take more off the
    /// server than the sheet named (reproduced in Task 8's review: the sheet named one commit,
    /// two left). With the sha as the refspec's source side, git pushes exactly that commit.
    ///
    /// Measured on git 2.54: `push --force-with-lease=refs/heads/main:<theirs> origin
    /// <sha>:refs/heads/main` exits 0 and prints `+⇥<sha>:refs/heads/main⇥034c32c...d9229ae
    /// (forced update)` — the source side is the full sha, the destination is unchanged, and
    /// the parser, which matches on the destination, reads it as before.
    ///
    /// Both directions a branch can move: forward (a commit on top) and back (a reset to an
    /// older commit). Either way the server ends at the sheet's commit exactly, and the moved
    /// local branch is left where it was moved to.
    @Test(arguments: ["a commit on top", "a reset to an older commit"])
    func theBranchMovingAfterTheSheetDoesNotChangeWhatIsPushed(move: String) async throws {
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

        try repo.write("ours1.txt", "ours 1\n")
        try await repo.commitAll("ours 1")
        try repo.write("ours2.txt", "ours 2\n")
        try await repo.commitAll("ours 2")
        // What the sheet counted against, and what it described as "your branch".
        let sheetLocal = try await repo.headSha()

        // …and then, while the sheet was open, from a terminal:
        switch move {
        case "a commit on top":
            try repo.write("later.txt", "later\n")
            try await repo.commitAll("after the sheet")
        default:
            try await repo.git(["reset", "-q", "--hard", "HEAD~1"])
        }
        let moved = try await repo.revParse("refs/heads/main")
        #expect(moved != sheetLocal, "the branch did not move, so this proves nothing")

        let result = try await CLIGitBackend().forcePush(
            "main", to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: theirs,
            expectedLocalTip: sheetLocal, at: repo.root, progress: { _ in })

        guard case .forced(let from, let to) = result.outcome else {
            Issue.record("expected .forced, got \(result.outcome)")
            return
        }
        #expect(!from.isEmpty && theirs.hasPrefix(from))
        #expect(!to.isEmpty && sheetLocal.hasPrefix(to), "\(to) is not the sheet's \(sheetLocal)")
        #expect(try await bareGit(origin, ["rev-parse", "refs/heads/main"]) == sheetLocal,
                "the server's branch is not exactly the commit the sheet described")
        #expect(try await repo.revParse("refs/heads/main") == moved,
                "the local branch was moved by the push")
    }

    /// The local tip is checked exactly as the lease is — a full, lower-case object name that is
    /// not all zeros — and for a sharper reason: it is the refspec's **source side**. An
    /// abbreviation is resolved by git against whatever it happens to match, `HEAD` or a ref
    /// name is a local name that can move (the very hole this closes), an empty source side is
    /// a **deletion** on the server, and forty zeros would be read the same way. Each is refused
    /// before git is launched: no `pre-push` hook fires, and neither repository changes.
    @Test(arguments: [
        "", "   ",
        "1234567",
        "1234567890ABCDEF1234567890ABCDEF12345678",
        "1234567890abcdef1234567890abcdef1234567",
        "refs/heads/main", "HEAD", "main",
        "0000000000000000000000000000000000000000",
        " 1234567890abcdef1234567890abcdef12345678",
        "+1234567890abcdef1234567890abcdef1234567",
        ":1234567890abcdef1234567890abcdef1234567",
    ])
    func aLocalTipThatIsNotAFullObjectNameIsRefusedBeforeGitRuns(localTip: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let marker = repo.root.appendingPathComponent(".git/pre-push-ran")
        try repo.writeExecutable(".git/hooks/pre-push", """
            #!/bin/sh
            : > "\(marker.path)"

            """)
        let remoteTip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])
        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")

        let localBefore = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)

        let error = await remoteError {
            _ = try await CLIGitBackend().forcePush(
                "main", to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: remoteTip,
                expectedLocalTip: localTip, at: repo.root, progress: { _ in })
        }
        #expect(error == .invalidLease(localTip))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "git ran")
        try await assertRepoUnchanged(repo, since: localBefore, worktree: worktreeBefore)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    // MARK: - The server's own refusal

    /// A `pre-receive` hook that declines. The lease matched, so this is the server saying no
    /// for its own reasons — a different outcome from `.staleLease`, and the server's words
    /// come back beside it.
    @Test func aPreReceiveHookThatDeclinesAForcePushLeavesTheRemoteUntouched() async throws {
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

        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")

        try writeBareHook(origin, "pre-receive", """
            #!/bin/sh
            echo "policy: this branch is protected"
            exit 1

            """)

        let serverBefore = try await RemoteState.capture(origin)
        let result = try await CLIGitBackend().forcePush(
            "main", to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: theirs,
            expectedLocalTip: try await repo.headSha(),
            at: repo.root, progress: { _ in })

        #expect(result.outcome == .rejected(.remoteRejected("pre-receive hook declined")))
        #expect(result.remoteMessages == ["policy: this branch is protected"])
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    // MARK: - Leases refused before git runs

    /// Anything that is not a full object name is refused **before git is launched**, and each
    /// of these was measured on git 2.54 to show why leaving it to git is not an option:
    ///
    /// | lease value | what git does |
    /// |---|---|
    /// | `211f4ff` (abbreviated) | `error: cannot parse expected object name`, exit 129 |
    /// | a 40-hex name in **upper case** | **accepted** — the push is forced |
    /// | `refs/heads/main`, `HEAD` | **accepted**, resolved *locally* as a revision |
    /// | empty | accepted, and means "the ref must not exist" |
    /// | forty zeros | accepted; means the same, so it **creates** a branch that is absent |
    ///
    /// The three "accepted" rows are the reason this check exists. A lease git resolves as a
    /// revision is a lease on a **local** name that can move — measured:
    /// `--force-with-lease=refs/heads/main:refs/remotes/origin/main` forced the push, which is
    /// the bare `--force-with-lease` hole reached by another road. The all-zero name is worse
    /// than useless: measured, with the remote branch absent it exits 0 and pushes
    /// `[new branch]`, so it is a lease that can never refuse anything. And upper case is a
    /// different spelling of a sha nobody showed the user; the sheet's own sha is git's, and
    /// git prints lower case.
    ///
    /// The refusal is proved to be a true no-op three ways: the repository is unchanged, the
    /// server is unchanged, and a `pre-push` hook — which runs on **this** machine before the
    /// transport, so it fires even for a push that never reaches a server — left no marker.
    @Test(arguments: [
        "", "   ", "\n",
        "1234567",
        "1234567890ABCDEF1234567890ABCDEF12345678",
        "1234567890abcdef1234567890abcdef1234567",
        "1234567890abcdef1234567890abcdef123456789",
        "1234567890abcdef1234567890abcdef1234567g",
        "refs/heads/main", "HEAD", "main@{upstream}", "origin/main",
        "0000000000000000000000000000000000000000",
        "0000000000000000000000000000000000000000000000000000000000000000",
        " 1234567890abcdef1234567890abcdef12345678",
        "1234567890abcdef1234567890abcdef12345678 ",
    ])
    func aLeaseThatIsNotAFullObjectNameIsRefusedBeforeGitRuns(tip: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let marker = repo.root.appendingPathComponent(".git/pre-push-ran")
        try repo.writeExecutable(".git/hooks/pre-push", """
            #!/bin/sh
            : > "\(marker.path)"

            """)
        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")

        let localBefore = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)

        let error = await remoteError {
            _ = try await CLIGitBackend().forcePush(
                "main", to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: tip,
                expectedLocalTip: try await repo.headSha(),
                at: repo.root, progress: { _ in })
        }
        #expect(error == .invalidLease(tip))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "git ran")
        try await assertRepoUnchanged(repo, since: localBefore, worktree: worktreeBefore)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// The control that keeps the assertion above from being vacuous: with a **valid** lease
    /// the very same hook does fire, so "no marker" really does mean "git never ran" rather
    /// than "the hook never worked".
    @Test func thePrePushHookFiresWhenTheLeaseIsOneGitIsGiven() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let marker = repo.root.appendingPathComponent(".git/pre-push-ran")
        try repo.writeExecutable(".git/hooks/pre-push", """
            #!/bin/sh
            : > "\(marker.path)"

            """)
        let tip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])
        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")

        _ = try await CLIGitBackend().forcePush(
            "main", to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: tip,
            expectedLocalTip: try await repo.headSha(),
            at: repo.root, progress: { _ in })

        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    /// The other side of that rule: a full **sha-256** object name is a lease, and is handed to
    /// git. In a sha-1 repository git then answers `error: cannot parse expected object name`
    /// and exits 129 with no porcelain line, so what comes back is git's own words — **not**
    /// `.invalidLease`, which would have been Gitter refusing a name that is perfectly valid in
    /// a repository with the other object format.
    @Test func aFullSha256ObjectNameIsALeaseAndReachesGit() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        var thrown: Error?
        do {
            _ = try await CLIGitBackend().forcePush(
                "main", to: "origin", remoteRef: "refs/heads/main",
                expectedRemoteTip: String(repeating: "0123456789abcdef", count: 4),
                expectedLocalTip: try await repo.headSha(),
                at: repo.root, progress: { _ in })
        } catch {
            thrown = error
        }
        guard case .commandFailed(let code, let stderr)? = thrown as? GitError else {
            Issue.record("expected GitError.commandFailed, got \(String(describing: thrown))")
            return
        }
        #expect(code == 129, "git's own status")
        #expect(stderr.contains("cannot parse expected object name"), "\(stderr)")
    }

    /// The names `push` refuses, refused here too and by the same shared checks — a force push
    /// must not be the one door where a branch called `a:b` gets through.
    @Test(arguments: ["-x", " -x", "", "   ", "a:b", ":"])
    func aBranchNameForcePushWouldMisreadIsRefusedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let before = try await RepoState.capture(repo)
        let serverBefore = try await RemoteState.capture(origin)
        let tip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])

        await branchError {
            _ = try await CLIGitBackend().forcePush(
                name, to: "origin", remoteRef: "refs/heads/main", expectedRemoteTip: tip,
                expectedLocalTip: try await repo.headSha(),
                at: repo.root, progress: { _ in })
        }
        #expect(try await RepoState.capture(repo) == before)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    @Test(arguments: ["-x", " -x", "", "   ", "."])
    func aRemoteNameForcePushWouldMisreadIsRefusedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let serverBefore = try await RemoteState.capture(origin)
        let tip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])

        let error = await remoteError {
            _ = try await CLIGitBackend().forcePush(
                "main", to: name, remoteRef: "refs/heads/main", expectedRemoteTip: tip,
                expectedLocalTip: try await repo.headSha(),
                at: repo.root, progress: { _ in })
        }
        #expect(error == .noRemote)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// The destination goes into the lease **and** into the refspec, so it is checked exactly as
    /// `push` checks it: a full `refs/heads/…` name, no second `:`, no leading `+`, `-` or `:`.
    @Test(arguments: [
        "main", "heads/main", "refs/tags/v1", "refs/heads/", "", "+refs/heads/main",
        "-refs/heads/main", ":refs/heads/main", "refs/heads/a:b",
    ])
    func aForcePushDestinationThatIsNotAFullBranchRefIsRefusedBeforeGitRuns(ref: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let before = try await RepoState.capture(repo)
        let serverBefore = try await RemoteState.capture(origin)
        let tip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])

        await branchError {
            _ = try await CLIGitBackend().forcePush(
                "main", to: "origin", remoteRef: ref, expectedRemoteTip: tip,
                expectedLocalTip: try await repo.headSha(),
                at: repo.root, progress: { _ in })
        }
        #expect(try await RepoState.capture(repo) == before)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    // MARK: - Cancellation

    /// Twenty cancelled force pushes, held open by the same deliberately slow `receive-pack`
    /// `PushTests` uses. Each must end with `CancellationError`, and the repository must be
    /// sound with no `*.lock` and no stray transport afterwards.
    ///
    /// The server is untouched here only because this fixture's wrapper sleeps *before* it
    /// execs `git-receive-pack`. That is a property of the fixture: a cancelled force push in
    /// general says nothing about what reached the server, which is exactly what
    /// `GitRemoteBackend.forcePush` promises.
    ///
    /// That the cancel ended each force push, rather than the wrapper's sleep running out, is
    /// the time limit's: the sleep outlasts it. A `< 20 s` per attempt on the test's clock stood
    /// here, which load could exceed; the control is
    /// `aForcePushTheCancelDidNotStopIsReportedOnceTheTestIsCancelled`. The `pgrep` for the
    /// `sleep` and the lock, fsck and state checks prove the child gone and the repositories
    /// intact (`PushTests.twentyCancelledPushesAllEndAtOnceAndLeaveTheRepositorySound`).
    @Test(.timeLimit(.minutes(10)))
    func twentyCancelledForcePushesAllEndAtOnceAndLeaveTheRepositorySound() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let started = repo.root.appendingPathComponent(".git/slow-receive-pack.started")
        let sleep = try await PushTests.installSlowReceivePack(in: repo, started: started)

        let remoteTip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])
        try repo.write("slowly.txt", "slowly\n")
        try await repo.commitAll("slowly")

        let before = try await RepoState.capture(repo)
        let worktreeBefore = worktreeSnapshot(repo)
        let serverBefore = try await RemoteState.capture(origin)

        for attempt in 0..<20 {
            try? FileManager.default.removeItem(at: started)
            let call = forcePush(repo, expectedRemoteTip: remoteTip)
            try await PushTests.waitForSlowTransport(started, attempt)

            call.cancel()
            guard let thrown = await call.value("attempt \(attempt)") else { return }
            #expect(thrown is CancellationError, "attempt \(attempt): \(String(describing: thrown))")
        }

        try await PushTests.expectNoTransportLeft(sleep)

        #expect(try await repo.fsckComplaints() == "")
        #expect(repo.lockFiles() == [])
        try await assertRepoUnchanged(repo, since: before, worktree: worktreeBefore)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// The control for the test above's hang guard: a force push the cancel did not stop —
    /// here, one never cancelled — is still waiting on the wrapper's sleep when the time limit
    /// cancels the test, and the test reports it. The limit is stood in for by a waiting task
    /// this test cancels (`TimeLimitSupport.swift`); then the force push is cancelled for real,
    /// and nothing is left behind.
    @Test func aForcePushTheCancelDidNotStopIsReportedOnceTheTestIsCancelled() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let started = repo.root.appendingPathComponent(".git/slow-receive-pack.started")
        let sleep = try await PushTests.installSlowReceivePack(in: repo, started: started)
        let remoteTip = try await bareGit(origin, ["rev-parse", "refs/heads/main"])
        try repo.write("slowly.txt", "slowly\n")
        try await repo.commitAll("slowly")
        let serverBefore = try await RemoteState.capture(origin)

        let call = forcePush(repo, expectedRemoteTip: remoteTip)
        try await PushTests.waitForSlowTransport(started, 0)

        await withKnownIssue("the force push is not cancelled, so it waits on the wrapper's sleep") {
            let waiter = Task { await call.value("the force push") }
            try await Task.sleep(for: .milliseconds(300))
            waiter.cancel()
            let thrown = await waiter.value
            #expect(thrown == nil, "the force push came back: \(String(describing: thrown))")
        }

        call.cancel()
        #expect(await call.task.value is CancellationError)
        try await PushTests.expectNoTransportLeft(sleep)
        try await assertRemoteUnchanged(origin, since: serverBefore)
    }

    /// A force push of `main` with the lease on `expectedRemoteTip`, in a task of its own.
    private func forcePush(_ repo: TestRepo, expectedRemoteTip: String) -> CallUnderTest<Error?> {
        CallUnderTest { () -> Error? in
            do {
                _ = try await CLIGitBackend().forcePush(
                    "main", to: "origin", remoteRef: "refs/heads/main",
                    expectedRemoteTip: expectedRemoteTip,
                    expectedLocalTip: try await repo.headSha(), at: repo.root, progress: { _ in })
                return nil
            } catch {
                return error
            }
        }
    }
}

/// A lock-protected collector for progress segments, which arrive on the pipe's background
/// queue while the call is still running and are read after it has returned.
private final class LeaseSegments: @unchecked Sendable {
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
