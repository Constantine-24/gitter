import Foundation
import Testing

@testable import GitCore

/// A merge stopped on `f.txt` from three texts given byte for byte (no final newline added).
func threeWayMerge(
    base: String?, ours: String?, theirs: String?, name: String = "f.txt",
    prepare: @Sendable (TestRepo) async throws -> Void = { _ in }
) async throws -> TestRepo {
    let repo = try await TestRepo.makeEmpty()
    try await prepare(repo)
    func place(_ text: String?) throws {
        let url = repo.root.appendingPathComponent(name)
        try? FileManager.default.removeItem(at: url)
        if let text {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
    }
    try repo.write("keep.txt", "keep\n")
    try place(base)
    try await repo.commitAll("base")
    try await repo.git(["switch", "-q", "-c", "theirs"])
    try place(theirs)
    try await repo.commitAll("theirs")
    try await repo.git(["switch", "-q", "main"])
    try place(ours)
    try await repo.commitAll("ours")
    try await repo.git(["merge", "--no-edit", "theirs"], allowedExitCodes: [1])
    try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")
    return repo
}

// MARK: - Ruling 9: the file ends as the last side written ends

/// merge-file ends every side of a block with a line terminator, so a stage whose last line
/// has none looks, in a block at the end of the file, as if it had one. Taking all of one side
/// must give exactly that side's blob.
@Suite struct FinalNewlineTests {
    static let backend = CLIGitBackend()

    enum Setting: String, CaseIterable, Sendable {
        case plain, diff3, zdiff3, autocrlf, eolCRLF, smudgeFilter, crlfCommitted

        var eol: String { self == .crlfCommitted ? "\r\n" : "\n" }

        func apply(_ repo: TestRepo) async throws {
            switch self {
            case .plain, .crlfCommitted: break
            case .diff3: try await repo.git(["config", "merge.conflictStyle", "diff3"])
            case .zdiff3: try await repo.git(["config", "merge.conflictStyle", "zdiff3"])
            case .autocrlf: try await repo.git(["config", "core.autocrlf", "true"])
            case .eolCRLF: try repo.write(".gitattributes", "*.txt text eol=crlf\n")
            case .smudgeFilter:
                // perl -p keeps a last line without a newline as it is; sed would add one.
                try await repo.git(["config", "filter.at.smudge", #"perl -pe 's/\@\@/SMUDGED/'"#])
                try await repo.git(["config", "filter.at.clean", #"perl -pe 's/SMUDGED/\@\@/'"#])
                try repo.write(".gitattributes", "f.txt filter=at\n")
            }
        }
    }

    enum Ending: String, CaseIterable, Sendable {
        case bothHave, oursLacks, theirsLacks, bothLack
        var ours: Bool { self == .bothHave || self == .theirsLacks }
        var theirs: Bool { self == .bothHave || self == .oursLacks }
    }

    /// Two blocks: line 2, and the last line, which ends the file.
    static func text(_ two: [String], _ last: [String], finalNewline: Bool, eol: String) -> String {
        let lines = ["one"] + two + ["three", "four @@", "five", "six", "seven", "eight"] + last
        return lines.joined(separator: eol) + (finalNewline ? eol : "")
    }

    @Test(arguments: Setting.allCases, Ending.allCases)
    func everyChoiceEndsTheFileAsItsLastSideDoes(setting: Setting, ending: Ending) async throws {
        let eol = setting.eol
        for choice in [BlockChoice.ours, .theirs, .oursThenTheirs, .theirsThenOurs] {
            let repo = try await threeWayMerge(
                base: Self.text(["two"], ["last"], finalNewline: true, eol: eol),
                ours: Self.text(["two OURS"], ["last OURS"], finalNewline: ending.ours, eol: eol),
                theirs: Self.text(["two THEIRS"], ["last THEIRS"], finalNewline: ending.theirs, eol: eol),
                prepare: setting.apply)
            defer { repo.cleanUp() }
            let stages = try #require(try await ConflictFixtures.stages(repo)["f.txt"])
            let ours = try #require(stages[2]), theirs = try #require(stages[3])
            let snapshot = try await ConflictWriteTests.snapshot(repo, "f.txt")
            let label = "\(setting) \(ending) \(choice)"

            _ = try await Self.backend.resolve(snapshot, choices: [choice, choice], recordIfEdited: false, at: repo.root)

            let line = try await repo.indexLine("f.txt")
            let gitsForm = try await repo.git(["cat-file", "--filters", "--path=f.txt", ":f.txt"])
            #expect(try repo.bytes("f.txt") == gitsForm, "\(label)")
            switch choice {
            case .ours:
                #expect(line == "\(ours.mode) \(ours.blob) 0\tf.txt\n", "\(label)")
            case .theirs:
                #expect(line == "\(theirs.mode) \(theirs.blob) 0\tf.txt\n", "\(label)")
            case .oursThenTheirs:
                let expected = Self.text(
                    ["two OURS", "two THEIRS"], ["last OURS", "last THEIRS"], finalNewline: ending.theirs,
                    eol: eol)
                #expect(try await repo.indexContent(of: "f.txt") == Data(expected.utf8), "\(label)")
            case .theirsThenOurs:
                let expected = Self.text(
                    ["two THEIRS", "two OURS"], ["last THEIRS", "last OURS"], finalNewline: ending.ours,
                    eol: eol)
                #expect(try await repo.indexContent(of: "f.txt") == Data(expected.utf8), "\(label)")
            }
        }
    }

    /// An add/add (no base) and a side that deleted the tail, each way round.
    @Test(arguments: [
        ("add/add, ours lacks", nil, "x\nOURS", "x\nTHEIRS\n"),
        ("add/add, theirs lacks", nil, "x\nOURS\n", "x\nTHEIRS"),
        ("ours deleted the tail, theirs lacks", "a\nb\nc\n", "a\n", "a\nb\nc T"),
        ("theirs deleted the tail, ours lacks", "a\nb\nc\n", "a\nb\nc O", "a\n"),
    ] as [(String, String?, String, String)])
    func takingEverythingFromOneSideIsThatSidesBlob(label: String, base: String?, ours: String, theirs: String) async throws {
        for side in [ConflictSide.ours, .theirs] {
            let repo = try await threeWayMerge(base: base, ours: ours, theirs: theirs)
            defer { repo.cleanUp() }
            let stage = try #require(try await ConflictFixtures.stages(repo)["f.txt"]?[side == .ours ? 2 : 3])
            let document = try await ConflictReadTests.document(repo, "f.txt")
            let blocks = try #require(ConflictReadTests.blocks(document), "\(label): \(document.presentation)")

            _ = try await Self.backend.resolve(
                document.snapshot, choices: Array(repeating: side == .ours ? .ours : .theirs, count: blocks.count),
                recordIfEdited: false, at: repo.root)

            #expect(try await repo.indexLine("f.txt") == "\(stage.mode) \(stage.blob) 0\tf.txt\n", "\(label) \(side)")
            #expect(try repo.bytes("f.txt") == Data((side == .ours ? ours : theirs).utf8), "\(label) \(side)")
        }
    }
}

extension FinalNewlineTests {
    /// Fix round 2: what the rebuild added is decided against the stage's own ending. A file
    /// whose lines are not CRLF gets a lone `\n` after a last line ending in `\r` — stripping
    /// two bytes there deleted content.
    @Test(arguments: [
        ("LF file, last lines end in a lone CR", "a\nb\nlast\n", "a\nb\nlast O\r", "a\nb\nlast T\r", false,
         "a\nb\nlast O\r\nlast T\r", "a\nb\nlast T\r\nlast O\r"),
        ("CR-only file", "a\rb\rc\r", "a\rO\rc\r", "a\rT\rc\r", false,
         "a\rO\rc\r\na\rT\rc\r", "a\rT\rc\r\na\rO\rc\r"),
        ("autocrlf, ours ends in a lone CR", "a\nb\nlast\n", "a\nb\nlast O\r", "a\nb\nlast T\n", true, nil, nil),
        ("CRLF file, last lines end in a lone CR", "a\r\nb\r\nlast\r\n", "a\r\nb\r\nlast O\r", "a\r\nb\r\nlast T\r", false,
         nil, nil),
    ] as [(String, String, String, String, Bool, String?, String?)])
    func aLastLineEndingInACarriageReturnKeepsIt(
        label: String, base: String, ours: String, theirs: String, autocrlf: Bool, oursThenTheirs: String?,
        theirsThenOurs: String?
    ) async throws {
        for choice in [BlockChoice.ours, .theirs, .oursThenTheirs, .theirsThenOurs] {
            let repo = try await threeWayMerge(base: base, ours: ours, theirs: theirs) { repo in
                if autocrlf { try await repo.git(["config", "core.autocrlf", "true"]) }
            }
            defer { repo.cleanUp() }
            let stages = try #require(try await ConflictFixtures.stages(repo)["f.txt"])
            let document = try await ConflictReadTests.document(repo, "f.txt")
            let blocks = try #require(ConflictReadTests.blocks(document), "\(label): \(document.presentation)")

            _ = try await Self.backend.resolve(
                document.snapshot, choices: Array(repeating: choice, count: blocks.count), recordIfEdited: false,
                at: repo.root)

            let what = "\(label) \(choice)"
            // Under autocrlf git converts no text holding a lone CR (measured): its own conflict
            // file, the rebuild and so the resolution keep LF, where a checkout of the result
            // alone would write CRLF. The index is exact, and nothing shows as unstaged.
            let gitsForm = try await repo.git(["cat-file", "--filters", "--path=f.txt", ":f.txt"])
            if autocrlf {
                let status = String(decoding: try await repo.git(["status", "--porcelain=v2", "--", "f.txt"]), as: UTF8.self)
                #expect(status.hasPrefix("1 M. ") || status.isEmpty, "\(what): \(status)")
            } else {
                #expect(try repo.bytes("f.txt") == gitsForm, "\(what)")
            }
            switch choice {
            case .ours, .theirs:
                let stage = try #require(stages[choice == .ours ? 2 : 3])
                #expect(try await repo.indexLine("f.txt") == "\(stage.mode) \(stage.blob) 0\tf.txt\n", "\(what)")
                let stageForm = try await repo.git(["cat-file", "--filters", "--path=f.txt", stage.blob])
                if !autocrlf { #expect(try repo.bytes("f.txt") == stageForm, "\(what)") }
            case .oursThenTheirs:
                if let oursThenTheirs {
                    #expect(try await repo.indexContent(of: "f.txt") == Data(oursThenTheirs.utf8), "\(what)")
                }
            case .theirsThenOurs:
                if let theirsThenOurs {
                    #expect(try await repo.indexContent(of: "f.txt") == Data(theirsThenOurs.utf8), "\(what)")
                }
            }
        }
    }
}

// MARK: - A path whose type changed

/// `restore --ours|--theirs` over a directory, or under a leading component that is now a file,
/// deletes what is there and exits 0 — and a record refuses a type-changed path. Every write
/// refuses first, with nothing written.
@Suite struct PathTypeChangedTests {
    static let backend = CLIGitBackend()

    enum Shape: String, CaseIterable, Sendable {
        /// `f.txt` (UU) is now a directory holding `f.txt/precious`.
        case directoryAtAConflictedFile
        /// `du.txt` (DU) is now a directory holding `du.txt/precious`.
        case directoryAtADeletion
        /// `sub/p.txt` (UU): `sub` is now an untracked file.
        case fileAtALeadingDirectory

        var path: String {
            switch self {
            case .directoryAtAConflictedFile: return "f.txt"
            case .directoryAtADeletion: return "du.txt"
            case .fileAtALeadingDirectory: return "sub/p.txt"
            }
        }

        /// The untracked item that must survive, and its bytes.
        var precious: String {
            switch self {
            case .directoryAtAConflictedFile: return "f.txt/precious"
            case .directoryAtADeletion: return "du.txt/precious"
            case .fileAtALeadingDirectory: return "sub"
            }
        }

        func make() async throws -> TestRepo {
            let repo: TestRepo
            switch self {
            case .directoryAtAConflictedFile: repo = try await ConflictFixtures.merge(kind: .bothModified)
            case .directoryAtADeletion: repo = try await ConflictFixtures.merge(kind: .deletedByUs)
            case .fileAtALeadingDirectory:
                repo = try await threeWayMerge(base: "a\nb\nc\n", ours: "a\nO\nc\n", theirs: "a\nT\nc\n", name: "sub/p.txt")
            }
            try FileManager.default.removeItem(at: repo.root.appendingPathComponent(self == .fileAtALeadingDirectory ? "sub" : path))
            try repo.write(precious, "PRECIOUS\n")
            return repo
        }
    }

    enum Write: String, CaseIterable, Sendable {
        case takeOurs, takeTheirs, keep, delete, resolve, markResolved

        func run(_ snapshot: ConflictSnapshot, at root: URL) async throws {
            let backend = PathTypeChangedTests.backend
            switch self {
            case .takeOurs: _ = try await backend.take(.ours, snapshot, recordIfEdited: true, at: root)
            case .takeTheirs: _ = try await backend.take(.theirs, snapshot, recordIfEdited: true, at: root)
            case .keep: _ = try await backend.keep(snapshot, recordIfEdited: true, at: root)
            case .delete: _ = try await backend.delete(snapshot, recordIfEdited: true, at: root)
            case .resolve: _ = try await backend.resolve(snapshot, choices: [.ours], recordIfEdited: true, at: root)
            case .markResolved: try await backend.markResolved(snapshot, allowingMarkers: true, at: root)
            }
        }
    }

    @Test(arguments: Shape.allCases, Write.allCases)
    func aWriteOverAChangedPathTypeWritesNothing(shape: Shape, write: Write) async throws {
        let repo = try await shape.make()
        defer { repo.cleanUp() }
        let snapshot = try await ConflictWriteTests.snapshot(repo, shape.path)
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        #expect(worktree[shape.precious] == Data("PRECIOUS\n".utf8))

        await #expect(throws: ConflictError.pathTypeChanged(shape.path)) {
            try await write.run(snapshot, at: repo.root)
        }

        #expect(try repo.bytes(shape.precious) == Data("PRECIOUS\n".utf8))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
        #expect(try await repo.stashCount() == 0)
    }

    /// `restore --merge` over a directory where the resolution was: refused the same way.
    @Test func reopenOverADirectoryWritesNothing() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        try await ReopenTests.resolveUU(repo)
        #expect(try await Self.backend.canReopen("f.txt", at: repo.root))
        try repo.remove("f.txt")
        try repo.write("f.txt/precious", "PRECIOUS\n")
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: ConflictError.pathTypeChanged("f.txt")) {
            try await Self.backend.reopen("f.txt", expectingWorktreeHash: nil, at: repo.root)
        }

        #expect(try repo.bytes("f.txt/precious") == Data("PRECIOUS\n".utf8))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
        #expect(try await repo.stashCount() == 0)
    }
}

// MARK: - Leftover markers under odd names

@Suite struct LeftoverMarkerNameTests {
    static let backend = CLIGitBackend()

    /// `diff --check` prints the name raw: a newline in it splits the record, and a `:3:` in it
    /// looks like a line number.
    @Test(arguments: ["new\nline.txt", "odd:3: name.txt"])
    func markResolvedRefusesMarkersUnderAnOddName(name: String) async throws {
        let repo = try await threeWayMerge(base: "a\nb\nc\n", ours: "a\nO\nc\n", theirs: "a\nT\nc\n", name: name)
        defer { repo.cleanUp() }
        #expect(try await Self.backend.leftoverMarkers(in: name, at: repo.root) == 1)
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await ConflictWriteTests.snapshot(repo, name)

        await #expect(throws: ConflictError.leftoverMarkers(1)) {
            try await Self.backend.markResolved(snapshot, allowingMarkers: false, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
    }

    @Test func recordsAreReadAcrossTheWholeOutput() {
        let output = Data("new\nline.txt:2: leftover conflict marker\nnew\nline.txt:4: leftover conflict marker\n".utf8)
        #expect(CLIGitBackend.leftoverMarkerLines(in: output, path: "new\nline.txt") == [2, 4])
    }

    /// Fail closed: git said "leftover conflict marker" and no record could be read.
    @Test func anUnreadableReportStillCountsAsMarkers() {
        let output = Data("\"quoted\\nname\":2: leftover conflict marker\n".utf8)
        #expect(CLIGitBackend.leftoverMarkerLines(in: output, path: "quoted\nname") == nil)
    }

    /// Whitespace errors share `diff --check`'s exit code; they are not markers.
    @Test func whitespaceErrorsAreNotMarkers() async throws {
        let output = Data("f.txt:3: trailing whitespace.\n+b  \n".utf8)
        #expect(CLIGitBackend.leftoverMarkerLines(in: output, path: "f.txt") == [])

        let repo = try await threeWayMerge(base: "a\nb\nc\n", ours: "a\nO\nc\n", theirs: "a\nT\nc\n")
        defer { repo.cleanUp() }
        try repo.write("f.txt", "a\nMINE  \nc\n")
        #expect(try await Self.backend.leftoverMarkers(in: "f.txt", at: repo.root) == 0)
    }
}

// MARK: - Leftover markers git's check cannot see

/// Fix round 2 (Ruling 15), measured: under `-diff`, or a diff driver with `binary=true`,
/// `diff --check` prints nothing and exits 0 while the merge still wrote markers. The guard
/// cannot rest on it alone.
@Suite struct LeftoverMarkerAttributeTests {
    static let backend = CLIGitBackend()

    enum Attributes: String, CaseIterable, Sendable {
        case unsetDiff, binaryDiffDriver, markerSize9, unsetDiffMarkerSize9

        func apply(_ repo: TestRepo) async throws {
            switch self {
            case .unsetDiff: try repo.write(".gitattributes", "f.txt -diff\n")
            case .binaryDiffDriver:
                try await repo.git(["config", "diff.bin.binary", "true"])
                try repo.write(".gitattributes", "f.txt diff=bin\n")
            case .markerSize9: try repo.write(".gitattributes", "f.txt conflict-marker-size=9\n")
            case .unsetDiffMarkerSize9: try repo.write(".gitattributes", "f.txt -diff conflict-marker-size=9\n")
            }
        }
    }

    static func merge(_ attributes: Attributes) async throws -> TestRepo {
        try await threeWayMerge(base: "a\nb\nc\n", ours: "a\nO\nc\n", theirs: "a\nT\nc\n", prepare: attributes.apply)
    }

    @Test(arguments: Attributes.allCases)
    func markersLeftAreRefusedWhateverTheDiffAttributes(attributes: Attributes) async throws {
        let repo = try await Self.merge(attributes)
        defer { repo.cleanUp() }
        #expect(String(decoding: try repo.bytes("f.txt"), as: UTF8.self).contains("<<<<<<<"), "git wrote no markers")
        #expect(try await Self.backend.leftoverMarkers(in: "f.txt", at: repo.root) == 1)
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let snapshot = try await ConflictWriteTests.snapshot(repo, "f.txt")

        await #expect(throws: ConflictError.leftoverMarkers(1)) {
            try await Self.backend.markResolved(snapshot, allowingMarkers: false, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
    }

    @Test(arguments: Attributes.allCases)
    func aCleanResolutionHasNoneWhateverTheDiffAttributes(attributes: Attributes) async throws {
        let repo = try await Self.merge(attributes)
        defer { repo.cleanUp() }
        try repo.write("f.txt", "a\nMINE\nc\n")
        #expect(try await Self.backend.leftoverMarkers(in: "f.txt", at: repo.root) == 0)
        let snapshot = try await ConflictWriteTests.snapshot(repo, "f.txt")

        try await Self.backend.markResolved(snapshot, allowingMarkers: false, at: repo.root)

        #expect(try await repo.indexContent(of: "f.txt") == Data("a\nMINE\nc\n".utf8))
    }

    /// Final review M4: a hand resolution that kept only a block's closing marker (or its
    /// separator too) — under `-diff` git's check is blind, and the opening-marker scan found
    /// nothing. A closing marker at the path's size counts; a separator alone does not (a
    /// Markdown heading underline is exactly `=======`).
    @Test(arguments: [Attributes.unsetDiff, .unsetDiffMarkerSize9])
    func aLeftoverClosingMarkerIsCountedUnderUnsetDiff(attributes: Attributes) async throws {
        let repo = try await Self.merge(attributes)
        defer { repo.cleanUp() }
        let size = attributes == .unsetDiffMarkerSize9 ? 9 : 7
        let closing = String(repeating: ">", count: size)
        let separator = String(repeating: "=", count: size)
        try repo.write("f.txt", "a\nMINE\n\(closing) feature\nc\n")
        #expect(try await Self.backend.leftoverMarkers(in: "f.txt", at: repo.root) == 1)
        try repo.write("f.txt", "a\nMINE\n\(separator)\nT\n\(closing)\nc\n")
        #expect(try await Self.backend.leftoverMarkers(in: "f.txt", at: repo.root) == 1)
        try repo.write("f.txt", "Title\n\(separator)\nMINE\n")
        #expect(try await Self.backend.leftoverMarkers(in: "f.txt", at: repo.root) == 0)
    }

    @Test func theScanCountsClosingMarkersAtTheGivenSize() {
        let text = Data("a\n>>>>>>> t\n>>>>>>>\r\n>>>>>>>> wider\n>>>>>>>x\n=======\n".utf8)
        #expect(CLIGitBackend.closingMarkers(in: text, markerSize: 7) == 2)
        #expect(CLIGitBackend.closingMarkers(in: text, markerSize: 8) == 1)
        #expect(CLIGitBackend.closingMarkers(in: Data("a\n=======\nb\n".utf8), markerSize: 7) == 0)
    }

    /// The scan counts git's own opening marker — exactly the path's size of `<`, then a space
    /// or the end of the line — and nothing else.
    @Test func theScanCountsOpeningMarkersAtTheGivenSize() {
        let text = Data("a\n<<<<<<< HEAD\nO\n=======\nT\n>>>>>>> t\n<<<<<<<\r\nx\n<<<<<<<< wider\n<<<<<<<x\n=======\n".utf8)
        #expect(CLIGitBackend.openingMarkers(in: text, markerSize: 7) == 2)
        #expect(CLIGitBackend.openingMarkers(in: text, markerSize: 8) == 1)
        #expect(CLIGitBackend.openingMarkers(in: Data("a\n=======\nb\n".utf8), markerSize: 7) == 0)
    }
}
