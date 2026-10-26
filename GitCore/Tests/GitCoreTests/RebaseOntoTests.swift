import Foundation
import Testing

@testable import GitCore

/// `rebasePlan(onto:at:)` and `rebase(_:at:)`: the current branch rebased onto a chosen commit
/// or branch — the replay list the sheet shows, and the run that keeps to it.
@Suite struct RebaseOntoTests {
    let backend = CLIGitBackend()

    /// B12's history. `topic` (from base): T1, M1-dup (patch-identical to `main`'s M1), T2, a
    /// merge of `sub` (S1), T3. `main`: M1, M2. HEAD on `topic`.
    static func makeTopic() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try await repo.commit("f", "base", "base")
        try await repo.git(["switch", "-q", "-c", "topic"])
        try await repo.commit("t1", "t1", "T1")
        try await repo.commit("m1", "m1", "M1-dup")
        try await repo.git(["switch", "-q", "-c", "sub"])
        try await repo.commit("s1", "s1", "S1")
        try await repo.git(["switch", "-q", "topic"])
        try await repo.commit("t2", "t2", "T2")
        try await repo.git(["merge", "-q", "--no-ff", "--no-edit", "sub"])
        try await repo.commit("t3", "t3", "T3")
        try await repo.git(["switch", "-q", "main"])
        try await repo.commit("m1", "m1", "M1")
        try await repo.commit("m2", "m2", "M2")
        try await repo.git(["switch", "-q", "topic"])
        return repo
    }

    // MARK: - The replay list is what git replays

    @Test(arguments: [false, true])
    func theReplayListIsWhatGitReplays(rebaseMergesConfigured: Bool) async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        if rebaseMergesConfigured { try await repo.git(["config", "rebase.rebaseMerges", "true"]) }
        let main = try await repo.revParse("main")
        let before = try await HistorySnapshot.capture(repo)

        let plan = try await backend.rebasePlan(onto: "main", at: repo.root)

        #expect(plan.target == main)
        #expect(plan.head == (try await repo.headSha()))
        #expect(plan.replayed.map(\.subject) == ["T1", "T2", "S1", "T3"])
        #expect(plan.flattenedMerges == 1)
        #expect(plan.skippedAsApplied == 1)
        #expect(plan.alreadyPushed == 0)
        try await before.assertUnchanged(repo)

        let outcome = try await backend.rebase(plan, at: repo.root)

        #expect(outcome == .rebased)
        #expect(try await repo.subjects("main..HEAD") == plan.replayed.map(\.subject))
        #expect(try await repo.git(["rev-list", "--merges", "main..HEAD"]).isEmpty, "flattened (RF3)")
        #expect(try await repo.currentBranch() == "topic")
    }

    /// The pull flow's vector carries `--no-rebase-merges` too: under `rebase.rebaseMerges`
    /// it would otherwise recreate the merge (B13).
    @Test func thePullFlowsRebaseIsFlattenedUnderRebaseMerges() async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        try await repo.git(["config", "rebase.rebaseMerges", "true"])

        #expect(try await backend.rebase(onto: "main", at: repo.root) == .rebased)

        #expect(try await repo.git(["rev-list", "--merges", "main..HEAD"]).isEmpty)
        #expect(try await repo.subjects("main..HEAD") == ["T1", "T2", "S1", "T3"])
    }

    /// A tag named like the branch takes over the short name in git (B17); the plan resolves
    /// the branch, and the run is given its full object id.
    @Test func aBranchNameATagShadowsResolvesToTheBranch() async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        let main = try await repo.revParse("refs/heads/main")
        let base = try await repo.revParse("main~2")
        try await repo.git(["tag", "main", base])

        let plan = try await backend.rebasePlan(onto: "main", at: repo.root)

        #expect(plan.target == main)
        #expect(try await backend.rebase(plan, at: repo.root) == .rebased)
        #expect(try await repo.revParse("HEAD~4") == main)
    }

    @Test func commitsAlreadyOnARemoteAreCounted() async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        let bare = repo.root.deletingLastPathComponent().appendingPathComponent("\(repo.root.lastPathComponent)-bare.git")
        defer { try? FileManager.default.removeItem(at: bare) }
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try await bareGit(bare, ["init", "-q", "--bare", "-b", "main", "."])
        try await repo.git(["remote", "add", "origin", bare.path])
        try await repo.git(["push", "-q", "origin", "topic~1:refs/heads/topic"])
        try await repo.git(["fetch", "-q", "origin"])

        let plan = try await backend.rebasePlan(onto: "main", at: repo.root)

        // `main..topic` holds T1, M1-dup, S1, T2, the merge and T3; all but T3 are on origin.
        #expect(plan.alreadyPushed == 5)
    }

    // MARK: - Outcomes

    /// An ancestor of HEAD with a straight line between: git says "up to date" and replays
    /// nothing, so the plan lists nothing (B11).
    @Test func anAncestorWithAStraightLineIsUpToDate() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let base = try await repo.commit("f", "base", "base")
        try await repo.commit("a", "a", "A")
        try await repo.commit("b", "b", "B")
        let before = try await HistorySnapshot.capture(repo)

        let plan = try await backend.rebasePlan(onto: base, at: repo.root)

        #expect(plan.replayed.isEmpty)
        #expect(plan.flattenedMerges == 0 && plan.skippedAsApplied == 0 && plan.alreadyPushed == 0)
        #expect(try await backend.rebase(plan, at: repo.root) == .upToDate)
        try await before.assertUnchanged(repo)
    }

    /// An ancestor with a merge between is not "up to date": git flattens it (measured, Task 1).
    @Test func anAncestorWithAMergeBetweenIsFlattened() async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        let base = try await repo.revParse("topic~5")
        #expect(try await repo.subject(of: base) == "base")

        let plan = try await backend.rebasePlan(onto: base, at: repo.root)

        #expect(plan.replayed.map(\.subject) == ["T1", "M1-dup", "T2", "S1", "T3"])
        #expect(plan.flattenedMerges == 1)
        #expect(try await backend.rebase(plan, at: repo.root) == .rebased)
        #expect(try await repo.subjects("\(base)..HEAD") == plan.replayed.map(\.subject))
    }

    @Test func aDescendantIsAFastForward() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.commit("f", "base", "base")
        try await repo.git(["switch", "-q", "-c", "ahead"])
        let tip = try await repo.commit("a", "a", "A")
        try await repo.git(["switch", "-q", "main"])

        let plan = try await backend.rebasePlan(onto: "ahead", at: repo.root)

        #expect(plan.replayed.isEmpty)
        #expect(try await backend.rebase(plan, at: repo.root) == .fastForwarded)
        #expect(try await repo.headSha() == tip)
        #expect(try await repo.currentBranch() == "main")
    }

    @Test func aConflictStopsTheRebase() async throws {
        let repo = try await TestRepo.makeConflicting()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "feature"])

        let plan = try await backend.rebasePlan(onto: "main", at: repo.root)

        #expect(plan.replayed.map(\.subject) == ["feature change"])
        #expect(try await backend.rebase(plan, at: repo.root) == .conflicts)
        #expect(try await backend.operationProgress(at: repo.root)?.operation == .rebase)
    }

    // MARK: - What the sheet showed is what runs (RF1)

    @Test func aTargetThatMovedSinceThePlanRunsNothing() async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        let plan = try await backend.rebasePlan(onto: "main", at: repo.root)
        try await repo.git(["branch", "-f", "main", "main~1"])
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: HistoryRefusal.planChanged) {
            try await backend.rebase(plan, at: repo.root)
        }
        try await before.assertUnchanged(repo)
    }

    /// `makeTopic` with `origin` (a bare repository beside it) holding `topic~1`, fetched: five
    /// of `main..topic` already pushed. Returns the bare repository's URL, for the caller to remove.
    static func publishAllButTheTip(_ repo: TestRepo) async throws -> URL {
        let bare = repo.root.deletingLastPathComponent().appendingPathComponent("\(repo.root.lastPathComponent)-bare.git")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        try await bareGit(bare, ["init", "-q", "--bare", "-b", "main", "."])
        try await repo.git(["remote", "add", "origin", bare.path])
        try await repo.git(["push", "-q", "origin", "topic~1:refs/heads/topic"])
        try await repo.git(["fetch", "-q", "origin"])
        return bare
    }

    /// B4 2d: fewer commits already pushed than the sheet warned about (a remote-tracking branch
    /// gone since) — the warning the user saw was stronger than the truth, so the rebase runs.
    @Test func fewerCommitsPushedThanThePlanSaidStillRuns() async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        let bare = try await Self.publishAllButTheTip(repo)
        defer { try? FileManager.default.removeItem(at: bare) }
        let plan = try await backend.rebasePlan(onto: "main", at: repo.root)
        #expect(plan.alreadyPushed == 5)
        try await repo.git(["update-ref", "-d", "refs/remotes/origin/topic"])
        #expect(try await backend.rebasePlan(onto: "main", at: repo.root).alreadyPushed == 0)
        let main = try await repo.revParse("main")

        #expect(try await backend.rebase(plan, at: repo.root) == .rebased)
        #expect(try await repo.revParse("HEAD~4") == main)
        #expect(try await repo.currentBranch() == "topic")
    }

    /// B4 2d: more commits already pushed than the sheet warned about — its warning was too weak,
    /// so nothing runs.
    @Test func moreCommitsPushedThanThePlanSaidRunsNothing() async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        let plan = try await backend.rebasePlan(onto: "main", at: repo.root)
        #expect(plan.alreadyPushed == 0)
        let bare = try await Self.publishAllButTheTip(repo)
        defer { try? FileManager.default.removeItem(at: bare) }
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: HistoryRefusal.planChanged) {
            try await backend.rebase(plan, at: repo.root)
        }
        try await before.assertUnchanged(repo)
    }

    /// B4 2d: a pushed count that fell does not excuse a target that moved.
    @Test func fewerPushedWithAMovedTargetRunsNothing() async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        let bare = try await Self.publishAllButTheTip(repo)
        defer { try? FileManager.default.removeItem(at: bare) }
        let plan = try await backend.rebasePlan(onto: "main", at: repo.root)
        try await repo.git(["update-ref", "-d", "refs/remotes/origin/topic"])
        try await repo.git(["branch", "-f", "main", "main~1"])
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: HistoryRefusal.planChanged) {
            try await backend.rebase(plan, at: repo.root)
        }
        try await before.assertUnchanged(repo)
    }

    @Test func headMovedSinceThePlanRunsNothing() async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        let plan = try await backend.rebasePlan(onto: "main", at: repo.root)
        try await repo.commit("t4", "t4", "T4")
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: HistoryRefusal.headMoved) {
            try await backend.rebase(plan, at: repo.root)
        }
        try await before.assertUnchanged(repo)
    }

    /// HEAD at the same commit but on another branch, or detached: the rebase would rewrite a
    /// branch the sheet never named (fix round 1). Nothing runs.
    @Test(arguments: ["another branch", "detached"])
    func headOnAnotherBranchAtTheSameCommitRunsNothing(move: String) async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        let plan = try await backend.rebasePlan(onto: "main", at: repo.root)
        #expect(plan.headRef == "refs/heads/topic")
        try await repo.git(move == "detached" ? ["switch", "-q", "--detach"] : ["switch", "-q", "-c", "published"])
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: HistoryRefusal.headMoved) {
            try await backend.rebase(plan, at: repo.root)
        }
        try await before.assertUnchanged(repo)
    }

    // MARK: - Refusals

    @Test(arguments: ["staged", "unstaged"])
    func aTrackedChangeRefuses(kind: String) async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        try repo.write("t3", "edited\n")
        if kind == "staged" { try await repo.git(["add", "t3"]) }
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: HistoryRefusal.trackedChanges(["t3"])) {
            try await backend.rebasePlan(onto: "main", at: repo.root)
        }
        try await before.assertUnchanged(repo)
    }

    @Test func anOperationInProgressRefuses() async throws {
        let repo = try await TestRepo.makeConflicting()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "feature"], allowedExitCodes: [1])

        await #expect(throws: HistoryRefusal.operationInProgress(.merge)) {
            try await backend.rebasePlan(onto: "feature", at: repo.root)
        }
    }

    @Test func anUnbornBranchRefuses() async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "--orphan", "fresh"])

        await #expect(throws: HistoryRefusal.unbornHead) {
            try await backend.rebasePlan(onto: "main", at: repo.root)
        }
    }

    @Test(arguments: ["", "-x", "main~1", "main^", "a..b", "HEAD@{1}"])
    func aTargetThatIsNotANameIsRefused(target: String) async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }

        await #expect(throws: BranchOperationError.invalidName(target)) {
            try await backend.rebasePlan(onto: target, at: repo.root)
        }
    }

    @Test func aTargetThatNamesNothingIsNoSuchBranch() async throws {
        let repo = try await Self.makeTopic()
        defer { repo.cleanUp() }

        await #expect(throws: BranchOperationError.noSuchBranch("nosuch")) {
            try await backend.rebasePlan(onto: "nosuch", at: repo.root)
        }
    }
}
