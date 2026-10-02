import Foundation
import Testing

@testable import GitCore

/// A cherry-pick or revert range git stopped part-way without an operation (Task 6 fix round 1,
/// measured on git 2.54): a `--continue` that made its commit, or a `--skip`, and then refused the
/// next commit over an untracked file it adds (exit 128). `sequencer/` stays with no
/// `CHERRY_PICK_HEAD` / `REVERT_HEAD`, `sequencer/todo` lists exactly the commits not applied —
/// the refused one first — and `git status` still says "Cherry-pick currently in progress". A
/// later `--continue` would leave the first of them out; `--quit` keeps HEAD, the index and the
/// worktree, after which picking (reverting) the listed commits again applies them.
@Suite struct HaltedSequenceTests {
    static let backend = CLIGitBackend()

    /// base, then `feature`: c1 conflicts with main on f.txt, c2 adds n.txt, c3 adds o.txt.
    static func threeCommits() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("f.txt", "a\nb\nc\n")
        try await repo.commitAll("base")
        try await repo.git(["tag", "base"])
        try await repo.git(["switch", "-q", "-c", "feature"])
        try repo.write("f.txt", "a\nb F1\nc\n")
        try await repo.commitAll("c1 f")
        try repo.write("n.txt", "n C2\n")
        try await repo.commitAll("c2 adds n")
        try repo.write("o.txt", "o C3\n")
        try await repo.commitAll("c3 adds o")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", "a\nb M\nc\n")
        try await repo.commitAll("m")
        return repo
    }

    static func shas(_ repo: TestRepo, _ revs: [String]) async throws -> [String] {
        var shas: [String] = []
        for rev in revs { shas.append(try await repo.revParse(rev)) }
        return shas
    }

    @Test func noSequencerIsNoHalt() async throws {
        let repo = try await Self.threeCommits()
        defer { repo.cleanUp() }
        #expect(try await Self.backend.haltedSequence(at: repo.root) == nil)
    }

    /// A range stopped at a conflict is an operation in progress, not a halt.
    @Test func aStoppedRangeIsAnOperationNotAHalt() async throws {
        let repo = try await Self.threeCommits()
        defer { repo.cleanUp() }
        try await repo.git(["cherry-pick", "base..feature"], allowedExitCodes: [1])
        try await ConflictFixtures.requireUnmerged(repo)
        #expect(try await Self.backend.operationProgress(at: repo.root)?.operation == .cherryPick)
        #expect(try await Self.backend.haltedSequence(at: repo.root) == nil)
    }

    /// Continue made c1 and refused c2: c2 and c3 are not applied.
    @Test func aContinueThatHaltsListsTheCommitsItDidNotApply() async throws {
        let repo = try await Self.threeCommits()
        defer { repo.cleanUp() }
        try await repo.git(["cherry-pick", "base..feature"], allowedExitCodes: [1])
        try await SequenceFixtures.resolve(repo)
        try repo.write("n.txt", "n USER\n")

        let outcome = try await Self.backend.continueOperation(.cherryPick, message: nil, at: repo.root)
        guard case .sequenceHalted = outcome else {
            Issue.record("expected .sequenceHalted, got \(outcome)")
            return
        }
        #expect(try await SequenceFixtures.subjects(repo, "-1") == ["c1 f"])

        let halted = try #require(try await Self.backend.haltedSequence(at: repo.root))
        #expect(halted.operation == .cherryPick)
        #expect(halted.notApplied.map(\.sha) == (try await Self.shas(repo, ["feature~1", "feature"])))
        #expect(halted.notApplied.map(\.subject) == ["c2 adds n", "c3 adds o"])
        #expect(halted.total == 2)
    }

    /// Skip at c1 skipped it and refused c2 — no commit was made at all.
    @Test func aSkipThatHaltsMadeNoCommitAndListsTheRest() async throws {
        let repo = try await Self.threeCommits()
        defer { repo.cleanUp() }
        try await repo.git(["cherry-pick", "base..feature"], allowedExitCodes: [1])
        let head = try await repo.headSha()
        let c1 = try await repo.revParse("feature~2")
        try repo.write("n.txt", "n USER\n")

        let result = try await Self.backend.skip(.cherryPick, stoppedAt: c1, at: repo.root)
        guard case .sequenceHalted = result.outcome else {
            Issue.record("expected .sequenceHalted, got \(result.outcome)")
            return
        }
        #expect(result.recorded != nil)
        #expect(try await repo.headSha() == head)

        let halted = try #require(try await Self.backend.haltedSequence(at: repo.root))
        #expect(halted.operation == .cherryPick)
        #expect(halted.notApplied.map(\.subject) == ["c2 adds n", "c3 adds o"])
    }

    /// The same for a revert range: `revert` lines, `.revert`.
    @Test func aRevertRangeHaltsTheSameWay() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f.txt", "one\ntwo\nthree\n")
        try repo.write("g.txt", "g\n")
        try await repo.commitAll("base")
        try await repo.git(["rm", "-q", "g.txt"])
        try await repo.git(["commit", "-q", "-m", "A deletes g"])
        let a = try await repo.headSha()
        try repo.write("f.txt", "one\nTWO\nthree\n")
        try await repo.commitAll("B two")
        let b = try await repo.headSha()
        try repo.write("f.txt", "one\nTWO2\nthree\n")
        try await repo.commitAll("D two again")
        try await repo.git(["revert", "--no-edit", b, a], allowedExitCodes: [1])
        try await ConflictFixtures.requireUnmerged(repo)
        try repo.write("g.txt", "untracked\n")

        let result = try await Self.backend.skip(.revert, stoppedAt: b, at: repo.root)
        guard case .sequenceHalted = result.outcome else {
            Issue.record("expected .sequenceHalted, got \(result.outcome)")
            return
        }
        let halted = try #require(try await Self.backend.haltedSequence(at: repo.root))
        #expect(halted.operation == .revert)
        #expect(halted.notApplied.map(\.sha) == [a])
        #expect(halted.notApplied.map(\.subject) == ["A deletes g"])
    }

    /// The way forward the app names: move the file, `--quit` (nothing changes but `sequencer/`
    /// goes), then pick the listed commits again — all of them land.
    @Test func quitThenPickingTheListAgainAppliesThemAll() async throws {
        let repo = try await Self.threeCommits()
        defer { repo.cleanUp() }
        try await repo.git(["cherry-pick", "base..feature"], allowedExitCodes: [1])
        let c1 = try await repo.revParse("feature~2")
        try repo.write("n.txt", "n USER\n")
        _ = try await Self.backend.skip(.cherryPick, stoppedAt: c1, at: repo.root)
        let halted = try #require(try await Self.backend.haltedSequence(at: repo.root))
        let head = try await repo.headSha()

        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("n.txt"))
        try await repo.git(["cherry-pick", "--quit"])
        #expect(try await repo.headSha() == head)
        #expect(try await Self.backend.haltedSequence(at: repo.root) == nil)
        try await repo.git(["cherry-pick"] + halted.notApplied.map(\.sha))
        #expect(try await SequenceFixtures.subjects(repo, "-2") == ["c3 adds o", "c2 adds n"])
    }

    /// A todo naming a commit that no longer resolves keeps the todo's own words; a line git
    /// would not write is not a commit.
    @Test func anUnresolvableTodoLineKeepsItsOwnWords() async throws {
        let repo = try await Self.threeCommits()
        defer { repo.cleanUp() }
        let sequencer = try await ConflictFixtures.gitPath(repo, "sequencer")
        try FileManager.default.createDirectory(at: sequencer, withIntermediateDirectories: true)
        let c2 = try await repo.revParse("feature~1")
        try Data("revert 0123456 Gone commit\n# a comment\n\nrevert \(c2.prefix(7)) c2 adds n\n".utf8)
            .write(to: sequencer.appendingPathComponent("todo"))

        let halted = try #require(try await Self.backend.haltedSequence(at: repo.root))
        #expect(halted.operation == .revert)
        #expect(halted.notApplied == [CommitRef(sha: "0123456", subject: "Gone commit"), CommitRef(sha: c2, subject: "c2 adds n")])
        #expect(halted.total == 2)
    }

    /// A long list resolves its first commits only; `total` still counts every one.
    @Test func aLongListIsCappedButCounted() async throws {
        let repo = try await Self.threeCommits()
        defer { repo.cleanUp() }
        let sequencer = try await ConflictFixtures.gitPath(repo, "sequencer")
        try FileManager.default.createDirectory(at: sequencer, withIntermediateDirectories: true)
        let c2 = try await repo.revParse("feature~1")
        let lines = (0..<30).map { _ in "pick \(c2.prefix(7)) c2 adds n" }.joined(separator: "\n") + "\n"
        try Data(lines.utf8).write(to: sequencer.appendingPathComponent("todo"))

        let halted = try #require(try await Self.backend.haltedSequence(at: repo.root))
        #expect(halted.notApplied.count == HaltedSequence.listed)
        #expect(halted.total == 30)
    }
}
