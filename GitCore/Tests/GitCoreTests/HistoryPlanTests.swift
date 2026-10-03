import Foundation
import Testing

@testable import GitCore

/// `historyPlan(_:shas:at:)`: what a cherry-pick or revert of a selection will do, and every
/// refusal, read before git runs. Each refusal leaves the repository exactly as it was.
@Suite struct HistoryPlanTests {
    let backend = CLIGitBackend()

    /// `main`: base, M. `feat` (from base): A, X — committed with a date *older* than A's — and
    /// C. `other` (from base): D, committed last. HEAD on `main`.
    struct Lab {
        let repo: TestRepo
        let a: String, x: String, c: String, d: String, m: String, base: String
    }

    static func makeLab() async throws -> Lab {
        let repo = try await TestRepo.makeEmpty()
        let base = try await repo.commit("f", "base", "base", date: "2024-01-01T00:00:00Z")
        try await repo.git(["switch", "-q", "-c", "feat"])
        let a = try await repo.commit("a", "a", "A", date: "2024-01-02T00:00:00Z")
        let x = try await repo.commit("x", "x", "X skewed", date: "2023-06-01T00:00:00Z")
        let c = try await repo.commit("c", "c", "C", date: "2024-01-04T00:00:00Z")
        try await repo.git(["switch", "-q", "-c", "other", base])
        let d = try await repo.commit("d", "d", "D", date: "2024-01-05T00:00:00Z")
        try await repo.git(["switch", "-q", "main"])
        let m = try await repo.commit("m", "m", "M", date: "2024-01-06T00:00:00Z")
        return Lab(repo: repo, a: a, x: x, c: c, d: d, m: m, base: base)
    }

    // MARK: - Order (RF4)

    /// A skewed committer date inside one branch, a second branch, any order of selection: the
    /// pick order is topological — A before X before C, though X's date is the oldest (B2).
    @Test func aPickIsOrderedByTopologyNotByDateAcrossTwoBranches() async throws {
        let lab = try await Self.makeLab()
        defer { lab.repo.cleanUp() }
        let before = try await HistorySnapshot.capture(lab.repo)

        let plan = try await backend.historyPlan(.cherryPick, shas: [lab.c, lab.d, lab.x, lab.a], at: lab.repo.root)

        let order = plan.commits.map(\.sha)
        #expect(Set(order) == [lab.a, lab.x, lab.c, lab.d])
        let index = { (sha: String) in order.firstIndex(of: sha) ?? -1 }
        #expect(index(lab.a) < index(lab.x) && index(lab.x) < index(lab.c), "\(plan.commits.map(\.subject))")
        #expect(plan.action == .cherryPick)
        #expect(plan.head == lab.m)
        #expect(plan.commits.first { $0.sha == lab.x }?.subject == "X skewed")
        #expect(plan.leftOut.isEmpty && plan.mayDrop.isEmpty)
        // A plan reads only.
        try await before.assertUnchanged(lab.repo)
    }

    /// The plan is a function of the selected *set*: git's topological order breaks ties by
    /// the order it was given (measured, Task 1), so the plan must not pass the selection on
    /// as the user happened to click it — the run re-makes the plan from another order.
    @Test func thePlanDoesNotDependOnTheOrderOfTheSelection() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let same = "2024-01-01T00:00:00Z"
        let base = try await repo.commit("f", "base", "base", date: same)
        try await repo.git(["switch", "-q", "-c", "x"])
        let x1 = try await repo.commit("x1", "x1", "X1", date: same)
        let x2 = try await repo.commit("x2", "x2", "X2", date: same)
        try await repo.git(["switch", "-q", "-c", "y", base])
        let y1 = try await repo.commit("y1", "y1", "Y1", date: same)
        let y2 = try await repo.commit("y2", "y2", "Y2", date: same)
        try await repo.git(["switch", "-q", "main"])

        let one = try await backend.historyPlan(.cherryPick, shas: [x2, y2, x1, y1], at: repo.root)
        let two = try await backend.historyPlan(.cherryPick, shas: [y1, x1, y2, x2], at: repo.root)
        // A revert takes commits HEAD contains: both branches, merged.
        try await repo.git(["switch", "-q", "-c", "both", "y"])
        try await repo.git(["merge", "-q", "--no-ff", "--no-edit", "x"])
        let three = try await backend.historyPlan(.revert, shas: [x2, y1], at: repo.root)
        let four = try await backend.historyPlan(.revert, shas: [y1, x2], at: repo.root)

