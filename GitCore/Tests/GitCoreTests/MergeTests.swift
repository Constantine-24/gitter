import Foundation
import Testing

@testable import GitCore

/// The outcome half of `merge(_:mode:at:)`: every mode against every shape a branch can be
/// in, asserted against the repository *state* git left behind rather than against anything
/// git printed. Refusals live in `MergeRefusalTests.swift`.
@Suite struct MergeTests {
    /// The four shapes a branch can be in relative to HEAD, as repositories a test can build.
    enum Shape: String, Sendable, CaseIterable {
        case alreadyMerged, fastForwardable, divergedClean, divergedConflicting

        func makeRepo() async throws -> TestRepo {
            switch self {
            case .alreadyMerged: return try await TestRepo.makeAlreadyMerged()
            case .fastForwardable: return try await TestRepo.makeBranched()
            case .divergedClean: return try await TestRepo.makeDiverged()
            case .divergedConflicting: return try await TestRepo.makeConflicting()
            }
        }
    }

    // MARK: - The matrix

    /// Every mode × every shape. The three interesting disagreements are all here:
    /// `.alwaysMergeCommit` turns a fast-forwardable branch into a merge commit,
    /// `.fastForwardIfPossible` falls back to a merge commit once the branches diverge, and
    /// `.squash` reports `.squashed` for both — it never moves HEAD at all.
    @Test(arguments: [
        (MergeMode.fastForwardIfPossible, Shape.alreadyMerged, MergeOutcome.alreadyUpToDate),
        (.fastForwardIfPossible, .fastForwardable, .fastForwarded),
        (.fastForwardIfPossible, .divergedClean, .merged),
        (.fastForwardIfPossible, .divergedConflicting, .conflicts),
        (.alwaysMergeCommit, .alreadyMerged, .alreadyUpToDate),
        (.alwaysMergeCommit, .fastForwardable, .merged),
        (.alwaysMergeCommit, .divergedClean, .merged),
        (.alwaysMergeCommit, .divergedConflicting, .conflicts),
        (.squash, .alreadyMerged, .alreadyUpToDate),
        (.squash, .fastForwardable, .squashed),
        (.squash, .divergedClean, .squashed),
        (.squash, .divergedConflicting, .conflicts),
    ])
    func everyModeAgainstEveryShape(mode: MergeMode, shape: Shape, expected: MergeOutcome) async throws {
        let repo = try await shape.makeRepo()
        defer { repo.cleanUp() }
        let backend = CLIGitBackend()

        let outcome = try await backend.merge("feature", mode: mode, at: repo.root)
        #expect(outcome == expected, "\(mode) on \(shape)")
    }

    // MARK: - What each outcome means in the repository

    @Test func fastForwardLandsHeadExactlyOnTheBranchTip() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let tip = try await repo.revParse("feature")

        let outcome = try await CLIGitBackend().merge(
            "feature", mode: .fastForwardIfPossible, at: repo.root)

