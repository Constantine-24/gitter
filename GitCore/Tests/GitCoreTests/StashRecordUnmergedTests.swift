import Foundation
import Testing

@testable import GitCore

// MARK: - The record, for an unmerged path

@Suite struct StashRecordUnmergedTests {
    @Test func anUnmergedPathIsRecordedWithHEADsEntryAndTheWorktreeBytes() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let edited = try ConflictWriteTests.handEdit(repo)
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let stash = try await StashRecord.record(
            paths: ["f.txt"], message: "Replaced by Gitter: f.txt", allowingUnmerged: true,
            backend: CLIGitBackend(), at: repo.root)

        #expect(stash.reflogSubject == "Replaced by Gitter: f.txt")
        #expect(try await repo.blob(stash.sha, "f.txt") == edited)
        #expect(try await repo.blob("\(stash.sha)^2", "f.txt") == (try await repo.blob("HEAD", "f.txt")))
        // Nothing but refs/stash moved: the stages, the worktree, the operation.
        assertWorktreeUnchanged(repo, since: worktree)
        let now = try await RepoState.capture(repo)
        #expect(now.index == state.index && now.head == state.head)
        try await assertOperationUnchanged(repo, since: operation)

        // Recoverable: on a clean tree, the entry puts the edited bytes back.
        try await repo.git(["merge", "--abort"])
        try await repo.git(["stash", "apply", "-q"])
        #expect(try repo.bytes("f.txt") == edited)
    }

    @Test func aDUPathNotInHEADIsRecordedFromTheWorktree() async throws {
        let repo = try await ConflictFixtures.merge(kind: .deletedByUs)
        defer { repo.cleanUp() }
        try repo.write("du.txt", "d EDITED\n")

        let stash = try await StashRecord.record(
            paths: ["du.txt"], message: "Replaced by Gitter: du.txt", allowingUnmerged: true,
            backend: CLIGitBackend(), at: repo.root)

        #expect(try await repo.blob(stash.sha, "du.txt") == Data("d EDITED\n".utf8))
        #expect(try await repo.mode("\(stash.sha)^2", "du.txt") == nil)
        #expect(try await ConflictWriteTests.unmerged(repo, "du.txt"))
    }

    @Test func withoutTheFlagAnUnmergedPathIsStillRefused() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }

        await #expect(throws: StashRefusal.unmergedPaths(["f.txt"])) {
            try await StashRecord.record(
                paths: ["f.txt"], message: "m", allowingUnmerged: false, backend: CLIGitBackend(), at: repo.root)
        }
        #expect(try await repo.stashCount() == 0)
    }

    @Test func theOtherRefusalsStand() async throws {
        let repo = try await ConflictFixtures.merge(kind: .submodule)
        defer { repo.cleanUp() }

        await #expect(throws: StashRefusal.submodules(["sub"])) {
            try await StashRecord.record(
                paths: ["sub"], message: "m", allowingUnmerged: true, backend: CLIGitBackend(), at: repo.root)
        }
        #expect(try await repo.stashCount() == 0)
    }
}
