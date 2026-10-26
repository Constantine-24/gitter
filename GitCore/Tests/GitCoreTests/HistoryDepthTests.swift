import Foundation
import Testing

@testable import GitCore

/// H1's GitCore half: the history read to a depth (`snapshot(at:historyDepth:)`), whether it
/// reached the start of history, and the two reads a jump to an unloaded commit needs —
/// `historyRow(of:at:)`, its row in the list, and `commit(_:at:)`, the commit itself.
///
/// Fixtures over 100 commits come from one `git fast-import` stream written here
/// (`HistoryFixture`), never from a `git commit` each.
@Suite struct HistoryDepthTests {
    let backend = CLIGitBackend()

    // MARK: - The depth

    @Test func depthForRow() {
        #expect(HistoryDepth.page == 500)
        #expect(HistoryDepth.cap == 50_000)
        #expect(HistoryDepth.depth(forRow: 0) == 500)
        #expect(HistoryDepth.depth(forRow: 499) == 500)
        #expect(HistoryDepth.depth(forRow: 500) == 1000)
    }

    /// RF1: a repository of exactly one page is all read at the first depth, and says so.
    @Test func exactlyAPageIsComplete() async throws {
        let repo = try await HistoryFixture.linear(500)
        defer { repo.cleanUp() }

        let snapshot = try await backend.snapshot(at: repo.root, historyDepth: 500)

        #expect(snapshot.commits.count == 500)
        #expect(snapshot.graph.count == 500)
        #expect(snapshot.historyDepth == 500)
        #expect(snapshot.historyIsComplete)
    }

    @Test func onePastAPageIsNot() async throws {
        let repo = try await HistoryFixture.linear(501)
        defer { repo.cleanUp() }

        let first = try await backend.snapshot(at: repo.root, historyDepth: 500)
        #expect(first.commits.count == 500)
        #expect(first.historyDepth == 500)
        #expect(!first.historyIsComplete)

        let deeper = try await backend.snapshot(at: repo.root, historyDepth: 1000)
        #expect(deeper.commits.count == 501)
        #expect(deeper.historyDepth == 1000)
        #expect(deeper.historyIsComplete)
    }

    /// `snapshot(at:)` is the first page.
    @Test func theDefaultReadIsOnePage() async throws {
        let repo = try await HistoryFixture.linear(501)
        defer { repo.cleanUp() }

        let snapshot = try await backend.snapshot(at: repo.root)

        #expect(snapshot.commits.count == HistoryDepth.page)
        #expect(snapshot.historyDepth == HistoryDepth.page)
        #expect(!snapshot.historyIsComplete)
    }

