import Foundation
import Testing

@testable import GitCore

/// Discard, every kind: recorded first (tracked) or moved to the Trash (untracked), and only
/// what was named changes. Every test runs beside `h` (two layers) and `k` (unstaged), which
/// must come through byte-identical (RF1).
@Suite struct DiscardTests {
    private let backend = CLIGitBackend()

    @Test(arguments: DiscardCase.allCases)
    func eachKindDiscardsWhatItNamesAndRecordsItFirst(_ kind: DiscardCase) async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        let head = worktreeState(repo)
        try await kind.prepare(repo)
        let bystanders = try await Bystanders.capture(repo)
        let before = worktreeState(repo)
        var named: [String: (index: String, entry: WorktreeEntry?)] = [:]
        for path in kind.paths {
            named[path] = (try await repo.indexLine(path), before[StashRecord.withoutTrailingSlash(path)])
        }
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let request = try await kind.request(repo)

        let receipt = try await backend.discard(request, trasher: trasher, at: repo.root)

        try await bystanders.assertUnchanged(repo, "by the discard")
        try await kind.expectDiscarded(repo, head: head)
        #expect(receipt.request == request)
        #expect(receipt.headAtDiscard == (try await repo.headSha()))
        if kind.isUntracked {
            #expect(receipt.record == nil)
            #expect(try await repo.stashRef() == nil, "an untracked discard filed a record")
            for path in kind.paths {
                let trashed = try #require(receipt.trashed[path])
                #expect(trashed.path.hasPrefix(trasher.folder.path))
                #expect(FileManager.default.fileExists(atPath: trashed.path))
            }
            let file = try #require(receipt.trashed[kind.paths[0]])
            let inside = kind == .untrackedDirectory ? file.appendingPathComponent("deeper/b") : file
            #expect(try Data(contentsOf: inside) == Data((kind == .untrackedDirectory ? "b\n" : "u\n").utf8))
            return
        }

