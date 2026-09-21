import Foundation
import Testing

@testable import GitCore

/// `git commit --amend` part-way through an operation, which git only half-refuses.
///
/// Measured on git 2.54.0 (Apple Git-157), in throwaway repositories, with every conflict
/// already resolved and staged so that nothing but the operation itself could stop the amend:
///
/// | in progress | `git commit --amend` |
/// |---|---|
/// | merge (`MERGE_HEAD`) | refused, exit 128, "You are in the middle of a merge -- cannot amend." |
/// | cherry-pick (`CHERRY_PICK_HEAD`) | refused, exit 128, "…in the middle of a cherry-pick…" |
/// | revert (`REVERT_HEAD`) | **accepted** — tip rewritten, `REVERT_HEAD` deleted, the revert vanishes |
/// | rebase (`rebase-merge/`) | **accepted** — tip rewritten, the rebase still in progress on a commit that is now gone |
/// | `git am` (`rebase-apply/applying`) | **accepted** — tip rewritten, `rebase-apply/` left behind |
/// | pending squash (`SQUASH_MSG`) | **accepted** — tip rewritten, `SQUASH_MSG` deleted, the squash folded into the previous commit |
///
/// Four of the six, then, rewrite the commit the operation was standing on and leave it
/// reachable from no ref at all — which is precisely the thing this milestone promises never to
/// do without a confirmation that names it. `CLIGitBackend.commit(message:amend:…)` therefore
/// re-reads what is in progress and refuses all six itself, before git runs, so that the
/// refusal is Gitter's own typed one everywhere rather than git's in two places and nothing in
/// the other four.
@Suite struct AmendDuringOperationTests {

    /// Every operation, with the state built so that git itself would accept the amend wherever
    /// it is willing to (conflicts resolved and staged, nothing unmerged left in the index).
    enum Cell: String, CaseIterable, Sendable {
        case merge, cherryPick, revert, rebase, applyingPatches, squash

        var operation: RepositoryOperation {
            switch self {
            case .merge: return .merge
            case .cherryPick: return .cherryPick
            case .revert: return .revert
            case .rebase: return .rebase
            case .applyingPatches: return .applyingPatches
            case .squash: return .squash
            }
        }

        /// The marker file or pseudo-ref whose disappearance is what "the operation vanished"
        /// looks like from outside. A rebase keeps a directory, which `gitFileExists` cannot
        /// stat through `--git-path`'s file form, so it is covered by `operationInProgress`
        /// alone.
        var stateFile: String? {
            switch self {
            case .merge: return "MERGE_HEAD"
            case .cherryPick: return "CHERRY_PICK_HEAD"
            case .revert: return "REVERT_HEAD"
            case .squash: return "SQUASH_MSG"
            case .rebase, .applyingPatches: return nil
            }
        }
    }

    // MARK: - The refusal

    @Test(arguments: Cell.allCases)
    func amendingIsRefusedAndChangesNothing(cell: Cell) async throws {
        let repo = try await makeAmendLab(cell)
        defer { repo.cleanUp() }
        let backend = CLIGitBackend()

        // Non-vacuous: the state really is the one this cell is about, and the index really is
        // free of unmerged entries, so nothing but the new guard can be what refuses below.
        #expect(try await backend.snapshot(at: repo.root).status.operationInProgress == cell.operation)
        #expect(try await repo.unmergedEntries().isEmpty)

        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: GitError.amendDuringOperation(cell.operation)) {
            _ = try await backend.commit(
                message: "amended", amend: true, allTracked: false, at: repo.root)
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(
            try await backend.snapshot(at: repo.root).status.operationInProgress == cell.operation,
            "the operation stopped being in progress")
        if let stateFile = cell.stateFile {
            #expect(try await repo.gitFileExists(stateFile), "\(stateFile) went away")
        }
    }

    /// The control. Without an operation in progress the guard must stay out of the way — a
    /// refusal that fired everywhere would pass every case above while breaking amending.
    @Test func amendingWithNothingInProgressStillWorks() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try repo.write("a.txt", "two\n")
        try await repo.git(["add", "a.txt"])
        let before = try await repo.headSha()

