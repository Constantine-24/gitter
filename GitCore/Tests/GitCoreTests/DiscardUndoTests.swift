import Foundation
import Testing

@testable import GitCore

/// Undo of every discard kind: back byte for byte, the record dropped by its sha, and a
/// refusal — never an overwrite — when the files moved on since.
@Suite struct DiscardUndoTests {
    private let backend = CLIGitBackend()

    /// Everything a pre-discard state is: HEAD, the index, every ref (the stash too), and the
    /// worktree with modes and links.
    private struct Full: Equatable {
        let repo: RepoState
        let worktree: [String: WorktreeEntry]
        static func capture(_ r: TestRepo) async throws -> Full {
            Full(repo: try await RepoState.capture(r), worktree: worktreeState(r))
        }
    }

    @Test(arguments: DiscardCase.allCases)
    func eachKindComesBackExactly(_ kind: DiscardCase) async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await kind.prepare(repo)
        let bystanders = try await Bystanders.capture(repo)
        let before = try await Full.capture(repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(try await kind.request(repo), trasher: trasher, at: repo.root)
        #expect(try await Full.capture(repo) != before, "the discard changed nothing")

        let outcome = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)

        #expect(outcome == .restored)
        let after = try await Full.capture(repo)
        #expect(after.repo == before.repo, "HEAD, the index or a ref (the stash) differs")
        assertWorktreeState(repo, equals: before.worktree)
        try await bystanders.assertUnchanged(repo, "by the discard and its undo")
        #expect(try await repo.stashRef() == nil)
    }

    /// M B b: after a commit that touched `p` elsewhere, restoring the staged part from the
    /// record would stage a reversal of that commit. It is skipped; the content comes back.
    @Test func aStagedSideUndoAfterANewCommitComesBackUnstaged() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await DiscardCase.stagedBothLayers.prepare(repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(try await DiscardCase.stagedBothLayers.request(repo), trasher: trasher, at: repo.root)
        let bystanders = try await Bystanders.capture(repo)
        try repo.write("p", numbered(12, [6: "6 elsewhere"]))
        try await repo.git(["commit", "-q", "-m", "p elsewhere", "--", "p"])

        let outcome = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)

        #expect(outcome == .restoredUnstaged)
        // The index holds the new commit's p, not the record's older staged one.
        #expect(try await repo.indexContent(of: "p") == (try await repo.blob("HEAD", "p")))
        #expect(try repo.bytes("p") == Data(numbered(12, [2: "2 staged", 6: "6 elsewhere", 11: "11 unstaged"]).utf8))
        try await bystanders.assertUnchanged(repo, "by the undo")
        #expect(try await repo.stashRef() == nil, "the record was not dropped")
    }

    /// A commit since the discard that changed the line next to a discarded one: the record
    /// goes back with git's conflict (reported by `ls-files -u`, `-q` says nothing, M A.1), and
    /// stays listed; nothing is dropped.
    @Test func anUndoThatConflictsKeepsTheRecord() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await DiscardCase.stagedBothLayers.prepare(repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(try await DiscardCase.stagedBothLayers.request(repo), trasher: trasher, at: repo.root)
        let record = try #require(receipt.record)
        try repo.write("p", numbered(12, [12: "12 next to it"]))
        try await repo.git(["commit", "-q", "-m", "p next to it", "--", "p"])

        let outcome = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)

        #expect(outcome == .conflicted(["p"], recordKept: try await backend.stashes(at: repo.root).first))
        #expect(try await repo.stashShas() == [record.sha])
        #expect(try await repo.unmergedEntries().isEmpty == false)
    }

    /// RF3: `p` edited again after the discard. The undo refuses, `p` keeps the new edit, and
    /// the record stays listed.
    @Test(arguments: [DiscardCase.unstagedModified, .stagedBothLayers])
    func anUndoOverAFileEditedSinceIsRefusedAndTheRecordKept(_ kind: DiscardCase) async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await kind.prepare(repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(try await kind.request(repo), trasher: trasher, at: repo.root)
        let record = try #require(receipt.record)
        try repo.write("p", numbered(12, [7: "7 later"]))
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let outcome = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)

        guard case .refused(let words, let kept) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(words.contains("p"))
        #expect(kept?.sha == record.sha)
        #expect(try await repo.stashShas() == [record.sha])
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// The lines were edited after their discard: the forward patch no longer fits, and git
    /// refuses it atomically.
    @Test func aLinesUndoAfterTheLinesWereEditedIsRefused() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await DiscardCase.linesOneHunkOfThree.prepare(repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(
            try await DiscardCase.linesOneHunkOfThree.request(repo), trasher: trasher, at: repo.root)
        try repo.write("f3", numbered(30, [3: "3 A", 14: "14 edited", 27: "27 C"]))
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let outcome = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)

        guard case .refused(let words, let kept) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(words.contains("patch does not apply"), "\(words)")
        #expect(kept?.sha == receipt.record?.sha)
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// An untracked item whose path exists again is not overwritten; the other comes back.
    @Test func anUntrackedUndoOntoARecreatedPathRestoresTheRestAndOverwritesNothing() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try repo.write("u.txt", "u\n")
        try repo.write("v.txt", "v\n")
        let paths = ["u.txt", "v.txt"]
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(
            .untracked(paths: paths, expected: try await backend.discardExpectation(untracked: paths, at: repo.root)),
            trasher: trasher, at: repo.root)
        try repo.write("u.txt", "made again\n")

        let outcome = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)

        #expect(outcome == .partiallyRestored(notRestored: ["u.txt"]))
        #expect(try repo.bytes("u.txt") == Data("made again\n".utf8))
        #expect(try repo.bytes("v.txt") == Data("v\n".utf8))
        let stillTrashed = try #require(receipt.trashed["u.txt"])
        #expect(try Data(contentsOf: stillTrashed) == Data("u\n".utf8))
    }

    /// RF2: another entry pushed between the discard and its undo moves the record to
    /// `stash@{1}`. The undo still restores, and drops the record — found by its sha — never
    /// the entry now at the position the receipt remembers.
    @Test(arguments: [DiscardCase.unstagedModified, .stagedBothLayers, .linesOneHunkOfThree])
    func anEntryPushedInBetweenIsNeverTheOneDropped(_ kind: DiscardCase) async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await kind.prepare(repo)
        let before = try await Full.capture(repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(try await kind.request(repo), trasher: trasher, at: repo.root)
        #expect(receipt.record?.index == 0)
        try repo.write("d", "d\nneighbour\n")
        try await repo.git(["stash", "push", "-q", "-m", "neighbour", "--", "d"])
        let neighbour = try #require(try await repo.stashShas().first)
        #expect(try await repo.stashShas() == [neighbour, receipt.record?.sha])

        let outcome = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)

        #expect(outcome == .restored)
        #expect(try await repo.stashShas() == [neighbour], "the wrong entry was dropped")
        assertWorktreeState(repo, equals: before.worktree)
        #expect(try await RepoState.capture(repo).index == before.repo.index)
    }

    /// The record already gone from the list (dropped in a terminal): the undo still applies it
    /// by sha, drops nothing, and says the content is back.
    @Test func anUndoWhoseRecordWasDroppedElsewhereStillRestoresAndDropsNothing() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await DiscardCase.unstagedModified.prepare(repo)
        let pBefore = try repo.bytes("p")
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(try await DiscardCase.unstagedModified.request(repo), trasher: trasher, at: repo.root)
        try repo.write("d", "d\nneighbour\n")
        try await repo.git(["stash", "push", "-q", "-m", "neighbour", "--", "d"])
        try await repo.git(["stash", "drop", "-q", "stash@{1}"])
        let neighbour = try await repo.stashShas()

        #expect(try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root) == .restored)
        #expect(try repo.bytes("p") == pBefore)
        #expect(try await repo.stashShas() == neighbour)
    }
}
