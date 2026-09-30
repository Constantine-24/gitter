import Foundation
import Testing

@testable import GitCore

/// Final review I1: Discard All… scaled by process spawns — two git processes per path for the
/// sheet's read, one `ls-files` per path in the record's survey and one `update-index` per
/// index entry (200 modified files: the sheet 3.3 s, the discard 6.7 s). The reads are batched
/// now; these tests pin that the number of git processes no longer grows with the number of
/// files, and that the batched reads give exactly what the per-path ones gave.
@Suite struct DiscardScalingTests {
    private let backend = CLIGitBackend()

    // MARK: - A git that counts

    /// A shell script standing in for `/usr/bin/git`: it writes its first argument (the
    /// subcommand) to `log`, one line per process, then execs the real git.
    private struct CountingGit {
        let directory: URL
        var wrapper: URL { directory.appendingPathComponent("git") }
        var log: URL { directory.appendingPathComponent("log") }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitter-counting-git-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = """
                #!/bin/sh
                printf '%s\\n' "$1" >> '\(directory.path)/log'
                exec /usr/bin/git "$@"
                """
            try script.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        }

        /// The subcommands run since the last call, and the log emptied.
        func take() throws -> [String] {
            guard FileManager.default.fileExists(atPath: log.path) else { return [] }
            let text = try String(contentsOf: log, encoding: .utf8)
            try FileManager.default.removeItem(at: log)
            return text.split(separator: "\n").map(String.init)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    /// `count` committed files, each then changed in the worktree — and, with `staged`, first
    /// changed and staged on another line.
    private static func repo(files count: Int, staged: Bool) async throws -> (TestRepo, [String]) {
        let repo = try await TestRepo.makeEmpty()
        let paths = (0..<count).map { "dir\($0 % 3)/file\($0).txt" }
        for path in paths { try repo.write(path, numbered(12)) }
        try await repo.commitAll("root")
        if staged {
            for path in paths { try repo.write(path, numbered(12, [2: "2 staged"])) }
            try await repo.git(["add", "--"] + paths)
        }
        for path in paths { try repo.write(path, numbered(12, [2: staged ? "2 staged" : "2", 11: "11 unstaged"])) }
        return (repo, paths)
    }

    /// The git subcommands one sheet read, one discard and its undo run, for `count` files.
    private func processes(files count: Int, staged: Bool) async throws -> (sheet: [String], discard: [String], undo: [String]) {
        let (repo, paths) = try await Self.repo(files: count, staged: staged)
        defer { repo.cleanUp() }
        let git = try CountingGit()
        defer { git.cleanUp() }
        let counted = CLIGitBackend(gitPath: git.wrapper.path)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }

        let expected = try await counted.discardExpectation(tracked: paths, includingStaged: staged, at: repo.root)
        let sheet = try git.take()
        guard case .diffs(let diffs) = expected else {
            Issue.record("not a tracked expectation")
            return ([], [], [])
        }
        #expect(diffs.count == count * (staged ? 2 : 1), "the read found \(diffs.count) diffs")
        let request: DiscardRequest =
            staged
            ? .stagedAndUnstaged(paths: paths, expected: expected) : .unstaged(paths: paths, expected: expected)
        let receipt = try await counted.discard(request, trasher: trasher, at: repo.root)
        let discard = try git.take()
        #expect(try await counted.undoDiscard(receipt, trasher: trasher, at: repo.root) == .restored)
        return (sheet, discard, try git.take())
    }

    /// The same git processes for 3 files as for 12: nothing runs once per path.
    @Test(arguments: [false, true])
    func theNumberOfGitProcessesDoesNotGrowWithTheFiles(staged: Bool) async throws {
        let few = try await processes(files: 3, staged: staged)
        let many = try await processes(files: 12, staged: staged)

        #expect(!few.sheet.isEmpty && !few.discard.isEmpty && !few.undo.isEmpty, "the wrapper counted nothing")
        #expect(many.sheet == few.sheet, "the sheet's read: \(few.sheet.count) → \(many.sheet.count) processes")
        #expect(many.discard == few.discard, "the discard: \(few.discard.count) → \(many.discard.count) processes")
        #expect(many.undo == few.undo, "the undo: \(few.undo.count) → \(many.undo.count) processes")
    }

    // MARK: - The batched read is the per-path read

