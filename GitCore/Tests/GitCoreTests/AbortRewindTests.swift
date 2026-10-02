import Foundation
import Testing

@testable import GitCore

/// Final review I2 (measured on git 2.54): a cherry-pick or revert range keeps the HEAD it began
/// on in `sequencer/head` and the last commit it made in `sequencer/abort-safety`. After a
/// Continue made a commit and the range stopped again, `--abort` resets to `sequencer/head`: the
/// commits the range made leave the branch (reflog only). Only while HEAD is `abort-safety` —
/// with HEAD moved since, git warns "Not rewinding" and keeps it. A single pick or revert writes
/// no `sequencer/`.
@Suite struct AbortRewindTests {
    static let backend = CLIGitBackend()

    /// `HaltedSequenceTests.threeCommits`, with main also adding n.txt so c2 conflicts too: the
    /// range stops on c1, and after a Continue on c2.
    static func pickRange() async throws -> TestRepo {
        let repo = try await HaltedSequenceTests.threeCommits()
        try repo.write("n.txt", "n M\n")
        try await repo.commitAll("m adds n")
        try await repo.git(["cherry-pick", "base..feature"], allowedExitCodes: [1])
        return repo
    }

    /// The commits `rev`'s branch had that it no longer has: `before` not reachable from HEAD.
    static func left(_ repo: TestRepo, since before: String) async throws -> [String] {
        let data = try await repo.git(["rev-list", "--reverse", before, "^HEAD"])
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    @Test func aRangeThatMadeACommitRemovesItOnAbort() async throws {
        let repo = try await Self.pickRange()
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        let outcome = try await Self.backend.continueOperation(.cherryPick, message: nil, at: repo.root)
        guard case .stoppedAgain = outcome else {
            Issue.record("expected the range to stop on c2: \(outcome)")
            return
        }
        let made = try await repo.headSha()

        let removed = try await Self.backend.commitsAbortRemoves(at: repo.root)
        #expect(removed == [CommitRef(sha: made, subject: "c1 f")])

        // Git agrees: exactly those leave the branch.
        try await Self.backend.abort(.cherryPick, at: repo.root)
        #expect(try await Self.left(repo, since: made) == removed.map(\.sha))
        #expect(try await SequenceFixtures.subjects(repo, "-1") == ["m adds n"])
    }

    @Test func aRevertRangeThatMadeACommitRemovesItOnAbort() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f.txt", "a\n")
        try await repo.commitAll("base")
        for index in 1...3 {
            try repo.write("f.txt", "v\(index)\n")
            try await repo.commitAll("V\(index)")
        }
        try repo.write("f.txt", "last\n")
        try await repo.commitAll("last")
        let last = try await repo.headSha()
        try await repo.git(["revert", "--no-edit", "HEAD~1", "HEAD~2", "HEAD~3"], allowedExitCodes: [1])
        #expect(try await Self.backend.commitsAbortRemoves(at: repo.root).isEmpty, "the first stop made nothing")
        try repo.write("f.txt", "r\n")
        try await repo.git(["add", "f.txt"])
        _ = try await Self.backend.continueOperation(.revert, message: nil, at: repo.root)
        #expect(try await Self.backend.operationProgress(at: repo.root)?.operation == .revert)
        let made = try await repo.headSha()

        let removed = try await Self.backend.commitsAbortRemoves(at: repo.root)
        #expect(removed == [CommitRef(sha: made, subject: "Revert \"V3\"")])

        try await Self.backend.abort(.revert, at: repo.root)
        #expect(try await repo.headSha() == last)
        #expect(try await Self.left(repo, since: made) == removed.map(\.sha))
    }

    @Test func theFirstStopOfARangeRemovesNothing() async throws {
        let repo = try await Self.pickRange()
        defer { repo.cleanUp() }
        let head = try await repo.headSha()
        #expect(try await Self.backend.commitsAbortRemoves(at: repo.root).isEmpty)
        try await Self.backend.abort(.cherryPick, at: repo.root)
        #expect(try await repo.headSha() == head)
    }

    @Test func aSinglePickHasNoSequencerAndRemovesNothing() async throws {
        let repo = try await HaltedSequenceTests.threeCommits()
        defer { repo.cleanUp() }
        let head = try await repo.headSha()
        try await repo.git(["cherry-pick", "feature~2"], allowedExitCodes: [1])
        #expect(!FileManager.default.fileExists(atPath: try await ConflictFixtures.gitPath(repo, "sequencer").path))
        #expect(try await Self.backend.commitsAbortRemoves(at: repo.root).isEmpty)
        try await Self.backend.abort(.cherryPick, at: repo.root)
        #expect(try await repo.headSha() == head)
    }

    /// HEAD moved since the range's last commit (`abort-safety`): git does not rewind, and
    /// nothing is said to leave.
    @Test func aMovedHeadIsNotRewound() async throws {
        let repo = try await Self.pickRange()
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        _ = try await Self.backend.continueOperation(.cherryPick, message: nil, at: repo.root)
        let tree = String(decoding: try await repo.git(["rev-parse", "HEAD^{tree}"]), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
        let moved = String(
            decoding: try await repo.git(["commit-tree", "-p", "HEAD", "-m", "extra", tree]), as: UTF8.self
        ).trimmingCharacters(in: .newlines)
        try await repo.git(["update-ref", "HEAD", moved])

        #expect(try await Self.backend.commitsAbortRemoves(at: repo.root).isEmpty)
        try await Self.backend.abort(.cherryPick, at: repo.root)
        #expect(try await repo.headSha() == moved, "git kept HEAD (measured: \"Not rewinding\")")
    }

    @Test func aMergeRemovesNothing() async throws {
        let repo = try await HaltedSequenceTests.threeCommits()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "feature"], allowedExitCodes: [1])
        #expect(try await Self.backend.operationProgress(at: repo.root)?.operation == .merge)
        #expect(try await Self.backend.commitsAbortRemoves(at: repo.root).isEmpty)
    }
}
