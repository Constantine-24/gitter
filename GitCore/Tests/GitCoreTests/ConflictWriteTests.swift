import Darwin
import Foundation
import Testing

@testable import GitCore

// MARK: - What a conflict write may change

/// Everything a write to one conflicted path must leave alone: every other index entry, every
/// other worktree entry (type, permission bits, bytes or link target), HEAD, every ref but
/// `refs/stash`, and the operation's files (the M 20 fingerprint without `ls-files -u -s`,
/// which the index entries above already cover path by path).
struct WriteBaseline {
    let path: String
    let otherIndexEntries: [String]
    let otherWorktree: [String: WorktreeEntry]
    let head: String
    let symbolicHead: String
    let refsOtherThanStash: String
    let operation: [String: String]

    static func capture(_ repo: TestRepo, path: String) async throws -> WriteBaseline {
        let state = try await RepoState.capture(repo)
        var worktree = worktreeState(repo)
        worktree[path] = nil
        var operation = try await OperationState.capture(repo).fingerprint
        operation["ls-files -u -s"] = nil
        return WriteBaseline(
            path: path, otherIndexEntries: try await otherEntries(repo, path),
            otherWorktree: worktree, head: state.head, symbolicHead: state.symbolicHead,
            refsOtherThanStash: try await refs(repo), operation: operation)
    }

    /// `ls-files -s -z` records of every path but `path`.
    static func otherEntries(_ repo: TestRepo, _ path: String) async throws -> [String] {
        let data = try await repo.git(["ls-files", "-s", "-z"])
        return String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
            .filter { $0.split(separator: "\t", maxSplits: 1).last.map(String.init) != path }
    }

    static func refs(_ repo: TestRepo) async throws -> String {
        let data = try await repo.git(["for-each-ref", "--format=%(objectname) %(refname)"])
        return String(decoding: data, as: UTF8.self).split(separator: "\n")
            .filter { !$0.hasSuffix(" refs/stash") }.joined(separator: "\n")
    }
}

/// Asserts that nothing but `baseline.path`'s index entries, its worktree entry and
/// `refs/stash` changed. Fails on an empty baseline.
func assertOnlyThePathChanged(
    _ repo: TestRepo, since baseline: WriteBaseline, sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    #expect(!baseline.otherIndexEntries.isEmpty && !baseline.otherWorktree.isEmpty,
            "the baseline is empty, so comparing against it proves nothing", sourceLocation: sourceLocation)
    let now = try await WriteBaseline.capture(repo, path: baseline.path)
    #expect(now.otherIndexEntries == baseline.otherIndexEntries, "another index entry changed",
            sourceLocation: sourceLocation)
    for path in Set(now.otherWorktree.keys).union(baseline.otherWorktree.keys).sorted()
    where now.otherWorktree[path] != baseline.otherWorktree[path] {
        let was = baseline.otherWorktree[path]?.description ?? "<absent>"
        let is_ = now.otherWorktree[path]?.description ?? "<absent>"
        Issue.record("worktree \(path) was \(was), is \(is_)", sourceLocation: sourceLocation)
    }
    #expect(now.head == baseline.head && now.symbolicHead == baseline.symbolicHead, "HEAD moved",
            sourceLocation: sourceLocation)
    #expect(now.refsOtherThanStash == baseline.refsOtherThanStash, "a ref other than refs/stash changed",
            sourceLocation: sourceLocation)
    for name in Set(now.operation.keys).union(baseline.operation.keys).sorted()
    where now.operation[name] != baseline.operation[name] {
        Issue.record("the operation's \(name) changed", sourceLocation: sourceLocation)
    }
}

/// Proves `assertOnlyThePathChanged` can fail on each thing it guards.
@Suite struct WriteBaselineTests {
    @Test func failsWhenAnotherWorktreeFileChanges() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")

        try repo.write("keep.txt", "keep CHANGED\n")

        await withKnownIssue("keep.txt really changed") {
            try await assertOnlyThePathChanged(repo, since: baseline)
        }
    }

    @Test func failsWhenTheOperationsMessageChanges() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        #expect(baseline.operation["MERGE_MSG"] != nil)

        try Data("other\n".utf8).write(to: try await ConflictFixtures.gitPath(repo, "MERGE_MSG"))

        await withKnownIssue("MERGE_MSG really changed") {
            try await assertOnlyThePathChanged(repo, since: baseline)
        }
    }

    @Test func thePathItselfMayChange() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")

        try repo.write("f.txt", "resolved\n")
        try await repo.git(["add", "--", "f.txt"])
        try await repo.git(["update-ref", "refs/stash", "HEAD"])

        try await assertOnlyThePathChanged(repo, since: baseline)
    }
}

// MARK: - Writes

