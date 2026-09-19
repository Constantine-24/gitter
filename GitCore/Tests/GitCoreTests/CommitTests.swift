import Foundation
import Testing
@testable import GitCore

@Suite struct CommitTests {
    private func snapshotCommits(_ repo: TestRepo) async throws -> [Commit] {
        try await CLIGitBackend().snapshot(at: repo.root).commits
    }

    @Test func commitWithStagedChangesReturnsShaMatchingRevParseHeadAndSubjectAppearsInLog() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        let sha = try await backend.commit(
            message: "Add second line", amend: false, allTracked: false, at: repo.root
        )

        assertWorktreeUnchanged(repo, since: before)
        #expect(sha == (try await repo.revParse("HEAD")))
        let commits = try await snapshotCommits(repo)
        #expect(commits.first { $0.sha == sha }?.summary == "Add second line")
    }

    @Test func multiLineMessageBodyIsPreserved() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let message = "Subject line\n\nFirst body paragraph.\nSecond body line.\n\nThird paragraph."
        let before = worktreeSnapshot(repo)

        _ = try await backend.commit(message: message, amend: false, allTracked: false, at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        let stored = try await backend.headMessage(at: repo.root)
        #expect(stored == message)
    }

    @Test func nothingStagedAndAllTrackedFalseThrowsAndLeavesHeadUnchanged() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        let headBefore = try await repo.headSha()
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        await #expect(throws: GitError.self) {
            _ = try await backend.commit(message: "nothing to commit", amend: false, allTracked: false, at: repo.root)
        }

        assertWorktreeUnchanged(repo, since: before)
        #expect((try await repo.headSha()) == headBefore)
    }

    @Test func allTrackedCommitsModifiedTrackedFileButLeavesUntrackedFileUntracked() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("a.txt", "one\ntwo\n")
        try repo.write("untracked.txt", "new\n")
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        let sha = try await backend.commit(
            message: "commit all tracked", amend: false, allTracked: true, at: repo.root
        )

        assertWorktreeUnchanged(repo, since: before)
        #expect(sha == (try await repo.headSha()))
        let files = try await CLIGitBackend().commitFiles(at: repo.root, sha: sha)
        #expect(files.map(\.path) == ["a.txt"])
        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        let untracked = status.files.first { $0.path == "untracked.txt" }
        #expect(untracked?.unstaged == .untracked)
        #expect(untracked?.staged == nil)
    }

    @Test func amendChangesHeadShaKeepsParentAndReplacesMessage() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        let rootSha = try await repo.headSha()
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.git(["add", "a.txt"])
        try await repo.git(["commit", "-q", "-m", "first message"])
        let originalSecondSha = try await repo.headSha()

        try repo.write("a.txt", "one\ntwo\nthree\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        let amendedSha = try await backend.commit(
            message: "second message amended", amend: true, allTracked: false, at: repo.root
        )

        assertWorktreeUnchanged(repo, since: before)
        #expect(amendedSha != originalSecondSha)
        #expect(amendedSha == (try await repo.headSha()))
        let commits = try await snapshotCommits(repo)
        let amendedCommit = commits.first { $0.sha == amendedSha }
        #expect(amendedCommit?.parents == [rootSha])
        #expect(amendedCommit?.summary == "second message amended")
    }

    @Test func amendWithNothingStagedIsMessageOnlyAndKeepsParentAndTree() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        let rootSha = try await repo.headSha()
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.git(["add", "a.txt"])
        try await repo.git(["commit", "-q", "-m", "first message"])
        let treeBefore = try await repo.revParse("HEAD^{tree}")
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        let amendedSha = try await backend.commit(
            message: "message only amend", amend: true, allTracked: false, at: repo.root
        )

        assertWorktreeUnchanged(repo, since: before)
        let treeAfter = try await repo.revParse("HEAD^{tree}")
        #expect(treeAfter == treeBefore)
        let commits = try await snapshotCommits(repo)
        let amendedCommit = commits.first { $0.sha == amendedSha }
        #expect(amendedCommit?.parents == [rootSha])
        #expect((try await backend.headMessage(at: repo.root)) == "message only amend")
    }

    @Test func firstCommitInAnEmptyRepoSucceeds() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        let sha = try await backend.commit(message: "initial commit", amend: false, allTracked: false, at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        #expect(sha == (try await repo.headSha()))
        let commits = try await snapshotCommits(repo)
        #expect(commits.first { $0.sha == sha }?.parents.isEmpty == true)
    }

    @Test func failingPreCommitHookThrowsAndLeavesHeadAndIndexUnchanged() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        let headBefore = try await repo.headSha()
        try repo.writeExecutable(
            ".git/hooks/pre-commit", "#!/bin/sh\necho \"blocked by hook\" >&2\nexit 1\n"
        )
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        await #expect {
            _ = try await backend.commit(message: "should be blocked", amend: false, allTracked: false, at: repo.root)
        } throws: { error in
            guard case let GitError.commandFailed(_, stderr) = error else { return false }
            return stderr.contains("blocked by hook")
        }

        assertWorktreeUnchanged(repo, since: before)
        #expect((try await repo.headSha()) == headBefore)
        #expect(try await repo.isInIndex("a.txt"))
        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        #expect(status.files.first { $0.path == "a.txt" }?.staged == .modified)
    }

    @Test func headMessageReturnsSubjectAndBody() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let message = "A subject\n\nA body paragraph explaining the change."
        let before = worktreeSnapshot(repo)

        _ = try await backend.commit(message: message, amend: false, allTracked: false, at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        #expect((try await backend.headMessage(at: repo.root)) == message)
    }

    @Test func headMessageOnRepoWithNoCommitsReturnsEmptyString() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        #expect((try await backend.headMessage(at: repo.root)) == "")

        assertWorktreeUnchanged(repo, since: before)
    }

    @Test func emptyMessageThrowsBeforeRunningGitAndLeavesStagedChangeStaged() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        let headBefore = try await repo.headSha()
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        await #expect(throws: GitError.emptyCommitMessage) {
            _ = try await backend.commit(message: "", amend: false, allTracked: false, at: repo.root)
        }
        await #expect(throws: GitError.emptyCommitMessage) {
            _ = try await backend.commit(message: "   \n\t  ", amend: false, allTracked: false, at: repo.root)
        }

        assertWorktreeUnchanged(repo, since: before)
        #expect((try await repo.headSha()) == headBefore)
        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        #expect(status.files.first { $0.path == "a.txt" }?.staged == .modified)
    }

    /// Documents the default cleanup applied when no `--cleanup` flag is passed. Because the
    /// message always arrives via `-F` (never interactively edited), git's default is
    /// `whitespace`, not `strip`: leading/trailing blank lines and trailing whitespace are
    /// trimmed, but `#`-prefixed lines are kept as ordinary content, unlike `--cleanup=strip`.
    @Test func commentLikeLineInBodySurvivesUnderDefaultCleanup() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let message = "Subject\n\nBody line one\n# looks like a comment\nBody line two"
        let before = worktreeSnapshot(repo)

        _ = try await backend.commit(message: message, amend: false, allTracked: false, at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        #expect((try await backend.headMessage(at: repo.root)) == message)
    }

    @Test func unicodeInMessageSurvives() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let message = "héllo 世界 🚀\n\nbody with ünïcödé"
        let before = worktreeSnapshot(repo)

        _ = try await backend.commit(message: message, amend: false, allTracked: false, at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        #expect((try await backend.headMessage(at: repo.root)) == message)
    }

    @Test func amendInARepoWithNoCommitsThrowsAndLeavesIndexUnchanged() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let before = worktreeSnapshot(repo)

        await #expect {
            _ = try await backend.commit(message: "amend with nothing to amend", amend: true, allTracked: false, at: repo.root)
        } throws: { error in
            guard case let GitError.commandFailed(_, stderr) = error else { return false }
            return stderr.contains("nothing to amend")
        }

        assertWorktreeUnchanged(repo, since: before)
        #expect(try await repo.isInIndex("a.txt"))
        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        #expect(status.files.first { $0.path == "a.txt" }?.staged == .added)
    }

    @Test func messageStartingWithADashCommitsAndReadsBackVerbatim() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.git(["add", "a.txt"])
        let backend = CLIGitBackend()
        let message = "-not-a-flag\n\nbody"
        let before = worktreeSnapshot(repo)

        _ = try await backend.commit(message: message, amend: false, allTracked: false, at: repo.root)

        assertWorktreeUnchanged(repo, since: before)
        #expect((try await backend.headMessage(at: repo.root)) == message)
    }
}