    /// An empty repository has all of its (no) history.
    @Test func anEmptyRepositoryIsComplete() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }

        let snapshot = try await backend.snapshot(at: repo.root, historyDepth: 500)

        #expect(snapshot.commits.isEmpty)
        #expect(snapshot.historyIsComplete)
    }

    /// A deeper read is the shallower one with more after it: the same commits and the same
    /// graph rows, lanes and edges included, across two side branches whose lines cross row 500.
    @Test func deeperIsAPrefix() async throws {
        let fixture = try await HistoryFixture.branched()
        defer { fixture.repo.cleanUp() }

        let shallow = try await backend.snapshot(at: fixture.repo.root, historyDepth: 500)
        let deep = try await backend.snapshot(at: fixture.repo.root, historyDepth: 1000)

        #expect(shallow.commits.count == 500)
        #expect(deep.commits.count == 1000)
        #expect(shallow.commits == Array(deep.commits.prefix(500)))
        #expect(shallow.graph == Array(deep.graph.prefix(500)))
        // A side branch's lane is open across the page boundary, so the cut falls mid-line.
        #expect(deep.graph[499].laneCount > 1 && deep.graph[500].laneCount > 1)
    }

    // MARK: - historyRow(of:at:)

    @Test func rowOfATip() async throws {
        let fixture = try await HistoryFixture.branched()
        defer { fixture.repo.cleanUp() }
        let all = try await backend.snapshot(at: fixture.repo.root, historyDepth: 1100)
        #expect(all.commits.count == 1100)
        #expect(all.historyIsComplete)

        for tip in [fixture.mainTip, fixture.side1Tip, fixture.side2Tip] {
            let row = try await backend.historyRow(of: tip, at: fixture.repo.root)
            #expect(row == all.commits.firstIndex { $0.sha == tip })
            #expect(row != nil)
        }
        #expect(try await backend.historyRow(of: fixture.mainTip, at: fixture.repo.root) == 0)
    }

    @Test func rowOfADeepCommit() async throws {
        let fixture = try await HistoryFixture.branched()
        defer { fixture.repo.cleanUp() }
        let all = try await backend.snapshot(at: fixture.repo.root, historyDepth: 1100)

        let m200 = try await fixture.repo.revParse("refs/heads/main~800")
        for sha in [fixture.mainRoot, m200] {
            let row = try await backend.historyRow(of: sha, at: fixture.repo.root)
            let expected = try #require(all.commits.firstIndex { $0.sha == sha })
            #expect(row == expected)
            #expect(expected >= 500, "a deep commit is past the first page")
        }
        // A side branch's commit, which git lists right after the merge that brings it in.
        let side = try #require(all.commits.firstIndex { $0.sha == fixture.side1Middle })
        #expect(try await backend.historyRow(of: fixture.side1Middle, at: fixture.repo.root) == side)
        #expect(try await backend.historyRow(of: fixture.mainRoot, at: fixture.repo.root) == 1099)
    }

    /// A commit only the stash reaches is not in History (it walks `--exclude=refs/stash --all`),
    /// so it has no row. Control: the stash's parent, HEAD, does.
    @Test func rowOfAStashOnlyCommit() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("first")
        try repo.write("a.txt", "two\n")
        try await repo.git(["stash", "push", "-q", "-m", "wip"])
        let w = try await repo.revParse("refs/stash")
        let head = try await repo.headSha()
        #expect(w != head)

        #expect(try await backend.historyRow(of: w, at: repo.root) == nil)
        #expect(try await backend.historyRow(of: head, at: repo.root) == 0)
    }

    /// Full object ids only, refused before git runs. The short id names a real commit, so only
    /// the refusal can make it fail. Control: the full id of the same commit is read.
    @Test func rowRefusesAShortId() async throws {
        let repo = try await HistoryFixture.linear(3)
        defer { repo.cleanUp() }
        let head = try await repo.headSha()
        let short = String(head.prefix(7))

        await #expect(throws: BranchOperationError.invalidName(short)) {
            _ = try await backend.historyRow(of: short, at: repo.root)
        }
        await #expect(throws: BranchOperationError.invalidName("HEAD")) {
            _ = try await backend.historyRow(of: "HEAD", at: repo.root)
        }
        #expect(try await backend.historyRow(of: head, at: repo.root) == 0)
    }

    // MARK: - commit(_:at:)

    /// Every field the history read has, from the one-commit read: a tip with decorations (HEAD,
    /// a branch and a tag), a merge and a root.
    @Test func commitByIdReadsAllFields() async throws {
        let fixture = try await HistoryFixture.branched()
        defer { fixture.repo.cleanUp() }
        try await fixture.repo.git(["tag", "v1", fixture.mainTip])
        try await fixture.repo.git(["tag", "-a", "-m", "annotated", "v0", fixture.mainRoot])
        let all = try await backend.snapshot(at: fixture.repo.root, historyDepth: 1100)
        let merge = try #require(all.commits.first { $0.isMerge }).sha

        for sha in [fixture.mainTip, fixture.side2Tip, merge, fixture.mainRoot, fixture.side1Middle] {
            let read = try await backend.commit(sha, at: fixture.repo.root)
            let listed = try #require(all.commits.first { $0.sha == sha })
            #expect(read == listed)
        }
        // The fields compared are not empty ones.
        let tip = try #require(try await backend.commit(fixture.mainTip, at: fixture.repo.root))
        #expect(tip.refs.contains("HEAD -> main"))
        #expect(tip.refs.contains("tag: v1"))
        #expect(tip.summary == "m1000")
        #expect(tip.authorName == "Tester")
        #expect(tip.authorDate == Date(timeIntervalSince1970: TimeInterval(HistoryFixture.time(1000))))
        #expect(try await backend.commit(merge, at: fixture.repo.root)?.parents.count == 2)
    }

    @Test func commitOfAnUnknownIdIsNil() async throws {
        let repo = try await HistoryFixture.linear(3)
        defer { repo.cleanUp() }
        let nothing = String(repeating: "dead", count: 10)

        #expect(try await backend.commit(nothing, at: repo.root) == nil)
    }

    /// Refused before git runs; the short id names a real commit. Control: the full id is read.
    @Test func commitRefusesAShortId() async throws {
        let repo = try await HistoryFixture.linear(3)
        defer { repo.cleanUp() }
        let head = try await repo.headSha()
        let short = String(head.prefix(7))

        await #expect(throws: BranchOperationError.invalidName(short)) {
            _ = try await backend.commit(short, at: repo.root)
        }
        await #expect(throws: BranchOperationError.invalidName("--all")) {
            _ = try await backend.commit("--all", at: repo.root)
        }
        #expect(try await backend.commit(head, at: repo.root)?.sha == head)
    }

    /// `log.showSignature=true` in the repository's config would put gpg's lines into the `-z`
    /// record ahead of the commit's id, garbling a signed commit (final review F2). No real gpg:
    /// the commit carries a `gpgsig` header and `gpg.program` is a script that writes a line to
    /// stderr, which git prints into the log. Control: the probe below shows git does print it
    /// without `--no-show-signature`, so the read's answer is not vacuous.
    @Test func commitIgnoresShowSignature() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.git(["commit", "-q", "--allow-empty", "-m", "base"])
        let tree = try await repo.revParse("HEAD^{tree}")
        let parent = try await repo.headSha()
        try repo.write(
            "signed-commit.txt",
            "tree \(tree)\nparent \(parent)\nauthor Tester <t@t> 1700000000 +0000\n"
                + "committer Tester <t@t> 1700000000 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n abc\n"
                + " -----END PGP SIGNATURE-----\n\nsigned\n")
        let signed = String(
            decoding: try await repo.git(["hash-object", "-t", "commit", "-w", "signed-commit.txt"]), as: UTF8.self
        ).trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.writeExecutable(
            ".git/fake-gpg",
            "#!/bin/sh\necho 'gpg: a fake signature line' >&2\necho '[GNUPG:] GOODSIG 0 Tester'\nexit 0\n")
        try await repo.git(["config", "log.showSignature", "true"])
        try await repo.git(["config", "gpg.program", repo.root.appendingPathComponent(".git/fake-gpg").path])

        // The control: git does print the fake gpg's line with the setting on.
        let shown = String(
            decoding: try await repo.git(["log", "-1", "--no-walk", "--format=%H", "--end-of-options", signed]),
            as: UTF8.self)
        #expect(shown.contains("gpg: a fake signature line"))

        let read = try #require(try await backend.commit(signed, at: repo.root))
        #expect(read.sha == signed)
        #expect(read.summary == "signed")
        #expect(read.parents == [parent])
    }

    // MARK: - The fixtures themselves

    /// `HistoryFixture`'s repositories have the shape the tests above rely on. Control: a count
    /// that is not the fixture's is told apart.
    @Test func theFixturesHaveTheirShape() async throws {
        let linear = try await HistoryFixture.linear(501)
        defer { linear.cleanUp() }
        let linearCount = try await HistoryFixture.count(linear)
        #expect(linearCount == 501)
        withKnownIssue("the linear fixture has 501 commits, not 500") {
            #expect(linearCount == 500)
        }

        let fixture = try await HistoryFixture.branched()
        defer { fixture.repo.cleanUp() }
        #expect(try await HistoryFixture.count(fixture.repo) == 1100)
        let merges = try await fixture.repo.git(["rev-list", "--merges", "--count", "--all"])
        #expect(String(decoding: merges, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "2")
        let branches = try await fixture.repo.git(["for-each-ref", "--format=%(refname)", "refs/heads"])
        #expect(String(decoding: branches, as: UTF8.self)
            == "refs/heads/main\nrefs/heads/side1\nrefs/heads/side2\n")
        #expect(Set([fixture.mainTip, fixture.side1Tip, fixture.side2Tip, fixture.mainRoot, fixture.side1Middle]).count == 5)
    }
}