        // The record is the one entry, filed before the change, and holds exactly what was
        // there: applied with --index in a clean clone, both layers come back byte for byte.
        let record = try #require(receipt.record)
        #expect(receipt.trashed.isEmpty)
        #expect(try await repo.stashShas() == [record.sha])
        #expect(record.kind == .discarded)
        #expect(record.reflogSubject == request.recordMessage)
        #expect(record.parents.first == receipt.headAtDiscard)
        let clone = try await cloneApplyingRecord(repo, record.sha)
        defer { clone.cleanUp() }
        let cloned = worktreeState(clone)
        for path in kind.paths {
            #expect(try await clone.indexLine(path) == named[path]?.index, "\(path)'s index entry in the record")
            #expect(cloned[path] == named[path]?.entry, "\(path) in the record: \(cloned[path]?.description ?? "<absent>")")
        }
    }

    /// Hunks and lines leave the index alone: only the worktree is patched.
    @Test(arguments: [DiscardCase.linesOneHunkOfThree, .linesTwoLinesOfAHunk])
    func linesLeaveTheIndexUntouched(_ kind: DiscardCase) async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await kind.prepare(repo)
        let index = try await RepoState.capture(repo).index
        #expect(!index.isEmpty)

        _ = try await backend.discard(try await kind.request(repo), trasher: try FakeTrasher(), at: repo.root)

        #expect(try await RepoState.capture(repo).index == index)
    }

    /// Why `discardPatch` builds as `.unstage` does: a `.stage` patch of two lines out of a hunk
    /// keeps the index side of the unselected `-15`/`+15 B`, which the worktree does not have,
    /// and git refuses it. Nothing changes, and the record made for it is dropped again.
    @Test func aStagePatchOfPartOfAHunkDoesNotFitTheWorktree() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await DiscardCase.linesTwoLinesOfAHunk.prepare(repo)
        let file = try await loadDiff(repo, "f3")
        let hunk = try hunkID(file, containing: "15a")
        let lines = changedLineIDs(file, "15a", "15b")
        let stagePatch = try #require(PatchBuilder.patch(file: file, hunkIDs: [hunk], lineIDs: lines, direction: .stage))
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect {
            _ = try await backend.discard(
                .lines(path: "f3", patch: stagePatch, lineCount: 2, expected: .diffs([file])),
                trasher: try FakeTrasher(), at: repo.root)
        } throws: { error in
            guard case GitError.commandFailed(_, let stderr) = error else { return false }
            return stderr.contains("patch does not apply")
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    /// `restore` is all or nothing for a pathspec or a lock, but not for the file system
    /// (measured): with one file in a read-only directory it restores the other, says
    /// `error: unable to unlink old 'ro/r': Permission denied` and exits 255. The files did
    /// change, so the record stays, and the error names it.
    @Test func aRestoreThatFailsPartWayKeepsTheRecordAndNamesIt() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try repo.write("ro/r", "r\n")
        try await repo.git(["add", "ro/r"])
        try await repo.git(["commit", "-q", "-m", "ro", "--", "ro/r"])
        try repo.write("p", numbered(12, [5: "5 mod"]))
        try repo.write("ro/r", "r\nr2\n")
        try repo.chmod("ro", 0o555)
        defer { try? repo.chmod("ro", 0o755) }
        let request = DiscardRequest.unstaged(
            paths: ["p", "ro/r"],
            expected: try await backend.discardExpectation(tracked: ["p", "ro/r"], includingStaged: false, at: repo.root))

        let failure = await #expect(throws: DiscardFailure.self) {
            _ = try await backend.discard(request, trasher: try FakeTrasher(), at: repo.root)
        }

        let record = try #require(failure?.receipt.record)
        #expect(failure?.gitsWords.contains("Permission denied") == true, "\(failure?.gitsWords ?? "")")
        #expect(try await repo.stashShas() == [record.sha])
        #expect(try repo.bytes("p") == Data(numbered(12).utf8), "p was restored before the failure")
        #expect(try repo.bytes("ro/r") == Data("r\nr2\n".utf8))
        #expect(try await repo.blob(record.sha, "p") == Data(numbered(12, [5: "5 mod"]).utf8))
    }

    /// RF4: names git would read as patterns, magic or options, and names with spaces and
    /// non-ASCII letters, discarded together — and only they. `a1.txt`, which `a*.txt` would
    /// match as a glob, keeps its change.
    @Test func namesThatLookLikePatternsOrFlagsDiscardExactlyThemselves() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        let names = ["a*.txt", "-dash", ":colon", "sp ace", "ünï", "[x].txt"]
        for name in names + ["a1.txt"] { try repo.write(name, "\(name)\n") }
        let literal = (names + ["a1.txt"]).map { ":(literal)" + $0 }
        try await repo.git(["add", "--"] + literal)
        // Only these: h's staged layer stays out of the commit.
        try await repo.git(["commit", "-q", "-m", "names", "--"] + literal)
        for name in names + ["a1.txt"] { try repo.write(name, "\(name)\nchanged\n") }
        try repo.write("?q u", "untracked\n")
        try repo.write("a?.txt", "untracked too\n")
        let bystanders = try await Bystanders.capture(repo)

        let receipt = try await backend.discard(
            .unstaged(paths: names, expected: try await backend.discardExpectation(tracked: names, includingStaged: false, at: repo.root)),
            trasher: try FakeTrasher(), at: repo.root)

        for name in names { #expect(try repo.bytes(name) == Data("\(name)\n".utf8), "\(name)") }
        #expect(try repo.bytes("a1.txt") == Data("a1.txt\nchanged\n".utf8))
        #expect(receipt.record?.reflogSubject == "Discarded by Gitter: a*.txt, -dash, :colon and 3 more")
        let record = try #require(receipt.record)
        #expect(Set(try await repo.nameStatus(from: "\(record.sha)^1", to: record.sha)) == Set(names.map { "M\t\($0)" }))

        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let untracked = ["?q u", "a?.txt"]
        let trashed = try await backend.discard(
            .untracked(paths: untracked, expected: try await backend.discardExpectation(untracked: untracked, at: repo.root)),
            trasher: trasher, at: repo.root)
        #expect(Set(trashed.trashed.keys) == Set(untracked))
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("?q u").path))
        #expect(try repo.bytes("a1.txt") == Data("a1.txt\nchanged\n".utf8))
        try await bystanders.assertUnchanged(repo, "by the named discards")
    }

    /// `submodule.recurse=true` would make `restore --worktree -- sub` throw away the work
    /// inside the submodule (M A.5). A submodule is refused before anything runs, and every
    /// vector carries `--no-recurse-submodules` besides.
    @Test func aSubmoduleIsRefusedWithRecursionConfigured() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try repo.write("sub/s", "s\n")
        let sub = TestRepo(root: repo.root.appendingPathComponent("sub"))
        try await sub.git(["init", "-q", "-b", "main"])
        try await sub.git(["-c", "user.name=T", "-c", "user.email=t@t", "add", "s"])
        try await sub.git(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "s"])
        try await repo.git(["add", "sub"])
        try await repo.git(["commit", "-q", "-m", "sub"])
        try await repo.git(["config", "submodule.recurse", "true"])
        try repo.write("sub/s", "s\nwork inside\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        for request in [
            DiscardRequest.unstaged(paths: ["sub"], expected: .diffs([])),
            .stagedAndUnstaged(paths: ["sub", "p"], expected: .diffs([])),
        ] {
            await #expect(throws: DiscardRefusal.submodules(["sub"])) {
                _ = try await backend.discard(request, trasher: try FakeTrasher(), at: repo.root)
            }
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try repo.bytes("sub/s") == Data("s\nwork inside\n".utf8))
    }

    /// `apply.whitespace=fix` would silently drop trailing spaces the patch puts back (M 9);
    /// `--whitespace=nowarn` keeps them, both ways.
    @Test func trailingSpacesComeBackExactlyUnderApplyWhitespaceFix() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await repo.git(["config", "apply.whitespace", "fix"])
        let edited = Data("a\ny   \nb\n".utf8)
        try edited.write(to: repo.root.appendingPathComponent("ws"))
        let file = try await loadDiff(repo, "ws")
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }

        let receipt = try await backend.discard(
            try linesRequest(file, hunks: everyHunkID(file), lines: changedLineIDs(file, "x   ", "y   ")),
            trasher: trasher, at: repo.root)
        #expect(try repo.bytes("ws") == Data("a\nx   \nb\n".utf8))

        #expect(try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root) == .restored)
        #expect(try repo.bytes("ws") == edited)
    }

    /// Ruling 2: a Latin-1 file has no partial discard (its diff is not UTF-8), but is
    /// discarded whole and put back byte for byte.
    @Test func aLatin1FileIsDiscardedWholeAndComesBackByteExact() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        let committed = Data("a\n".utf8) + Data([0x63, 0x61, 0x66, 0xE9, 0x0A]) + Data("b\n".utf8)
        try committed.write(to: repo.root.appendingPathComponent("latin1"))
        try await repo.git(["add", "latin1"])
        try await repo.git(["commit", "-q", "-m", "latin1"])
        let edited = committed + Data([0xFC, 0x62, 0x65, 0x72, 0x0A])  // "\xFCber\n"
        try edited.write(to: repo.root.appendingPathComponent("latin1"))
        let file = try await loadDiff(repo, "latin1")
        #expect(file.isValidUTF8 == false)
        #expect(PatchBuilder.supportsPartialDiscard(file) == false)
        #expect(PatchBuilder.discardPatch(file: file, hunkIDs: everyHunkID(file), lineIDs: nil) == nil)

        // A patch made from its U+FFFD text anyway is refused before anything runs.
        let lossy = try #require(PatchBuilder.patch(
            file: FileDiff(oldPath: "latin1", newPath: "latin1", kind: .modified, isBinary: false,
                           hunks: file.hunks, oldBlob: file.oldBlob, newBlob: file.newBlob),
            hunkIDs: everyHunkID(file), lineIDs: nil, direction: .unstage))
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        await #expect(throws: DiscardRefusal.needsWholeFile("latin1")) {
            _ = try await backend.discard(
                .lines(path: "latin1", patch: lossy, lineCount: 1, expected: .diffs([file])),
                trasher: try FakeTrasher(), at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)

        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let receipt = try await backend.discard(
            .unstaged(paths: ["latin1"], expected: try await backend.discardExpectation(tracked: ["latin1"], includingStaged: false, at: repo.root)),
            trasher: trasher, at: repo.root)
        #expect(try repo.bytes("latin1") == committed)
        #expect(try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root) == .restored)
        #expect(try repo.bytes("latin1") == edited)
    }

    @Test func theRecordMessageNamesAtMostThreeAndCountsLines() throws {
        let e = DiscardExpectation.diffs([])
        #expect(DiscardRequest.unstaged(paths: ["a"], expected: e).recordMessage == "Discarded by Gitter: a")
        #expect(DiscardRequest.stagedAndUnstaged(paths: ["a", "b", "c"], expected: e).recordMessage
                == "Discarded by Gitter: a, b, c")
        #expect(DiscardRequest.untracked(paths: ["a", "b", "c", "d"], expected: .untracked([])).recordMessage
                == "Discarded by Gitter: a, b, c and 1 more")
        let patch = Patch(text: "", hasContextFreeHunk: false, path: "f", oldBlob: nil, newBlob: nil)
        #expect(DiscardRequest.lines(path: "f", patch: patch, lineCount: 1, expected: e).recordMessage
                == "Discarded by Gitter: 1 line in f")
        #expect(DiscardRequest.lines(path: "f", patch: patch, lineCount: 3, expected: e).recordMessage
                == "Discarded by Gitter: 3 lines in f")
    }

    /// The negative control `Bystanders.assertUnchanged` needs: h's staged layer lost.
    @Test func bystandersNoticeALostStagedLayer() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        let bystanders = try await Bystanders.capture(repo)
        try await repo.git(["restore", "--staged", "h"])

        await withKnownIssue("h's staged layer is gone") {
            try await bystanders.assertUnchanged(repo, "on purpose")
        }
    }

    /// The negative control `assertWorktreeState` needs: it notices a changed executable bit,
    /// a retargeted link and an emptied directory, none of which `worktreeSnapshot` can see.
    @Test func assertWorktreeStateNoticesModesLinksAndDirectories() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try repo.write("dir/x", "x\n")
        let before = worktreeState(repo)
        let bytesBefore = worktreeSnapshot(repo)
        try repo.chmod("s.sh", 0o755)
        try repo.relink("link", to: "k")
        try repo.remove("dir/x")

        withKnownIssue("the executable bit, the link and dir/x changed") {
            assertWorktreeState(repo, equals: before)
        }
        #expect(worktreeState(repo)["dir"]?.kind == .directory)
        #expect(bytesBefore["s.sh"] == worktreeSnapshot(repo)["s.sh"], "the byte snapshot cannot see a mode")
    }
}