    /// The read the sheet was built from before the batching, spelled as it was: per path, the
    /// staged side, then the unstaged side when the index has an entry for the path.
    private func perPathExpectation(_ paths: [String], includingStaged: Bool, _ repo: TestRepo) async throws
        -> DiscardExpectation
    {
        var diffs: [FileDiff] = []
        for path in paths {
            if includingStaged {
                diffs += try await backend.workingCopyDiff(at: repo.root, path: path, staged: true)
            }
            if !(try await repo.git(["ls-files", "-z", "--", ":(literal)" + path])).isEmpty {
                diffs += try await backend.workingCopyDiff(at: repo.root, path: path, staged: false)
            }
        }
        return .diffs(diffs)
    }

    /// A mixed set, each file its own shape: modified, deleted, a mode change, CRLF lines, a
    /// staged rename (its source is a path of its own, as the app passes both), bytes that are
    /// not UTF-8, a file with a staged and an unstaged layer, a staged new file and a staged
    /// deletion — every FileDiff must be the one the per-path read gave, in the same order. And
    /// under `plan b/`, whose headers are ambiguous and have no `---`/`+++` lines to settle them:
    /// a binary change, a mode change, an empty file deleted and one added.
    @Test(arguments: [false, true])
    func theBatchedReadIsThePerPathRead(includingStaged: Bool) async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try Data("one\r\ntwo\r\nthree\r\n".utf8).write(to: repo.root.appendingPathComponent("crlf"))
        try Data([0x63, 0x61, 0x66, 0xE9, 0x0A, 0x6F, 0x6B, 0x0A]).write(to: repo.root.appendingPathComponent("latin1"))
        try repo.write("gone", "gone\n")
        try repo.write("plan b/mode.sh", "echo\n")
        try repo.write("plan b/empty.txt", "")
        try Data([0x00, 0x01, 0x62]).write(to: repo.root.appendingPathComponent("plan b/blob.bin"))
        try await repo.commitAll("more")

        try repo.write("p", numbered(12, [5: "5 mod"]))
        try repo.remove("d")
        try repo.chmod("s.sh", 0o755)
        try Data("one\r\nTWO\r\nthree\r\n".utf8).write(to: repo.root.appendingPathComponent("crlf"))
        try Data([0x63, 0x61, 0x66, 0xE8, 0x0A, 0x6F, 0x6B, 0x0A]).write(to: repo.root.appendingPathComponent("latin1"))
        try await repo.git(["mv", "old", "new"])
        try repo.write("new", "o1\no2\no3\no4\no5\no6\n")
        try repo.write("f3", numbered(30, [3: "3 staged"]))
        try await repo.git(["add", "f3"])
        try repo.write("f3", numbered(30, [3: "3 staged", 27: "27 unstaged"]))
        try repo.write("n", "n1\n")
        try await repo.git(["add", "n"])
        try await repo.git(["rm", "-q", "gone"])
        try Data([0x00, 0x02, 0x62]).write(to: repo.root.appendingPathComponent("plan b/blob.bin"))
        try repo.chmod("plan b/mode.sh", 0o755)
        try repo.remove("plan b/empty.txt")
        try repo.write("plan b/new empty.txt", "")
        try await repo.git(["add", "--", "plan b/new empty.txt"])
        // `h` and `k` are unchanged here: a path with nothing to show is in the set too.
        let paths = [
            "p", "d", "s.sh", "crlf", "latin1", "new", "old", "f3", "n", "gone", "h", "k",
            "plan b/blob.bin", "plan b/mode.sh", "plan b/empty.txt", "plan b/new empty.txt",
        ]

        let batched = try await backend.discardExpectation(tracked: paths, includingStaged: includingStaged, at: repo.root)
        let perPath = try await perPathExpectation(paths, includingStaged: includingStaged, repo)

