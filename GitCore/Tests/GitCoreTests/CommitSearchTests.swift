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

    @Test func scanWithMessagesBuildsOnlyWhatIsKeptAndStopsAtTheLimit() {
        func record(_ n: Int, message: String) -> String {
            "\(n)\u{0}\u{0}A\u{0}a@x\u{0}2026-10-26T10:00:00Z\u{0}S\(n)\u{0}\u{0}\(message)\u{0}"
        }
        let data = Data((1...5).map { record($0, message: $0 % 2 == 0 ? "even\n" : "odd") }.joined().utf8)
        let all = LogParser.scanWithMessages(data) { _ in true }
        #expect(all == LogParser.parseWithMessages(data).map(\.commit) && all.count == 5)
        #expect(LogParser.scanWithMessages(data) { String(decoding: $0.bytes(.message), as: UTF8.self).hasPrefix("even") }.map(\.sha) == ["2", "4"])
        #expect(LogParser.scanWithMessages(data, limit: 2) { _ in true }.map(\.sha) == ["1", "2"])
        #expect(LogParser.scanWithMessages(data) { _ in false }.isEmpty)
        #expect(LogParser.scanWithMessages(Data()) { _ in true }.isEmpty)
        // An incomplete last record is dropped, as `parse` drops one.
        #expect(LogParser.scanWithMessages(data.dropLast(4)) { _ in true }.count == 4)
    }

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

    /// The spec promises the body: a phrase hard-wrapped across two of its lines is found.
    @Test func aPhraseOnlyInTheWrappedBodyIsFound() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await commit(repo, "subject one\n\nThe stash\ncaption is wrapped here.", file: "a.txt")
        try await commit(repo, "unrelated", file: "b.txt")

        #expect(summaries(try await search(.messageAuthorOrID, "stash caption", in: repo)) == ["subject one"])
        #expect(summaries(try await search(.messageAuthorOrID, "subject one", in: repo)) == ["subject one"], "control")
    }

    /// Words of hex letters, and a revert's id quoted in a message, are found as text.
    @Test func aHexLookingWordInAMessageIsFoundAsText() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await commit(repo, "See 1234abcd for the old one", file: "a.txt")
        try await commit(repo, "added a row", file: "b.txt")
        try await commit(repo, "unrelated", file: "c.txt")
        let shas = try await search(.messageAuthorOrID, "unrelated", in: repo).commits.map(\.sha)
            + (try await search(.messageAuthorOrID, "row", in: repo).commits.map(\.sha))
        #expect(!shas.contains { $0.hasPrefix("1234abcd") || $0.hasPrefix("added") }, "the fixture's ids must not start with the words")

        #expect(summaries(try await search(.messageAuthorOrID, "1234abcd", in: repo)) == ["See 1234abcd for the old one"])
        #expect(summaries(try await search(.messageAuthorOrID, "added", in: repo)) == ["added a row"])
    }

    /// The author's email is a field of its own: found when it is the only one holding the query.
    @Test func theAuthorEmailAloneIsSearched() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await commit(repo, "by zed", file: "a.txt", author: "Zed <zed@example.org>")
        try await commit(repo, "by the tester", file: "b.txt")

        #expect(summaries(try await search(.messageAuthorOrID, "example.org", in: repo)) == ["by zed"])
        #expect(summaries(try await search(.messageAuthorOrID, "zed", in: repo)) == ["by zed"], "the name too")
    }

    /// `log.showRoot=false` stops `log` diffing a root commit, so `-S` without `--root` never
    /// searches it (measured); every search vector passes `--root`.
    @Test func theRootCommitIsSearchedUnderLogShowRootFalse() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("root.txt", "a rootneedle here\n")
        try await repo.commitAll("the root")
        try await commit(repo, "second", file: "b.txt")
        try await repo.git(["config", "log.showRoot", "false"])

        // Control: under this configuration, the vector without `--root` misses the root.
        let plain = try await repo.git(["log", "--all", "--format=%s", "-i", "-Srootneedle"])
        #expect(String(decoding: plain, as: UTF8.self).isEmpty, "log.showRoot=false must hide the root, or this proves nothing")

        #expect(summaries(try await search(.code, "ROOTNEEDLE", in: repo)) == ["the root"])
        #expect(summaries(try await search(.file, "root.txt", in: repo)) == ["the root"])
    }

    /// `i18n.logOutputEncoding` re-encodes what `log` prints (measured: Latin-1 bytes); every
    /// search vector passes `--encoding=UTF-8`, so the matcher and the rows read UTF-8.
    @Test func searchReadsUTF8UnderAnotherLogOutputEncoding() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("café.txt", "x\n")
        try await repo.git(["add", "-A"])
        try await repo.git(["commit", "-q", "-m", "café work", "--author", "José <jose@example.org>"])
        try await commit(repo, "other", file: "b.txt")
        try await repo.git(["config", "i18n.logOutputEncoding", "ISO-8859-1"])

        // Control: under this configuration, plain `log` prints Latin-1 (0xE9), not UTF-8.
        let plain = try await repo.git(["log", "--all", "--format=%s"])
        #expect(plain.contains(0xE9) && !plain.contains(0xC3), "the setting must re-encode, or this proves nothing")

        #expect(summaries(try await search(.messageAuthorOrID, "café", in: repo)) == ["café work"])
        #expect(summaries(try await search(.messageAuthorOrID, "josé", in: repo)) == ["café work"])
        let file = try await search(.file, "fé.txt", in: repo)
        #expect(summaries(file) == ["café work"] && file.commits.first?.authorName == "José")
        #expect(summaries(try await search(.code, "x", in: repo)) == ["café work"])
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

        // Every commit that changed `f`, merges' sides followed (Ruling P19); no merge here
        // changed it against all its parents.
        #expect(Set(summaries(result)) == ["c1", "c2", "c4", "c5"], "\(summaries(result))")
        #expect(Self.isSubsequence(summaries(result), of: history), "\(summaries(result)) vs \(history)")
        let cut = try await search(.file, "f", limit: 2, in: repo)
        #expect(summaries(cut) == Array(summaries(result).prefix(2)) && cut.isCut, "the cut is made after ordering")
    }

    /// Side branches whose change to `f.txt` a merge did not keep, each deleted after its merge —
    /// where git's default simplification follows only the kept parent and drops their commits —
    /// beside the spec's clean merge (not listed) and evil merge (listed), and an octopus merge.
    private func droppedSideHistory(_ repo: TestRepo) async throws {
        func change(_ path: String, _ text: String, _ message: String) async throws {
            try repo.write(path, text + "\n")
            try await repo.commitAll(message)
        }
        func branch(_ name: String) async throws { try await repo.git(["switch", "-q", "-c", name]) }
        func main() async throws { try await repo.git(["switch", "-q", "main"]) }
        func delete(_ name: String) async throws { try await repo.git(["branch", "-q", "-D", name]) }
        try await change("f.txt", "base", "base")
        try await change("other.txt", "o", "other base")
        // A change undone on its branch, merged with --no-ff.
        try await branch("s1")
        try await change("f.txt", "changed", "s1: touch f")
        try await change("f.txt", "base", "s1: undo f")
        try await main()
        try await change("other.txt", "o1", "main: other 1")
        try await repo.git(["merge", "-q", "--no-ff", "-m", "merge s1", "s1"])
        try await delete("s1")
        // `-s ours`.
        try await branch("s2")
        try await change("f.txt", "side two", "s2: change f")
        try await main()
        try await change("other.txt", "o2", "main: other 2")
        try await repo.git(["merge", "-q", "-s", "ours", "-m", "merge s2 ours", "s2"])
        try await delete("s2")
        // A conflict resolved by taking ours.
        try await branch("s3")
        try await change("f.txt", "side three", "s3: change f")
        try await main()
        try await change("f.txt", "main three", "main: change f")
        try await repo.git(["merge", "-q", "s3"], allowedExitCodes: [1])
        try await repo.git(["checkout", "-q", "--ours", "f.txt"])
        try await repo.git(["add", "f.txt"])
        try await repo.git(["commit", "-q", "-m", "merge s3 kept ours"])
        try await delete("s3")
        // A clean merge of a side change (the spec's case: the side commit is listed, the merge not).
        try await branch("s5")
        try await change("f.txt", "side five", "s5: change f")
        try await main()
        try await change("other.txt", "o5", "main: other 5")
        try await repo.git(["merge", "-q", "-m", "merge s5 clean", "s5"])
        try await delete("s5")
        // An evil merge: neither side changes f, the merge does (the spec's case: listed).
        try await branch("s6")
        try await change("g.txt", "g", "s6: g")
        try await main()
        try await change("other.txt", "o6", "main: other 6")
        try await repo.git(["merge", "-q", "--no-commit", "s6"])
        try repo.write("f.txt", "evil\n")
        try await repo.commitAll("merge s6 evil")
        try await delete("s6")
        // An octopus that takes one side's f: TREESAME to that parent, so not listed.
        try await branch("o1")
        try await change("a.txt", "a", "o1: a")
        try await main()
        try await branch("o2")
        try await change("f.txt", "octo", "o2: change f")
        try await main()
        try await change("other.txt", "o7", "main: other 7")
        try await repo.git(["merge", "-q", "-m", "octopus", "o1", "o2"])
        for name in ["o1", "o2"] { try await delete(name) }
    }

    /// Ruling P19: File lists every non-merge commit that changed a matching path, as History
    /// shows them, and a merge only when it changed the path against every parent.
    @Test func fileModeListsSideCommitsAMergeDidNotKeep() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await droppedSideHistory(repo)
        let history = try await backend.snapshot(at: repo.root, historyDepth: 1000).commits.map(\.summary)

        // Control: git's default simplification (the vector before) misses the dropped sides.
        let plain = try await repo.git(["log", "--exclude=refs/stash", "--all", "--topo-order", "--format=%s", "--", "f.txt"])
        let simplified = String(decoding: plain, as: UTF8.self).split(separator: "\n").map(String.init)
        #expect(!simplified.contains("s1: touch f") && !simplified.contains("s2: change f") && !simplified.contains("s3: change f"),
                "the fixture must defeat default simplification, or this proves nothing: \(simplified)")

        let found = summaries(try await search(.file, "f.txt", in: repo))

        #expect(Set(found) == [
            "base", "s1: touch f", "s1: undo f", "s2: change f", "s3: change f", "main: change f",
            "s5: change f", "merge s6 evil", "o2: change f",
        ], "\(found)")
        #expect(Self.isSubsequence(found, of: history), "\(found) vs \(history)")
    }

    // MARK: - What the walk starts from

    /// Ruling P21: `--all` starts from every ref under `refs/` but `refs/stash` — notes, a
    /// remote-tracking ref with no remote part, any other namespace (measured) — and the snapshot
    /// carries every one of them by name and id (`RefCollection.walkedRefs`), so the app can tell
    /// when the walk's start points moved.
    @Test func theSnapshotCarriesEveryRefTheWalkStartsFrom() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await commit(repo, "base", file: "a.txt")
        try await repo.git(["tag", "-a", "v1", "-m", "v1"])
        let tree = String(decoding: try await repo.git(["write-tree"]), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        var only: [String: String] = [:]
        for ref in ["refs/pull/1/head", "refs/remotes/noslash", "refs/custom/x"] {
            let made = try await repo.git(["commit-tree", tree, "-p", "HEAD", "-m", "only \(ref)"])
            let sha = String(decoding: made, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            try await repo.git(["update-ref", ref, sha])
            only[ref] = sha
        }
        try await repo.git(["notes", "add", "-m", "a note", "HEAD"])
        try repo.write("a.txt", "stashed\n")
        try await repo.git(["stash", "push", "-q"])

        // Control: the walk does start from each of them.
        let walked = String(decoding: try await repo.git(["log", "--exclude=refs/stash", "--all", "--format=%s"]), as: UTF8.self)
        for ref in only.keys { #expect(walked.contains("only \(ref)"), "\(ref)") }

        let refs = try await backend.snapshot(at: repo.root, historyDepth: 100).refs
        #expect(Set(refs.walkedRefs.keys) == [
            "refs/heads/main", "refs/tags/v1", "refs/notes/commits", "refs/pull/1/head", "refs/remotes/noslash", "refs/custom/x",
        ])
        for (ref, sha) in only { #expect(refs.walkedRefs[ref] == sha, "\(ref)") }
        #expect(refs.walkedRefs["refs/heads/main"] == (try await repo.headSha()))
    }

    // MARK: - A partial clone

    /// How many objects the repository at `root` lacks (`rev-list --missing=print`, which never
    /// fetches).
    private func missingObjects(_ repo: TestRepo) async throws -> Int {
        let out = try await repo.git(["rev-list", "--objects", "--all", "--missing=print"])
        return String(decoding: out, as: UTF8.self).split(separator: "\n").filter { $0.hasPrefix("?") }.count
    }

    /// Ruling P20: a search only reads. In a partial clone git would fetch every missing blob a
    /// Code search diffs (measured: 4 missing before, 0 after); with `GIT_NO_LAZY_FETCH=1` it
    /// fails at once instead, as `CommitSearchError.contentsNotDownloaded`, and nothing is
    /// fetched. Message and File need no blobs, and still search. The promisor is a local bare
    /// repository over `file://`: no network.
    @Test func aPartialCloneIsNeverFetchedFrom() async throws {
        let source = try await TestRepo.makeEmpty()
        defer { source.cleanUp() }
        for index in 1...3 {
            try source.write("f\(index).txt", "content \(index) needle\(index)\n")
            try await source.commitAll("c\(index)")
        }
        let bare = source.root.appendingPathExtension("bare")
        let cloneURL = source.root.appendingPathExtension("partial")
        defer {
            try? FileManager.default.removeItem(at: bare)
            try? FileManager.default.removeItem(at: cloneURL)
        }
        try await source.git(["clone", "-q", "--bare", source.root.path, bare.path])
        try await source.git(["-C", bare.path, "config", "uploadpack.allowFilter", "true"])
        try await source.git(["clone", "-q", "--filter=blob:none", "--no-checkout", "file://" + bare.path, cloneURL.path])
        let clone = TestRepo(root: cloneURL)
        let missing = try await missingObjects(clone)
        #expect(missing >= 3, "the clone must lack the blobs, or this proves nothing")

        let error = await thrownError { _ = try await search(.code, "needle2", in: clone) }
        guard case CommitSearchError.contentsNotDownloaded? = error as? CommitSearchError else {
            Issue.record("expected contentsNotDownloaded, got \(String(describing: error))")
            return
        }
        #expect(try await missingObjects(clone) == missing, "nothing was fetched")
        #expect(summaries(try await search(.messageAuthorOrID, "c2", in: clone)) == ["c2"])
        #expect(summaries(try await search(.file, "f2", in: clone)) == ["c2"])
        #expect(try await missingObjects(clone) == missing, "nor by Message or File")

        // Control: the same read without the variable does fetch, so the fixture is a live
        // promisor and the variable is what stopped it.
        let fetched = try await clone.git(["log", "--all", "--format=%s", "-i", "-Sneedle2"])
        #expect(String(decoding: fetched, as: UTF8.self) == "c2\n")
        #expect(try await missingObjects(clone) < missing)
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