        let sha = try await CLIGitBackend().commit(
            message: "amended", amend: true, allTracked: false, at: repo.root)

        #expect(sha != before)
        #expect(try await repo.subject(of: "HEAD") == "amended")
        #expect(try await repo.revParse("HEAD") == sha)
        // One commit, not two: this really amended rather than adding on top.
        let count = try await repo.git(["rev-list", "--count", "HEAD"])
        #expect(String(decoding: count, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "1")
    }

    /// The same guard must not fire for an ordinary commit: concluding a merge by committing is
    /// the whole way out of one, and `commit()` without `--amend` is what does it.
    @Test func anOrdinaryCommitMidOperationIsStillAllowed() async throws {
        let repo = try await makeAmendLab(.merge)
        defer { repo.cleanUp() }

        let sha = try await CLIGitBackend().commit(
            message: "merged", amend: false, allTracked: false, at: repo.root)

        #expect(try await repo.parents(of: sha).count == 2)
        #expect(try await CLIGitBackend().snapshot(at: repo.root).status.operationInProgress == nil)
    }
}

// MARK: - The six states

/// A repository part-way through `cell`, with every conflict resolved and staged.
///
/// That last part is what makes these tests mean something: with an unmerged entry still in the
/// index git refuses *every* amend ("Committing is not possible because you have unmerged
/// files."), so a suite built on `makeAbortLab`'s half-resolved states would pass whether or not
/// Gitter's own guard existed.
private func makeAmendLab(_ cell: AmendDuringOperationTests.Cell) async throws -> TestRepo {
    let repo = try await TestRepo.makeEmpty()
    try repo.write("a.txt", "base\n")
    try repo.write("keep.txt", "keep\n")
    try await repo.commitAll("base")

    switch cell {
    case .squash:
        // A clean squash: nothing conflicts, the combined change is staged and `SQUASH_MSG`
        // is written. This is the state the original reproduction reached.
        try await repo.git(["switch", "-q", "-c", "side"])
        try repo.write("b.txt", "side\n")
        try await repo.commitAll("side")
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["merge", "--ff", "--squash", "side"])

    case .merge, .cherryPick, .rebase:
        try await repo.git(["switch", "-q", "-c", "side"])
        try repo.write("a.txt", "side\n")
        try await repo.commitAll("side")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("a.txt", "main\n")
        try await repo.commitAll("main")
        switch cell {
        case .merge: try await repo.git(["merge", "side"], allowedExitCodes: [1])
        case .cherryPick: try await repo.git(["cherry-pick", "side"], allowedExitCodes: [1])
        default:
            try await repo.git(["switch", "-q", "side"])
            try await repo.git(["rebase", "main"], allowedExitCodes: [1])
        }
        try await resolve(repo, "a.txt")

    case .revert:
        try repo.write("a.txt", "v2\n")
        try await repo.commitAll("second")
        try repo.write("a.txt", "v3\n")
        try await repo.commitAll("third")
        try await repo.git(["revert", "--no-edit", "HEAD~1"], allowedExitCodes: [1])
        try await resolve(repo, "a.txt")

    case .applyingPatches:
        try await repo.git(["switch", "-q", "-c", "side"])
        try repo.write("a.txt", "side\n")
        try await repo.commitAll("side")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("a.txt", "main\n")
        try await repo.commitAll("main")
        let patches = try await repo.git(["format-patch", "-1", "--stdout", "side"])
        try patches.write(to: repo.root.appendingPathComponent(".git/patches.mbox"))
        try await repo.git(["am", "-3", ".git/patches.mbox"], allowedExitCodes: [128])
        try await resolve(repo, "a.txt")
    }
    return repo
}

/// Writes a resolution over `path` and stages it, leaving no unmerged entry behind.
private func resolve(_ repo: TestRepo, _ path: String) async throws {
    try repo.write(path, "resolved\n")
    try await repo.git(["add", path])
}