        #expect(outcome == .fastForwarded)
        #expect(try await repo.headSha() == tip)
        #expect(try await repo.parents(of: "HEAD").count == 1)
        #expect(try await repo.currentBranch() == "main")  // still on main, not on feature
        #expect(try repo.fileContents("a.txt") == "feature\n")
    }

    /// The whole point of `.alwaysMergeCommit`: a branch git *could* fast-forward still gets a
    /// commit with two parents, the first of which is where HEAD was.
    @Test func alwaysMergeCommitMakesTwoParentsEvenWhenAFastForwardWasPossible() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let before = try await repo.headSha()
        let tip = try await repo.revParse("feature")

        let outcome = try await CLIGitBackend().merge(
            "feature", mode: .alwaysMergeCommit, at: repo.root)

        #expect(outcome == .merged)
        #expect(try await repo.headSha() != tip)
        #expect(try await repo.parents(of: "HEAD") == [before, tip])
    }

    @Test func fastForwardIfPossibleFallsBackToAMergeCommitOnceTheBranchesDiverge() async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }
        let before = try await repo.headSha()
        let tip = try await repo.revParse("feature")

        let outcome = try await CLIGitBackend().merge(
            "feature", mode: .fastForwardIfPossible, at: repo.root)

        #expect(outcome == .merged)
        #expect(try await repo.parents(of: "HEAD") == [before, tip])
    }

    /// `.squashed` means: HEAD did not move, the branch's changes are sitting in the index, and
    /// the snapshot reports the sixth in-progress state so the UI can offer "Commit Squash".
    @Test(arguments: [Shape.fastForwardable, .divergedClean])
    func squashStagesTheChangesWithoutMovingHead(shape: Shape) async throws {
        let repo = try await shape.makeRepo()
        defer { repo.cleanUp() }
        let before = try await repo.headSha()
        let backend = CLIGitBackend()

        let outcome = try await backend.merge("feature", mode: .squash, at: repo.root)

        #expect(outcome == .squashed)
        #expect(try await repo.headSha() == before, "a squash must never move HEAD")
        #expect(try await repo.gitFileExists("SQUASH_MSG"))
        #expect(try await repo.gitFileExists("MERGE_HEAD") == false)
        let snapshot = try await backend.snapshot(at: repo.root)
        #expect(snapshot.status.operationInProgress == .squash)
        let staged = snapshot.status.files.filter { $0.staged != nil }.map(\.path)
        #expect(staged == ["a.txt"], "the branch's change should be staged, not just on disk")
        #expect(try await repo.indexContent(of: "a.txt") == Data("feature\n".utf8))
    }

    /// An already-merged branch is a no-op in every mode: nothing staged, no `SQUASH_MSG`, no
    /// merge commit. Verified on git 2.54: `--squash` prints "Already up to date. (nothing to
    /// squash)" and writes no `SQUASH_MSG` at all.
    @Test(arguments: MergeMode.allCases)
    func anAlreadyMergedBranchChangesNothingInAnyMode(mode: MergeMode) async throws {
        let repo = try await TestRepo.makeAlreadyMerged()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let backend = CLIGitBackend()

        let outcome = try await backend.merge("feature", mode: mode, at: repo.root)

        #expect(outcome == .alreadyUpToDate)
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.gitFileExists("SQUASH_MSG") == false)
        #expect(try await backend.snapshot(at: repo.root).status.operationInProgress == nil)
    }

    /// Merging a branch into itself is the same no-op, and must not be special-cased into an
    /// error: git says "Already up to date."
    @Test func mergingTheCurrentBranchIntoItselfIsAlreadyUpToDate() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let outcome = try await CLIGitBackend().merge(
            "main", mode: .fastForwardIfPossible, at: repo.root)

        #expect(outcome == .alreadyUpToDate)
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    // MARK: - Conflicts are an outcome, not an error

    /// A conflicting merge must come back as a value and leave the repository *exactly* as git
    /// left it: unmerged entries in the index, `MERGE_HEAD` set, the conflict markers on disk.
    /// Gitter never tidies that up — the existing in-progress UI takes over.
    @Test(arguments: [MergeMode.fastForwardIfPossible, .alwaysMergeCommit])
    func aConflictingMergeLeavesGitsOwnMergeStateAlone(mode: MergeMode) async throws {
        let repo = try await TestRepo.makeConflicting()
        defer { repo.cleanUp() }
        let before = try await repo.headSha()
        let backend = CLIGitBackend()

        let outcome = try await backend.merge("feature", mode: mode, at: repo.root)

        #expect(outcome == .conflicts)
        #expect(try await repo.headSha() == before, "a conflict must not commit anything")
        #expect(try await repo.unmergedEntries().isEmpty == false)
        #expect(try await repo.gitFileExists("MERGE_HEAD"))
        #expect(try await backend.snapshot(at: repo.root).status.operationInProgress == .merge)
        #expect(try repo.fileContents("a.txt").contains("<<<<<<<"))
    }

    /// A conflicting `--squash` is the *other* in-progress shape: unmerged entries and a
    /// `SQUASH_MSG`, but no `MERGE_HEAD`, so the snapshot reports `.squash`.
    @Test func aConflictingSquashReportsSquashNotMerge() async throws {
        let repo = try await TestRepo.makeConflicting()
        defer { repo.cleanUp() }
        let before = try await repo.headSha()
        let backend = CLIGitBackend()

        let outcome = try await backend.merge("feature", mode: .squash, at: repo.root)

        #expect(outcome == .conflicts)
        #expect(try await repo.headSha() == before)
        #expect(try await repo.unmergedEntries().isEmpty == false)
        #expect(try await repo.gitFileExists("MERGE_HEAD") == false)
        #expect(try await repo.gitFileExists("SQUASH_MSG"))
        #expect(try await backend.snapshot(at: repo.root).status.operationInProgress == .squash)
    }

    // MARK: - Uncommitted work that is not in the way

    /// The safety promise from the other side: a merge that *succeeds* must not touch a file
    /// the user was editing but the merge does not need. Byte-for-byte, not "looks the same".
    @Test func anUnrelatedDirtyFileSurvivesASuccessfulMerge() async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }
        try repo.write("keep.txt", "work in progress\r\nno trailing newline")
        let mine = try Data(contentsOf: repo.root.appendingPathComponent("keep.txt"))

        let outcome = try await CLIGitBackend().merge(
            "feature", mode: .alwaysMergeCommit, at: repo.root)

        #expect(outcome == .merged)
        #expect(try Data(contentsOf: repo.root.appendingPathComponent("keep.txt")) == mine)
    }

    // MARK: - Detached HEAD

    /// git allows merging into a detached HEAD, and so does Gitter: HEAD moves to the new
    /// commit and stays detached.
    @Test func mergingIntoADetachedHeadWorksAndLeavesItDetached() async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }
        let before = try await repo.headSha()
        let tip = try await repo.revParse("feature")
        try await repo.git(["switch", "--detach", "-q", "HEAD"])

        let outcome = try await CLIGitBackend().merge(
            "feature", mode: .alwaysMergeCommit, at: repo.root)

        #expect(outcome == .merged)
        #expect(try await repo.currentBranch() == nil, "HEAD should still be detached")
        #expect(try await repo.parents(of: "HEAD") == [before, tip])
        #expect(try await repo.localBranches() == ["feature", "main"])
        #expect(try await repo.revParse("main") == before, "main must not have moved")
    }

    @Test func aFastForwardIntoADetachedHeadStillReportsFastForwarded() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "--detach", "-q", "HEAD"])
        let tip = try await repo.revParse("feature")

        let outcome = try await CLIGitBackend().merge(
            "feature", mode: .fastForwardIfPossible, at: repo.root)

        #expect(outcome == .fastForwarded)
        #expect(try await repo.headSha() == tip)
        #expect(try await repo.currentBranch() == nil)
    }
}
