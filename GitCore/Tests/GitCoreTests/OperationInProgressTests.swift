import Foundation
import Testing

@testable import GitCore

/// Whether the repository is part-way through a merge, cherry-pick, revert or rebase.
///
/// The index cannot answer this. Once the last conflict is resolved and staged there are no
/// unmerged entries left, yet the operation is still open — and `git reset` would end it
/// silently. The snapshot therefore asks git, per worktree.
@Suite struct OperationInProgressTests {

    /// Two branches that both rewrite the same line, so any of the four operations conflicts.
    private static func makeDivergent() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("f.txt", "one\n")
        try await repo.commitAll("base")
        try await repo.git(["checkout", "-q", "-b", "side"])
        try repo.write("f.txt", "side\n")
        try await repo.commitAll("side")
        try await repo.git(["checkout", "-q", "main"])
        try repo.write("f.txt", "main\n")
        try await repo.commitAll("main")
        return repo
    }

    private static func operation(in repo: TestRepo) async throws -> RepositoryOperation? {
        try await operation(at: repo.root)
    }


    private static func operation(at root: URL) async throws -> RepositoryOperation? {
        try await CLIGitBackend().snapshot(at: root).status.operationInProgress
    }

    /// `with(operationInProgress:)` is how the backend completes the parser's output; dropping
    /// a field here would silently blank the branch, the counts or the file list.
    @Test func withOperationKeepsEveryOtherField() {
        let file = FileStatus(path: "a.txt", originalPath: nil, staged: .modified, unstaged: nil)
        let status = WorkingCopyStatus(
            headSha: "abc123", branch: "main", upstream: "origin/main", ahead: 2, behind: 1,
            files: [file]
        )

        let merged = status.with(operationInProgress: .merge)

        #expect(merged.operationInProgress == .merge)
        #expect(merged.files == [file])
        #expect(merged.branch == "main")
        #expect(merged.upstream == "origin/main")
        // `==` is synthesized over every stored property, so this pins the rest of them too.
        #expect(merged.with(operationInProgress: nil) == status)
        #expect(status.operationInProgress == nil)
    }

    @Test func plainRepositoryHasNoOperationInProgress() async throws {
        let repo = try await Self.makeDivergent()
        defer { repo.cleanUp() }

        #expect(try await Self.operation(in: repo) == nil)
    }

    @Test func emptyRepositoryHasNoOperationInProgress() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }

        #expect(try await Self.operation(in: repo) == nil)
    }

    @Test func conflictedMergeIsInProgress() async throws {
        let repo = try await Self.makeDivergent()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "side"], allowedExitCodes: [1])
        let before = worktreeSnapshot(repo)

        let status = try await CLIGitBackend().snapshot(at: repo.root).status

        #expect(status.operationInProgress == .merge)
        #expect(status.files.contains { $0.staged == .unmerged })
        // Reading the state must not rewrite the half-merged files.
        assertWorktreeUnchanged(repo, since: before)
    }

    /// The bug this whole field exists for: no unmerged entry is left, but the merge is not
    /// over, and `git reset` here would delete `MERGE_HEAD` and turn the next commit into an
    /// ordinary single-parent one.
    @Test func mergeStaysInProgressOnceTheLastConflictIsStaged() async throws {
        let repo = try await Self.makeDivergent()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "side"], allowedExitCodes: [1])
        try repo.write("f.txt", "resolved\n")
        try await repo.git(["add", "f.txt"])

        let status = try await CLIGitBackend().snapshot(at: repo.root).status

        #expect(status.files.allSatisfy { $0.staged != .unmerged && $0.unstaged != .unmerged })
        #expect(status.operationInProgress == .merge)
    }

    @Test func mergeIsOverOnceItIsCommitted() async throws {
        let repo = try await Self.makeDivergent()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "side"], allowedExitCodes: [1])
        try repo.write("f.txt", "resolved\n")
        try await repo.git(["add", "f.txt"])
        try await repo.git(["commit", "-q", "-m", "merge side"])

        #expect(try await Self.operation(in: repo) == nil)
    }

    @Test func conflictedCherryPickIsInProgress() async throws {
        let repo = try await Self.makeDivergent()
        defer { repo.cleanUp() }
        try await repo.git(["cherry-pick", "side"], allowedExitCodes: [1])

        #expect(try await Self.operation(in: repo) == .cherryPick)
    }

    @Test func cherryPickStaysInProgressOnceTheLastConflictIsStaged() async throws {
        let repo = try await Self.makeDivergent()
        defer { repo.cleanUp() }
        try await repo.git(["cherry-pick", "side"], allowedExitCodes: [1])
        try repo.write("f.txt", "resolved\n")
        try await repo.git(["add", "f.txt"])

        #expect(try await Self.operation(in: repo) == .cherryPick)
    }

    @Test func conflictedRevertIsInProgress() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f.txt", "one\n")
        try await repo.commitAll("base")
        try repo.write("f.txt", "two\n")
        try await repo.commitAll("second")
        try repo.write("f.txt", "three\n")
        try await repo.commitAll("third")
        try await repo.git(["revert", "--no-edit", "HEAD~1"], allowedExitCodes: [1])

        #expect(try await Self.operation(in: repo) == .revert)
    }

    @Test func conflictedRebaseIsInProgress() async throws {
        let repo = try await Self.makeDivergent()
        defer { repo.cleanUp() }
        try await repo.git(["checkout", "-q", "side"])
        try await repo.git(["rebase", "main"], allowedExitCodes: [1])

        #expect(try await Self.operation(in: repo) == .rebase)
    }

    /// The older `am` rebase backend uses `rebase-apply/` instead of `rebase-merge/`. It is
    /// still a rebase, and `git rebase --abort` is still the way out of it.
    @Test func rebaseWithTheApplyBackendIsStillARebase() async throws {
        let repo = try await Self.makeDivergent()
        defer { repo.cleanUp() }
        try await repo.git(["checkout", "-q", "side"])
        try await repo.git(["rebase", "--apply", "main"], allowedExitCodes: [1])

        #expect(try await Self.operation(in: repo) == .rebase)
    }

    /// `git am` borrows `rebase-apply/` from the rebase backend, so the directory alone cannot
    /// tell the two apart — and calling it a rebase would send the user to
    /// `git rebase --abort`, which git refuses with "It looks like 'git am' is in progress".
    /// The marker git's own `wt-status` uses is the `applying` file inside that directory.
    @Test func aStuckGitAmIsReportedAsApplyingPatches() async throws {
        let repo = try await Self.makeDivergent()
        defer { repo.cleanUp() }
        let patch = try await repo.git(["format-patch", "-1", "--stdout", "side"])
        let patchFile = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-am-\(UUID().uuidString).patch")
        defer { try? FileManager.default.removeItem(at: patchFile) }
        try patch.write(to: patchFile)
        // The patch does not apply onto `main`, which is the whole point; git exits 128.
        try await repo.git(["am", patchFile.path], allowedExitCodes: [128])

        #expect(try await Self.operation(in: repo) == .applyingPatches)
    }

    /// `rebase -r` re-creates a merge commit by merging, so a conflict there sets `MERGE_HEAD`
    /// *and* leaves `rebase-merge/` in place. The rebase is the operation the user is in, and
    /// the one whose advice applies, so it has to win.
    @Test func rebaseReplayingAConflictingMergeIsStillARebase() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f.txt", "base\n")
        try await repo.commitAll("base")
        try await repo.git(["checkout", "-q", "-b", "topic"])
        try repo.write("f.txt", "topic\n")
        try await repo.commitAll("topic edits f")
        try await repo.git(["checkout", "-q", "main"])
        try repo.write("f.txt", "mainline\n")
        try await repo.commitAll("main edits f")
        // A merge whose conflict was resolved by hand, so replaying it conflicts again.
        try await repo.git(["merge", "--no-commit", "topic"], allowedExitCodes: [1])
        try repo.write("f.txt", "merged\n")
        try await repo.git(["add", "f.txt"])
        try await repo.git(["commit", "-q", "-m", "merge topic"])
        // A new base that touches nothing either side changed, so only the merge conflicts.
        try await repo.git(["checkout", "-q", "-b", "newbase", "main~2"])
        try repo.write("z.txt", "z\n")
        try await repo.commitAll("newbase adds z")
        try await repo.git(["checkout", "-q", "main"])
        try await repo.git(["rebase", "-r", "newbase"], allowedExitCodes: [1])

        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        #expect(try await repo.revParse("MERGE_HEAD").isEmpty == false)  // both markers exist
        #expect(status.operationInProgress == .rebase)
    }

    /// A linked worktree keeps its own `MERGE_HEAD` under `.git/worktrees/<name>/`, and its
    /// own `.git` is a *file*, so looking for `<root>/.git/MERGE_HEAD` would find nothing
    /// here and would find the main checkout's merge in the other direction.
    @Test func mergeInALinkedWorktreeIsSeenOnlyThere() async throws {
        let repo = try await Self.makeDivergent()
        defer { repo.cleanUp() }
        let linked = repo.root.deletingLastPathComponent()
            .appendingPathComponent("gitter-wt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: linked) }
        try await repo.git(["worktree", "add", "-q", linked.path, "side"])
        try await repo.git(["-C", linked.path, "merge", "main"], allowedExitCodes: [1])

        #expect(try await Self.operation(at: linked) == .merge)
        #expect(try await Self.operation(in: repo) == nil)
    }
}
