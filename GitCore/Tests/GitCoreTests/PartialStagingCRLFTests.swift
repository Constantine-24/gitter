import Foundation
import Testing

@testable import GitCore

/// Staging and unstaging of files, hunks and lines whose content ends in `\r\n`.
///
/// Swift reads `"\r\n"` as ONE `Character`, so a diff split on the Character `"\n"` never
/// breaks a CRLF line: a whole CRLF hunk collapsed into one line, and the patch built from it
/// was refused ("the file changed"), came out nil, or — adding `X`,`Y` to an empty file —
/// staged `X` alone. Every line has to keep its own `\r` as content and every patch has to
/// give it back byte for byte, so each case asserts the index's exact bytes.
///
/// Variants: CRLF committed with `core.autocrlf` unset or `false` (the diff carries the `\r`s);
/// `core.autocrlf=true`, where the blob is LF and the worktree CRLF (the diff carries none,
/// M 9); a file mixing LF and CRLF lines; and CRLF files that end without a newline, one of
/// them on a lone `\r`.
@Suite struct PartialStagingCRLFTests {

    static let path = "src/crlf.txt"

    enum Selection: Sendable {
        /// Every hunk, every line: the whole file through the patch.
        case all
        /// The one hunk that changes a line with exactly this text.
        case hunk(String)
        /// Exactly these changed lines (texts as the model holds them, `\r` included).
        case lines([String])
    }

    struct Case: Sendable, CustomTestStringConvertible {
        let name: String
        /// `core.autocrlf`, set before the first commit; nil leaves it unset.
        var autocrlf: String? = nil
        let head: String
        /// What `git add` is given before the diff is loaded; nil stages nothing.
        var staged: String? = nil
        let worktree: String
        let direction: PatchDirection
        let selection: Selection
        /// The index's exact bytes afterwards.
        let expected: String

        var testDescription: String { name }
    }

    /// `lines` joined and terminated with CRLF.
    static func crlf(_ lines: [String]) -> String { lines.map { $0 + "\r\n" }.joined() }
    static func lf(_ lines: [String]) -> String { lines.map { $0 + "\n" }.joined() }

    /// `l01` … `l12`.
    static let base: [String] = (1...12).map { $0 < 10 ? "l0\($0)" : "l\($0)" }

    static func edited(_ edit: (inout [String]) -> Void) -> [String] {
        var lines = base
        edit(&lines)
        return lines
    }

    /// Two hunks: `l02` → `A` and `l11` → `B` (far enough apart for `-U3` to keep them apart).
    static let twoHunks = edited { $0[1] = "A"; $0[10] = "B" }
    static let onlyA = edited { $0[1] = "A" }
    /// One hunk with context: `X` and `Y` inserted after `l06`.
    static let xy = edited { $0.insert(contentsOf: ["X", "Y"], at: 6) }
    static let onlyY = edited { $0.insert("Y", at: 6) }