/// The history fixtures, each one `fast-import` stream.
enum HistoryFixture {
    struct Branched {
        let repo: TestRepo
        let mainTip: String, side1Tip: String, side2Tip: String, mainRoot: String, side1Middle: String
    }

    /// Commit `n`'s time: a minute apart, from 2023-11-14.
    static func time(_ n: Int) -> Int { 1_700_000_000 + n * 60 }

    /// One commit on `branch` with mark `mark`, its author offset varied so the dates read are
    /// not all in one zone.
    static func commit(
        _ branch: String, mark: Int, time: Int, message: String, from: Int?, merge: Int? = nil
    ) -> String {
        let offsets = ["+0000", "+0200", "-0730"]
        var text = "commit refs/heads/\(branch)\nmark :\(mark)\n"
        text += "author Tester <t@t> \(time) \(offsets[mark % 3])\n"
        text += "committer Tester <t@t> \(time) +0000\n"
        text += "data \(message.utf8.count)\n\(message)\n"
        if let from { text += "from :\(from)\n" }
        if let merge { text += "merge :\(merge)\n" }
        let blob = "\(mark)\n"
        text += "M 100644 inline \(branch).txt\ndata \(blob.utf8.count)\n\(blob)\n"
        return text
    }

    /// `count` commits on `main`, `m1` (the root) to `m<count>`.
    static func linear(_ count: Int) async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        var stream = ""
        for n in 1...count {
            stream += commit("main", mark: n, time: time(n), message: "m\(n)", from: n == 1 ? nil : n - 1)
        }
        try await repo.fastImport(stream)
        return repo
    }

    /// 1,100 commits: `main` m1…m1000, `side1` (50 commits from m100, merged at m600) and `side2`
    /// (50 from m400, merged at m900). Both side branches keep their refs. git lists each side
    /// branch right after its merge, and its lane stays open down to its fork (m100, m400), across
    /// row 500 of the history.
    static func branched() async throws -> Branched {
        let repo = try await TestRepo.makeEmpty()
        var stream = ""
        func side(_ name: String, firstMark: Int, fork: Int) {
            for k in 0..<50 {
                let mark = firstMark + k
                stream += commit(
                    name, mark: mark, time: time(fork) + (k + 1) * 6, message: "\(name)-\(k + 1)",
                    from: k == 0 ? fork : mark - 1)
            }
        }
        func main(_ range: ClosedRange<Int>) {
            for n in range {
                let merge = n == 600 ? 2_049 : n == 900 ? 3_049 : nil
                stream += commit("main", mark: n, time: time(n), message: "m\(n)", from: n == 1 ? nil : n - 1, merge: merge)
            }
        }
        main(1...599)
        side("side1", firstMark: 2_000, fork: 100)
        main(600...899)
        side("side2", firstMark: 3_000, fork: 400)
        main(900...1000)
        try await repo.fastImport(stream)

        return Branched(
            repo: repo,
            mainTip: try await repo.revParse("refs/heads/main"),
            side1Tip: try await repo.revParse("refs/heads/side1"),
            side2Tip: try await repo.revParse("refs/heads/side2"),
            mainRoot: try await repo.revParse("refs/heads/main~999"),
            side1Middle: try await repo.revParse("refs/heads/side1~25"))
    }

    static func count(_ repo: TestRepo) async throws -> Int {
        let data = try await repo.git(["rev-list", "--count", "--all"])
        return Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    }
}