        #expect(batched == perPath)
        guard case .diffs(let diffs) = perPath else {
            Issue.record("not a tracked expectation")
            return
        }
        // Not vacuous: every shape is in the set.
        #expect(diffs.count == (includingStaged ? 16 : 10), "\(diffs.map(\.displayPath))")
        #expect(diffs.contains { $0.displayPath == "d" && $0.kind == .deleted })
        #expect(diffs.contains { $0.displayPath == "s.sh" && $0.hunks.isEmpty })
        #expect(diffs.contains { $0.displayPath == "crlf" && $0.hunks.flatMap(\.lines).contains { $0.text.hasSuffix("\r") } })
        #expect(diffs.contains { $0.displayPath == "latin1" && !$0.isValidUTF8 })
        #expect(diffs.contains { $0.displayPath == "plan b/blob.bin" && $0.isBinary })
        #expect(diffs.contains { $0.displayPath == "plan b/mode.sh" && $0.hunks.isEmpty && $0.kind == .modified })
        #expect(diffs.contains { $0.displayPath == "plan b/empty.txt" && $0.kind == .deleted && $0.hunks.isEmpty })
        if includingStaged {
            #expect(diffs.contains { $0.oldPath == "old" && $0.newPath == nil }, "the rename's source, read alone")
            #expect(diffs.contains { $0.displayPath == "gone" && $0.kind == .deleted })
            #expect(diffs.filter { $0.displayPath == "f3" }.count == 2, "both layers of f3")
            #expect(diffs.contains { $0.displayPath == "plan b/new empty.txt" && $0.kind == .added && $0.hunks.isEmpty })
        }
    }

    // MARK: - The record's survey

    /// One `ls-files -s` for every path gives each path the entries its own read gave: a file,
    /// a directory (everything under it), a staged deletion (none) and a path git never knew.
    @Test func theSurveysEntriesAreEachPathsOwn() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try repo.write("dir/a", "a\n")
        try repo.write("dir/sub/b", "b\n")
        try repo.write("dirx", "x\n")
        try await repo.commitAll("dirs")
        try repo.write("p", numbered(12, [5: "5 mod"]))
        try repo.write("dir/a", "a\nmore\n")
        try await repo.git(["rm", "-q", "d"])
        let named = ["p", "dir", "d", "dirx", "h"]

        let survey = try await StashRecord.survey(paths: named, backend: backend, at: repo.root)

        for path in named {
            let own = CLIGitBackend.indexRecords(try await repo.git(["ls-files", "-s", "-z", "--", ":(literal)" + path]))
            let got = try #require(survey.entries[path], "\(path) has no entry list")
            #expect(got.map { "\($0.mode) \($0.sha) \($0.stage) \($0.path)" } == own.map { "\($0.mode) \($0.sha) \($0.stage) \($0.path)" },
                    "\(path)")
        }
        #expect(survey.entries["dir"]?.map(\.path) == ["dir/a", "dir/sub/b"], "not vacuous: the directory's entries")
        #expect(survey.entries["d"]?.isEmpty == true)
    }

    // MARK: - The record's `update-index`

    /// Every entry once, as `--cacheinfo <mode>,<sha>,<path>`, at most `limit` entries a call.
    @Test func cacheinfoArgumentsAreChunked() {
        let entries = (0..<5).map { (mode: "100644", sha: String(repeating: "\($0)", count: 40), stage: "0", path: "f\($0)") }

        let chunks = StashRecord.cacheinfoArguments(entries, limit: 2)

        #expect(chunks.count == 3)
        #expect(chunks.map(\.count) == [4, 4, 2])
        #expect(chunks.flatMap { $0 }.enumerated().allSatisfy { $0.offset % 2 == 1 || $0.element == "--cacheinfo" })
        #expect(chunks.flatMap { $0 }.filter { $0 != "--cacheinfo" }
            == entries.map { "\($0.mode),\($0.sha),\($0.path)" })
        #expect(StashRecord.cacheinfoArguments([], limit: 2).isEmpty)
        #expect(StashRecord.cacheinfoLimit == 1_000)
    }

    /// More staged entries than one call takes: the record's index commit still holds every
    /// one of them.
    @Test func aRecordOfMoreEntriesThanOneCallTakesHoldsThemAll() async throws {
        let (repo, paths) = try await Self.repo(files: StashRecord.cacheinfoLimit + 5, staged: true)
        defer { repo.cleanUp() }
        let before = try await RepoState.capture(repo)

        let record = try await StashRecord.record(paths: paths, message: "m", backend: backend, at: repo.root)

        let staged = String(decoding: try await repo.git(["diff", "--name-only", "-z", "HEAD", "\(record.sha)^2"]), as: UTF8.self)
            .split(separator: "\0").map(String.init)
        #expect(Set(staged) == Set(paths), "\(staged.count) of \(paths.count) staged paths in the index commit")
        let worktree = String(decoding: try await repo.git(["diff", "--name-only", "-z", "\(record.sha)^2", record.sha]), as: UTF8.self)
            .split(separator: "\0").map(String.init)
        #expect(Set(worktree) == Set(paths))
        #expect(try await RepoState.capture(repo).head == before.head)
        #expect(try await RepoState.capture(repo).index == before.index, "the real index moved")
    }
}