    static let cases: [Case] = [
        // Committed CRLF, core.autocrlf unset. The first three are the reviewer's measurements.
        Case(
            name: "CRLF: stage a replacement of a,b by X (whole file, no context)",
            head: crlf(["a", "b"]), worktree: crlf(["X"]), direction: .stage,
            selection: .all, expected: crlf(["X"])),
        Case(
            name: "CRLF: unstage all of a staged replacement of a,b by X",
            head: crlf(["a", "b"]), staged: crlf(["X"]), worktree: crlf(["X"]),
            direction: .unstage, selection: .all, expected: crlf(["a", "b"])),
        Case(
            name: "CRLF: stage X,Y into an empty file stages both",
            head: "", worktree: crlf(["X", "Y"]), direction: .stage,
            selection: .all, expected: crlf(["X", "Y"])),
        Case(
            name: "CRLF: stage only Y of X,Y added to an empty file",
            head: "", worktree: crlf(["X", "Y"]), direction: .stage,
            selection: .lines(["Y\r"]), expected: crlf(["Y"])),
        Case(
            name: "CRLF: stage one hunk of two, with context",
            head: crlf(base), worktree: crlf(twoHunks), direction: .stage,
            selection: .hunk("A\r"), expected: crlf(onlyA)),
        Case(
            name: "CRLF: stage both hunks",
            head: crlf(base), worktree: crlf(twoHunks), direction: .stage,
            selection: .all, expected: crlf(twoHunks)),
        Case(
            name: "CRLF: stage one line of a hunk with context",
            head: crlf(base), worktree: crlf(xy), direction: .stage,
            selection: .lines(["Y\r"]), expected: crlf(onlyY)),
        Case(
            name: "CRLF: unstage one hunk of two",
            head: crlf(base), staged: crlf(twoHunks), worktree: crlf(twoHunks),
            direction: .unstage, selection: .hunk("B\r"), expected: crlf(onlyA)),
        Case(
            name: "CRLF: unstage both hunks",
            head: crlf(base), staged: crlf(twoHunks), worktree: crlf(twoHunks),
            direction: .unstage, selection: .all, expected: crlf(base)),
        Case(
            name: "CRLF: unstage one line of a hunk with context",
            head: crlf(base), staged: crlf(xy), worktree: crlf(xy),
            direction: .unstage, selection: .lines(["X\r"]), expected: crlf(onlyY)),

        // Committed CRLF with core.autocrlf=false: git leaves every byte alone, like unset.
        Case(
            name: "CRLF, autocrlf=false: stage one hunk of two", autocrlf: "false",
            head: crlf(base), worktree: crlf(twoHunks), direction: .stage,
            selection: .hunk("A\r"), expected: crlf(onlyA)),
        Case(
            name: "CRLF, autocrlf=false: unstage one line", autocrlf: "false",
            head: crlf(base), staged: crlf(xy), worktree: crlf(xy),
            direction: .unstage, selection: .lines(["X\r"]), expected: crlf(onlyY)),

        // core.autocrlf=true: the blob is LF, the worktree CRLF, and the diff has no `\r`.
        Case(
            name: "autocrlf=true: stage one hunk of two", autocrlf: "true",
            head: crlf(base), worktree: crlf(twoHunks), direction: .stage,
            selection: .hunk("A"), expected: lf(onlyA)),
        Case(
            name: "autocrlf=true: stage one line", autocrlf: "true",
            head: crlf(base), worktree: crlf(xy), direction: .stage,
            selection: .lines(["Y"]), expected: lf(onlyY)),
        Case(
            name: "autocrlf=true: stage a whole-file replacement", autocrlf: "true",
            head: crlf(["a", "b"]), worktree: crlf(["X"]), direction: .stage,
            selection: .all, expected: lf(["X"])),
        Case(
            name: "autocrlf=true: unstage one hunk of two", autocrlf: "true",
            head: crlf(base), staged: crlf(twoHunks), worktree: crlf(twoHunks),
            direction: .unstage, selection: .hunk("B"), expected: lf(onlyA)),
        Case(
            name: "autocrlf=true: unstage one line", autocrlf: "true",
            head: crlf(base), staged: crlf(xy), worktree: crlf(xy),
            direction: .unstage, selection: .lines(["X"]), expected: lf(onlyY)),

        // One file, both endings: each line keeps its own.
        Case(
            name: "mixed: stage the LF line of two added between CRLF and LF lines",
            head: "l01\r\nl02\nl03\r\nl04\nl05\r\nl06\n",
            worktree: "l01\r\nl02\nl03\r\nX\r\nY\nl04\nl05\r\nl06\n", direction: .stage,
            selection: .lines(["Y"]), expected: "l01\r\nl02\nl03\r\nY\nl04\nl05\r\nl06\n"),
        Case(
            name: "mixed: stage the CRLF line of two added between CRLF and LF lines",
            head: "l01\r\nl02\nl03\r\nl04\nl05\r\nl06\n",
            worktree: "l01\r\nl02\nl03\r\nX\r\nY\nl04\nl05\r\nl06\n", direction: .stage,
            selection: .lines(["X\r"]), expected: "l01\r\nl02\nl03\r\nX\r\nl04\nl05\r\nl06\n"),
        Case(
            name: "mixed: unstage the CRLF line",
            head: "l01\r\nl02\nl03\r\nl04\nl05\r\nl06\n",
            staged: "l01\r\nl02\nl03\r\nX\r\nY\nl04\nl05\r\nl06\n",
            worktree: "l01\r\nl02\nl03\r\nX\r\nY\nl04\nl05\r\nl06\n", direction: .unstage,
            selection: .lines(["X\r"]), expected: "l01\r\nl02\nl03\r\nY\nl04\nl05\r\nl06\n"),

        // CRLF files that end without a newline.
        Case(
            name: "no newline: stage a CRLF line added before an unterminated last line",
            head: "a\r\nb\r\nc", worktree: "a\r\nb\r\nX\r\nc", direction: .stage,
            selection: .lines(["X\r"]), expected: "a\r\nb\r\nX\r\nc"),
        Case(
            name: "no newline: stage the replacement of an unterminated last line",
            head: "a\r\nb\r\nc", worktree: "a\r\nb\r\nC", direction: .stage,
            selection: .all, expected: "a\r\nb\r\nC"),
        Case(
            name: "no newline: unstage a CRLF line added before an unterminated last line",
            head: "a\r\nb\r\nc", staged: "a\r\nX\r\nb\r\nc", worktree: "a\r\nX\r\nb\r\nc",
            direction: .unstage, selection: .lines(["X\r"]), expected: "a\r\nb\r\nc"),
        Case(
            name: "no newline: stage a line added before a last line ending on a lone CR",
            head: "a\r\nb\r", worktree: "a\r\nX\r\nb\r", direction: .stage,
            selection: .lines(["X\r"]), expected: "a\r\nX\r\nb\r"),
    ]

