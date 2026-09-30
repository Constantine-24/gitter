import Foundation
import Testing

@testable import GitCore

/// `operationProgress`, `pendingMessage` for a merge and a squash, and `operationPaths` (M 16,
/// M 19, M 26, M 31), read from the files git keeps.
@Suite struct OperationProgressTests {
    static let backend = CLIGitBackend()

    static func commitRef(_ repo: TestRepo, _ rev: String) async throws -> CommitRef {
        let data = try await repo.git(["log", "-1", "--format=%H%x00%s", rev])
        let fields = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
            .split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        return CommitRef(sha: fields[0], subject: fields[1])
    }

    /// Five commits `c1`…`c5`, each changing its own file where main changed it too; the rebase
    /// is resolved and continued in git itself twice, so it stands at the third.
    @Test func aRebaseStoppedAtTheThirdOfFive() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        for n in 1...5 { try repo.write("f\(n).txt", "x\n") }
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "feature"])
        for n in 1...5 {
            try repo.write("f\(n).txt", "x F\n")
            try await repo.commitAll("c\(n)")
        }
        try await repo.git(["switch", "-q", "main"])
        for n in 1...5 { try repo.write("f\(n).txt", "x M\n") }
        try await repo.commitAll("m")
        try await repo.git(["switch", "-q", "feature"])
        try await repo.git(["rebase", "main"], allowedExitCodes: [1])
        for n in 1...2 {
            try repo.write("f\(n).txt", "x RES\n")
            try await repo.git(["add", "--", "f\(n).txt"])
            try await repo.git(["rebase", "--continue"], allowedExitCodes: [1])
        }
        #expect(try await SequenceFixtures.unmerged(repo) == ["f3.txt"])

        let progress = try #require(try await Self.backend.operationProgress(at: repo.root))

        #expect(progress.operation == .rebase)
        #expect(progress.step == 3)
        #expect(progress.total == 5)
        #expect(progress.remaining == nil)
        #expect(progress.headName == "feature")
        #expect(progress.onto == (try await Self.commitRef(repo, "main")))
        #expect(progress.current == (try await Self.commitRef(repo, "feature~2")))
        #expect(progress.current?.subject == "c3")
        #expect(progress.mergeHead == nil && progress.mergedName == nil)
    }

    @Test func aDetachedRebaseHasNoHeadName() async throws {
        let repo = try await SequenceFixtures.history()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "--detach", "one"])
        try await repo.git(["rebase", "main"], allowedExitCodes: [1])
        try await ConflictFixtures.requireUnmerged(repo)

        let progress = try #require(try await Self.backend.operationProgress(at: repo.root))

        #expect(progress.headName == nil)
        #expect(progress.step == 1 && progress.total == 1)
    }

    /// M 16: `sequencer/todo` lists the current commit first; there is no total.
    @Test func aPickRangeCountsWhatRemains() async throws {
        let repo = try await ConflictFixtures.cherryPickRange(stopAt: 1)
        defer { repo.cleanUp() }

        let progress = try #require(try await Self.backend.operationProgress(at: repo.root))

        #expect(progress.operation == .cherryPick)
        #expect(progress.remaining == 3)
        #expect(progress.step == nil && progress.total == nil)
        #expect(progress.current == (try await Self.commitRef(repo, "CHERRY_PICK_HEAD")))
        #expect(progress.current?.subject == "pick 1")
    }

    @Test func aRevertRangeCountsWhatRemains() async throws {
        let repo = try await SequenceFixtures.stopped(.revert, commits: 2)
        defer { repo.cleanUp() }

        let progress = try #require(try await Self.backend.operationProgress(at: repo.root))

        #expect(progress.operation == .revert)
        #expect(progress.remaining == 2)
        #expect(progress.current?.subject == "r2 g")
    }

    @Test func aSinglePickHasNothingRemaining() async throws {
        let repo = try await ConflictFixtures.cherryPick(kind: .bothModified)
        defer { repo.cleanUp() }

        let progress = try #require(try await Self.backend.operationProgress(at: repo.root))

        #expect(progress == OperationProgress(
            operation: .cherryPick, current: try await Self.commitRef(repo, "theirs")))
    }

    /// M 26: the merged name, when `MERGE_MSG` names a branch, a tag or a remote-tracking branch.
    @Test(arguments: [
        ("theirs", [String](), "theirs"),
        ("v1", [], "v1"),
        ("origin/x", [], "origin/x"),
        ("theirs", ["-m", "custom message"], nil),
    ] as [(String, [String], String?)])
    func aMergeNamesWhatItMerges(target: String, options: [String], expected: String?) async throws {
        let repo = try await ConflictFixtures.history(.bothModified)
        defer { repo.cleanUp() }
        try await repo.git(["tag", "v1", "theirs"])
        try await repo.git(["update-ref", "refs/remotes/origin/x", "theirs"])
        try await repo.git(["merge", "--no-edit"] + options + [target], allowedExitCodes: [1])
        try await ConflictFixtures.requireUnmerged(repo)

        let progress = try #require(try await Self.backend.operationProgress(at: repo.root))

        #expect(progress.operation == .merge)
        #expect(progress.mergeHead == (try await Self.commitRef(repo, "theirs")))
        #expect(progress.mergedName == expected)
    }

    /// Outside main and master git names the branch merged into: `Merge branch 'x' into topic`.
    @Test func aMergeIntoAnotherBranchStillNamesWhatItMerges() async throws {
        let repo = try await ConflictFixtures.history(.bothModified)
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "-c", "topic"])
        try await repo.git(["merge", "--no-edit", "theirs"], allowedExitCodes: [1])
        let firstLine = try String(contentsOf: try await ConflictFixtures.gitPath(repo, "MERGE_MSG"), encoding: .utf8)
            .split(separator: "\n").first
        #expect(firstLine == "Merge branch 'theirs' into topic")

        #expect(try await Self.backend.operationProgress(at: repo.root)?.mergedName == "theirs")
    }

    @Test func noOperationHasNoProgress() async throws {
        let repo = try await SequenceFixtures.history()
        defer { repo.cleanUp() }

        #expect(try await Self.backend.operationProgress(at: repo.root) == nil)
        #expect(try await Self.backend.pendingMessage(at: repo.root) == nil)
    }

    // MARK: - Merge and squash messages (M 19)

    @Test func aMergesPendingMessageIsMergeMsgWithoutItsConflictBlock() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }

        #expect(try await Self.backend.pendingMessage(at: repo.root)
                == PendingMessage(text: "Merge branch 'theirs'", commentChar: "#"))
    }

    /// A squash's message is `SQUASH_MSG`; its `MERGE_MSG` holds only the conflict list.
    @Test func aSquashsPendingMessageIsSquashMsg() async throws {
        let repo = try await ConflictFixtures.squash(kind: .bothModified)
        defer { repo.cleanUp() }

        let pending = try #require(try await Self.backend.pendingMessage(at: repo.root))

        #expect(pending.text.hasPrefix("Squashed commit of the following:"))
        #expect(pending.text.contains("theirs change"))
        #expect(try await Self.backend.operationProgress(at: repo.root) == OperationProgress(operation: .squash))
    }

    // MARK: - operationPaths (M 31)

    @Test func aMergesOperationPathsAreItsResult() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }

        #expect(try await Self.backend.operationPaths(at: repo.root) == ["f.txt"])
    }

    /// M 31: a `stash apply` writes an `AUTO_MERGE` with no operation; it is not read.
    @Test func anAutoMergeWithNoOperationIsNotRead() async throws {
        let repo = try await ConflictFixtures.stashApplyConflict()
        defer { repo.cleanUp() }
        #expect(!(try await repo.git(["rev-parse", "-q", "--verify", "AUTO_MERGE"], allowedExitCodes: [1])).isEmpty,
                "no AUTO_MERGE: the test proves nothing")

        #expect(try await Self.backend.operationPaths(at: repo.root) == nil)
    }
}
