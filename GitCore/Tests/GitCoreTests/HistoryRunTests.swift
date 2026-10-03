import Foundation
import Testing

@testable import GitCore

/// `run(_:at:)`: a cherry-pick or revert plan run, and the repository read back afterwards —
/// every outcome judged against what git left, before and after.
@Suite struct HistoryRunTests {
    let backend = CLIGitBackend()

    /// `main`: base (f = "base"). `side` (from base): S1 (s1), S2 (f = "side"), S3 (s3). HEAD
    /// on `main` with M (m).
    static func makeSide() async throws -> (repo: TestRepo, s1: String, s2: String, s3: String) {
        let repo = try await TestRepo.makeEmpty()
        try await repo.commit("f", "base", "base")
        try await repo.git(["switch", "-q", "-c", "side"])
        let s1 = try await repo.commit("s1", "s1", "S1")
        let s2 = try await repo.commit("f", "side", "S2")
        let s3 = try await repo.commit("s3", "s3", "S3")
        try await repo.git(["switch", "-q", "main"])
        try await repo.commit("m", "m", "M")
        return (repo, s1, s2, s3)
    }

    // MARK: - Applied

    @Test func oneCommitIsPicked() async throws {
        let (repo, s1, _, _) = try await Self.makeSide()
        defer { repo.cleanUp() }
        let before = try await HistorySnapshot.capture(repo)
        let plan = try await backend.historyPlan(.cherryPick, shas: [s1], at: repo.root)

        let outcome = try await backend.run(plan, at: repo.root)

        #expect(outcome == .applied(count: 1, dropped: []))
        #expect(try await repo.revParse("HEAD~1") == before.state.head.trimmingCharacters(in: .newlines))
        #expect(try await repo.subjects("HEAD~1..HEAD") == ["S1"])
        #expect(try repo.fileContents("s1") == "s1\n")
        #expect(worktreeSnapshot(repo).count == before.worktree.count + 1)
        #expect(try await backend.operationProgress(at: repo.root) == nil)
    }

    @Test func threeCommitsArePickedOldestFirst() async throws {
        let (repo, s1, s2, s3) = try await Self.makeSide()
        defer { repo.cleanUp() }
        let plan = try await backend.historyPlan(.cherryPick, shas: [s3, s1, s2], at: repo.root)

        let outcome = try await backend.run(plan, at: repo.root)

        #expect(outcome == .applied(count: 3, dropped: []))
        #expect(try await repo.subjects("HEAD~3..HEAD") == ["S1", "S2", "S3"])
        #expect(try repo.fileContents("f") == "side\n")
        #expect(try await backend.haltedSequence(at: repo.root) == nil)
    }

    @Test func aPatchIdenticalCommitIsDroppedAndNamed() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        try await repo.git(["switch", "-q", "-c", "side"])
        let dup = try await repo.commit("p", "p", "P on side")
        let q = try await repo.commit("q", "q", "Q")
        try await repo.git(["switch", "-q", "main"])
        let head = try await repo.commit("p", "p", "P on main")
        let plan = try await backend.historyPlan(.cherryPick, shas: [dup, q], at: repo.root)
        #expect(plan.mayDrop.map(\.sha) == [dup])

        let outcome = try await backend.run(plan, at: repo.root)

