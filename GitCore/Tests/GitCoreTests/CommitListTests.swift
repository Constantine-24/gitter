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
    /// $ …  --exclude=origin/topic --exclude='*/HEAD' --remotes
    /// 3
    /// ```
    ///
    /// So `*/HEAD` is excluded too. It costs nothing: `HEAD` is not a valid branch name
    /// (measured: `git branch HEAD` → `fatal: 'HEAD' is not a valid branch name`), so no real
    /// remote branch is ever excluded by it, and another remote's `HEAD` only ever points at a
    /// branch of that remote which `--remotes` already lists in its own right.
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

    /// A name that would be read as an option, or as a glob the exclusion cannot mean. `*`,
    /// `?` and `[` cannot occur in a real ref name (git's own `check-ref-format` forbids them),
    /// and one of them in the `--exclude=` argument would exclude refs nobody named — which
    /// **inflates** the count, so a sheet would warn about commits that are in fact held
    /// elsewhere. Refused rather than passed on.
    @Test(arguments: ["-x", " -x", "", "   ", "origin/*", "origin/to?ic", "origin/[t]opic"])
    func aRemoteBranchNameTheCountWouldMisreadIsRefusedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }

        await branchError {
            _ = try await CLIGitBackend().commitsOnlyOnRemoteBranch(name, at: repo.root)
        }
    }
}