    @Test(arguments: cases)
    func theIndexGetsExactlyTheSelectedBytes(_ c: Case) async throws {
        let repo = try await Self.makeRepo(c)
        defer { repo.cleanUp() }
        let file = try await loadDiff(repo, Self.path, staged: c.direction == .unstage)
        let before = worktreeSnapshot(repo)
        let head = try await repo.headSha()

        try await Self.apply(c.selection, of: file, direction: c.direction, in: repo)

        let index = try await repo.indexContent(of: Self.path)
        #expect(
            index == Data(c.expected.utf8),
            "index \(String(decoding: index, as: UTF8.self).debugDescription), expected \(c.expected.debugDescription)")
        #expect(try await repo.headSha() == head)
        assertWorktreeUnchanged(repo, since: before)
    }

    /// Staging a selection and then unstaging the very same lines from the staged diff puts
    /// the index back to HEAD's bytes exactly.
    @Test(arguments: cases.filter { $0.direction == .stage && $0.head != "" })
    func stagingThenUnstagingTheSameLinesRestoresTheIndex(_ c: Case) async throws {
        let repo = try await Self.makeRepo(c)
        defer { repo.cleanUp() }
        let original = try await repo.git(["show", "HEAD:" + Self.path])
        #expect(try await repo.indexContent(of: Self.path) == original)

        try await Self.apply(
            c.selection, of: try await loadDiff(repo, Self.path), direction: .stage, in: repo)
        #expect(try await repo.indexContent(of: Self.path) != original)
        try await Self.apply(
            c.selection, of: try await loadDiff(repo, Self.path, staged: true),
            direction: .unstage, in: repo)

        let index = try await repo.indexContent(of: Self.path)
        #expect(
            index == original,
            "index \(String(decoding: index, as: UTF8.self).debugDescription)")
    }

    /// The model keeps each line's `\r`: a CRLF hunk is as many lines as the file has.
    @Test func aCRLFDiffIsOneModelLinePerFileLineEachKeepingItsCR() async throws {
        let repo = try await Self.makeRepo(
            Case(
                name: "", head: Self.crlf(Self.base), worktree: Self.crlf(Self.xy), direction: .stage,
                selection: .all, expected: ""))
        defer { repo.cleanUp() }
        let file = try await loadDiff(repo, Self.path)
        let hunk = try #require(file.hunks.first)
        #expect(file.hunks.count == 1)
        #expect(hunk.lines.count == 8)
        #expect(hunk.lines.map(\.text) == ["l04\r", "l05\r", "l06\r", "X\r", "Y\r", "l07\r", "l08\r", "l09\r"])
        #expect(hunk.lines.map(\.kind) == [.context, .context, .context, .added, .added, .context, .context, .context])
        #expect(hunk.lines.map(\.newNumber) == [4, 5, 6, 7, 8, 9, 10, 11])
    }

    // MARK: - Support

    static func makeRepo(_ c: Case) async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        if let autocrlf = c.autocrlf {
            try await repo.git(["config", "core.autocrlf", autocrlf])
        }
        try repo.write(path, c.head)
        try await repo.commitAll("root")
        if let staged = c.staged {
            try repo.write(path, staged)
            try await repo.git(["add", "--", path])
        }
        try repo.write(path, c.worktree)
        return repo
    }

    static func apply(
        _ selection: Selection, of file: FileDiff, direction: PatchDirection, in repo: TestRepo,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        switch selection {
        case .all:
            try await applySelection(repo, file, direction: direction, sourceLocation: sourceLocation)
        case .hunk(let text):
            try await applySelection(
                repo, file, direction: direction, hunks: [try hunkID(file, containing: text)],
                sourceLocation: sourceLocation)
        case .lines(let texts):
            let ids = Set(
                file.hunks.flatMap(\.lines)
                    .filter { ($0.kind == .added || $0.kind == .removed) && texts.contains($0.text) }
                    .map(\.id))
            #expect(ids.count == texts.count, "selected \(ids.count) of \(texts)", sourceLocation: sourceLocation)
            try await applySelection(
                repo, file, direction: direction, lines: ids, sourceLocation: sourceLocation)
        }
    }
}