        #expect(outcome == .applied(count: 1, dropped: [CommitRef(sha: dup, subject: "P on side")]))
        #expect(try await repo.subjects("\(head)..HEAD") == ["Q"])
    }

    // MARK: - Stopped (RF5)

    /// A conflict at the second commit: the first stays applied, the second is A2's stop.
    @Test func aConflictAtTheSecondCommitIsAStopA2Sees() async throws {
        let (repo, s1, s2, s3) = try await Self.makeSide()
        defer { repo.cleanUp() }
        try await repo.commit("f", "main's own", "M2")
        let plan = try await backend.historyPlan(.cherryPick, shas: [s1, s2, s3], at: repo.root)

        let outcome = try await backend.run(plan, at: repo.root)

        #expect(outcome == .stopped)
        let progress = try await backend.operationProgress(at: repo.root)
        #expect(progress?.operation == .cherryPick)
        #expect(progress?.current?.sha == s2)
        #expect(progress?.remaining == 2)
        #expect(try await repo.subjects("HEAD~1..HEAD") == ["S1"])
        #expect(try await repo.unmergedEntries().contains("\tf\n"))
    }

    /// An untracked file a later commit adds: git applies the first, refuses the second and
    /// leaves `sequencer/` with no pseudo-ref — A2's halted range, and the file is untouched.
    @Test func anUntrackedFileALaterCommitAddsHaltsTheRange() async throws {
        let (repo, s1, _, s3) = try await Self.makeSide()
        defer { repo.cleanUp() }
        try repo.write("s3", "mine\n")
        let plan = try await backend.historyPlan(.cherryPick, shas: [s1, s3], at: repo.root)

        let outcome = try await backend.run(plan, at: repo.root)

        #expect(outcome == .stopped)
        #expect(try await backend.operationProgress(at: repo.root) == nil)
        let halted = try await backend.haltedSequence(at: repo.root)
        #expect(halted?.notApplied.map(\.sha) == [s3])
        #expect(try await repo.subjects("HEAD~1..HEAD") == ["S1"])
        #expect(try repo.fileContents("s3") == "mine\n")
    }

    /// A single pick git refuses — an untracked file where the commit adds one — changes
    /// nothing and leaves no state (B6): git's refusal, thrown, never a stop.
    @Test func aSinglePickGitRefusesIsItsRefusalAndChangesNothing() async throws {
        let (repo, s1, _, _) = try await Self.makeSide()
        defer { repo.cleanUp() }
        try repo.write("s1", "mine\n")
        let plan = try await backend.historyPlan(.cherryPick, shas: [s1], at: repo.root)
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: BranchOperationError.wouldOverwrite(tracked: [], untracked: ["s1"])) {
            try await backend.run(plan, at: repo.root)
        }
        try await before.assertUnchanged(repo)
        #expect(try await backend.operationProgress(at: repo.root) == nil)
        #expect(try await backend.haltedSequence(at: repo.root) == nil)
    }

    // MARK: - Revert

    @Test func aSeriesIsRevertedNewestFirst() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        let f1 = try await repo.commit("f", "one", "F1")
        let f2 = try await repo.commit("f", "two", "F2")
        let f3 = try await repo.commit("f", "three", "F3")
        let plan = try await backend.historyPlan(.revert, shas: [f1, f3, f2], at: repo.root)
        #expect(plan.commits.map(\.sha) == [f3, f2, f1])

        let outcome = try await backend.run(plan, at: repo.root)

        #expect(outcome == .applied(count: 3, dropped: []))
        #expect(try await repo.subjects("HEAD~3..HEAD") == ["Revert \"F3\"", "Revert \"F2\"", "Revert \"F1\""])
        #expect(try repo.fileContents("f") == "base\n")
    }

    /// `revert.reference=true` would commit git's placeholder comment as the subject (B9).
    @Test func revertReferenceDoesNotReachTheMessage() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        let f1 = try await repo.commit("f", "one", "F1")
        try await repo.git(["config", "revert.reference", "true"])
        let plan = try await backend.historyPlan(.revert, shas: [f1], at: repo.root)

        #expect(try await backend.run(plan, at: repo.root) == .applied(count: 1, dropped: []))

        #expect(try await repo.subject(of: "HEAD") == "Revert \"F1\"")
        let body = String(decoding: try await repo.git(["log", "-1", "--format=%B"]), as: UTF8.self)
        #expect(body.contains("This reverts commit \(f1)."))
    }

    /// A change HEAD already undoes: "nothing to commit", nothing changed. git leaves a
    /// `MERGE_MSG` behind, which a terminal `git commit` would take as its message (measured,
    /// Task 1); it is this run's own, so Gitter removes it.
    @Test func aChangeAlreadyUndoneIsAlreadyReverted() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        let f1 = try await repo.ref(try await repo.commit("f", "one", "F1"))
        try await repo.git(["revert", "--no-edit", f1.sha])
        let before = try await HistorySnapshot.capture(repo)
        let plan = try await backend.historyPlan(.revert, shas: [f1.sha], at: repo.root)

        let outcome = try await backend.run(plan, at: repo.root)

        #expect(outcome == .alreadyReverted(f1))
        try await before.assertUnchanged(repo)
        #expect(try await repo.gitFileExists("MERGE_MSG") == false)
        #expect(try await backend.operationProgress(at: repo.root) == nil)
    }

    /// A `MERGE_MSG` that was there before the run is not Gitter's to remove.
    @Test func aMergeMsgThatWasThereBeforeIsKept() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        let f1 = try await repo.commit("f", "one", "F1")
        try await repo.git(["revert", "--no-edit", f1])
        try repo.write(".git/MERGE_MSG", "the user's own words\n")
        let plan = try await backend.historyPlan(.revert, shas: [f1], at: repo.root)

        #expect(try await backend.run(plan, at: repo.root) == .alreadyReverted(try await repo.ref(f1)))

        #expect(try await repo.gitFileExists("MERGE_MSG"))
    }

    // MARK: - Signing and hooks (RF3, RF5)

    /// A pick whose commit cannot be signed stops with `CHERRY_PICK_HEAD` (B7): A2's stop, and
    /// Abort puts everything back.
    @Test func aPickThatCannotBeSignedIsAStopAbortUndoes() async throws {
        let (repo, s1, _, s3) = try await Self.makeSide()
        defer { repo.cleanUp() }
        try await repo.failSigning()
        let before = try await HistorySnapshot.capture(repo)
        let plan = try await backend.historyPlan(.cherryPick, shas: [s1, s3], at: repo.root)

        #expect(try await backend.run(plan, at: repo.root) == .stopped)

        #expect(try await backend.operationProgress(at: repo.root)?.operation == .cherryPick)
        #expect(try String(contentsOf: repo.root.appendingPathComponent(".git/fake-gpg.log"), encoding: .utf8).contains("-bsau"))
        try await backend.abort(.cherryPick, at: repo.root)
        try await before.assertUnchanged(repo)
    }

    /// A single revert that cannot be signed leaves the revert staged with no `REVERT_HEAD` and
    /// no `sequencer/` — a state no operation check can see (B10) — and says so.
    @Test func aSingleRevertThatCannotBeSignedIsLeftStagedAndSaid() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        let g = try await repo.commit("g", "g", "G")
        try await repo.failSigning()
        let head = try await repo.headSha()
        let plan = try await backend.historyPlan(.revert, shas: [g], at: repo.root)

        let outcome = try await backend.run(plan, at: repo.root)

        guard case .unsignedRevertLeftStaged(let words) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(words.contains("gpg failed to sign"))
        #expect(try await repo.headSha() == head)
        #expect(try await repo.gitFileExists("REVERT_HEAD") == false)
        #expect(try await backend.operationProgress(at: repo.root) == nil)
        let status = String(decoding: try await repo.git(["status", "--porcelain"]), as: UTF8.self)
        #expect(status == "D  g\n")
    }

    /// A `prepare-commit-msg` hook that says no leaves a single revert in the same state
    /// (measured, Task 1), in the hook's words.
    @Test func aSingleRevertAHookRefusesIsLeftStagedInTheHooksWords() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        let g = try await repo.commit("g", "g", "G")
        try repo.writeExecutable(".git/hooks/prepare-commit-msg", "#!/bin/sh\necho HOOK-SAYS-NO\nexit 1\n")
        let plan = try await backend.historyPlan(.revert, shas: [g], at: repo.root)

        let outcome = try await backend.run(plan, at: repo.root)

        guard case .unsignedRevertLeftStaged(let words) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(words.contains("HOOK-SAYS-NO"))
        #expect(words.contains("'prepare-commit-msg' hook failed"))
    }

    // MARK: - What the sheet showed is what runs (RF1)

    @Test func headMovedSinceThePlanRunsNothing() async throws {
        let (repo, s1, _, _) = try await Self.makeSide()
        defer { repo.cleanUp() }
        let plan = try await backend.historyPlan(.cherryPick, shas: [s1], at: repo.root)
        try await repo.commit("n", "n", "N")
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: HistoryRefusal.headMoved) {
            try await backend.run(plan, at: repo.root)
        }
        try await before.assertUnchanged(repo)
    }

    /// HEAD at the same commit but naming another branch, or detached: the sheet named `main`,
    /// and the run would land elsewhere (fix round 1). Nothing runs.
    @Test(arguments: ["another branch", "detached"])
    func headOnAnotherBranchAtTheSameCommitRunsNothing(move: String) async throws {
        let (repo, s1, _, _) = try await Self.makeSide()
        defer { repo.cleanUp() }
        let plan = try await backend.historyPlan(.cherryPick, shas: [s1], at: repo.root)
        #expect(plan.headRef == "refs/heads/main")
        try await repo.git(move == "detached" ? ["switch", "-q", "--detach"] : ["switch", "-q", "-c", "feature"])
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: HistoryRefusal.headMoved) {
            try await backend.run(plan, at: repo.root)
        }
        try await before.assertUnchanged(repo)
    }

    /// A range git refuses at its FIRST commit — an untracked file the first commit adds (or a
    /// revert recreates) — leaves `sequencer/` with nothing applied (measured). Gitter clears it
    /// with the range's own `--abort` (which rewinds to HEAD itself and keeps the untracked file,
    /// measured) and throws git's refusal, as for a single pick (fix round 1, Ruling 6b).
    @Test(arguments: [HistoryAction.cherryPick, .revert])
    func aRangeGitRefusesAtItsFirstCommitIsItsRefusalAndLeavesNoState(action: HistoryAction) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        let shas: [String]
        let blocked: String
        if action == .cherryPick {
            try await repo.git(["switch", "-q", "-c", "side"])
            let u = try await repo.commit("u", "u", "adds u")
            let q = try await repo.commit("q", "q", "Q")
            try await repo.git(["switch", "-q", "main"])
            try await repo.commit("m", "m", "M")
            (shas, blocked) = ([u, q], "u")
        } else {
            let e = try await repo.commit("e", "e", "adds e")
            try await repo.git(["rm", "-q", "e"])
            try await repo.git(["commit", "-q", "-m", "deletes e"])
            let x = try await repo.headSha()
            try await repo.commit("y", "y", "Y")
            (shas, blocked) = ([x, e], "e")
        }
        try repo.write(blocked, "mine\n")
        let plan = try await backend.historyPlan(action, shas: shas, at: repo.root)
        #expect(plan.commits.count == 2)
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: BranchOperationError.wouldOverwrite(tracked: [], untracked: [blocked])) {
            try await backend.run(plan, at: repo.root)
        }
        try await before.assertUnchanged(repo)
        #expect(try repo.fileContents(blocked) == "mine\n")
        #expect(try await backend.operationProgress(at: repo.root) == nil)
        #expect(try await backend.haltedSequence(at: repo.root) == nil)
        #expect(try await repo.gitFileExists("sequencer") == false)
    }

    @Test func aPlanThatIsNotTheOneMadeNowRunsNothing() async throws {
        let (repo, s1, _, s3) = try await Self.makeSide()
        defer { repo.cleanUp() }
        let plan = try await backend.historyPlan(.cherryPick, shas: [s1, s3], at: repo.root)
        let reordered = HistoryPlan(
            action: plan.action, head: plan.head, commits: plan.commits.reversed(), leftOut: plan.leftOut,
            mayDrop: plan.mayDrop, headRef: plan.headRef)
        let predictsADrop = HistoryPlan(
            action: plan.action, head: plan.head, commits: plan.commits, leftOut: plan.leftOut,
            mayDrop: [plan.commits[0]], headRef: plan.headRef)
        let before = try await HistorySnapshot.capture(repo)

        for changed in [reordered, predictsADrop] {
            await #expect(throws: HistoryRefusal.planChanged) {
                try await backend.run(changed, at: repo.root)
            }
        }
        try await before.assertUnchanged(repo)
    }

    @Test func aTrackedChangeMadeSinceThePlanRunsNothing() async throws {
        let (repo, s1, _, _) = try await Self.makeSide()
        defer { repo.cleanUp() }
        let plan = try await backend.historyPlan(.cherryPick, shas: [s1], at: repo.root)
        try repo.write("m", "edited\n")
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: HistoryRefusal.trackedChanges(["m"])) {
            try await backend.run(plan, at: repo.root)
        }
        try await before.assertUnchanged(repo)
    }
}

/// The new helper's negative control: `HistorySnapshot.assertUnchanged` really fails — here
/// over one new ref, the smallest change it must see (one known issue).
@Suite struct HistorySnapshotTests {
    @Test func noticesAChange() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        let before = try await HistorySnapshot.capture(repo)
        #expect(!before.worktree.isEmpty && !before.state.head.isEmpty)
        try await repo.git(["branch", "extra"])

        await withKnownIssue {
            try await before.assertUnchanged(repo)
        }
    }
}
