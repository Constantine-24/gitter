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

    /// `makeDivergent`, moved to `<parent>/main` before any worktree is added, so the main
    /// checkout's path can hold a character `temporaryDirectory` never does.
    private static func makeDivergent(movedTo parent: URL) async throws -> TestRepo {
        let made = try await makeDivergent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let main = parent.appendingPathComponent("main", isDirectory: true)
        try FileManager.default.moveItem(at: made.root, to: main)
        return TestRepo(root: main)
    }

    private static func operation(in repo: TestRepo) async throws -> RepositoryOperation? {
        try await operation(at: repo.root)
    }


    private static func operation(at root: URL) async throws -> RepositoryOperation? {
        try await CLIGitBackend().snapshot(at: root).status.operationInProgress
    }

    /// `main` plus a `feature` branch that only adds a new file, so squashing it never
    /// conflicts — unlike `makeDivergent`, which exists precisely to conflict.
    private static func makeSquashable() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("f.txt", "one\n")
        try await repo.commitAll("base")
        try await repo.git(["checkout", "-q", "-b", "feature"])
        try repo.write("g.txt", "two\n")
        try await repo.commitAll("feature change")
        try await repo.git(["checkout", "-q", "main"])
        return repo
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

    /// See `RepositoryOperation.blocksUnstaging`'s doc comment for the scratch-repo evidence:
    /// plain `git reset -q` (what "Unstage All" runs) deletes `.git/SQUASH_MSG`, so `.squash`
    /// is no safer to blanket-unstage than the other five, even though *some* of the
    /// individual commands the app also uses (`git restore --staged`, `git apply --cached -R`)
    /// leave it alone.
    @Test func blocksUnstagingIsTrueForEveryOperation() {
        for operation: RepositoryOperation in [.merge, .cherryPick, .revert, .rebase, .applyingPatches, .squash] {
            #expect(operation.blocksUnstaging, "\(operation)")
        }
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

    // MARK: - Pending squash

    /// `git merge --squash` stages the combined changes and writes `.git/SQUASH_MSG`, but —
    /// unlike the other four — sets no pseudo-ref of its own. This is what finds it instead.
    @Test func squashPendingIsInProgress() async throws {
        let repo = try await Self.makeSquashable()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "--squash", "feature"])

        #expect(try await Self.operation(in: repo) == .squash)
    }

    @Test func squashIsOverOnceItIsCommitted() async throws {
        let repo = try await Self.makeSquashable()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "--squash", "feature"])
        try await repo.git(["commit", "-q", "-m", "squashed"])

        #expect(try await Self.operation(in: repo) == nil)
    }

    /// `git reset --merge` is the documented way to undo a pending squash (see the design
    /// doc's evidence table): verified separately that it removes `SQUASH_MSG` along with
    /// un-staging the squashed changes.
    @Test func squashIsOverAfterResetMerge() async throws {
        let repo = try await Self.makeSquashable()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "--squash", "feature"])
        try await repo.git(["reset", "-q", "--merge"])

        #expect(try await Self.operation(in: repo) == nil)
    }

    /// A `--squash` that conflicts still writes `SQUASH_MSG` (verified: exit 1, no
    /// `MERGE_HEAD`, an unmerged entry in `status --porcelain=v2`) — still a squash, just one
    /// with conflicts to resolve before it can be committed.
    @Test func conflictedSquashIsInProgress() async throws {
        let repo = try await Self.makeDivergent()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "--squash", "side"], allowedExitCodes: [1])

        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        #expect(status.operationInProgress == .squash)
        #expect(status.files.contains { $0.staged == .unmerged })
    }

    /// A leftover `SQUASH_MSG` from an earlier, never-committed squash can in principle sit
    /// next to a real merge conflict. Verified that git itself refuses to *start* a second
    /// merge while a squash is still staged ("Your local changes... would be overwritten by
    /// merge"), so the only way to reach this state is by hand — which is legitimate here:
    /// the state, however it arises, must resolve to the real operation, not the leftover.
    @Test func squashLeftoverDoesNotMaskARealMerge() async throws {
        let repo = try await Self.makeDivergent()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "side"], allowedExitCodes: [1])
        try repo.write(".git/SQUASH_MSG", "Squashed commit of the following:\n")

        #expect(try await Self.operation(in: repo) == .merge)
    }

    /// Same isolation as `mergeInALinkedWorktreeIsSeenOnlyThere`: `SQUASH_MSG` lives under
    /// `.git/worktrees/<name>/`, not the shared top-level `.git/`.
    @Test func squashInALinkedWorktreeIsSeenOnlyThere() async throws {
        let repo = try await Self.makeSquashable()
        defer { repo.cleanUp() }
        let linked = repo.root.deletingLastPathComponent()
            .appendingPathComponent("gitter-wt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: linked) }
        try await repo.git(["worktree", "add", "-q", "-b", "linked", linked.path, "main"])
        try await repo.git(["-C", linked.path, "merge", "--squash", "feature"])

        #expect(try await Self.operation(at: linked) == .squash)
        #expect(try await Self.operation(in: repo) == nil)
    }

    // MARK: - A line-breaking character in the repository's path

    /// `--git-path` answers with an absolute path in a linked worktree, and that path holds
    /// whatever the main checkout's directory is called. Split with `isNewline`, a U+2028,
    /// U+0085, `\r` or vertical tab in it cut one answer into two, the count check failed, and
    /// a rebase went unreported — the operation gate open while one was in progress.
    @Test(arguments: ["\u{2028}", "\u{85}", "\r", "\u{0B}"])
    func aRebaseInALinkedWorktreeIsSeenWhateverTheMainCheckoutIsCalled(breaking: String) async throws {
        let made = try await Self.makeDivergent()
        let parent = made.root.deletingLastPathComponent()
        let moved = parent.appendingPathComponent(
            "gitter-test-a\(breaking)b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.moveItem(at: made.root, to: moved)
        let repo = TestRepo(root: moved)
        defer { repo.cleanUp() }
        let linked = parent.appendingPathComponent("gitter-wt-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: linked) }
        try await repo.git(["worktree", "add", "-q", linked.path, "side"])
        try await repo.git(["-C", linked.path, "rebase", "main"], allowedExitCodes: [1])
        // Not vacuous: git's answer really holds the character, and really is absolute.
        let gitPath = String(
            decoding: try await repo.git(["-C", linked.path, "rev-parse", "--git-path", "rebase-merge"]),
            as: UTF8.self)
        #expect(gitPath.hasPrefix("/") && gitPath.contains(breaking))

        #expect(try await Self.operation(at: linked) == .rebase)
        #expect(try await Self.operation(in: repo) == nil)
    }

    /// A raw newline (E3 B4.2), the one byte a line split cannot get around: with the main
    /// checkout at `par\nent/main`, the one `rev-parse --git-path ×4` a linked worktree asked
    /// printed eight lines, and its rebase was reported as none. git sanitises the worktree's
    /// own admin name (`wt\nree` → `wt-ree`), so only the main checkout's path reaches the
    /// answer. `""` is the plain-path control, the same fixture with no newline anywhere.
    @Test(arguments: ["\n", ""])
    func aRebaseInALinkedWorktreeIsSeenWhenTheMainCheckoutsParentHoldsANewline(newline: String) async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-nl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try await Self.makeDivergent(movedTo: base.appendingPathComponent("par\(newline)ent"))
        let linked = base.appendingPathComponent("wt\(newline)ree", isDirectory: true)
        try await repo.git(["worktree", "add", "-q", linked.path, "side"])
        try await repo.git(["-C", linked.path, "rebase", "main"], allowedExitCodes: [1])

        // Not vacuous: the old single call's answer really is broken by the newline (eight
        // lines for four paths), and git's answer for the worktree really is in a rebase.
        let fourPaths = try await repo.git(
            ["-C", linked.path, "rev-parse", "--git-path", "rebase-apply/applying", "--git-path", "rebase-merge",
             "--git-path", "rebase-apply", "--git-path", "SQUASH_MSG"])
        #expect(fourPaths.filter { $0 == 0x0A }.count == (newline.isEmpty ? 4 : 8))
        let rebaseMerge = String(
            decoding: try await repo.git(["-C", linked.path, "rev-parse", "--path-format=absolute", "--git-path", "rebase-merge"]),
            as: UTF8.self)
        #expect(FileManager.default.fileExists(atPath: String(rebaseMerge.dropLast())))

        #expect(try await Self.operation(at: linked) == .rebase)
        #expect(try await Self.operation(in: repo) == nil)
    }

    /// The main checkout's own answers hold the newline too once they are absolute (as
    /// `--absolute-git-dir`'s are): a rebase there is still seen, and only there.
    @Test func aRebaseInTheMainCheckoutIsSeenWhenItsParentHoldsANewline() async throws {
        let base = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-nl-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let repo = try await Self.makeDivergent(movedTo: base.appendingPathComponent("par\nent"))
        let linked = base.appendingPathComponent("linked", isDirectory: true)
        try await repo.git(["worktree", "add", "-q", "-b", "other", linked.path, "main"])
        try await repo.git(["rebase", "side"], allowedExitCodes: [1])
        let gitDir = String(decoding: try await repo.git(["rev-parse", "--absolute-git-dir"]), as: UTF8.self)
        #expect(gitDir.dropLast().contains("\n"), "the git dir must hold the newline: \(gitDir)")

        #expect(try await Self.operation(in: repo) == .rebase)
        #expect(try await Self.operation(at: linked) == nil)
    }
}