@Suite struct ConflictWriteTests {
    static let backend = CLIGitBackend()

    static func snapshot(_ repo: TestRepo, _ path: String) async throws -> ConflictSnapshot {
        try await ConflictReadTests.document(repo, path).snapshot
    }

    /// The fixture's ten lines (`ConflictFixtures.baseText`) with line 2 and line 9 as given —
    /// built from the known lines, never from the parser.
    static func fixtureText(_ two: [String], _ nine: [String], eol: String = "\n", five: String = "five @@") -> Data {
        let lines = ["one"] + two + ["three", "four", five, "six", "seven", "eight"] + nine + ["ten"]
        return Data(lines.map { $0 + eol }.joined().utf8)
    }

    static func lines(_ choice: BlockChoice, ours: String, theirs: String) -> [String] {
        switch choice {
        case .ours: return [ours]
        case .theirs: return [theirs]
        case .oursThenTheirs: return [ours, theirs]
        case .theirsThenOurs: return [theirs, ours]
        }
    }

    /// `ls-files -s -- p` as one line: `<mode> <oid> <stage>\t<path>\n` per entry.
    static func entry(_ repo: TestRepo, _ path: String) async throws -> String {
        try await repo.indexLine(path)
    }

    static func permissions(_ repo: TestRepo, _ path: String) throws -> Int {
        let attributes = try FileManager.default.attributesOfItem(atPath: repo.root.appendingPathComponent(path).path)
        return (attributes[.posixPermissions] as? Int ?? 0) & 0o777
    }

    static func exists(_ repo: TestRepo, _ path: String) -> Bool {
        var info = stat()
        return lstat(repo.root.appendingPathComponent(path).path, &info) == 0
    }

    static func unmerged(_ repo: TestRepo, _ path: String) async throws -> Bool {
        !(try await repo.git(["ls-files", "-u", "--", ":(literal)" + path])).isEmpty
    }

    /// The newest stash entry, as the backend lists it.
    static func newestStash(_ repo: TestRepo) async throws -> Stash? {
        try await backend.stashes(at: repo.root).first
    }

