import Foundation
import Testing

@testable import GitCore

/// The two reads the force-push and delete-remote-branch confirmations are built out of:
/// `commits(in:notIn:limit:)`, which names the commits a force push would discard, and
/// `commitsOnlyOnRemoteBranch`, which says how many of a remote branch's commits would survive
/// nowhere else if it were deleted.
///
/// Neither writes anything, and both exist so a sheet can say what will be lost rather than
/// how many refs will move.
@Suite struct CommitListTests {
    // MARK: - The commits a force push would discard

    /// The colleague's three commits, newest first, with their summaries and their parent
    /// links — the same `Commit` the history list is drawn from, through the same `LogParser`.
    @Test func listsTheCommitsOnTheRemoteThatAreNotOnTheBranch() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        for step in ["first", "second", "third"] {
            try colleague.write("\(step).txt", "\(step)\n")
            try await colleague.commitAll("the colleague's \(step) commit")
        }
        try await colleague.git(["push", "-q", "origin", "main"])
        try await repo.git(["fetch", "-q", "origin"])

        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")

        let commits = try await CLIGitBackend().commits(
            in: "refs/remotes/origin/main", notIn: "refs/heads/main", limit: 50, at: repo.root)

        #expect(commits.map(\.summary) == [
            "the colleague's third commit",
            "the colleague's second commit",
            "the colleague's first commit",
        ])
        #expect(commits.allSatisfy { $0.authorName == "Colleague" })
        #expect(commits.first?.sha == (try await colleague.headSha()))
        #expect(commits.first?.parents == [commits[1].sha], "the parent links survived the parse")
    }

    /// `limit` is git's `-n`, and it keeps the newest: a sheet that lists twenty commits out of
    /// two hundred must list the twenty nearest the tip, which are the ones the user recognises.
    @Test func honoursTheLimitAndKeepsTheNewest() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        for step in 1...5 {
            try colleague.write("c\(step).txt", "\(step)\n")
            try await colleague.commitAll("colleague \(step)")
        }
        try await colleague.git(["push", "-q", "origin", "main"])
        try await repo.git(["fetch", "-q", "origin"])

        let backend = CLIGitBackend()
        let two = try await backend.commits(
            in: "refs/remotes/origin/main", notIn: "refs/heads/main", limit: 2, at: repo.root)
        #expect(two.map(\.summary) == ["colleague 5", "colleague 4"])

        let all = try await backend.commits(
            in: "refs/remotes/origin/main", notIn: "refs/heads/main", limit: 99, at: repo.root)
        #expect(all.count == 5)
    }

    /// A limit of zero or less is clamped to one rather than passed on. `git log -n 0` prints
    /// nothing, so a caller whose arithmetic produced a zero would get an empty list and a
    /// sheet that said no commits would be lost — the one wrong answer this pair must never
    /// give. One commit is a visibly incomplete list; none is a false reassurance.
    @Test(arguments: [0, -1, Int.min])
    func clampsALimitThatIsNotPositive(limit: Int) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let colleague = try await repo.addColleague()
        defer { colleague.cleanUp() }

        for step in 1...3 {
            try colleague.write("c\(step).txt", "\(step)\n")
            try await colleague.commitAll("colleague \(step)")
        }
        try await colleague.git(["push", "-q", "origin", "main"])
        try await repo.git(["fetch", "-q", "origin"])

        let commits = try await CLIGitBackend().commits(
            in: "refs/remotes/origin/main", notIn: "refs/heads/main", limit: limit, at: repo.root)
        #expect(commits.map(\.summary) == ["colleague 3"])
    }

    /// Nothing on one side that is not on the other: an empty list, not an error.
    @Test func aRangeWithNothingInItIsEmpty() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let commits = try await CLIGitBackend().commits(
            in: "refs/remotes/origin/main", notIn: "refs/heads/main", limit: 50, at: repo.root)
        #expect(commits.isEmpty)
    }

    /// Both revisions are checked before git runs, by the same `requireRevision` that guards
    /// `commitCount(in:notIn:)` — they are two halves of one `<base>..<revision>` argument.
    @Test(arguments: ["-x", " -x", "", "   "])
    func aRevisionGitWouldMisreadIsRefusedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let backend = CLIGitBackend()

        await branchError {
            _ = try await backend.commits(
                in: name, notIn: "refs/heads/main", limit: 10, at: repo.root)
        }
        await branchError {
            _ = try await backend.commits(
                in: "refs/heads/main", notIn: name, limit: 10, at: repo.root)
        }
    }

    /// **These parameters are ref names, not revisions, and a revision is refused.**
    ///
    /// `commits(in:notIn:)` builds one `<base>..<revision>` argument out of them, so an
    /// argument that is itself range syntax silently makes a *different* question. The two that
    /// matter most, and neither errors today:
    ///
    /// - `base = "refs/heads/main."` — the trailing dot joins the `..` this code writes into
    ///   `...`, which is the **symmetric** difference: a sheet listing commits from both sides.
    /// - `revision = "a..b"` — `<base>..a..b`, which git reads as a different range again.
    ///
    /// `^`, `~` and `@{…}` are the other three ways to name something other than the ref
    /// passed, and `:` is `<rev>:<path>`. A leading `.` is the mirror of the trailing one (it
    /// joins the `..` from the other side). All six are refused **before git runs**, which is
    /// why `branchError` is the assertion: a sheet built on the wrong range is worse than one
    /// that refuses to open.
    @Test(arguments: [
        "refs/heads/main.", ".refs/heads/main", "a..b", "main^", "main~1", "main@{1}", "a:b",
    ])
    func aRevisionWhereARefNameIsExpectedIsRefusedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let backend = CLIGitBackend()

        await branchError {
            _ = try await backend.commits(
                in: name, notIn: "refs/heads/main", limit: 10, at: repo.root)
        }
        await branchError {
            _ = try await backend.commits(
                in: "refs/heads/main", notIn: name, limit: 10, at: repo.root)
        }
    }

    /// The forms the pair above is *for*, which the rule must not take with it: a full ref
    /// name on either side, the short remote-tracking name, `HEAD`, and a plain object name.
    /// Each is resolved and answers rather than throwing.
    @Test func theFormsCallersLegitimatelyPassAreStillAccepted() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try repo.write("ours.txt", "ours\n")
        try await repo.commitAll("ours")
        let tip = try await repo.headSha()
        let base = try await repo.revParse("refs/remotes/origin/main")
        let backend = CLIGitBackend()

        for (revision, name) in [
            ("refs/heads/main", "a full ref name"), ("HEAD", "HEAD"), (tip, "a full object name"),
        ] {
            let commits = try await backend.commits(
                in: revision, notIn: base, limit: 10, at: repo.root)
            #expect(commits.map(\.summary) == ["ours"], "\(name) was not accepted")
        }
        // And the short remote-tracking name, which is what `commitsOnlyOnRemoteBranch` takes.
        #expect(try await backend.commits(
            in: "origin/main", notIn: "refs/heads/main", limit: 10, at: repo.root).isEmpty)
        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/feat/x", at: repo.root) >= 0)
    }

    /// A revision that is plausible but not there fails loudly. A confirmation built on a
    /// silent empty list would tell the user nothing will be lost, which is the one answer
    /// that can cost them work.
    @Test func aRevisionThatDoesNotResolveThrows() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        var thrown: Error?
        do {
            _ = try await CLIGitBackend().commits(
                in: "nosuchref", notIn: "refs/heads/main", limit: 10, at: repo.root)
        } catch {
            thrown = error
        }
        guard case .commandFailed(_, let stderr)? = thrown as? GitError else {
            Issue.record("expected GitError.commandFailed, got \(String(describing: thrown))")
            return
        }
        #expect(stderr.contains("bad revision"), "\(stderr)")
    }

    // MARK: - Commits that would survive nowhere else

    /// The count the delete-a-remote-branch sheet is built on, in the four shapes that decide
    /// it. "Somewhere else" is any local branch, any tag, or any **other** remote-tracking
    /// ref — the branch's own ref is excluded, or it would always cover itself and the answer
    /// would always be 0.
    @Test func countsOnlyTheCommitsNoOtherRefHolds() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let fork = try await repo.addEmptyRemote(named: "fork")
        defer { try? FileManager.default.removeItem(at: fork) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        for step in 1...3 {
            try repo.write("t\(step).txt", "\(step)\n")
            try await repo.commitAll("topic \(step)")
        }
        try await repo.git(["push", "-q", "origin", "refs/heads/topic:refs/heads/topic"])
        try await repo.git(["fetch", "-q", "origin"])
        try await repo.git(["switch", "-q", "main"])

        let backend = CLIGitBackend()
        // The local branch still holds them.
        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/topic", at: repo.root) == 0)

        try await repo.git(["branch", "-q", "-D", "topic"])
        // Now nothing else does.
        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/topic", at: repo.root) == 3)

        // A tag is somewhere else.
        try await repo.git(["tag", "keep", "refs/remotes/origin/topic"])
        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/topic", at: repo.root) == 0)
        try await repo.git(["tag", "-d", "keep"])

        // And so is another remote.
        try await repo.git(["push", "-q", "fork", "refs/remotes/origin/topic:refs/heads/topic"])
        try await repo.git(["fetch", "-q", "fork"])
        #expect(try await repo.gitRefExists("refs/remotes/fork/topic"))
        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/topic", at: repo.root) == 0)
    }

    /// **`refs/remotes/<r>/HEAD` is a symbolic ref, and a symref is not an independent holder.**
    ///
    /// Measured on git 2.54: `rev-list --remotes` lists `refs/remotes/origin/HEAD` as a ref of
    /// its own, so when it points at the very branch being asked about it covers that branch's
    /// commits and the count comes back **0** — "nothing would be lost" for a branch whose
    /// deletion would strand three commits. But `origin/HEAD` holds nothing on its own: it is a
    /// pointer at `origin/topic`, and deleting `origin/topic` leaves it dangling.
    ///
    /// ```
    /// $ git rev-list --count refs/remotes/origin/topic --not --branches --tags \
    ///       --exclude=origin/topic --remotes
    /// 0
    /// $ …  --exclude=origin/topic --exclude=origin/HEAD --remotes
    /// 3
    /// ```
    ///
    /// So the symbolic refs under `refs/remotes` are excluded too — **listed and named**, one
    /// `--exclude` each. `--exclude=*/HEAD` gives 3 here as well and was what stood in the code
    /// until Task 6's fix round, on the claim that it "costs nothing, since `HEAD` is not a
    /// valid branch name". The two tests below are why that claim is gone: it costs an
    /// over-count for a real branch called `x/HEAD`, and an **under**-count for a symref that
    /// is not called `HEAD` at all.
    @Test func theRemotesOwnHeadSymrefDoesNotCoverTheBranchItPointsAt() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        for step in 1...3 {
            try repo.write("t\(step).txt", "\(step)\n")
            try await repo.commitAll("topic \(step)")
        }
        try await repo.git(["push", "-q", "origin", "refs/heads/topic:refs/heads/topic"])
        // The server's default branch is now `topic`, and the clone's `origin/HEAD` follows it.
        try await bareGit(origin, ["symbolic-ref", "HEAD", "refs/heads/topic"])
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["branch", "-q", "-D", "topic"])
        try await repo.git(["fetch", "-q", "origin"])
        try await repo.git(["symbolic-ref", "refs/remotes/origin/HEAD", "refs/remotes/origin/topic"])

        #expect(try await repo.symbolicRef("refs/remotes/origin/HEAD")
                == "refs/remotes/origin/topic")
        #expect(try await CLIGitBackend().commitsOnlyOnRemoteBranch("origin/topic", at: repo.root)
                == 3)
    }

    /// **A real remote branch whose last component is `HEAD` is a holder like any other.**
    ///
    /// The `*/HEAD` glob this exclusion used to be spelled with rested on a claim that was
    /// false: that it "costs nothing, because `HEAD` is not a valid branch name". Only a
    /// **whole-name** `HEAD` is refused — measured on git 2.54:
    ///
    /// ```
    /// $ git check-ref-format --branch HEAD      → fatal: 'HEAD' is not a valid branch name
    /// $ git check-ref-format --branch x/HEAD    → x/HEAD          (exit 0)
    /// $ git branch x/HEAD                       → (exit 0)
    /// ```
    ///
    /// — and `*` in an `--exclude` pattern crosses `/`, so `*/HEAD` matched
    /// `refs/remotes/other/x/HEAD`, an ordinary remote-tracking ref for an ordinary branch
    /// somebody pushed. The commits it holds were counted as held by nothing: 3 where the truth
    /// is 0, a sheet warning about work that is in fact safe on a second remote.
    ///
    /// The exclusion now names the symbolic refs it means, one `--exclude` each, so this is the
    /// **true** answer rather than an over-count that was tolerated.
    @Test func aRemoteBranchWhoseLastComponentIsHeadStillHoldsItsCommits() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let other = try await repo.addEmptyRemote(named: "other")
        defer { try? FileManager.default.removeItem(at: other) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        for step in 1...3 {
            try repo.write("t\(step).txt", "\(step)\n")
            try await repo.commitAll("topic \(step)")
        }
        try await repo.git(["push", "-q", "origin", "refs/heads/topic:refs/heads/topic"])
        try await repo.git(["fetch", "-q", "origin"])
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["branch", "-q", "-D", "topic"])

        let backend = CLIGitBackend()
        // A baseline that can fail: with nothing else holding them the answer really is 3, so
        // the 0 below is the second remote being seen and not an exclusion swallowing the ref.
        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/topic", at: repo.root) == 3)

        // A branch literally called `x/HEAD`, pushed to a second remote and fetched back — not
        // a contrivance with `update-ref`, a real branch reached the ordinary way.
        try await repo.git(["push", "-q", "other", "refs/remotes/origin/topic:refs/heads/x/HEAD"])
        try await repo.git(["fetch", "-q", "other"])
        #expect(try await repo.gitRefExists("refs/remotes/other/x/HEAD"))
        #expect(try await repo.symbolicRef("refs/remotes/other/x/HEAD") == nil,
                "it must be a real ref, or this tests the symref rule instead")

        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/topic", at: repo.root) == 0,
                "a second remote holds every one of them")
    }

    /// The mirror image, and the reason the glob was not merely over-cautious: a symbolic ref
    /// under `refs/remotes` **need not be called `HEAD`**, and `*/HEAD` missed every other one —
    /// under-counting, which is the direction that costs work.
    ///
    /// Measured on git 2.54 with `refs/remotes/origin/default → refs/remotes/origin/topic`:
    /// `--exclude=origin/topic --exclude='*/HEAD' --remotes` answers **0** (the symref covers
    /// the branch's own commits) where the truth is 3. Excluding the symrefs by name answers 3.
    @Test func aRemoteSymrefThatIsNotCalledHeadIsStillNotAHolder() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        for step in 1...3 {
            try repo.write("t\(step).txt", "\(step)\n")
            try await repo.commitAll("topic \(step)")
        }
        try await repo.git(["push", "-q", "origin", "refs/heads/topic:refs/heads/topic"])
        try await repo.git(["fetch", "-q", "origin"])
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["branch", "-q", "-D", "topic"])

        let backend = CLIGitBackend()
        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/topic", at: repo.root) == 3)

        try await repo.git(
            ["symbolic-ref", "refs/remotes/origin/default", "refs/remotes/origin/topic"])
        #expect(try await repo.symbolicRef("refs/remotes/origin/default")
                == "refs/remotes/origin/topic")

        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/topic", at: repo.root) == 3,
                "a pointer at the branch is not a second holder of its commits")
    }

    /// The same rule under `refs/heads` and `refs/tags` (E3 B4.3): `--branches` and `--tags`
    /// list a symref there as a ref of its own, so one pointing at the remote branch being
    /// deleted covered its commits and the count came back **0** where three would be stranded.
    /// A symref to a real local branch holds nothing the branch does not, and changes nothing.
    @Test(arguments: ["refs/heads/y", "refs/tags/s"])
    func aLocalSymrefAtTheRemoteBranchIsStillNotAHolder(symref: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        try await repo.git(["switch", "-q", "-c", "topic"])
        for step in 1...3 {
            try repo.write("t\(step).txt", "\(step)\n")
            try await repo.commitAll("topic \(step)")
        }
        try await repo.git(["push", "-q", "origin", "refs/heads/topic:refs/heads/topic"])
        try await repo.git(["fetch", "-q", "origin"])
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["branch", "-q", "-D", "topic"])

        let backend = CLIGitBackend()
        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/topic", at: repo.root) == 3)

        // A symref to a local branch: harmless before and after.
        try await repo.git(["symbolic-ref", "refs/heads/x", "refs/heads/main"])
        #expect(try await repo.symbolicRef("refs/heads/x") == "refs/heads/main")
        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/topic", at: repo.root) == 3)

        try await repo.git(["symbolic-ref", symref, "refs/remotes/origin/topic"])
        #expect(try await repo.symbolicRef(symref) == "refs/remotes/origin/topic")
        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/topic", at: repo.root) == 3,
                "a pointer at the branch is not a second holder of its commits")

        // And a real holder in the same namespace still is one: the exclusion names the
        // symref, not the namespace.
        if symref.hasPrefix("refs/heads/") {
            try await repo.git(["branch", "keep", "refs/remotes/origin/topic"])
        } else {
            try await repo.git(["tag", "keep", "refs/remotes/origin/topic"])
        }
        #expect(try await backend.commitsOnlyOnRemoteBranch("origin/topic", at: repo.root) == 0)
    }

    /// A name that would be read as an option, or as a glob the exclusion cannot mean. `*`,
    /// `?` and `[` cannot occur in a real ref name (git's own `check-ref-format` forbids them),
    /// and one of them in the `--exclude=` argument would exclude refs nobody named — which
    /// **inflates** the count, so a sheet would warn about commits that are in fact held
    /// elsewhere. Refused rather than passed on.
    ///
    /// The last six are the range and revision operators: this parameter is spelled into
    /// `refs/remotes/<name>` and handed to `rev-list` as a *revision*, so `origin/a..main`
    /// becomes a range and the count comes back **0** — "nothing would be lost" — for a name
    /// nobody could have meant. Same rule, same reason and same refusal as
    /// `commits(in:notIn:)`'s.
    @Test(arguments: [
        "-x", " -x", "", "   ", "origin/*", "origin/to?ic", "origin/[t]opic",
        "origin/a..main", "origin/topic^", "origin/topic~1", "origin/topic@{1}", "origin/topic.",
        "origin/to:pic",
    ])
    func aRemoteBranchNameTheCountWouldMisreadIsRefusedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        await branchError {
            _ = try await CLIGitBackend().commitsOnlyOnRemoteBranch(name, at: repo.root)
        }
    }
}
