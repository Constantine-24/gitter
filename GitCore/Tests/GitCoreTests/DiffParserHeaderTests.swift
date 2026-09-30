import Foundation
import Testing

@testable import GitCore

/// Which paths a `diff --git` header names, read from real git output.
///
/// An unquoted header is `a/<old> b/<new>` with nothing to mark where the first name ends, so a
/// name containing ` b/` is ambiguous: `diff --git a/plan b/blob.bin b/plan b/blob.bin` was read
/// greedily as `plan b/blob.bin b/plan` → `blob.bin`. A diff with `---`/`+++` lines corrected
/// that; one without them (a binary change, a mode change, an empty file) kept the wrong paths,
/// and the batched discard read dropped or misattributed it. git's own reader (`git_header_name`
/// in apply.c) splits where the two halves are the same name; a rename or copy names both
/// sides again on its own lines, and one side of a header can be quoted while the other is not.
@Suite struct DiffParserHeaderTests {

    /// A committed repository with the files these cases change.
    private static func repo() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try Data([0x00, 0x01, 0x62, 0x69, 0x6E]).write(to: try repo.url("plan b/blob.bin"))
        try Data([0x00, 0x01, 0x62, 0x69, 0x6E]).write(to: try repo.url("x b/y b/z.bin"))
        try repo.write("plan b/mode.sh", "echo\n")
        try repo.write("plan b/empty.txt", "")
        try repo.write("plan b/text.txt", "a\nb\n")
        try repo.write("x b/y b/z", "z\n")
        try repo.write("plan b/old", "o1\no2\no3\n")
        try repo.write("plan b/source", "s1\ns2\ns3\ns4\n")
        try repo.write("ordinary.txt", "o\n")
        try repo.write("tab\tname b/t.txt", "t\n")
        try repo.write("plain.txt", "p1\np2\np3\n")
        try await repo.commitAll("root")
        return repo
    }

    /// `diff` with `arguments`, parsed, and the header lines git wrote.
    private static func diff(_ repo: TestRepo, _ arguments: [String]) async throws -> (files: [FileDiff], headers: [String]) {
        let data = try await repo.git(["diff", "--no-color", "--full-index", "-U3"] + arguments)
        let headers = String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("diff --git ") }
        return (DiffParser.parse(data), headers)
    }

    private static func only(_ repo: TestRepo, _ path: String, staged: Bool = false, renames: Bool = false)
        async throws -> (file: FileDiff, header: String)
    {
        let (files, headers) = try await diff(
            repo, (staged ? ["--cached"] : []) + [renames ? "-M" : "--no-renames", "--", ":(literal)" + path])
        #expect(files.count == 1 && headers.count == 1, "\(headers)")
        return (try #require(files.first, "no diff for \(path)"), headers.first ?? "")
    }

    // MARK: - No `---`/`+++` lines: only the header names the file

    @Test func aBinaryChangeUnderAPathWithBSlash() async throws {
        let repo = try await Self.repo()
        defer { repo.cleanUp() }
        try Data([0x00, 0x02, 0x62, 0x69, 0x6E]).write(to: try repo.url("plan b/blob.bin"))

        let (file, header) = try await Self.only(repo, "plan b/blob.bin")

        #expect(header == "diff --git a/plan b/blob.bin b/plan b/blob.bin")
        #expect(file.isBinary)
        #expect(file.oldPath == "plan b/blob.bin")
        #expect(file.newPath == "plan b/blob.bin")
        #expect(file.kind == .modified)
    }

    @Test func aModeChangeUnderAPathWithBSlash() async throws {
        let repo = try await Self.repo()
        defer { repo.cleanUp() }
        try repo.chmod("plan b/mode.sh", 0o755)

        let (file, header) = try await Self.only(repo, "plan b/mode.sh")

        #expect(header == "diff --git a/plan b/mode.sh b/plan b/mode.sh")
        #expect(file.hunks.isEmpty && file.oldBlob == nil, "a mode-only diff: no hunks, no index line")
        #expect(file.oldPath == "plan b/mode.sh")
        #expect(file.newPath == "plan b/mode.sh")
    }

    @Test func anEmptyFileAddedAndOneDeletedUnderAPathWithBSlash() async throws {
        let repo = try await Self.repo()
        defer { repo.cleanUp() }
        try repo.write("plan b/new empty.txt", "")
        try await repo.git(["add", "--", "plan b/new empty.txt"])
        try await repo.git(["rm", "-q", "--", "plan b/empty.txt"])

        let (added, addedHeader) = try await Self.only(repo, "plan b/new empty.txt", staged: true)
        let (deleted, deletedHeader) = try await Self.only(repo, "plan b/empty.txt", staged: true)

        #expect(addedHeader == "diff --git a/plan b/new empty.txt b/plan b/new empty.txt")
        #expect(added.kind == .added && added.hunks.isEmpty)
        #expect(added.displayPath == "plan b/new empty.txt")
        #expect(added.newPath == "plan b/new empty.txt")
        #expect(deletedHeader == "diff --git a/plan b/empty.txt b/plan b/empty.txt")
        #expect(deleted.kind == .deleted && deleted.hunks.isEmpty)
        #expect(deleted.displayPath == "plan b/empty.txt")
        #expect(deleted.oldPath == "plan b/empty.txt")
    }

    /// Two ` b/` in the name, so two wrong places to split.
    @Test func aBinaryChangeUnderAPathWithTwoBSlashes() async throws {
        let repo = try await Self.repo()
        defer { repo.cleanUp() }
        try Data([0x00, 0x03, 0x62, 0x69, 0x6E]).write(to: try repo.url("x b/y b/z.bin"))

        let (file, header) = try await Self.only(repo, "x b/y b/z.bin")

        #expect(header == "diff --git a/x b/y b/z.bin b/x b/y b/z.bin")
        #expect(file.isBinary)
        #expect(file.oldPath == "x b/y b/z.bin")
        #expect(file.newPath == "x b/y b/z.bin")
    }

    // MARK: - With `---`/`+++` lines (right before, and still right)

    @Test(arguments: ["plan b/text.txt", "x b/y b/z", "ordinary.txt"])
    func aTextChangeKeepsItsPaths(_ path: String) async throws {
        let repo = try await Self.repo()
        defer { repo.cleanUp() }
        try repo.write(path, "changed\n")

        let (file, header) = try await Self.only(repo, path)

        #expect(header == "diff --git a/\(path) b/\(path)")
        #expect(file.oldPath == path)
        #expect(file.newPath == path)
        #expect(!file.hunks.isEmpty)
    }

    // MARK: - Renames and copies: both names again on their own lines

    /// `-M`, as the per-path staged read runs: the halves differ, and `rename from`/`rename to`
    /// name them.
    @Test func aStagedRenameUnderAPathWithBSlash() async throws {
        let repo = try await Self.repo()
        defer { repo.cleanUp() }
        try await repo.git(["mv", "plan b/old", "plan b/new"])

        let (files, headers) = try await Self.diff(repo, ["--cached", "-M"])

        #expect(headers == ["diff --git a/plan b/old b/plan b/new"])
        let file = try #require(files.first)
        #expect(files.count == 1)
        #expect(file.kind == .renamed)
        #expect(file.oldPath == "plan b/old")
        #expect(file.newPath == "plan b/new")
    }

    @Test func aStagedCopyUnderAPathWithBSlash() async throws {
        let repo = try await Self.repo()
        defer { repo.cleanUp() }
        try repo.write("plan b/copy", "s1\ns2\ns3\ns4\n")
        try await repo.git(["add", "--", "plan b/copy"])

        let (files, headers) = try await Self.diff(repo, ["--cached", "-C", "--find-copies-harder"])

        #expect(headers == ["diff --git a/plan b/source b/plan b/copy"])
        let file = try #require(files.first)
        #expect(file.kind == .copied)
        #expect(file.oldPath == "plan b/source")
        #expect(file.newPath == "plan b/copy")
    }

    // MARK: - Quoting

    /// A name with a TAB is quoted on both sides: unchanged behaviour.
    @Test func aQuotedPathOnBothSides() async throws {
        let repo = try await Self.repo()
        defer { repo.cleanUp() }
        try repo.write("tab\tname b/t.txt", "t2\n")

        let (file, header) = try await Self.only(repo, "tab\tname b/t.txt")

        #expect(header == #"diff --git "a/tab\tname b/t.txt" "b/tab\tname b/t.txt""#)
        #expect(file.oldPath == "tab\tname b/t.txt")
        #expect(file.newPath == "tab\tname b/t.txt")
    }

    /// A rename between a name git quotes and one it does not: git quotes each side of the
    /// header on its own, so one is quoted and the other is not. Such a header was not
    /// recognised at all, and the whole diff was lost.
    @Test func aRenameWithOneSideQuoted() async throws {
        let repo = try await Self.repo()
        defer { repo.cleanUp() }
        try await repo.git(["mv", "tab\tname b/t.txt", "plan b/moved.txt"])
        try FileManager.default.createDirectory(at: try repo.url("re\tn b"), withIntermediateDirectories: true)
        try await repo.git(["mv", "plain.txt", "re\tn b/x"])
        try await repo.git(["mv", "ordinary.txt", "t\tx"])

        let (files, headers) = try await Self.diff(repo, ["--cached", "-M"])

        #expect(headers == [
            #"diff --git "a/tab\tname b/t.txt" b/plan b/moved.txt"#,
            #"diff --git a/plain.txt "b/re\tn b/x""#,
            #"diff --git a/ordinary.txt "b/t\tx""#,
        ])
        #expect(files.count == 3)
        #expect(files.map(\.kind) == [.renamed, .renamed, .renamed])
        #expect(files.first?.oldPath == "tab\tname b/t.txt")
        #expect(files.first?.newPath == "plan b/moved.txt")
        #expect(files.dropFirst().first?.oldPath == "plain.txt")
        #expect(files.dropFirst().first?.newPath == "re\tn b/x")
        #expect(files.last?.oldPath == "ordinary.txt")
        #expect(files.last?.newPath == "t\tx")
    }

    // MARK: - The header alone

    /// The header by itself, with nothing after it to correct it: the split is the header's.
    @Test(arguments: [
        ("diff --git a/plan b/blob.bin b/plan b/blob.bin", "plan b/blob.bin", "plan b/blob.bin"),
        ("diff --git a/x b/y b/z b/x b/y b/z", "x b/y b/z", "x b/y b/z"),
        ("diff --git a/ordinary.txt b/ordinary.txt", "ordinary.txt", "ordinary.txt"),
        (#"diff --git a/plain.txt "b/re\tn b/x""#, "plain.txt", "re\tn b/x"),
        (#"diff --git a/plain.txt "b/t\tx""#, "plain.txt", "t\tx"),
        (#"diff --git "a/tab\tname b/t.txt" b/plan b/moved.txt"#, "tab\tname b/t.txt", "plan b/moved.txt"),
        (#"diff --git "a/q\"uote" "b/q\"uote""#, "q\"uote", "q\"uote"),
    ])
    func theHeaderAloneSplitsWhereGitDoes(_ line: String, _ old: String, _ new: String) throws {
        let header = try #require(DiffParser.parseDiffGitHeader(line))
        #expect(header.oldPath == old)
        #expect(header.newPath == new)
    }

    /// Different halves with no equal split (a rename) keep the old reading: the rename's own
    /// lines decide, as the tests above show.
    @Test func aHeaderWithDifferentHalvesStillParses() throws {
        let header = try #require(DiffParser.parseDiffGitHeader("diff --git a/plan b/old b/plan b/new"))
        #expect(header.newPath == "new", "the greedy reading, corrected by `rename to`")
        #expect(DiffParser.parseDiffGitHeader("diff --git a/x") == nil)
        #expect(DiffParser.parseDiffGitHeader(#"diff --git "a/unterminated b/x"#) == nil)
    }
}
