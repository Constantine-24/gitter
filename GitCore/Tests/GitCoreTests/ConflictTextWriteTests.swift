import Foundation
import Testing

@testable import GitCore

/// The resolver's two members (conflict resolver Task 1): the three stages as the editor shows
/// them (`conflictSides`), and the Result written exactly as given (`resolve(_:text:…)`).
@Suite struct ConflictTextWriteTests {
    static let backend = CLIGitBackend()

    static func snapshot(_ repo: TestRepo, _ path: String) async throws -> ConflictSnapshot {
        try await ConflictReadTests.document(repo, path).snapshot
    }

    static func crlf(_ text: String) -> Data {
        Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8)
    }

    // MARK: - The sides

    @Test func theSidesAreTheStagesInWorktreeForm() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified, prepare: { repo in
            try repo.write(".gitattributes", "* text eol=crlf\n")
        })
        defer { repo.cleanUp() }
        let snapshot = try await Self.snapshot(repo, "f.txt")

        let sides = try await Self.backend.conflictSides(snapshot, at: repo.root)

        // The literal versions, CRLF, built from the fixture's text and not from git.
        #expect(sides.ours == Self.crlf(ConflictFixtures.oursText))
        #expect(sides.base == Self.crlf(ConflictFixtures.baseText))
        #expect(sides.theirs == Self.crlf(ConflictFixtures.theirsText))
        // And what a checkout of each stage writes.
        for (stage, side) in [(2, sides.ours), (1, sides.base), (3, sides.theirs)] {
            #expect(side == (try await repo.git(["cat-file", "--filters", "--path=f.txt", ":\(stage):f.txt"])))
        }
        #expect(sides.markerSize == 7)
    }

    @Test func theSidesFollowConflictMarkerSize() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified, prepare: { repo in
            try repo.write(".gitattributes", "f.txt conflict-marker-size=11\n")
        })
        defer { repo.cleanUp() }
        let snapshot = try await Self.snapshot(repo, "f.txt")

        let sides = try await Self.backend.conflictSides(snapshot, at: repo.root)

        #expect(sides.markerSize == 11)
        #expect(sides.ours == Data(ConflictFixtures.oursText.utf8))
    }

    @Test func anAddAddHasNoBase() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothAdded)
        defer { repo.cleanUp() }
        let snapshot = try await Self.snapshot(repo, "aa.txt")

        let sides = try await Self.backend.conflictSides(snapshot, at: repo.root)

        #expect(sides == ConflictSides(
            ours: Data("one\nOURS\nthree\n".utf8), base: nil, theirs: Data("one\nTHEIRS\nthree\n".utf8),
            markerSize: 7))
    }

    /// The other absent stage: DU has no ours.
    @Test func aDeletedSideHasNoStage() async throws {
        let repo = try await ConflictFixtures.merge(kind: .deletedByUs)
        defer { repo.cleanUp() }
        let snapshot = try await Self.snapshot(repo, "du.txt")

        let sides = try await Self.backend.conflictSides(snapshot, at: repo.root)

        #expect(sides == ConflictSides(
            ours: nil, base: Data("d\n".utf8), theirs: Data("d THEIRS\n".utf8), markerSize: 7))
    }

    // MARK: - The text write

    @Test func theTextIsWrittenExactlyAndStaged() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        let snapshot = try await Self.snapshot(repo, "f.txt")
        let text = Data("one\ntwo, typed by hand\n<<<<<<< not a marker here\nten\n".utf8)

        let receipt = try await Self.backend.resolve(snapshot, text: text, recordIfEdited: false, at: repo.root)

        #expect(receipt == ConflictReceipt(path: "f.txt", recorded: nil))
        #expect(try repo.bytes("f.txt") == text)
        #expect(!(try await ConflictWriteTests.unmerged(repo, "f.txt")))
        #expect(try await repo.git(["show", ":0:f.txt"]) == text)
        let line = try await ConflictWriteTests.entry(repo, "f.txt")
        #expect(line.hasPrefix("100644 ") && line.hasSuffix(" 0\tf.txt\n"), "\(line)")
        #expect(try await repo.stashCount() == 0)
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    @Test func aCRLFFileIsWrittenExactly() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified, prepare: { repo in
            try repo.write(".gitattributes", "* text eol=crlf\n")
        })
        defer { repo.cleanUp() }
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        let snapshot = try await Self.snapshot(repo, "f.txt")
        let clean = ConflictFixtures.lines(["one", "two OURS", "two THEIRS", "three", "ten"])
        let text = Self.crlf(clean)

        _ = try await Self.backend.resolve(snapshot, text: text, recordIfEdited: false, at: repo.root)

        #expect(try repo.bytes("f.txt") == text)
        #expect(try await repo.indexContent(of: "f.txt") == Data(clean.utf8))
        // Nothing unstaged: the worktree is what the index checks out as.
        let status = String(decoding: try await repo.git(["status", "--porcelain=v2", "--", "f.txt"]), as: UTF8.self)
        #expect(status.hasPrefix("1 M. "), "\(status)")
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    /// No final-newline adjustment: the caller composes the exact bytes.
    @Test func noFinalNewlineIsKept() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let snapshot = try await Self.snapshot(repo, "f.txt")
        let text = Data("one\ntwo OURS\nten".utf8)

        _ = try await Self.backend.resolve(snapshot, text: text, recordIfEdited: false, at: repo.root)

        #expect(try repo.bytes("f.txt") == text)
        #expect(try repo.bytes("f.txt").last == UInt8(ascii: "n"))
        #expect(try await repo.indexContent(of: "f.txt") == text)
    }

    @Test func theExecutableBitSurvives() async throws {
        let repo = try await ConflictWriteTests.executableMerge()
        defer { repo.cleanUp() }
        let snapshot = try await Self.snapshot(repo, "f.txt")
        let text = Data("one\nresolved\nten\n".utf8)

        _ = try await Self.backend.resolve(snapshot, text: text, recordIfEdited: false, at: repo.root)

        #expect(try repo.bytes("f.txt") == text)
        #expect(try ConflictWriteTests.permissions(repo, "f.txt") == 0o755)
        let line = try await ConflictWriteTests.entry(repo, "f.txt")
        #expect(line.hasPrefix("100755 ") && line.hasSuffix(" 0\tf.txt\n"), "\(line)")
    }

    @Test func aMovedSnapshotIsRefused() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let snapshot = try await Self.snapshot(repo, "f.txt")
        _ = try ConflictWriteTests.handEdit(repo)
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: ConflictError.changedSinceShown("f.txt")) {
            try await Self.backend.resolve(snapshot, text: Data("x\n".utf8), recordIfEdited: true, at: repo.root)
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
        #expect(try await repo.stashCount() == 0)
        #expect(try await ConflictWriteTests.unmerged(repo, "f.txt"))
    }

    @Test func editsAreRefusedUnlessRecorded() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let edited = try ConflictWriteTests.handEdit(repo)
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await Self.snapshot(repo, "f.txt")
        let text = Data("one\nresolved\nten\n".utf8)

        await #expect(throws: ConflictError.wouldReplaceEdits("f.txt")) {
            try await Self.backend.resolve(snapshot, text: text, recordIfEdited: false, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
        #expect(try await repo.stashCount() == 0)

        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        let receipt = try await Self.backend.resolve(snapshot, text: text, recordIfEdited: true, at: repo.root)

        let recorded = try #require(receipt.recorded)
        #expect(recorded.reflogSubject == "Replaced by Gitter: f.txt")
        #expect(try await ConflictWriteTests.newestStash(repo) == recorded)
        #expect(try await repo.blob(recorded.sha, "f.txt") == edited)
        #expect(try repo.bytes("f.txt") == text)
        #expect(try await repo.indexContent(of: "f.txt") == text)
        #expect(!(try await ConflictWriteTests.unmerged(repo, "f.txt")))
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    @Test func aWholeFileConflictIsNotAvailable() async throws {
        let repo = try await ConflictFixtures.merge(kind: .deletedByUs)
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await Self.snapshot(repo, "du.txt")

        await #expect(throws: ConflictError.notAvailable("du.txt")) {
            try await Self.backend.resolve(snapshot, text: Data("x\n".utf8), recordIfEdited: true, at: repo.root)
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
        #expect(try await repo.stashCount() == 0)
        #expect(try repo.bytes("du.txt") == Data("d THEIRS\n".utf8))
    }
}
