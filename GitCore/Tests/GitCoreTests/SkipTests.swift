import Foundation
import Testing

@testable import GitCore

/// `skipReadiness` and `skip` (M 17, M 31, M 32): only the stopped commit's own changes may be
/// thrown away, and they are filed first.
@Suite struct SkipTests {
    static let backend = CLIGitBackend()
    static let sequences: [RepositoryOperation] = [.rebase, .cherryPick, .revert]

    /// The first stop's conflicted path, partially resolved and staged.
    static func partiallyResolve(_ repo: TestRepo) async throws -> (path: String, bytes: Data) {
        let path = try #require(try await SequenceFixtures.unmerged(repo).first)
        let bytes = Data("\(path) PARTIAL\n".utf8)
        try bytes.write(to: repo.root.appendingPathComponent(path))
        try await repo.git(["add", "--", path])
        return (path, bytes)
    }

    /// `<short sha> <subject>` of `rev`, as the record names it.
    static func summary(_ repo: TestRepo, _ rev: String) async throws -> String {
        String(decoding: try await repo.git(["log", "-1", "--format=%h %s", rev]), as: UTF8.self)
            .trimmingCharacters(in: .newlines)
    }

    @Test(arguments: sequences)
    func onlyTheStoppedCommitsChangesAreReady(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        let partial = try await Self.partiallyResolve(repo)

        #expect(try await Self.backend.skipReadiness(at: repo.root) == .ready(paths: [partial.path]))
    }

    /// M 32: every skip returns the tree to HEAD; Gitter files the partial resolution first.
    @Test(arguments: sequences)
    func aSkipFilesThePartialWorkAndMovesOn(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 2)
        defer { repo.cleanUp() }
        let partial = try await Self.partiallyResolve(repo)
        let first = try #require(try await Self.backend.operationProgress(at: repo.root)?.current)
        let firstSummary = try await Self.summary(repo, first.sha)

        let outcome = try await Self.backend.skip(operation, stoppedAt: first.sha, at: repo.root)

        guard case .stoppedAgain(let progress) = outcome.outcome else {
            Issue.record("expected the next stop, got \(outcome.outcome)")
            return
        }
        #expect(progress.current != nil && progress.current != first)
        let recorded = try #require(outcome.recorded)
        #expect(recorded.reflogSubject == "Skipped by Gitter: \(firstSummary)")
        #expect(try await repo.blob(recorded.sha, partial.path) == partial.bytes)
        // The skipped path is HEAD's again, in the index and the worktree.
        #expect(try repo.bytes(partial.path) == (try await repo.blob("HEAD", partial.path)))
        #expect(try await repo.git(["diff", "--quiet", "HEAD", "--", partial.path], allowedExitCodes: []).isEmpty)

        // The last stop, skipped unresolved: its conflicted file is what gets filed.
        let second = try #require(progress.current)
        let conflicted = try #require(try await SequenceFixtures.unmerged(repo).first)
        let conflictedBytes = try repo.bytes(conflicted)

        let last = try await Self.backend.skip(operation, stoppedAt: second.sha, at: repo.root)

