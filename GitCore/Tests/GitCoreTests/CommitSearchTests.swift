import Foundation
import GitCoreTestSupport
import Testing

@testable import GitCore

/// F1 Task 1: `searchCommits` on real git in scratch repositories. The vectors and the measured
/// facts behind them are documented on `GitBackend.searchCommits`.
@Suite(.timeLimit(.minutes(10))) struct CommitSearchTests {
    private let backend = CLIGitBackend()

    private func search(
        _ mode: CommitSearchMode, _ query: String, limit: Int = CommitSearchLimit.rows, in repo: TestRepo
    ) async throws -> CommitSearchResult {
        try await backend.searchCommits(CommitSearch(mode: mode, query: query), limit: limit, at: repo.root)
    }

    private func summaries(_ result: CommitSearchResult) -> [String] { result.commits.map(\.summary) }

    /// Whether `part` is `whole` with some elements left out, order kept.
    private static func isSubsequence(_ part: [String], of whole: [String]) -> Bool {
        var remaining = part[...]
        for element in whole where element == remaining.first { remaining.removeFirst() }
        return remaining.isEmpty
    }

    private func commit(_ repo: TestRepo, _ message: String, file: String, author: String? = nil) async throws {
        try repo.write(file, "\(message)\n")
        try await repo.git(["add", "-A"])
        var arguments = ["commit", "-q", "-m", message]
        if let author { arguments += ["--author", author] }
        try await repo.git(arguments)
    }

    // MARK: - Message, Author or ID

    @Test func parseWithMessagesKeepsTheWholeMessageOfEachRecord() {
        let head = "1111\u{0}\u{0}A\u{0}a@x\u{0}2026-10-26T10:00:00Z\u{0}Subject\u{0}HEAD -> main\u{0}"
        let one = head + "Subject\n\nbody line\n\u{0}"
        let two = "2222\u{0}1111\u{0}B\u{0}b@x\u{0}2026-10-26T11:00:00Z\u{0}Other\u{0}\u{0}Other\n\u{0}"
        let rows = LogParser.parseWithMessages(Data((one + two).utf8))
        #expect(rows.map(\.commit.sha) == ["1111", "2222"])
        #expect(rows.map(\.message) == ["Subject\n\nbody line\n", "Other\n"])
        #expect(rows[0].commit == LogParser.parse(Data(head.utf8)).first)
        #expect(rows[1].commit.parents == ["1111"])
        #expect(LogParser.parseWithMessages(Data()).isEmpty)
    }

    @Test func messageOrAuthorIsOr() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await commit(repo, "talk to alice about it", file: "a.txt")
        try await commit(repo, "second change", file: "b.txt", author: "Alice <alice@x.org>")
        try await commit(repo, "unrelated", file: "c.txt")

        let result = try await search(.messageAuthorOrID, "alice", in: repo)

        #expect(summaries(result) == ["second change", "talk to alice about it"])
        #expect(!result.isCut)
        #expect(result.search == CommitSearch(mode: .messageAuthorOrID, query: "alice"))
    }

    /// A merge, and a commit dated before its parent, written by `fast-import`.
    private func skewedHistory(_ repo: TestRepo) async throws {
        func commit(_ mark: Int, _ date: Int, _ ref: String, _ message: String, from: Int? = nil, merge: Int? = nil) -> String {
            var text = "commit refs/heads/\(ref)\nmark :\(mark)\ncommitter T <t@t> \(date) +0000\n"
            text += "data \(message.utf8.count)\n\(message)\n"
            if let from { text += "from :\(from)\n" }
            if let merge { text += "merge :\(merge)\n" }
            return text + "\n"
        }
        try await repo.fastImport(
            commit(1, 1_700_000_000, "main", "stash root")
            + commit(2, 1_600_000_000, "main", "stash skewed older than its parent", from: 1)
            + commit(3, 1_700_000_100, "side", "stash on the side", from: 1)
            + commit(4, 1_700_000_200, "main", "stash merge", from: 2, merge: 3)
            + commit(5, 1_700_000_300, "main", "stash tip", from: 4))
    }

    @Test func resultsKeepHistoryOrder() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await skewedHistory(repo)
        let history = try await backend.snapshot(at: repo.root, historyDepth: 1000).commits.map(\.sha)

        let result = try await search(.messageAuthorOrID, "stash", in: repo)

        #expect(result.commits.count == 5)
        #expect(Self.isSubsequence(result.commits.map(\.sha), of: history))
        // A narrower search is a subsequence too, and the order is git's walk, not date order.
        let narrower = try await search(.messageAuthorOrID, "on the side", in: repo)
        #expect(narrower.commits.count == 1)
        #expect(Self.isSubsequence(narrower.commits.map(\.sha), of: history))
        #expect(result.commits.map(\.sha) == history, "all five match, so the whole walk comes back")
        let byDate = history.sorted { a, b in
            (result.commits.first { $0.sha == a }?.authorDate ?? .distantPast)
                > (result.commits.first { $0.sha == b }?.authorDate ?? .distantPast)
        }
        #expect(byDate != history, "the fixture's walk is not date order, or the test proves nothing")
    }

    /// Control: the order check can fail.
    @Test func theSubsequenceCheckCanFail() {
        #expect(!Self.isSubsequence(["b", "a"], of: ["a", "b", "c"]))
        #expect(!Self.isSubsequence(["x"], of: ["a", "b"]))
        #expect(Self.isSubsequence(["a", "c"], of: ["a", "b", "c"]))
    }

    @Test func aHexNamedBranchIsNotAnIDMatch() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await commit(repo, "first", file: "a.txt")
        let first = try await repo.headSha()
        try await commit(repo, "second", file: "b.txt")
        let second = try await repo.headSha()
        #expect(!first.hasPrefix("abc1234") && !second.hasPrefix("abc1234"), "the fixture's ids must not start with the branch name")
        try await repo.git(["branch", "abc1234", first])

        let byName = try await search(.messageAuthorOrID, "abc1234", in: repo)
        let byID = try await search(.messageAuthorOrID, String(first.prefix(7)), in: repo)

        #expect(byName.commits.isEmpty, "a branch's name is not an id")
        #expect(byID.commits.map(\.sha) == [first], "control: a real id prefix is found")
    }

    @Test func stashCommitsAreNeverFound() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await commit(repo, "base", file: "a.txt")
        try repo.write("a.txt", "changed\n")
        try await repo.git(["stash", "push", "-q"])
        let stashID = try await repo.revParse("refs/stash")

        let byID = try await search(.messageAuthorOrID, String(stashID.prefix(7)), in: repo)
        let byText = try await search(.messageAuthorOrID, "WIP on", in: repo)
        let control = try await search(.messageAuthorOrID, "base", in: repo)

        #expect(byID.commits.isEmpty)
        #expect(byText.commits.isEmpty)
        #expect(summaries(control) == ["base"])
    }

    /// Eight commits that make a pathspec reorder git's walk (found by search over small DAGs):
    /// default simplification drops the merges' other parents, and `--topo-order` then sorts by
    /// what is left. `f` changes in every commit but 3 and the merges.
    private func simplifiedHistory(_ repo: TestRepo) async throws {
        let commits: [(mark: Int, date: Int, parents: [Int], changesFile: Bool)] = [
            (1, 1_700_000_010, [], true), (2, 1_600_000_002, [1], true), (3, 1_700_000_030, [1], false),
            (4, 1_600_000_004, [1], true), (5, 1_700_000_050, [1], true), (6, 1_700_000_060, [3, 4], false),
            (7, 1_700_000_070, [1, 5], false), (8, 1_700_000_080, [2, 7], false),
        ]
        var stream = ""
        for c in commits {
            stream += "commit refs/heads/b\(c.mark)\nmark :\(c.mark)\ncommitter T <t@t> \(c.date) +0000\ndata 3\nc\(c.mark)\n"
            if let first = c.parents.first { stream += "from :\(first)\n" }
            for other in c.parents.dropFirst() { stream += "merge :\(other)\n" }
            if c.changesFile { stream += "M 100644 inline f\ndata 3\nv\(c.mark)\n" }
            stream += "\n"
        }
        try await repo.fastImport(stream)
    }

    @Test func fileResultsKeepHistoryOrderDespiteSimplification() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await simplifiedHistory(repo)
        let history = try await backend.snapshot(at: repo.root, historyDepth: 1000).commits.map(\.summary)
        let plain = try await repo.git(["log", "--exclude=refs/stash", "--all", "--topo-order", "--format=%s", "--", "f"])
        let gitsOwn = String(decoding: plain, as: UTF8.self).split(separator: "\n").map(String.init)

        // The fixture must really make git's own order differ, or this test proves nothing.
        #expect(Set(gitsOwn).count == 4 && !Self.isSubsequence(gitsOwn, of: history), "\(gitsOwn) vs \(history)")

        let result = try await search(.file, "f", in: repo)

        #expect(Set(summaries(result)) == Set(gitsOwn), "the match set is git's")
        #expect(Self.isSubsequence(summaries(result), of: history), "\(summaries(result)) vs \(history)")
        let cut = try await search(.file, "f", limit: 2, in: repo)
        #expect(summaries(cut) == Array(summaries(result).prefix(2)) && cut.isCut, "the cut is made after ordering")
    }

    // MARK: - File

    @Test func fileModeMatchesFoldersFragmentsAndLiterals() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        for path in ["Server/Views/Sidebar.swift", "docs/a/b.md", "README.MD", "weird/a*b[1].txt", "weird/aXb1.txt", "other.txt"] {
            try await commit(repo, "add \(path)", file: path)
        }

        let table: [(query: String, expected: [String])] = [
            ("views", ["add Server/Views/Sidebar.swift"]),
            ("r/V", ["add Server/Views/Sidebar.swift"]),
            ("Views/Sidebar", ["add Server/Views/Sidebar.swift"]),
            ("docs/", ["add docs/a/b.md"]),
            (".MD", ["add README.MD", "add docs/a/b.md"]),
            ("a*b[1]", ["add weird/a*b[1].txt"]),
            ("nothing-like-it", []),
        ]
        for (query, expected) in table {
            let found = summaries(try await search(.file, query, in: repo))
            #expect(found == expected, "\(query): \(found)")
        }
    }


    @Test func fileModeSurvivesPathspecEnvironmentVariables() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        for path in ["Server/Views/Sidebar.swift", "docs/a/b.md", "weird/a*b[1].txt", "weird/aXb1.txt"] {
            try await commit(repo, "add \(path)", file: path)
        }
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-search-env-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        for variable in ["GIT_GLOB_PATHSPECS", "GIT_NOGLOB_PATHSPECS"] {
            let script = directory.appendingPathComponent("git-\(variable)")
            try "#!/bin/sh\nexport \(variable)=1\nexec /usr/bin/git \"$@\"\n".write(to: script, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
            let inherited = CLIGitBackend(gitPath: script.path, runner: isolatedRunner())

            // Control: the variable is in force, and the old single `:(icase)*q*` form fails under it.
            let old = try await inherited.run(
                ["log", "--all", "--format=%s", "--", ":(icase)*views*"], cwd: repo.root)
            #expect(old.isEmpty, "\(variable) must break the old form, or this test proves nothing")

            for (query, expected) in [("views", ["add Server/Views/Sidebar.swift"]), ("r/V", ["add Server/Views/Sidebar.swift"]),
                                      ("docs/", ["add docs/a/b.md"]), ("a*b[1]", ["add weird/a*b[1].txt"])] {
                let found = try await inherited.searchCommits(CommitSearch(mode: .file, query: query), limit: 10, at: repo.root)
                #expect(found.commits.map(\.summary) == expected, "\(variable) \(query): \(found.commits.map(\.summary))")
            }
        }
    }

    @Test func fileQueriesGitWouldNormaliseFindNothingAndRunNoGit() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        for path in ["docs/a/b.md", "a..b.txt", ".MD", "other.txt"] { try await commit(repo, "add \(path)", file: path) }
        let log = RecordingLog()
        let logged = CLIGitBackend(runner: isolatedRunner(), commandLog: log)

        for query in ["docs/../", "/../", "/./", "//", "a//b", "b/../b", "a/./b"] {
            let result = try await logged.searchCommits(CommitSearch(mode: .file, query: query), limit: 10, at: repo.root)
            #expect(result.commits.isEmpty && !result.isCut, "\(query)")
        }
        #expect(log.all.isEmpty, "no git ran for any of them")

        // Controls: dots in names, and a leading or trailing slash, still search.
        let expected: [(String, [String])] = [
            ("..", ["add a..b.txt"]), ("a..b", ["add a..b.txt"]), (".MD", ["add .MD", "add docs/a/b.md"]),
            ("/a", ["add docs/a/b.md"]), ("a/", ["add docs/a/b.md"]), ("a/b", ["add docs/a/b.md"]),
        ]
        for (query, summaries) in expected {
            let result = try await logged.searchCommits(CommitSearch(mode: .file, query: query), limit: 10, at: repo.root)
            #expect(result.commits.map(\.summary) == summaries, "\(query)")
        }
        #expect(log.all.count >= expected.count, "the controls did run git")
    }

    @Test func aQueryWithNULFindsNothingInEveryModeAndRunsNoGit() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await commit(repo, "one", file: "a.txt")
        let log = RecordingLog()
        let logged = CLIGitBackend(runner: isolatedRunner(), commandLog: log)
        for mode in CommitSearchMode.allCases {
            let result = try await logged.searchCommits(CommitSearch(mode: mode, query: "a\u{0}b"), limit: 10, at: repo.root)
            #expect(result.commits.isEmpty && !result.isCut, "\(mode)")
        }
        #expect(log.all.count == 1, "only Message mode reads (it never puts the query in an argument)")
    }

    @Test func codeModeIsNotChangedByDiffRenames() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.git(["config", "diff.renames", "false"])
        try repo.write("f.txt", "line one\nsecretword here\nline three\nfour\nfive\n")
        try await repo.commitAll("adds the text")
        try await repo.git(["mv", "f.txt", "g.txt"])
        try await repo.git(["commit", "-q", "-m", "renames the file"])

        // Control: without the pin, this configuration lists the rename too.
        let plain = try await repo.git(["log", "--format=%s", "-i", "-S", "secretword"])
        #expect(String(decoding: plain, as: UTF8.self).contains("renames the file"))

        #expect(summaries(try await search(.code, "secretword", in: repo)) == ["adds the text"])
    }

    // MARK: - Code

    @Test func codeModeIgnoresTextconv() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.git(["config", "diff.up.textconv", "sed s/secret/hidden/ <"])
        try repo.write(".gitattributes", "*.txt diff=up\n")
        try await repo.git(["add", "-A"])
        try await repo.git(["commit", "-q", "-m", "attributes"])
        try await commit(repo, "adds the text", file: "n.txt")
        try repo.write("n.txt", "a secret here\n")
        try await repo.commitAll("holds the secret")

        // Control: with textconv in force (no `--no-textconv`), the driver does convert, so
        // `hidden` is found. Without this, a driver that silently did not apply passes below.
        let withDriver = try await repo.git(["log", "--format=%s", "-S", "hidden"])
        #expect(String(decoding: withDriver, as: UTF8.self).contains("holds the secret"), "the textconv driver applies")

        let raw = try await search(.code, "secret", in: repo)
        let converted = try await search(.code, "hidden", in: repo)

        #expect(summaries(raw) == ["holds the secret"], "git is asked for the stored text")
        #expect(converted.commits.isEmpty, "the converted text is never searched")
    }

    @Test func codeModeIsCaseInsensitive() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("n.txt", "a secret [x] here\n")
        try await repo.commitAll("holds it")
        #expect(summaries(try await search(.code, "SECRET [X]", in: repo)) == ["holds it"])
        #expect(try await search(.code, "secret x", in: repo).commits.isEmpty, "the query is literal")
    }

    @Test func codeModeSkipsMergeOnlyChanges() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f.txt", "base\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "other"])
        try repo.write("f.txt", "other side\n")
        try await repo.commitAll("other edit")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", "main side\n")
        try await repo.commitAll("main edit")
        try await repo.git(["merge", "-q", "other"], allowedExitCodes: [1])
        try repo.write("f.txt", "resolved with evilword\n")
        try await repo.git(["add", "-A"])
        try await repo.git(["commit", "-q", "-m", "the evil merge"])

        let merged = try await search(.code, "evilword", in: repo)
        let control = try await search(.code, "other side", in: repo)

        #expect(merged.commits.isEmpty, "text added only while resolving a merge is not found")
        #expect(summaries(control) == ["other edit"])
    }

    // MARK: - The cut, the empty query, cancelling

    @Test func theCutIsStated() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        for index in 1...3 { try await commit(repo, "match \(index)", file: "f\(index).txt") }
        try await commit(repo, "other", file: "g.txt")

        let cut = try await search(.messageAuthorOrID, "match", limit: 2, in: repo)
        let exact = try await search(.messageAuthorOrID, "match", limit: 3, in: repo)
        let fileCut = try await search(.file, "f", limit: 2, in: repo)

        #expect(summaries(cut) == ["match 3", "match 2"], "the newest matches are kept")
        #expect(cut.isCut)
        #expect(exact.commits.count == 3)
        #expect(!exact.isCut)
        #expect(fileCut.commits.count == 2 && fileCut.isCut)
    }

    @Test func emptyQueryRunsNothing() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await commit(repo, "one", file: "a.txt")
        let log = RecordingLog()
        let logged = CLIGitBackend(runner: isolatedRunner(), commandLog: log)

        for mode in CommitSearchMode.allCases {
            let result = try await logged.searchCommits(CommitSearch(mode: mode, query: "  \n "), limit: 10, at: repo.root)
            #expect(result.commits.isEmpty && !result.isCut)
        }
        #expect(log.all.isEmpty)

        // Control: a real query does reach the log.
        _ = try await logged.searchCommits(CommitSearch(mode: .code, query: "one"), limit: 10, at: repo.root)
        #expect(log.all.count == 1)
    }

    @Test func anEmptyRepositoryHasNothingToFind() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        for mode in CommitSearchMode.allCases {
            let result = try await search(mode, "x", in: repo)
            #expect(result.commits.isEmpty && !result.isCut)
        }
    }

    @Test func aGitFailureIsThrown() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-search-notrepo-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let error = await thrownError { _ = try await backend.searchCommits(CommitSearch(mode: .code, query: "x"), limit: 5, at: directory) }
        #expect(error != nil, "not a repository is an error, not an empty list")
    }

    /// Deterministic, not a race against a slow git: a stand-in git that records that it started
    /// and then sleeps until killed. The read is cancelled once it is known to be running.
    @Test func cancellingKillsTheRead() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-search-cancel-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let sleep = "sleep 47.\(Int.random(in: 100_000...999_999))"
        let script = directory.appendingPathComponent("fake-git")
        try "#!/bin/sh\ntouch '\(marker.path)'\nexec \(sleep)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        let log = RecordingLog()
        let slow = CLIGitBackend(gitPath: script.path, runner: isolatedRunner(), commandLog: log)

        let call = CallUnderTest {
            await thrownError {
                _ = try await slow.searchCommits(CommitSearch(mode: .code, query: "x"), limit: 10, at: directory)
            }
        }
        do {
            while !FileManager.default.fileExists(atPath: marker.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            call.cancel()
            killLeftovers([sleep])
            throw error
        }
        call.cancel()
        guard let thrown = await call.value("the cancelled search") else {
            killLeftovers([sleep])
            return
        }
        #expect(thrown is CancellationError, "\(String(describing: thrown))")
        #expect(log.all.count == 1)
        #expect(log.all.first?.outcome == .cancelled)
        #expect(try await waitForNoOwnProcess(matching: sleep))
        killLeftovers([sleep])
    }
}
