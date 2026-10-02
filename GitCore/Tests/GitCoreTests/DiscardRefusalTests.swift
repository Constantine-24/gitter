import Foundation
import Testing

@testable import GitCore

/// Every refusal comes before anything is written: the repository — HEAD, the index, every
/// ref, `refs/stash` included — and the worktree are exactly as they were, and the Trash holds
/// nothing.
@Suite struct DiscardRefusalTests {
    private let backend = CLIGitBackend()

    private func expectRefused(
        _ request: DiscardRequest, _ refusal: DiscardRefusal, in repo: TestRepo,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let stash = try await repo.stashRef()
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }

        await #expect(throws: refusal, sourceLocation: sourceLocation) {
            _ = try await backend.discard(request, trasher: trasher, at: repo.root)
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree, sourceLocation: sourceLocation)
        #expect(try await repo.stashRef() == stash, "refs/stash moved", sourceLocation: sourceLocation)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trasher.folder.path).isEmpty,
                "something went to the Trash", sourceLocation: sourceLocation)
    }

    private func unstaged(_ paths: [String], _ repo: TestRepo) async throws -> DiscardRequest {
        .unstaged(paths: paths, expected: try await backend.discardExpectation(tracked: paths, includingStaged: false, at: repo.root))
    }

    private func staged(_ paths: [String], _ repo: TestRepo) async throws -> DiscardRequest {
        .stagedAndUnstaged(paths: paths, expected: try await backend.discardExpectation(tracked: paths, includingStaged: true, at: repo.root))
    }

    private func untracked(_ paths: [String], _ repo: TestRepo) async throws -> DiscardRequest {
        .untracked(paths: paths, expected: try await backend.discardExpectation(untracked: paths, at: repo.root))
    }

    // MARK: Operation in progress

    enum Stopped: String, CaseIterable, Sendable { case merge, cherryPick, squash, rebase }

    private func makeStopped(_ kind: Stopped) async throws -> (TestRepo, RepositoryOperation) {
        let repo: TestRepo
        let operation: RepositoryOperation
        switch kind {
        case .merge:
            repo = try await TestRepo.makeConflicting()
            try await repo.git(["merge", "feature"], allowedExitCodes: [1])
            operation = .merge
        case .cherryPick:
            repo = try await TestRepo.makeConflicting()
            try await repo.git(["cherry-pick", "feature"], allowedExitCodes: [1])
            operation = .cherryPick
        case .squash:
            repo = try await TestRepo.makeDiverged()
            try await repo.git(["merge", "--squash", "feature"])
            operation = .squash
        case .rebase:
            repo = try await TestRepo.makeConflicting()
            try await repo.git(["switch", "-q", "feature"])
            try await repo.git(["rebase", "main"], allowedExitCodes: [1])
            operation = .rebase
        }
        try repo.write("keep.txt", "keep\ndirty\n")
        try repo.write("u.txt", "u\n")
        return (repo, operation)
    }

    /// A2 Task 4 lifted A1's refusal: during each stop, every kind runs on a file the operation
    /// never touched, and the operation's files are as they were (`DiscardDuringOperationTests`
    /// has the operation's own paths, which the staged side refuses).
    @Test(arguments: Stopped.allCases)
    func noKindIsRefusedForTheOperationAlone(_ kind: Stopped) async throws {
        let (repo, operation) = try await makeStopped(kind)
        defer { repo.cleanUp() }
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        #expect(try await backend.operationInProgress(at: repo.root) == operation)
        let before = try await OperationState.capture(repo)
        let file = try await loadDiff(repo, "keep.txt")

        _ = try await backend.discard(
            try linesRequest(file, hunks: everyHunkID(file), lines: nil), trasher: trasher, at: repo.root)
        #expect(try repo.bytes("keep.txt") == Data("keep\n".utf8))
        try repo.write("keep.txt", "keep\ndirty\n")
        _ = try await backend.discard(try await unstaged(["keep.txt"], repo), trasher: trasher, at: repo.root)
        #expect(try repo.bytes("keep.txt") == Data("keep\n".utf8))
        try repo.write("keep.txt", "keep\nstaged\n")
        try await repo.git(["add", "--", "keep.txt"])
        _ = try await backend.discard(try await staged(["keep.txt"], repo), trasher: trasher, at: repo.root)
        #expect(try repo.bytes("keep.txt") == Data("keep\n".utf8))
        #expect(try await repo.indexContent(of: "keep.txt") == Data("keep\n".utf8))
        _ = try await backend.discard(try await untracked(["u.txt"], repo), trasher: trasher, at: repo.root)
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("u.txt").path))

        try await assertOperationUnchanged(repo, since: before)
    }

    // MARK: Paths the record cannot take

    @Test func anUnmergedPathIsRefused() async throws {
        let repo = try await TestRepo.makeConflicting()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "feature"], allowedExitCodes: [1])
        // Unmerged without an operation: MERGE_HEAD gone, the stages kept.
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent(".git/MERGE_HEAD"))
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent(".git/MERGE_MSG"))
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent(".git/MERGE_MODE"))
        #expect(try await repo.unmergedEntries().isEmpty == false)

        try await expectRefused(.unstaged(paths: ["a.txt"], expected: .diffs([])), .unmerged(["a.txt"]), in: repo)
        try await expectRefused(.stagedAndUnstaged(paths: ["a.txt"], expected: .diffs([])), .unmerged(["a.txt"]), in: repo)
    }

    @Test func anIntentToAddPathIsRefused() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try repo.write("n", "n\n")
        try await repo.git(["add", "-N", "n"])

        try await expectRefused(try await unstaged(["n"], repo), .intentToAdd(["n"]), in: repo)
        try await expectRefused(try await staged(["n", "p"], repo), .intentToAdd(["n"]), in: repo)
    }

    @Test func aNestedRepositoryIsRefusedAsUntracked() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try repo.write("nested/x", "x\n")
        try await TestRepo(root: repo.root.appendingPathComponent("nested")).git(["init", "-q"])

        try await expectRefused(try await untracked(["nested/"], repo), .nestedRepositories(["nested/"]), in: repo)
        try await expectRefused(try await untracked(["nested/x"], repo), .nestedRepositories(["nested/x"]), in: repo)
    }

    /// Fix round 1: status shows `? ud/` for a directory that holds a repository further down
    /// (`ud/inner/.git`); the Trash would take that repository whole. Refused as one.
    @Test func anUntrackedDirectoryHoldingARepositoryIsRefused() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try repo.write("ud/a", "a\n")
        try repo.write("ud/inner/x", "x\n")
        try await TestRepo(root: repo.root.appendingPathComponent("ud/inner")).git(["init", "-q"])

        try await expectRefused(try await untracked(["ud/"], repo), .nestedRepositories(["ud/"]), in: repo)
    }

    @Test func aFileAndADirectoryThatSwappedAreRefused() async throws {
        let a = try await makeTypeSwapA()
        defer { a.cleanUp() }
        try await expectRefused(.stagedAndUnstaged(paths: ["p"], expected: .diffs([])), .pathTypeChanged(["p"]), in: a)
        try await expectRefused(.unstaged(paths: ["p"], expected: .diffs([])), .pathTypeChanged(["p"]), in: a)
        let b = try await makeTypeSwapB()
        defer { b.cleanUp() }
        try await expectRefused(.unstaged(paths: ["d/a"], expected: .diffs([])), .pathTypeChanged(["d/a"]), in: b)
    }

    @Test func aPathTheKindCannotTakeIsNotTracked() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try repo.write("u.txt", "u\n")
        try await repo.git(["rm", "-q", "d"])

        try await expectRefused(.unstaged(paths: ["u.txt"], expected: .diffs([])), .notTracked(["u.txt"]), in: repo)
        // A staged deletion has no unstaged layer: only the staged side can discard it.
        try await expectRefused(.unstaged(paths: ["d", "p"], expected: .diffs([])), .notTracked(["d"]), in: repo)
        try await expectRefused(.stagedAndUnstaged(paths: ["p", "u.txt"], expected: .diffs([])), .notTracked(["u.txt"]), in: repo)
        // A tracked file is not trashed.
        try await expectRefused(try await untracked(["k"], repo), .changedSinceShown(["k"]), in: repo)
    }

    @Test func noPathsOrNothingChangedIsNothingSelected() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await expectRefused(.unstaged(paths: [], expected: .diffs([])), .nothingSelected, in: repo)
        try await expectRefused(.untracked(paths: [], expected: .untracked([])), .nothingSelected, in: repo)
        try await expectRefused(try await unstaged(["p"], repo), .nothingSelected, in: repo)
    }

    // MARK: Lines that have to be a whole file

    /// A one-line file replaced: the hunk has no context line, which git anchors only to an
    /// exact preimage (and `--unidiff-zero` is never passed). The sheet offers the whole file.
    @Test func aContextFreeSelectionNeedsTheWholeFile() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try repo.write("one", "a\n")
        try await repo.git(["add", "one"])
        try await repo.git(["commit", "-q", "-m", "one", "--", "one"])
        try repo.write("one", "b\n")
        let file = try await loadDiff(repo, "one")
        let request = try linesRequest(file, hunks: everyHunkID(file), lines: nil)
        guard case .lines(_, let patch, _, _) = request else { return }
        #expect(patch.hasContextFreeHunk)

        try await expectRefused(request, .needsWholeFile("one"), in: repo)
    }

    /// Fix round 3 (review, measured with plain git 2.54): a worktree `git apply` writes the
    /// whole file back through the checkout conversion, so a file not in its checkout form has
    /// every line's ending rewritten, not only the selected ones — `autocrlf=true` turns an LF
    /// file all CRLF, `autocrlf=input` a CRLF file all LF. Such a file is discarded whole or
    /// not at all: refused, with the file, the index and `refs/stash` as they were.
    @Test(arguments: ["true/lf", "input/crlf"])
    func aFileNotInItsCheckoutFormNeedsTheWholeFile(_ shape: String) async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        let (autocrlf, ending) = shape == "true/lf" ? ("true", "\n") : ("input", "\r\n")
        try await repo.git(["config", "core.autocrlf", autocrlf])
        func bytes(_ text: String) -> Data { Data(text.replacingOccurrences(of: "\n", with: ending).utf8) }
        try bytes(numbered(30, [3: "3 A", 15: "15 B", 27: "27 C"])).write(to: repo.root.appendingPathComponent("f3"))
        let file = try await loadDiff(repo, "f3")
        let request = try linesRequest(file, hunks: [try hunkID(file, containing: "15 B")], lines: nil)

        try await expectRefused(request, .needsWholeFile("f3"), in: repo)
        #expect(try repo.bytes("f3") == bytes(numbered(30, [3: "3 A", 15: "15 B", 27: "27 C"])))
    }

    @Test func aBinaryARenameOrADeletionNeedsTheWholeFile() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        let file = try await loadDiff(repo, "k")
        let patch = try #require(PatchBuilder.discardPatch(file: file, hunkIDs: everyHunkID(file), lineIDs: nil))
        for (kind, isBinary) in [(FileDiffKind.modified, true), (.renamed, false), (.deleted, false), (.added, false)] {
            let shown = FileDiff(oldPath: "k", newPath: "k", kind: kind, isBinary: isBinary, hunks: file.hunks,
                                 oldBlob: file.oldBlob, newBlob: file.newBlob)
            try await expectRefused(
                .lines(path: "k", patch: patch, lineCount: 1, expected: .diffs([shown])), .needsWholeFile("k"), in: repo)
        }
    }

    // MARK: RF3: stale

    /// The file changed between the sheet (`expected`) and the confirm: refused, no record.
    @Test(arguments: [DiscardCase.unstagedModified, .stagedBothLayers, .linesOneHunkOfThree, .untrackedFile, .untrackedDirectory])
    func aFileEditedAfterItWasShownIsRefused(_ kind: DiscardCase) async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await kind.prepare(repo)
        let request = try await kind.request(repo)
        switch kind {
        case .unstagedModified, .stagedBothLayers: try repo.write("p", numbered(12, [5: "5 edited while shown"]))
        case .linesOneHunkOfThree: try repo.write("f3", numbered(30, [3: "3 A", 15: "15 B", 20: "20 new", 27: "27 C"]))
        case .untrackedFile: try repo.write("u.txt", "u\nmore\n")
        case .untrackedDirectory: try repo.write("ud/deeper/b", "b\nmore\n")
        default: return
        }

        try await expectRefused(request, .changedSinceShown(kind.paths), in: repo)
    }

    /// A staged-only change while the sheet was up counts too: the index side is part of what
    /// the staged-side sheet showed.
    @Test func aStagedChangeAfterItWasShownIsRefused() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await DiscardCase.stagedBothLayers.prepare(repo)
        let request = try await DiscardCase.stagedBothLayers.request(repo)
        try await repo.git(["add", "p"])  // worktree unchanged; the split moved

        try await expectRefused(request, .changedSinceShown(["p"]), in: repo)
    }

    /// A binary file under a path with ` b/` in it (`diff --git a/plan b/blob.bin b/plan
    /// b/blob.bin`, no `---`/`+++` lines) is in what the sheet showed, so an edit to it while the
    /// sheet is up is found. Its header was split at the wrong ` b/`, its diff dropped from the
    /// batched read, and the discard went ahead.
    @Test func aBinaryUnderAPathWithBSlashEditedAfterItWasShownIsRefused() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        let blob = try repo.url("plan b/blob.bin")
        try repo.write("a b.txt", "a\n")
        try Data([0x00, 0x01, 0x62]).write(to: blob)
        try await repo.git(["add", "--", "a b.txt", "plan b/blob.bin"])
        try await repo.git(["commit", "-q", "-m", "b slash"])
        try repo.write("a b.txt", "a\nmore\n")
        try Data([0x00, 0x02, 0x62]).write(to: blob)
        let request = try await unstaged(["a b.txt", "plan b/blob.bin"], repo)
        guard case .unstaged(_, .diffs(let shown)) = request else {
            Issue.record("not an unstaged request")
            return
        }
        #expect(shown.map(\.displayPath) == ["a b.txt", "plan b/blob.bin"], "the sheet shows both files")
        let edited = Data([0x00, 0x03, 0x62])
        try edited.write(to: blob)

        try await expectRefused(request, .changedSinceShown(["a b.txt", "plan b/blob.bin"]), in: repo)
        #expect(try Data(contentsOf: blob) == edited, "the edit made while the sheet was up is gone")
    }

    /// A patch that does not come from the diff shown (other blob ids) is stale by definition.
    @Test func aPatchFromAnotherDiffIsRefused() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await DiscardCase.linesOneHunkOfThree.prepare(repo)
        let shown = try await loadDiff(repo, "f3")
        guard case .lines(_, let patch, let count, _) = try await DiscardCase.linesOneHunkOfThree.request(repo) else { return }
        let other = Patch(text: patch.text, hasContextFreeHunk: false, path: "f3", oldBlob: patch.oldBlob,
                          newBlob: String(repeating: "0", count: 40))

        try await expectRefused(.lines(path: "f3", patch: other, lineCount: count, expected: .diffs([shown])),
                                .changedSinceShown(["f3"]), in: repo)
    }

    /// Before the first commit there is no HEAD to record against: the survey's `ls-tree HEAD`
    /// fails in git's words (`fatal: Not a valid object name HEAD`) and nothing is written.
    @Test func aTrackedDiscardBeforeTheFirstCommitFailsInGitsWordsAndWritesNothing() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a", "a\n")
        try await repo.git(["add", "a"])
        try repo.write("a", "a\nb\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect {
            _ = try await backend.discard(try await unstaged(["a"], repo), trasher: try FakeTrasher(), at: repo.root)
        } throws: { error in
            guard case GitError.commandFailed(_, let stderr) = error else { return false }
            return stderr.contains("HEAD")
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    // MARK: index.lock

    /// `restore` cannot take `index.lock` (M A.5), and fails after the record was filed — the
    /// record uses a temporary index and `refs/stash`, neither of which needs that lock. The
    /// files are provably unchanged afterwards, so the record is dropped again and git's own
    /// words are thrown: nothing is left behind.
    @Test(arguments: [DiscardCase.unstagedModified, .stagedBothLayers])
    func aLockedIndexLeavesNoRecordAndSaysSoInGitsWords(_ kind: DiscardCase) async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await kind.prepare(repo)
        let request = try await kind.request(repo)
        let lock = repo.root.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect {
            _ = try await backend.discard(request, trasher: try FakeTrasher(), at: repo.root)
        } throws: { error in
            guard case GitError.commandFailed(_, let stderr) = error else { return false }
            return stderr.contains("index.lock") && stderr.contains("File exists")
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.stashRef() == nil, "a record was left behind")
    }

    /// A worktree `apply` takes no index lock: a line discard goes through with one present.
    @Test func aLineDiscardDoesNotNeedTheIndexLock() async throws {
        let repo = try await makeDiscardLab()
        defer { repo.cleanUp() }
        try await DiscardCase.linesOneHunkOfThree.prepare(repo)
        let request = try await DiscardCase.linesOneHunkOfThree.request(repo)
        let lock = repo.root.appendingPathComponent(".git/index.lock")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }

        let receipt = try await backend.discard(request, trasher: try FakeTrasher(), at: repo.root)

        #expect(receipt.record != nil)
        #expect(try repo.bytes("f3") == Data(numbered(30, [3: "3 A", 27: "27 C"]).utf8))
    }
}