        #expect(last.outcome == .finished)
        #expect(try await repo.blob(try #require(last.recorded).sha, conflicted) == conflictedBytes)
        #expect(try await Self.backend.operationProgress(at: repo.root) == nil)
        #expect(try await repo.git(["status", "--porcelain"]).isEmpty, "the tree is not HEAD's")
        #expect(try await repo.stashCount() == 2)
    }

    /// RF5: an unrelated staged and unstaged edit are not the stopped commit's — `rebase --skip`
    /// would reset both (M 17). Refused, running nothing.
    @Test(arguments: sequences)
    func anUnrelatedEditRefusesTheSkip(operation: RepositoryOperation) async throws {
        let repo = try await SequenceFixtures.stopped(operation, commits: 1)
        defer { repo.cleanUp() }
        _ = try await Self.partiallyResolve(repo)
        try repo.write("h.txt", "h STAGED\n")
        try await repo.git(["add", "--", "h.txt"])
        try repo.write("i.txt", "i UNSTAGED\n")
        try repo.write("untracked.txt", "untracked\n")
        let current = try #require(try await Self.backend.operationProgress(at: repo.root)?.current)
        let readiness = try await Self.backend.skipReadiness(at: repo.root)
        #expect(readiness == .otherChanges(["h.txt", "i.txt"]))
        let untouched = try await SequenceFixtures.Untouched.capture(repo)

        await #expect(throws: OperationError.skipRefused(readiness)) {
            try await Self.backend.skip(operation, stoppedAt: current.sha, at: repo.root)
        }

        try await untouched.assert(repo)
        #expect(try await repo.stashCount() == 0)
    }

    @Test func aStopThatMovedOnIsNotSkipped() async throws {
        let repo = try await SequenceFixtures.stopped(.cherryPick, commits: 2)
        defer { repo.cleanUp() }
        let first = try #require(try await Self.backend.operationProgress(at: repo.root)?.current)
        try await SequenceFixtures.resolve(repo)
        try await repo.git(["cherry-pick", "--continue"], allowedExitCodes: [1])
        try await ConflictFixtures.requireUnmerged(repo)
        let untouched = try await SequenceFixtures.Untouched.capture(repo)

        await #expect(throws: OperationError.stoppedCommitChanged) {
            try await Self.backend.skip(.cherryPick, stoppedAt: first.sha, at: repo.root)
        }

        try await untouched.assert(repo)
        #expect(try await repo.stashCount() == 0)
    }

    @Test func anotherOperationIsAMismatch() async throws {
        let repo = try await SequenceFixtures.stopped(.revert, commits: 1)
        defer { repo.cleanUp() }
        let current = try #require(try await Self.backend.operationProgress(at: repo.root)?.current)
        let untouched = try await SequenceFixtures.Untouched.capture(repo)

        await #expect(throws: OperationError.operationMismatch(expected: .cherryPick, found: .revert)) {
            try await Self.backend.skip(.cherryPick, stoppedAt: current.sha, at: repo.root)
        }
        try await untouched.assert(repo)
    }

    // MARK: - Fix round 1: paths git cannot reset (I3)

    /// Commit `C` conflicts on `f.txt`, changes `z.txt` cleanly, adds `new.txt` and deletes
    /// `del.txt`. A pick or rebase replays it onto `main`; a revert reverts it under `later`
    /// (which re-adds `del.txt` and deletes `new.txt`).
    static func wide(_ operation: RepositoryOperation) async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("f.txt", "a\nb\nc\n")
        try repo.write("z.txt", "z\n")
        try repo.write("del.txt", "del\n")
        try repo.write("h.txt", "h\n")
        try await repo.commitAll("base")
        func commitC() async throws {
            try repo.write("f.txt", "a\nb F\nc\n")
            try repo.write("z.txt", "z F\n")
            try repo.write("new.txt", "new from C\n")
            try repo.remove("del.txt")
            try await repo.commitAll("C")
        }
        if operation == .revert {
            try await commitC()
            try repo.write("f.txt", "a\nb L\nc\n")
            try await repo.commitAll("later")
            try await repo.git(["revert", "--no-edit", "HEAD~1"], allowedExitCodes: [1])
        } else {
            try await repo.git(["switch", "-q", "-c", "feature"])
            try await commitC()
            try await repo.git(["switch", "-q", "main"])
            try repo.write("f.txt", "a\nb M\nc\n")
            try await repo.commitAll("m")
            if operation == .rebase {
                try await repo.git(["switch", "-q", "feature"])
                try await repo.git(["rebase", "main"], allowedExitCodes: [1])
            } else {
                try await repo.git(["cherry-pick", "feature"], allowedExitCodes: [1])
            }
        }
        try await ConflictFixtures.requireUnmerged(repo)
        return repo
    }

    enum Unclean: String, CaseIterable, Sendable {
        /// The normal flow: a partial resolution staged, then edited again (`MM f.txt`).
        case partialThenEdited
        /// An edit to a path the commit changed cleanly (`MM z.txt`).
        case cleanPathEdited
        /// An edit to a file the commit added (`AM new.txt`).
        case addedThenEdited
        /// A file the commit deleted, recreated (`D` + `??`).
        case deletedRecreated

        func apply(_ repo: TestRepo, _ operation: RepositoryOperation) async throws -> String {
            switch self {
            case .partialThenEdited:
                try repo.write("f.txt", "a\nb PARTIAL\nc\n")
                try await repo.git(["add", "--", "f.txt"])
                try repo.write("f.txt", "a\nb PARTIAL EDITED\nc\n")
                return "f.txt"
            case .cleanPathEdited:
                try repo.write("z.txt", "z USER\n")
                return "z.txt"
            case .addedThenEdited:
                try repo.write("new.txt", "new USER\n")
                return "new.txt"
            case .deletedRecreated:
                // A revert of `C` deletes `new.txt`; a pick or rebase of it deletes `del.txt`.
                let path = operation == .revert ? "new.txt" : "del.txt"
                try repo.write(path, "USER RECREATED\n")
                return path
            }
        }
    }

    /// Measured (fix round 1): git refuses each of these skips (exit 128) after Gitter had filed
    /// an entry. Now readiness names them and nothing is filed or run.
    static let refusedSkips: [(RepositoryOperation, Unclean)] = [
        (.cherryPick, .partialThenEdited), (.cherryPick, .cleanPathEdited), (.cherryPick, .addedThenEdited),
        (.cherryPick, .deletedRecreated),
        (.revert, .partialThenEdited), (.revert, .cleanPathEdited), (.revert, .deletedRecreated),
        (.rebase, .deletedRecreated),
    ]

    @Test(arguments: refusedSkips)
    func aSkipGitWouldRefuseIsRefusedFirst(operation: RepositoryOperation, unclean: Unclean) async throws {
        let repo = try await Self.wide(operation)
        defer { repo.cleanUp() }
        let path = try await unclean.apply(repo, operation)
        let current = try #require(try await Self.backend.operationProgress(at: repo.root)?.current)

        #expect(try await Self.backend.skipReadiness(at: repo.root) == .needsCleanPaths([path]))

        let untouched = try await SequenceFixtures.Untouched.capture(repo)
        await #expect(throws: OperationError.skipRefused(.needsCleanPaths([path]))) {
            try await Self.backend.skip(operation, stoppedAt: current.sha, at: repo.root)
        }
        try await untouched.assert(repo)
        #expect(try await repo.stashCount() == 0, "a refused skip filed an entry")
    }

    /// `rebase --skip` resets every tracked file, so an edited path of the commit's is no
    /// obstacle there: it is filed, and the skip runs.
    @Test(arguments: [Unclean.partialThenEdited, .cleanPathEdited, .addedThenEdited])
    func aRebaseSkipsOverEditedPathsOfItsCommit(unclean: Unclean) async throws {
        let repo = try await Self.wide(.rebase)
        defer { repo.cleanUp() }
        let path = try await unclean.apply(repo, .rebase)
        let edited = try repo.bytes(path)
        let current = try #require(try await Self.backend.operationProgress(at: repo.root)?.current)
        guard case .ready(let paths) = try await Self.backend.skipReadiness(at: repo.root) else {
            Issue.record("expected .ready")
            return
        }
        #expect(paths.contains(path))

        let outcome = try await Self.backend.skip(.rebase, stoppedAt: current.sha, at: repo.root)

        #expect(outcome.outcome == .finished)
        #expect(try await repo.blob(try #require(outcome.recorded).sha, path) == edited)
        #expect(try await repo.git(["status", "--porcelain"]).isEmpty)
    }

    // MARK: - Stops with no commit to skip (M 31, Ruling 19)

    /// A failed `exec` after a clean pick: no `AUTO_MERGE` and no commit pending, so nothing to
    /// skip (Ruling 19 supersedes the brief's `.ready([])` here).
    @Test func anExecFailureStopIsNotSkippable() async throws {
        let repo = try await SequenceFixtures.history()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "one"])
        try await repo.git(["rebase", "--exec", "false", "base"], allowedExitCodes: [1])
        #expect(try await Self.backend.operationProgress(at: repo.root)?.operation == .rebase)

        #expect(try await Self.backend.operationPaths(at: repo.root) == nil)
        #expect(try await Self.backend.skipReadiness(at: repo.root) == .notSkippable)
        // No commit is pending, so nothing can come out empty.
        #expect(try await Self.backend.continueReadiness(at: repo.root) == .ready)
        #expect(try await Self.backend.operationProgress(at: repo.root)?.current == nil)
        #expect(try await Self.backend.pendingMessage(at: repo.root) == nil)
        let head = try await repo.headSha()
        let untouched = try await SequenceFixtures.Untouched.capture(repo)
        await #expect(throws: OperationError.skipRefused(.notSkippable)) {
            try await Self.backend.skip(.rebase, stoppedAt: head, at: repo.root)
        }
        try await untouched.assert(repo)
    }

    @Test func aBreakStopIsNotSkippable() async throws {
        let repo = try await SequenceFixtures.history()
        defer { repo.cleanUp() }
        try await Self.sequenceEditor(repo, "{ echo break; cat \"$1\"; } > \"$1.new\" && mv \"$1.new\" \"$1\"")
        try await repo.git(["switch", "-q", "one"])
        try await repo.git(["rebase", "-i", "main"])
        #expect(try await Self.backend.operationProgress(at: repo.root)?.operation == .rebase)

        #expect(try await Self.backend.operationPaths(at: repo.root) == nil)
        #expect(try await Self.backend.skipReadiness(at: repo.root) == .notSkippable)
        #expect(try await Self.backend.continueReadiness(at: repo.root) == .ready)
    }

    /// Ruling 19: at a clean `edit` stop `REBASE_HEAD` is the edited commit, but it is already
    /// made — `rebase --skip` exits 0 and the commit stays (measured). Not a skip of it.
    @Test func aCleanEditStopIsNotSkippable() async throws {
        let repo = try await SequenceFixtures.history()
        defer { repo.cleanUp() }
        try await Self.sequenceEditor(repo, "sed -i '' '1s/^pick/edit/' \"$1\"")
        try await repo.git(["switch", "-q", "one"])
        try await repo.git(["rebase", "-i", "base"])
        let current = try #require(try await Self.backend.operationProgress(at: repo.root)?.current)
        #expect(current.subject == "c1 f")
        #expect(try await Self.backend.operationPaths(at: repo.root) == nil)
        let untouched = try await SequenceFixtures.Untouched.capture(repo)

        #expect(try await Self.backend.skipReadiness(at: repo.root) == .notSkippable)
        await #expect(throws: OperationError.skipRefused(.notSkippable)) {
            try await Self.backend.skip(.rebase, stoppedAt: current.sha, at: repo.root)
        }

        try await untouched.assert(repo)
        #expect(try await repo.stashCount() == 0)
    }

    /// `sequence.editor` set to a script in the test repository, run by `rebase -i`.
    static func sequenceEditor(_ repo: TestRepo, _ body: String) async throws {
        let editor = repo.root.appendingPathComponent(".git/sequence-editor.sh")
        try repo.writeExecutable(".git/sequence-editor.sh", "#!/bin/sh\n\(body)\n")
        try await repo.git(["config", "sequence.editor", editor.path])
    }

    /// M 31: with `--no-renames` both sides of a rename are the stopped commit's.
    @Test func aRenameInTheStoppedCommitCountsByBothNames() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f.txt", "a\nb\nc\n")
        try repo.write("ren.txt", (1...8).map { "line \($0)\n" }.joined())
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "topic"])
        try repo.write("f.txt", "a\nb T\nc\n")
        try await repo.git(["mv", "ren.txt", "renamed.txt"])
        try await repo.commitAll("C")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", "a\nb M\nc\n")
        try await repo.commitAll("m")
        try await repo.git(["switch", "-q", "topic"])
        try await repo.git(["rebase", "main"], allowedExitCodes: [1])
        try await ConflictFixtures.requireUnmerged(repo)
        let paths = try #require(try await Self.backend.operationPaths(at: repo.root))
        #expect(Set(paths) == ["f.txt", "ren.txt", "renamed.txt"])

        let readiness = try await Self.backend.skipReadiness(at: repo.root)

        guard case .ready(let ready) = readiness else {
            Issue.record("expected .ready, got \(readiness)")
            return
        }
        #expect(Set(ready) == ["f.txt", "ren.txt", "renamed.txt"])
        let current = try #require(try await Self.backend.operationProgress(at: repo.root)?.current)

        let outcome = try await Self.backend.skip(.rebase, stoppedAt: current.sha, at: repo.root)

        #expect(outcome.outcome == .finished)
        #expect(try await repo.blob(try #require(outcome.recorded).sha, "renamed.txt").count > 0)
        #expect(try await repo.git(["status", "--porcelain"]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("ren.txt").path))
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("renamed.txt").path))
    }
}