        #expect(one == two)
        #expect(three == four)
        #expect(one.commits.count == 4)
    }

    /// A revert runs newest first by the same topology (B8): C, then X, then A — though X is
    /// dated before A.
    @Test func aRevertIsOrderedNewestFirstByTopology() async throws {
        let lab = try await Self.makeLab()
        defer { lab.repo.cleanUp() }
        try await lab.repo.git(["switch", "-q", "feat"])

        let plan = try await backend.historyPlan(.revert, shas: [lab.a, lab.c, lab.x], at: lab.repo.root)

        #expect(plan.commits.map(\.sha) == [lab.c, lab.x, lab.a])
        #expect(plan.commits.map(\.subject) == ["C", "X skewed", "A"])
        #expect(plan.action == .revert)
        #expect(plan.leftOut.isEmpty && plan.mayDrop.isEmpty)
    }

    // MARK: - Already applied (RF4)

    /// Selected commits HEAD already contains — an ancestor and HEAD itself — are left out and
    /// named; the rest is picked.
    @Test func ancestorsOfHeadAreLeftOutAndNamed() async throws {
        let lab = try await Self.makeLab()
        defer { lab.repo.cleanUp() }

        let plan = try await backend.historyPlan(.cherryPick, shas: [lab.m, lab.d, lab.base], at: lab.repo.root)

        #expect(plan.commits.map(\.sha) == [lab.d])
        #expect(plan.leftOut.map(\.sha) == [lab.m, lab.base])
        #expect(plan.leftOut.map(\.subject) == ["M", "base"])
        #expect(plan.mayDrop.isEmpty)
    }

    /// A commit whose patch HEAD already has (as another commit) is still given to git, which
    /// drops it, and the plan names it in advance.
    @Test func aPatchIdenticalCommitIsPredictedAsDropped() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        try await repo.git(["switch", "-q", "-c", "side"])
        let dup = try await repo.commit("p", "p", "P on side")
        let q = try await repo.commit("q", "q", "Q")
        try await repo.git(["switch", "-q", "main"])
        try await repo.commit("p", "p", "P on main")

        let plan = try await backend.historyPlan(.cherryPick, shas: [q, dup], at: repo.root)

        #expect(plan.commits.map(\.sha) == [dup, q])
        #expect(plan.mayDrop == [CommitRef(sha: dup, subject: "P on side")])
        #expect(plan.leftOut.isEmpty)
    }

    // MARK: - Refusals

    @Test func aMergeCommitIsRefusedAndNamed() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        try await repo.git(["switch", "-q", "-c", "side"])
        let s = try await repo.commit("s", "s", "S")
        try await repo.git(["switch", "-q", "-c", "topic", "main"])
        try await repo.commit("t", "t", "T")
        try await repo.git(["merge", "-q", "--no-ff", "--no-edit", "side"])
        let merge = try await repo.ref("HEAD")
        try await repo.git(["switch", "-q", "main"])
        let before = try await HistorySnapshot.capture(repo)

        for action in [HistoryAction.cherryPick, .revert] {
            await #expect(throws: HistoryRefusal.mergeCommits([merge])) {
                try await backend.historyPlan(action, shas: [s, merge.sha], at: repo.root)
            }
        }
        try await before.assertUnchanged(repo)
    }

    @Test func anOperationInProgressRefuses() async throws {
        let repo = try await TestRepo.makeConflicting()
        defer { repo.cleanUp() }
        let feature = try await repo.revParse("feature")
        try await repo.git(["merge", "feature"], allowedExitCodes: [1])
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: HistoryRefusal.operationInProgress(.merge)) {
            try await backend.historyPlan(.cherryPick, shas: [feature], at: repo.root)
        }
        try await before.assertUnchanged(repo)
    }

    /// A range git left halted keeps `sequencer/` with no pseudo-ref, so no operation is
    /// detected — yet git refuses a new range over it, and a single pick over it leaves a stale
    /// sequence (Ruling 29; measured, Task 1). Refused as the operation its todo names.
    @Test func aHaltedRangeRefusesAsItsOperation() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        try await repo.git(["switch", "-q", "-c", "side"])
        let u = try await repo.commit("u", "u", "adds u")
        let q = try await repo.commit("q", "q", "Q")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("u", "mine\n")
        try await repo.git(["cherry-pick", u, q], allowedExitCodes: [128])
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("u"))
        #expect(try await backend.haltedSequence(at: repo.root) != nil, "the fixture is a halted range")

        for action in [HistoryAction.cherryPick, .revert] {
            await #expect(throws: HistoryRefusal.operationInProgress(.cherryPick)) {
                try await backend.historyPlan(action, shas: [q], at: repo.root)
            }
        }
    }

    @Test(arguments: ["staged", "unstaged"])
    func aTrackedChangeRefusesAndIsNamed(kind: String) async throws {
        let lab = try await Self.makeLab()
        defer { lab.repo.cleanUp() }
        try lab.repo.write("m", "changed\n")
        if kind == "staged" { try await lab.repo.git(["add", "m"]) }
        let before = try await HistorySnapshot.capture(lab.repo)

        // A pick of `other`'s D, a revert of `main`'s own M.
        for (action, sha) in [(HistoryAction.cherryPick, lab.d), (.revert, lab.m)] {
            await #expect(throws: HistoryRefusal.trackedChanges(["m"])) {
                try await backend.historyPlan(action, shas: [sha], at: lab.repo.root)
            }
        }
        try await before.assertUnchanged(lab.repo)
    }

    @Test func anUntrackedFileIsAllowed() async throws {
        let lab = try await Self.makeLab()
        defer { lab.repo.cleanUp() }
        try lab.repo.write("loose.txt", "mine\n")

        let plan = try await backend.historyPlan(.cherryPick, shas: [lab.d], at: lab.repo.root)

        #expect(plan.commits.map(\.sha) == [lab.d])
    }

    /// A revert of a commit HEAD does not contain would apply the inverse of a change this
    /// branch never had (fix round 1, Ruling 6a): refused, naming it, before anything runs.
    @Test func aRevertOfACommitNotOnTheBranchIsRefused() async throws {
        let lab = try await Self.makeLab()
        defer { lab.repo.cleanUp() }
        let before = try await HistorySnapshot.capture(lab.repo)

        await #expect(throws: HistoryRefusal.notOnBranch([CommitRef(sha: lab.d, subject: "D")])) {
            try await backend.historyPlan(.revert, shas: [lab.m, lab.d], at: lab.repo.root)
        }
        try await before.assertUnchanged(lab.repo)
        // A commit HEAD does contain is still revertable.
        #expect(try await backend.historyPlan(.revert, shas: [lab.m], at: lab.repo.root).commits.map(\.sha) == [lab.m])
    }

    @Test func everySelectedCommitAlreadyInHeadIsNothingToApply() async throws {
        let lab = try await Self.makeLab()
        defer { lab.repo.cleanUp() }

        await #expect(throws: HistoryRefusal.nothingToApply) {
            try await backend.historyPlan(.cherryPick, shas: [lab.m, lab.base], at: lab.repo.root)
        }
        for action in [HistoryAction.cherryPick, .revert] {
            await #expect(throws: HistoryRefusal.nothingToApply) {
                try await backend.historyPlan(action, shas: [], at: lab.repo.root)
            }
        }
    }

    @Test func anUnbornBranchRefuses() async throws {
        let lab = try await Self.makeLab()
        defer { lab.repo.cleanUp() }
        try await lab.repo.git(["switch", "-q", "--orphan", "fresh"])

        for action in [HistoryAction.cherryPick, .revert] {
            await #expect(throws: HistoryRefusal.unbornHead) {
                try await backend.historyPlan(action, shas: [lab.d], at: lab.repo.root)
            }
        }
    }

    /// Full object ids only: a short one could name a tag or branch spelled like it (B17), and
    /// anything starting with `-` must never reach git.
    @Test(arguments: ["", "-x", "HEAD", "main", "abc1234"])
    func aShaThatIsNotAFullObjectIdIsRefused(sha: String) async throws {
        let lab = try await Self.makeLab()
        defer { lab.repo.cleanUp() }

        await #expect(throws: BranchOperationError.invalidName(sha)) {
            try await backend.historyPlan(.cherryPick, shas: [lab.d, sha], at: lab.repo.root)
        }
    }
}