    /// A merge stopped on `f.txt` with two blocks, every version 100755.
    static func executableMerge() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        func place(_ text: String) throws {
            try repo.write("f.txt", text)
            try repo.chmod("f.txt", 0o755)
        }
        try repo.write("keep.txt", "keep\n")
        try place(ConflictFixtures.baseText)
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "theirs"])
        try place(ConflictFixtures.theirsText)
        try await repo.commitAll("theirs change")
        try await repo.git(["switch", "-q", "main"])
        try place(ConflictFixtures.oursText)
        try await repo.commitAll("ours change")
        try await repo.git(["merge", "--no-edit", "theirs"], allowedExitCodes: [1])
        try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")
        #expect(try await entry(repo, "f.txt").hasPrefix("100755 "))
        return repo
    }

    // MARK: - Resolve by blocks

    static let choiceCases: [[BlockChoice]] = [
        [.ours, .ours], [.theirs, .theirs], [.oursThenTheirs, .oursThenTheirs],
        [.theirsThenOurs, .theirsThenOurs], [.ours, .theirs], [.theirsThenOurs, .ours],
    ]

    @Test(arguments: choiceCases)
    func resolveWritesTheComposedBytesAndStagesThem(choices: [BlockChoice]) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        let snapshot = try await Self.snapshot(repo, "f.txt")

        let receipt = try await Self.backend.resolve(snapshot, choices: choices, recordIfEdited: false, at: repo.root)

        let expected = Self.fixtureText(
            Self.lines(choices[0], ours: "two OURS", theirs: "two THEIRS"),
            Self.lines(choices[1], ours: "nine OURS", theirs: "nine THEIRS"))
        #expect(receipt == ConflictReceipt(path: "f.txt", recorded: nil))
        #expect(try repo.bytes("f.txt") == expected)
        #expect(try await repo.indexContent(of: "f.txt") == expected)
        let line = try await Self.entry(repo, "f.txt")
        #expect(line.hasPrefix("100644 ") && line.hasSuffix(" 0\tf.txt\n"), "\(line)")
        #expect(try Self.permissions(repo, "f.txt") == 0o644)
        #expect(try await repo.stashCount() == 0)
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    /// RF1: content lines that look like markers are content, byte for byte.
    @Test func markerLikeContentSurvivesAResolution() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("keep.txt", "keep\n")
        try repo.write("f.txt", "top\nx\nmiddle\nm2\nm3\nm4\nm5\ny\nbottom\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "theirs"])
        try repo.write("f.txt", "top\n=======\nT\n>>>>>>> fake\nmiddle\nm2\nm3\nm4\nm5\n|||||||\nbottom\n")
        try await repo.commitAll("theirs")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", "top\n<<<<<<< fake\nO\n=======\nmiddle\nm2\nm3\nm4\nm5\n<<<<<<<<\nbottom\n")
        try await repo.commitAll("ours")
        try await repo.git(["merge", "--no-edit", "theirs"], allowedExitCodes: [1])
        try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        let snapshot = try await Self.snapshot(repo, "f.txt")

        _ = try await Self.backend.resolve(
            snapshot, choices: [.oursThenTheirs, .theirs], recordIfEdited: false, at: repo.root)

        let expected = Data(
            "top\n<<<<<<< fake\nO\n=======\n=======\nT\n>>>>>>> fake\nmiddle\nm2\nm3\nm4\nm5\n|||||||\nbottom\n".utf8)
        #expect(try repo.bytes("f.txt") == expected)
        #expect(try await repo.indexContent(of: "f.txt") == expected)
        #expect(!(try await Self.unmerged(repo, "f.txt")))
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    enum Conversion: String, CaseIterable, Sendable {
        case autocrlf, eolCRLF, smudgeAndClean, executable
    }

    /// RF2: the worktree is what git would write for the new index blob (`cat-file --filters`),
    /// the index holds the clean form, and the executable bit is kept.
    @Test(arguments: Conversion.allCases)
    func aResolutionIsInGitsFormInTheWorktreeAndCleanInTheIndex(conversion: Conversion) async throws {
        let repo: TestRepo
        switch conversion {
        case .autocrlf: repo = try await ConflictFixtures.merge(kind: .bothModified, prepare: ConflictReadTests.Setting.autocrlf.apply)
        case .eolCRLF: repo = try await ConflictFixtures.merge(kind: .bothModified, prepare: ConflictReadTests.Setting.eolCRLF.apply)
        case .smudgeAndClean: repo = try await ConflictFixtures.merge(kind: .bothModified, prepare: ConflictReadTests.Setting.smudgeFilter.apply)
        case .executable: repo = try await Self.executableMerge()
        }
        defer { repo.cleanUp() }
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        let snapshot = try await Self.snapshot(repo, "f.txt")

        _ = try await Self.backend.resolve(snapshot, choices: [.theirs, .ours], recordIfEdited: false, at: repo.root)

        let clean = Self.fixtureText(["two THEIRS"], ["nine OURS"])
        #expect(try await repo.indexContent(of: "f.txt") == clean)
        let gitsForm = try await repo.git(["cat-file", "--filters", "--path=f.txt", ":f.txt"])
        #expect(try repo.bytes("f.txt") == gitsForm)
        switch conversion {
        case .autocrlf, .eolCRLF:
            #expect(gitsForm == Self.fixtureText(["two THEIRS"], ["nine OURS"], eol: "\r\n"))
        case .smudgeAndClean:
            #expect(gitsForm == Self.fixtureText(["two THEIRS"], ["nine OURS"], five: "five SMUDGED"))
        case .executable:
            #expect(gitsForm == clean)
        }
        let line = try await Self.entry(repo, "f.txt")
        let mode = conversion == .executable ? "100755" : "100644"
        #expect(line.hasPrefix(mode + " ") && line.hasSuffix(" 0\tf.txt\n"), "\(line)")
        #expect(try Self.permissions(repo, "f.txt") == (conversion == .executable ? 0o755 : 0o644))
        // Nothing unstaged: the worktree is exactly what the index checks out as.
        let status = String(decoding: try await repo.git(["status", "--porcelain=v2", "--", "f.txt"]), as: UTF8.self)
        #expect(status.hasPrefix("1 M. "), "\(status)")
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    @Test func tooFewOrTooManyChoicesAreRefused() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await Self.snapshot(repo, "f.txt")

        for choices: [BlockChoice] in [[.ours], [.ours, .ours, .ours], []] {
            await #expect(throws: ConflictError.choicesDoNotMatch("f.txt")) {
                try await Self.backend.resolve(snapshot, choices: choices, recordIfEdited: true, at: repo.root)
            }
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
    }

    @Test(arguments: [ConflictFixtureKind.binary, .symlink, .modeOnly, .deletedByUs, .mergeBinary, .submodule])
    func blocksAreNotAvailableOnAWholeFilePath(kind: ConflictFixtureKind) async throws {
        let repo = try await ConflictFixtures.merge(kind: kind)
        defer { repo.cleanUp() }
        let path = kind.unmergedPaths[0]
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await Self.snapshot(repo, path)

        await #expect(throws: ConflictError.notAvailable(path)) {
            try await Self.backend.resolve(snapshot, choices: [.ours], recordIfEdited: true, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
    }

    @Test func aSubmoduleConflictIsNotWrittenByAnything() async throws {
        let repo = try await ConflictFixtures.merge(kind: .submodule)
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await Self.snapshot(repo, "sub")

        for side in [ConflictSide.ours, .theirs] {
            await #expect(throws: ConflictError.notAvailable("sub")) {
                try await Self.backend.take(side, snapshot, recordIfEdited: true, at: repo.root)
            }
        }
        await #expect(throws: ConflictError.notAvailable("sub")) {
            try await Self.backend.delete(snapshot, recordIfEdited: true, at: repo.root)
        }
        await #expect(throws: ConflictError.notAvailable("sub")) {
            try await Self.backend.keep(snapshot, recordIfEdited: true, at: repo.root)
        }
        await #expect(throws: ConflictError.notAvailable("sub")) {
            try await Self.backend.markResolved(snapshot, allowingMarkers: true, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
    }

    // MARK: - Take a side

    static let takeCases: [(ConflictFixtureKind, ConflictSide)] = [
        ConflictFixtureKind.bothModified, .binary, .symlink, .modeOnly, .bothAdded, .mergeBinary,
    ].flatMap { kind in [ConflictSide.ours, .theirs].map { (kind, $0) } }

    @Test(arguments: takeCases)
    func takeStagesExactlyThatSidesEntry(kind: ConflictFixtureKind, side: ConflictSide) async throws {
        let repo = try await ConflictFixtures.merge(kind: kind)
        defer { repo.cleanUp() }
        let path = kind.unmergedPaths[0]
        let stage = try #require(try await ConflictFixtures.stages(repo)[path]?[side == .ours ? 2 : 3])
        let baseline = try await WriteBaseline.capture(repo, path: path)
        let snapshot = try await Self.snapshot(repo, path)

        let receipt = try await Self.backend.take(side, snapshot, recordIfEdited: false, at: repo.root)

        #expect(receipt == ConflictReceipt(path: path, recorded: nil))
        #expect(try await Self.entry(repo, path) == "\(stage.mode) \(stage.blob) 0\t\(path)\n")
        if stage.mode == "120000" {
            let target = try FileManager.default.destinationOfSymbolicLink(atPath: repo.root.appendingPathComponent(path).path)
            #expect(Data(target.utf8) == (try await repo.git(["cat-file", "blob", stage.blob])))
        } else {
            #expect(try repo.bytes(path) == (try await repo.git(["cat-file", "--filters", "--path=\(path)", stage.blob])))
            #expect(try Self.permissions(repo, path) == (stage.mode == "100755" ? 0o755 : 0o644))
        }
        #expect(try await repo.stashCount() == 0)
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    /// M 27: `restore --theirs` on UD exits 0 and deletes the file. Refused before git runs.
    @Test(arguments: [(ConflictFixtureKind.deletedByThem, ConflictSide.theirs), (.deletedByUs, .ours), (.renameDelete, .theirs)])
    func takingASideWithNoStageIsRefused(kind: ConflictFixtureKind, side: ConflictSide) async throws {
        let repo = try await ConflictFixtures.merge(kind: kind)
        defer { repo.cleanUp() }
        let path = kind.unmergedPaths[0]
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        #expect(worktree[path] != nil)
        let snapshot = try await Self.snapshot(repo, path)

        await #expect(throws: ConflictError.stageMissing(path, side)) {
            try await Self.backend.take(side, snapshot, recordIfEdited: true, at: repo.root)
        }

        #expect(Self.exists(repo, path))
        #expect(try await Self.unmerged(repo, path))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
    }

    // MARK: - Delete and keep

    @Test func deletingAnUntouchedDURecordsNothing() async throws {
        let repo = try await ConflictFixtures.merge(kind: .deletedByUs)
        defer { repo.cleanUp() }
        #expect(try repo.bytes("du.txt") == Data("d THEIRS\n".utf8))
        let baseline = try await WriteBaseline.capture(repo, path: "du.txt")
        let snapshot = try await Self.snapshot(repo, "du.txt")

        let receipt = try await Self.backend.delete(snapshot, recordIfEdited: false, at: repo.root)

        #expect(receipt == ConflictReceipt(path: "du.txt", recorded: nil))
        #expect(try await Self.entry(repo, "du.txt") == "")
        #expect(!Self.exists(repo, "du.txt"))
        #expect(try await repo.stashCount() == 0)
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    /// M 28: `rm` of an edited DU file deletes it without a word — the edit is filed first.
    @Test func deletingAnEditedDURecordsTheEditFirst() async throws {
        let repo = try await ConflictFixtures.merge(kind: .deletedByUs)
        defer { repo.cleanUp() }
        try repo.write("du.txt", "d EDITED\n")
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await Self.snapshot(repo, "du.txt")

        await #expect(throws: ConflictError.wouldReplaceEdits("du.txt")) {
            try await Self.backend.delete(snapshot, recordIfEdited: false, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)

        let baseline = try await WriteBaseline.capture(repo, path: "du.txt")
        let receipt = try await Self.backend.delete(snapshot, recordIfEdited: true, at: repo.root)

        let recorded = try #require(receipt.recorded)
        #expect(recorded.reflogSubject == "Replaced by Gitter: du.txt")
        #expect(try await Self.newestStash(repo) == recorded)
        #expect(try await repo.blob(recorded.sha, "du.txt") == Data("d EDITED\n".utf8))
        #expect(try await Self.entry(repo, "du.txt") == "")
        #expect(!Self.exists(repo, "du.txt"))
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    @Test func keepingDUStagesTheirs() async throws {
        let repo = try await ConflictFixtures.merge(kind: .deletedByUs)
        defer { repo.cleanUp() }
        let theirs = try #require(try await ConflictFixtures.stages(repo)["du.txt"]?[3])
        let baseline = try await WriteBaseline.capture(repo, path: "du.txt")
        let snapshot = try await Self.snapshot(repo, "du.txt")

        let receipt = try await Self.backend.keep(snapshot, recordIfEdited: false, at: repo.root)

        #expect(receipt == ConflictReceipt(path: "du.txt", recorded: nil))
        #expect(try await Self.entry(repo, "du.txt") == "\(theirs.mode) \(theirs.blob) 0\tdu.txt\n")
        #expect(try repo.bytes("du.txt") == Data("d THEIRS\n".utf8))
        #expect(try await repo.stashCount() == 0)
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    @Test func keepingAnEditedDURecordsTheEditAndPutsTheirsBack() async throws {
        let repo = try await ConflictFixtures.merge(kind: .deletedByUs)
        defer { repo.cleanUp() }
        let theirs = try #require(try await ConflictFixtures.stages(repo)["du.txt"]?[3])
        try repo.write("du.txt", "d EDITED\n")
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await Self.snapshot(repo, "du.txt")

        await #expect(throws: ConflictError.wouldReplaceEdits("du.txt")) {
            try await Self.backend.keep(snapshot, recordIfEdited: false, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)

        let baseline = try await WriteBaseline.capture(repo, path: "du.txt")
        let receipt = try await Self.backend.keep(snapshot, recordIfEdited: true, at: repo.root)

        let recorded = try #require(receipt.recorded)
        #expect(recorded.reflogSubject == "Replaced by Gitter: du.txt")
        #expect(try await repo.blob(recorded.sha, "du.txt") == Data("d EDITED\n".utf8))
        #expect(try await Self.entry(repo, "du.txt") == "\(theirs.mode) \(theirs.blob) 0\tdu.txt\n")
        #expect(try repo.bytes("du.txt") == Data("d THEIRS\n".utf8))
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    @Test func keepingUDStagesOurs() async throws {
        let repo = try await ConflictFixtures.merge(kind: .deletedByThem)
        defer { repo.cleanUp() }
        let ours = try #require(try await ConflictFixtures.stages(repo)["ud.txt"]?[2])
        let baseline = try await WriteBaseline.capture(repo, path: "ud.txt")
        let snapshot = try await Self.snapshot(repo, "ud.txt")

        let receipt = try await Self.backend.keep(snapshot, recordIfEdited: false, at: repo.root)

        #expect(receipt == ConflictReceipt(path: "ud.txt", recorded: nil))
        #expect(try await Self.entry(repo, "ud.txt") == "\(ours.mode) \(ours.blob) 0\tud.txt\n")
        #expect(try repo.bytes("ud.txt") == Data("u OURS\n".utf8))
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    /// M 28: `add` of a UD path whose file is gone records a deletion, not a keep.
    @Test func keepingUDWithTheFileGonePutsOursBack() async throws {
        let repo = try await ConflictFixtures.merge(kind: .deletedByThem)
        defer { repo.cleanUp() }
        let ours = try #require(try await ConflictFixtures.stages(repo)["ud.txt"]?[2])
        try repo.remove("ud.txt")
        let baseline = try await WriteBaseline.capture(repo, path: "ud.txt")
        let snapshot = try await Self.snapshot(repo, "ud.txt")
        #expect(snapshot.worktreeHash == nil)

        let receipt = try await Self.backend.keep(snapshot, recordIfEdited: false, at: repo.root)

        #expect(receipt.recorded == nil)
        #expect(try await Self.entry(repo, "ud.txt") == "\(ours.mode) \(ours.blob) 0\tud.txt\n")
        #expect(try repo.bytes("ud.txt") == Data("u OURS\n".utf8))
        #expect(try await repo.stashCount() == 0)
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    @Test(arguments: [ConflictFixtureKind.bothModified, .bothAdded, .binary, .renameRename])
    func keepIsOnlyForADeletion(kind: ConflictFixtureKind) async throws {
        let repo = try await ConflictFixtures.merge(kind: kind)
        defer { repo.cleanUp() }
        let path = kind.unmergedPaths[0]
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await Self.snapshot(repo, path)

        await #expect(throws: ConflictError.notAvailable(path)) {
            try await Self.backend.keep(snapshot, recordIfEdited: true, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
    }

    // MARK: - Bytes git did not write

    static func handEdit(_ repo: TestRepo) throws -> Data {
        let written = String(decoding: try repo.bytes("f.txt"), as: UTF8.self)
        let edited = written.replacingOccurrences(of: "four\n", with: "four HAND EDIT\n")
        #expect(edited != written)
        try Data(edited.utf8).write(to: repo.root.appendingPathComponent("f.txt"))
        return Data(edited.utf8)
    }

    @Test func resolvingAHandEditedFileRecordsItFirst() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let edited = try Self.handEdit(repo)
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await Self.snapshot(repo, "f.txt")

        await #expect(throws: ConflictError.wouldReplaceEdits("f.txt")) {
            try await Self.backend.resolve(snapshot, choices: [.ours, .ours], recordIfEdited: false, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)

        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        let receipt = try await Self.backend.resolve(snapshot, choices: [.ours, .ours], recordIfEdited: true, at: repo.root)

        let recorded = try #require(receipt.recorded)
        #expect(recorded.reflogSubject == "Replaced by Gitter: f.txt")
        #expect(try await repo.blob(recorded.sha, "f.txt") == edited)
        // The entry's index side is HEAD's: an unmerged path has no staged version of its own.
        #expect(try await repo.blob("\(recorded.sha)^2", "f.txt") == (try await repo.blob("HEAD", "f.txt")))
        let expected = Self.fixtureText(["two OURS"], ["nine OURS"])
        #expect(try repo.bytes("f.txt") == expected)
        #expect(try await repo.indexContent(of: "f.txt") == expected)
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    @Test func takingASideOfAHandEditedFileRecordsItFirst() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let edited = try Self.handEdit(repo)
        let theirs = try #require(try await ConflictFixtures.stages(repo)["f.txt"]?[3])
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await Self.snapshot(repo, "f.txt")

        await #expect(throws: ConflictError.wouldReplaceEdits("f.txt")) {
            try await Self.backend.take(.theirs, snapshot, recordIfEdited: false, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)

        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        let receipt = try await Self.backend.take(.theirs, snapshot, recordIfEdited: true, at: repo.root)

        let recorded = try #require(receipt.recorded)
        #expect(recorded.reflogSubject == "Replaced by Gitter: f.txt")
        #expect(try await repo.blob(recorded.sha, "f.txt") == edited)
        #expect(try await Self.entry(repo, "f.txt") == "\(theirs.mode) \(theirs.blob) 0\tf.txt\n")
        #expect(try repo.bytes("f.txt") == Data(ConflictFixtures.theirsText.utf8))
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    // MARK: - RF3: changed since shown

    enum Write: String, CaseIterable, Sendable {
        case resolve, takeOurs, takeTheirs, delete, markResolved

        func run(_ snapshot: ConflictSnapshot, at root: URL) async throws {
            let backend = ConflictWriteTests.backend
            switch self {
            case .resolve: _ = try await backend.resolve(snapshot, choices: [.ours, .theirs], recordIfEdited: true, at: root)
            case .takeOurs: _ = try await backend.take(.ours, snapshot, recordIfEdited: true, at: root)
            case .takeTheirs: _ = try await backend.take(.theirs, snapshot, recordIfEdited: true, at: root)
            case .delete: _ = try await backend.delete(snapshot, recordIfEdited: true, at: root)
            case .markResolved: try await backend.markResolved(snapshot, allowingMarkers: true, at: root)
            }
        }
    }

    @Test(arguments: Write.allCases)
    func aFileChangedAfterItWasShownIsNotWritten(write: Write) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let snapshot = try await Self.snapshot(repo, "f.txt")
        _ = try Self.handEdit(repo)
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: ConflictError.changedSinceShown("f.txt")) {
            try await write.run(snapshot, at: repo.root)
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
        #expect(try await repo.stashCount() == 0)
    }

    @Test func keepOfADUChangedAfterItWasShownIsNotWritten() async throws {
        let repo = try await ConflictFixtures.merge(kind: .deletedByUs)
        defer { repo.cleanUp() }
        let snapshot = try await Self.snapshot(repo, "du.txt")
        try repo.write("du.txt", "d EDITED\n")
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: ConflictError.changedSinceShown("du.txt")) {
            try await Self.backend.keep(snapshot, recordIfEdited: true, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
    }

    @Test(arguments: Write.allCases)
    func aPathStagedAfterItWasShownIsNotWritten(write: Write) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let snapshot = try await Self.snapshot(repo, "f.txt")
        try await repo.git(["add", "--", "f.txt"])
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: ConflictError.changedSinceShown("f.txt")) {
            try await write.run(snapshot, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
    }

    @Test(arguments: Write.allCases)
    func aMergeAbortedAfterItWasShownIsNotWritten(write: Write) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let snapshot = try await Self.snapshot(repo, "f.txt")
        try await repo.git(["merge", "--abort"])
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: ConflictError.changedSinceShown("f.txt")) {
            try await write.run(snapshot, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
    }

    // MARK: - RF4: names

    @Test func eachSpecialNameIsResolvedAlone() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let names = ConflictReadTests.specialNames
        try repo.write("keep.txt", "keep\n")
        for name in names { try repo.write(name, "a\nb\nc\n") }
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "theirs"])
        for name in names { try repo.write(name, "a\nb THEIRS \(name)\nc\n") }
        try await repo.commitAll("theirs")
        try await repo.git(["switch", "-q", "main"])
        for name in names { try repo.write(name, "a\nb OURS \(name)\nc\n") }
        try await repo.commitAll("ours")
        try await repo.git(["merge", "--no-edit", "theirs"], allowedExitCodes: [1])
        try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")

        for (n, name) in names.enumerated() {
            let baseline = try await WriteBaseline.capture(repo, path: name)
            let snapshot = try await Self.snapshot(repo, name)
            let write = n % 3
            switch write {
            case 0: _ = try await Self.backend.resolve(snapshot, choices: [.theirs], recordIfEdited: false, at: repo.root)
            case 1: _ = try await Self.backend.take(.theirs, snapshot, recordIfEdited: false, at: repo.root)
            default: try await Self.backend.markResolved(snapshot, allowingMarkers: true, at: repo.root)
            }
            if write == 2 {
                #expect(try await repo.indexContent(of: name) == (try repo.bytes(name)), "\(name)")
            } else {
                #expect(try repo.bytes(name) == Data("a\nb THEIRS \(name)\nc\n".utf8), "\(name)")
                #expect(try await repo.indexContent(of: name) == Data("a\nb THEIRS \(name)\nc\n".utf8), "\(name)")
            }
            #expect(!(try await Self.unmerged(repo, name)), "\(name)")
            // Every later name is still unmerged, with its bytes: the baseline covers them.
            try await assertOnlyThePathChanged(repo, since: baseline)
            for later in names.dropFirst(n + 1) {
                #expect(try await Self.unmerged(repo, later), "\(later) was resolved with \(name)")
            }
        }
    }

    @Test func eachSpecialNameIsDeletedAlone() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let names = ConflictReadTests.specialNames
        try repo.write("keep.txt", "keep\n")
        for name in names { try repo.write(name, "d\n") }
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "theirs"])
        for name in names { try repo.write(name, "d THEIRS\n") }
        try await repo.commitAll("theirs")
        try await repo.git(["switch", "-q", "main"])
        for name in names { try repo.remove(name) }
        try await repo.commitAll("ours deletes")
        try await repo.git(["merge", "--no-edit", "theirs"], allowedExitCodes: [1])
        try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")

        for (n, name) in names.enumerated() {
            let baseline = try await WriteBaseline.capture(repo, path: name)
            let snapshot = try await Self.snapshot(repo, name)
            if n.isMultiple(of: 2) {
                _ = try await Self.backend.delete(snapshot, recordIfEdited: false, at: repo.root)
                #expect(!Self.exists(repo, name), "\(name)")
                #expect(try await Self.entry(repo, name) == "", "\(name)")
            } else {
                _ = try await Self.backend.keep(snapshot, recordIfEdited: false, at: repo.root)
                #expect(try repo.bytes(name) == Data("d THEIRS\n".utf8), "\(name)")
            }
            try await assertOnlyThePathChanged(repo, since: baseline)
        }
    }

    // MARK: - Mark resolved

    @Test(arguments: [ConflictReadTests.Setting.plain, .diff3, .markerSize9, .autocrlf])
    func markResolvedRefusesLeftoverMarkers(setting: ConflictReadTests.Setting) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified, prepare: setting.apply)
        defer { repo.cleanUp() }
        #expect(try await Self.backend.leftoverMarkers(in: "f.txt", at: repo.root) == 2)
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await Self.snapshot(repo, "f.txt")

        await #expect(throws: ConflictError.leftoverMarkers(2)) {
            try await Self.backend.markResolved(snapshot, allowingMarkers: false, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)

        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        try await Self.backend.markResolved(snapshot, allowingMarkers: true, at: repo.root)

        #expect(!(try await Self.unmerged(repo, "f.txt")))
        let gitsForm = try await repo.git(["cat-file", "--filters", "--path=f.txt", ":f.txt"])
        #expect(try repo.bytes("f.txt") == gitsForm)
        #expect(try await repo.stashCount() == 0)
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    @Test func leftoverMarkersCountsTheBlocksTheUserHasNotResolved() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let written = String(decoding: try repo.bytes("f.txt"), as: UTF8.self)
        let first = "<<<<<<< HEAD\ntwo OURS\n=======\ntwo THEIRS\n>>>>>>> theirs\n"
        let second = "<<<<<<< HEAD\nnine OURS\n=======\nnine THEIRS\n>>>>>>> theirs\n"
        #expect(written.contains(first) && written.contains(second))

        try repo.write("f.txt", written.replacingOccurrences(of: first, with: "two MINE\n"))
        #expect(try await Self.backend.leftoverMarkers(in: "f.txt", at: repo.root) == 1)

        try repo.write(
            "f.txt",
            written.replacingOccurrences(of: first, with: "two MINE\n").replacingOccurrences(of: second, with: "nine MINE\n"))
        #expect(try await Self.backend.leftoverMarkers(in: "f.txt", at: repo.root) == 0)
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        let snapshot = try await Self.snapshot(repo, "f.txt")
        try await Self.backend.markResolved(snapshot, allowingMarkers: false, at: repo.root)
        #expect(try await repo.indexContent(of: "f.txt") == (try repo.bytes("f.txt")))
        #expect(try await Self.entry(repo, "f.txt").hasSuffix(" 0\tf.txt\n"))
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    @Test func aBinaryConflictHasNoMarkersToCount() async throws {
        let repo = try await ConflictFixtures.merge(kind: .binary)
        defer { repo.cleanUp() }
        #expect(try await Self.backend.leftoverMarkers(in: "bin.dat", at: repo.root) == 0)
        let ours = try #require(try await ConflictFixtures.stages(repo)["bin.dat"]?[2])
        let baseline = try await WriteBaseline.capture(repo, path: "bin.dat")
        let snapshot = try await Self.snapshot(repo, "bin.dat")

        try await Self.backend.markResolved(snapshot, allowingMarkers: false, at: repo.root)

        // git left ours in the worktree; that is what is staged.
        #expect(try await Self.entry(repo, "bin.dat") == "\(ours.mode) \(ours.blob) 0\tbin.dat\n")
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    // MARK: - No operation

    @Test func resolveAndTakeWorkWithNoOperation() async throws {
        let repo = try await ConflictFixtures.stashApplyConflict()
        defer { repo.cleanUp() }
        #expect(try await Self.backend.operationInProgress(at: repo.root) == nil)
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        let snapshot = try await Self.snapshot(repo, "f.txt")

        let receipt = try await Self.backend.resolve(snapshot, choices: [.theirs, .ours], recordIfEdited: false, at: repo.root)

        #expect(receipt.recorded == nil)
        let expected = Self.fixtureText(["two THEIRS"], ["nine OURS"])
        #expect(try repo.bytes("f.txt") == expected)
        #expect(try await repo.indexContent(of: "f.txt") == expected)
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    @Test func takeWorksWithNoOperation() async throws {
        let repo = try await ConflictFixtures.stashApplyConflict()
        defer { repo.cleanUp() }
        let theirs = try #require(try await ConflictFixtures.stages(repo)["f.txt"]?[3])
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        let snapshot = try await Self.snapshot(repo, "f.txt")

        let receipt = try await Self.backend.take(.theirs, snapshot, recordIfEdited: false, at: repo.root)

        #expect(receipt.recorded == nil)
        #expect(try await Self.entry(repo, "f.txt") == "\(theirs.mode) \(theirs.blob) 0\tf.txt\n")
        try await assertOnlyThePathChanged(repo, since: baseline)
    }

    // MARK: - Every operation

    @Test(arguments: ConflictOperation.allCases)
    func resolveLeavesEveryOperationsStateAlone(operation: ConflictOperation) async throws {
        let repo = try await ConflictFixtures.stopped(operation, kind: .bothModified)
        defer { repo.cleanUp() }
        let baseline = try await WriteBaseline.capture(repo, path: "f.txt")
        #expect(baseline.operation[operation.marker] != nil || operation == .rebase)
        let snapshot = try await Self.snapshot(repo, "f.txt")

        let receipt = try await Self.backend.resolve(snapshot, choices: [.ours, .theirs], recordIfEdited: false, at: repo.root)

        #expect(receipt.recorded == nil)
        #expect(!(try await Self.unmerged(repo, "f.txt")))
        try await assertOnlyThePathChanged(repo, since: baseline)
    }
}

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
