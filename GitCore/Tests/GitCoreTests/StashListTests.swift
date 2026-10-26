import Foundation
import Testing

@testable import GitCore

/// Reading the stash list and showing an entry, against real repositories. Every stash here is
/// made by the TEST through `repo.git`: Task 3 only reads.
@Suite struct StashListTests {
    private func makeRepo() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        return repo
    }

    @Test func noStashesIsAnEmptyList() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }

        #expect(try await CLIGitBackend().stashes(at: repo.root) == [])
        #expect(try await CLIGitBackend().snapshot(at: repo.root).stashes == [])
    }

    @Test func aRepositoryWithNoCommitsHasNoStashes() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }

        #expect(try await CLIGitBackend().stashes(at: repo.root) == [])
    }

    @Test func twoPushesAreListedNewestFirstWithIndexMessageBranchAndDate() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        let before = Date()
        try repo.write("a.txt", "two\n")
        try await repo.git(["stash", "push", "-q", "-m", "first"])
        try repo.write("a.txt", "three\n")
        try await repo.git(["stash", "push", "-q", "-m", "second"])

        let stashes = try await CLIGitBackend().stashes(at: repo.root)

        try #require(stashes.count == 2)
        #expect(stashes.map(\.index) == [0, 1])
        #expect(stashes.map(\.message) == ["second", "first"])
        #expect(stashes.map(\.reflogSubject) == ["On main: second", "On main: first"])
        #expect(stashes.map(\.branch) == ["main", "main"])
        #expect(stashes.map(\.kind) == [.user, .user])
        #expect(stashes.map(\.isGitDefault) == [false, false])
        #expect(stashes[0].sha == (try await repo.revParse("stash@{0}")))
        #expect(stashes[1].sha == (try await repo.revParse("stash@{1}")))
        #expect(stashes[0].id == stashes[0].sha)
        #expect(stashes[0].parents == [try await repo.headSha(), try await repo.revParse("stash@{0}^2")])
        #expect(!stashes[0].hasUntrackedPart)
        // `%ct` has one-second resolution.
        for stash in stashes {
            #expect(stash.date >= before.addingTimeInterval(-1) && stash.date <= Date().addingTimeInterval(1),
                    "\(stash.date) is not between \(before) and now")
        }
        // And the snapshot carries the same list.
        #expect(try await CLIGitBackend().snapshot(at: repo.root).stashes == stashes)
    }

    @Test func aPlainPushIsWIPOnItsBranchWithTheHeadSubjectAsItsMessage() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "two\n")
        try await repo.git(["stash", "push", "-q"])
        let short = String(try await repo.headSha().prefix(7))

        let stash = try #require(try await CLIGitBackend().stashes(at: repo.root).first)

        #expect(stash.reflogSubject.hasPrefix("WIP on main: "))
        #expect(stash.branch == "main")
        #expect(stash.message.hasSuffix(" root"))
        #expect(stash.message.hasPrefix(String(short.prefix(7))))
        #expect(stash.isGitDefault)
    }

    @Test func aUserMessageThatLooksLikeGitsDefaultIsStillTheUsers() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "two\n")
        try await repo.git(["stash", "push", "-q", "-m", "WIP on x: y"])

        let stash = try #require(try await CLIGitBackend().stashes(at: repo.root).first)

        #expect(stash.reflogSubject == "On main: WIP on x: y")
        #expect(stash.message == "WIP on x: y")
        #expect(!stash.isGitDefault)
    }

    @Test func aStashOnADetachedHeadHasNoBranch() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "--detach"])
        try repo.write("a.txt", "two\n")
        try await repo.git(["stash", "push", "-q", "-m", "detached"])

        let stash = try #require(try await CLIGitBackend().stashes(at: repo.root).first)

        #expect(stash.reflogSubject == "On (no branch): detached")
        #expect(stash.branch == nil)
        #expect(stash.message == "detached")
    }

    @Test func anEntryWithUntrackedFilesHasAThirdParent() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "two\n")
        try repo.write("u.txt", "untracked\n")
        try await repo.git(["stash", "push", "-q", "-u", "-m", "with untracked"])

        let stash = try #require(try await CLIGitBackend().stashes(at: repo.root).first)

        #expect(stash.parents.count == 3)
        #expect(stash.hasUntrackedPart)
    }

    @Test func anEntryFiledByGitterAsADiscardIsDiscarded() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "two\n")
        let sha = try await createStash(repo)
        try await repo.git(["stash", "store", "-m", "Discarded by Gitter: a.txt", sha])
        // A different commit: storing the sha already at `stash@{0}` again exits 0 and files
        // nothing (measured on git 2.54).
        try repo.write("a.txt", "three\n")
        try await repo.git(["stash", "store", "-m", "Discarded by Gitter", try await createStash(repo)])

        let stashes = try await CLIGitBackend().stashes(at: repo.root)

        try #require(stashes.count == 2)
        // Newest first: the one without the colon is not Gitter's prefix, so it is the user's.
        #expect(stashes[0].kind == .user)
        #expect(stashes[1].kind == .discarded)
        #expect(stashes[1].sha == sha)
        #expect(stashes[1].reflogSubject == "Discarded by Gitter: a.txt")
        #expect(stashes[1].message == "Discarded by Gitter: a.txt")
        #expect(stashes[1].branch == nil)
    }

    private func createStash(_ repo: TestRepo) async throws -> String {
        let created = try await repo.git(["stash", "create"])
        return String(decoding: created, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    @Test func aMessageWithANewlineIsOneLine() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "two\n")
        try await repo.git(["stash", "push", "-q", "-m", "line1\nline2"])

        let stashes = try await CLIGitBackend().stashes(at: repo.root)

        #expect(stashes.count == 1)
        #expect(stashes.first?.message == "line1 line2")
    }

    /// The fields are split by US (0x1f), and the subject is the one field that can contain
    /// one, so it is read as everything between the second separator and the last two.
    @Test func aMessageContainingTheFieldSeparatorIsStillOneRecord() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "two\n")
        try await repo.git(["stash", "push", "-q", "-m", "before"])
        try repo.write("a.txt", "three\n")
        try await repo.git(["stash", "push", "-q", "-m", "a\u{1f}b\u{1f}c"])

        let stashes = try await CLIGitBackend().stashes(at: repo.root)

        try #require(stashes.count == 2)
        #expect(stashes[0].message == "a\u{1f}b\u{1f}c")
        #expect(stashes[0].parents.count == 2)
        #expect(stashes[1].message == "before")
    }

    @Test func showingAnEntryWithUntrackedFilesGivesTheTrackedPartThenTheUntrackedAsAdditions() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\ntwo\n")
        try repo.write("u.txt", "untracked\n")
        try await repo.git(["stash", "push", "-q", "-u", "-m", "both"])
        let stash = try #require(try await CLIGitBackend().stashes(at: repo.root).first)

        let diffs = try await CLIGitBackend().stashDiff(stash, at: repo.root)

        try #require(diffs.count == 2)
        #expect(diffs[0].displayPath == "a.txt")
        #expect(diffs[0].kind == .modified)
        #expect(diffs[0].hunks.flatMap(\.lines).filter { $0.kind == .added }.map(\.text) == ["two"])
        #expect(diffs[1].displayPath == "u.txt")
        #expect(diffs[1].kind == .added)
        #expect(diffs[1].hunks.flatMap(\.lines).map(\.text) == ["untracked"])
    }

    /// The two parts kept apart, for the detail's "Untracked" heading: a tracked file *added*
    /// in the entry (staged) is an addition too, and must not be taken for an untracked one.
    @Test func anEntrysContentsKeepTheTrackedAndTheUntrackedPartApart() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\ntwo\n")
        try repo.write("new.txt", "staged new\n")
        try await repo.git(["add", "new.txt"])
        try repo.write("u.txt", "untracked\n")
        try await repo.git(["stash", "push", "-q", "-u", "-m", "both"])
        let stash = try #require(try await CLIGitBackend().stashes(at: repo.root).first)

        let contents = try await CLIGitBackend().stashContents(stash, at: repo.root)

        #expect(contents.tracked.map(\.displayPath) == ["a.txt", "new.txt"])
        #expect(contents.tracked.map(\.kind) == [.modified, .added])
        #expect(contents.untracked.map(\.displayPath) == ["u.txt"])
        #expect(contents.all == (try await CLIGitBackend().stashDiff(stash, at: repo.root)))
    }

    @Test func showingAnEntryWithoutUntrackedFilesGivesOnlyTheTrackedPart() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\ntwo\n")
        try await repo.git(["stash", "push", "-q", "-m", "tracked"])
        let stash = try #require(try await CLIGitBackend().stashes(at: repo.root).first)

        let diffs = try await CLIGitBackend().stashDiff(stash, at: repo.root)

        #expect(diffs.map(\.displayPath) == ["a.txt"])
    }

    /// `diff-tree` with explicit flags is immune to the diff config that reshapes `stash show
    /// -p` (M A.6), so the same entry parses the same with that config set.
    @Test func showingAnEntryIgnoresTheUsersDiffConfig() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\ntwo\n")
        try repo.write("u.txt", "untracked\n")
        try await repo.git(["stash", "push", "-q", "-u", "-m", "both"])
        let stash = try #require(try await CLIGitBackend().stashes(at: repo.root).first)
        let plain = try await CLIGitBackend().stashDiff(stash, at: repo.root)
        try #require(plain.count == 2)

        for (key, value) in [
            ("diff.noprefix", "true"), ("color.ui", "always"), ("diff.context", "0"),
            ("diff.srcPrefix", "SRC/"), ("diff.external", "/usr/bin/false"),
        ] {
            try await repo.git(["config", key, value])
        }

        #expect(try await CLIGitBackend().stashDiff(stash, at: repo.root) == plain)
    }
}
