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

    /// The lines were edited after their discard: the file is no longer what the discard left,
    /// so the undo refuses before git is asked (the forward patch would no longer fit either).
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
        // Refused by the re-read of what the discard left, before git is asked at all.
        #expect(words.contains("f3"), "\(words)")
        #expect(kept?.sha == receipt.record?.sha)
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// Fix round 1 (review, probed): two identical six-line blocks, `NEW` discarded from the
    /// second; then ten lines added between the blocks. The forward patch's full context now
    /// matches the FIRST block nearer the recorded position, and git applied `NEW` there
    /// (`Hunk #1 succeeded at 7 (offset -6 lines)`, measured) — and the record was dropped. The
    /// undo re-reads what the discard left and refuses when it moved; the record stays listed.
    @Test func aLinesUndoAfterTheFileMovedIsRefusedBeforeItCanApplyAtAnOffset() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        let block = "a\nb\nc\nd\ne\nf\n"
        let filler = "f1\nf2\nf3\nf4\nf5\n"
        try repo.write("blocks", "top\n" + filler + block + block + "end\n")
        try await repo.git(["add", "blocks"])
        try await repo.git(["commit", "-q", "-m", "blocks", "--", "blocks"])
        try repo.write("blocks", "top\n" + filler + block + "a\nb\nc\nNEW\nd\ne\nf\n" + "end\n")
        let file = try await loadDiff(repo, "blocks")
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(
            try linesRequest(file, hunks: everyHunkID(file), lines: nil), trasher: trasher, at: repo.root)
        let record = try #require(receipt.record)
        let between = (1...10).map { "X\($0)\n" }.joined()
        try repo.write("blocks", "top\n" + filler + block + between + block + "end\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let outcome = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)

        guard case .refused(_, let kept) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(kept?.sha == record.sha)
        #expect(try await repo.stashShas() == [record.sha])
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// The last guard before the drop: the file must be byte for byte what the record holds,
    /// raw or as a checkout would write it. This stands in for a state the guard before the
    /// apply cannot tell apart with a receipt whose `afterDiscard` is the file as it is now,
    /// edited at line 29, away from the patch. The lines come back, and the record is kept
    /// rather than trusted to be redundant.
    @Test func aLinesUndoThatCannotProveTheFileIsAsRecordedKeepsTheRecord() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await DiscardCase.linesOneHunkOfThree.prepare(repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let discarded = try await backend.discard(
            try await DiscardCase.linesOneHunkOfThree.request(repo), trasher: trasher, at: repo.root)
        let record = try #require(discarded.record)
        try repo.write("f3", numbered(30, [3: "3 A", 27: "27 C", 29: "29 unseen"]))
        let receipt = DiscardReceipt(
            request: discarded.request, record: record, headAtDiscard: discarded.headAtDiscard, trashed: [:],
            afterDiscard: try await backend.discardedFileState(of: "f3", at: repo.root))

        let outcome = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)

        let listed = try await backend.stashes(at: repo.root).first
        #expect(outcome == .restoredUnverified(recordKept: listed), "\(outcome)")
        #expect(listed?.sha == record.sha)
        #expect(try repo.bytes("f3") == Data(numbered(30, [3: "3 A", 15: "15 B", 27: "27 C", 29: "29 unseen"]).utf8))
    }

    /// Fix round 2 (review, probed): a line discard that took every unstaged change of the
    /// file leaves an empty unstaged diff — and it stays empty when the user then edits the
    /// file and stages or commits the edit. The forward patch then went into the wrong block.
    /// The receipt holds the file's bytes, its index entry and HEAD; any of them moved refuses.
    @Test(arguments: ["add", "commit", "crlf"])
    func aLinesUndoAfterTheFileMovedOnAnyLayerIsRefused(_ how: String) async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        let block = "a\nb\nc\nd\ne\nf\n"
        let filler = "f1\nf2\nf3\nf4\nf5\n"
        try repo.write("t", "top\n" + filler + block + block + "end\n")
        try await repo.git(["add", "t"])
        try await repo.git(["commit", "-q", "-m", "t", "--", "t"])
        try repo.write("t", "top\n" + filler + block + "a\nb\nc\nNEW\nd\ne\nf\n" + "end\n")
        let file = try await loadDiff(repo, "t")
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(
            try linesRequest(file, hunks: everyHunkID(file), lines: nil), trasher: trasher, at: repo.root)
        let record = try #require(receipt.record)
        #expect(try await backend.discardExpectation(tracked: ["t"], includingStaged: false, at: repo.root) == .diffs([]))
        let between = (1...10).map { "X\($0)\n" }.joined()
        switch how {
        case "add", "commit":
            try repo.write("t", "top\n" + filler + block + between + block + "end\n")
            try await repo.git(["add", "t"])
            if how == "commit" { try await repo.git(["commit", "-q", "-m", "moved", "--", "t"]) }
        default:  // only the line endings: invisible to a diff, not to the bytes
            let lf = try repo.bytes("t")
            try Data(String(decoding: lf, as: UTF8.self).replacingOccurrences(of: "\n", with: "\r\n").utf8)
                .write(to: repo.root.appendingPathComponent("t"))
        }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let outcome = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)

        guard case .refused(_, let kept) = outcome else {
            Issue.record("expected a refusal, got \(outcome)")
            return
        }
        #expect(kept?.sha == record.sha)
        #expect(try await repo.stashShas() == [record.sha])
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// Minor 2 of fix round 2: where a checkout writes CRLF (`core.autocrlf=true`, or
    /// `eol=crlf` in `.gitattributes`) the record's blob is LF and the file CRLF. An undo right
    /// after the discard is still exact — the bytes equal the blob as a checkout writes it
    /// (`cat-file --filters`) — so it is `.restored` and the record goes.
    @Test(arguments: ["autocrlf", "attributes"])
    func aLinesUndoWhereCheckoutWritesCRLFIsRestoredAndDropsTheRecord(_ shape: String) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        if shape == "autocrlf" {
            try await repo.git(["config", "core.autocrlf", "true"])
        } else {
            try repo.write(".gitattributes", "f text eol=crlf\n")
        }
        func crlf(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8) }
        try crlf(numbered(30)).write(to: repo.root.appendingPathComponent("f"))
        try await repo.commitAll("root")
        #expect(try await repo.blob("HEAD", "f") == Data(numbered(30).utf8), "the blob is not LF")
        let edited = crlf(numbered(30, [3: "3 A", 15: "15 B", 27: "27 C"]))
        try edited.write(to: repo.root.appendingPathComponent("f"))
        let file = try await loadDiff(repo, "f")
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(
            try linesRequest(file, hunks: [try hunkID(file, containing: "15 B")], lines: nil), trasher: trasher, at: repo.root)
        #expect(try repo.bytes("f") == crlf(numbered(30, [3: "3 A", 27: "27 C"])))

        let outcome = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)

        #expect(outcome == .restored)
        #expect(try repo.bytes("f") == edited)
        #expect(try await repo.stashRef() == nil, "the record piled up")
    }

    /// Ruling 1 of fix round 1: a staged edit to `p` since a staged-side discard, HEAD unmoved.
    /// Step 1 merges it; step 2 would overwrite that staged edit with the record's index. It is
    /// skipped, and the user's staged edit stays staged.
    @Test func aStagedSideUndoOverAStagedEditSinceKeepsThatEditStaged() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await DiscardCase.stagedBothLayers.prepare(repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(
            try await DiscardCase.stagedBothLayers.request(repo), trasher: trasher, at: repo.root)
        try repo.write("p", numbered(12, [7: "7 staged since"]))
        try await repo.git(["add", "p"])
        let staged = try await repo.indexContent(of: "p")
        let head = try await repo.headSha()

        let outcome = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)

        #expect(outcome == .restoredUnstaged)
        #expect(try await repo.headSha() == head)
        #expect(try await repo.indexContent(of: "p") == staged, "the staged edit was overwritten")
        #expect(try repo.bytes("p") == Data(numbered(12, [2: "2 staged", 7: "7 staged since", 11: "11 unstaged"]).utf8))
        #expect(try await repo.stashRef() == nil)
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
