import Foundation
import Testing

@testable import GitCore

/// Ruling 26: `Process` raises an Objective-C exception — the app crashes — when it is given
/// more than 4096 arguments (measured on macOS 27: `NSInvalidArgumentException`, "too many
/// arguments (4097) -- limit is 4096", exit 134). Every public operation that takes a list of
/// paths is driven here with 5 000 of them, through the public API, and must do exactly what it
/// does for a few: the writes through `--pathspec-from-file` (one call, all or nothing), the
/// reads in batches.
///
/// Serialized: each test makes 5 000 files and runs git over all of them.
@Suite(.serialized) struct ArgumentLimitTests {
    private let backend = CLIGitBackend()

    static let count = 5_000

    /// Names that are pathspec magic or a glob unless git reads them literally, and one with a
    /// newline, which only a NUL-separated list can carry.
    static let oddNames = ["many/b[1].txt", "many/:colon.txt", "many/sp ace.txt", "many/q\"uote.txt", "many/new\nline.txt"]

    /// Not selected, and changed like the rest: `many/b[1].txt` read as a glob matches it.
    static let bystander = "many/b1.txt"

    /// `count` files under `many/` plus `oddNames` and `bystander`, committed, then each changed
    /// in the worktree — and, with `staged`, first changed and staged on another line. Returns
    /// the selection: every path but the bystander, in git's order.
    static func manyFiles(staged: Bool, committed: Bool = true) async throws -> (TestRepo, [String]) {
        let repo = try await TestRepo.makeEmpty()
        let all = (0..<count).map { String(format: "many/f%04d.txt", $0) } + oddNames + [bystander]
        for path in all { try repo.write(path, numbered(6)) }
        if committed {
            try await repo.commitAll("root")
        }
        if staged {
            for path in all { try repo.write(path, numbered(6, [2: "2 staged"])) }
            try await repo.git(["add", "-A"])
        }
        for path in all { try repo.write(path, numbered(6, [2: staged ? "2 staged" : "2", 5: "5 unstaged"])) }
        let listed = try await repo.git(committed ? ["ls-files", "-z"] : ["ls-files", "-z", "-o"])
        let selection = String(decoding: listed, as: UTF8.self).split(separator: "\0").map(String.init)
            .filter { $0 != bystander }
        #expect(selection.count == count + oddNames.count)
        return (repo, selection)
    }

    /// Each selected file holds HEAD's bytes and the bystander still holds its change.
    private func expectDiscarded(_ selection: [String], _ repo: TestRepo, bystanderBytes: Data?) {
        let now = worktreeSnapshot(repo)
        let wrong = selection.filter { now[$0] != Data(numbered(6).utf8) }
        #expect(wrong.isEmpty, "\(wrong.count) files were not put back, e.g. \(wrong.prefix(3))")
        #expect(bystanderBytes != nil && now[Self.bystander] == bystanderBytes, "the bystander changed")
    }

    private func porcelain(_ repo: TestRepo) async throws -> String {
        String(decoding: try await repo.git(["status", "--porcelain=v1", "-z"]), as: UTF8.self)
    }

    // MARK: - Discard and its undo

    /// Discard All… of 5 000 unstaged files, then Undo: every file back byte for byte, the
    /// index, HEAD and refs as they were (the record dropped). The sheet's read is the read of
    /// the directory, minus the bystander, in the same order.
    @Test func discardAllOfManyUnstagedFilesAndItsUndo() async throws {
        let (repo, selection) = try await Self.manyFiles(staged: false)
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let state = try await RepoState.capture(repo)

        let expected = try await backend.discardExpectation(tracked: selection, includingStaged: false, at: repo.root)
        let directory = try await backend.discardExpectation(tracked: ["many"], includingStaged: false, at: repo.root)
        guard case .diffs(let diffs) = expected, case .diffs(let all) = directory else {
            Issue.record("not a tracked expectation")
            return
        }
        #expect(diffs.count == selection.count)
        #expect(diffs.map(\.displayPath) == selection)
        #expect(diffs == all.filter { $0.displayPath != Self.bystander })

        let trasher = try FakeTrasher()
        let receipt = try await backend.discard(
            .unstaged(paths: selection, expected: expected), trasher: trasher, at: repo.root)
        expectDiscarded(selection, repo, bystanderBytes: before[Self.bystander])
        #expect(try await porcelain(repo) == " M \(Self.bystander)\0")

        #expect(try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root) == .restored)
        try await assertRepoUnchanged(repo, since: state, worktree: before)
    }

    /// The same for 5 000 files with a staged and an unstaged layer: the discard puts index and
    /// worktree back to HEAD, the undo restores both layers.
    @Test func discardOfManyStagedFilesAndItsUndo() async throws {
        let (repo, selection) = try await Self.manyFiles(staged: true)
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let state = try await RepoState.capture(repo)

        let expected = try await backend.discardExpectation(tracked: selection, includingStaged: true, at: repo.root)
        let directory = try await backend.discardExpectation(tracked: ["many"], includingStaged: true, at: repo.root)
        guard case .diffs(let diffs) = expected, case .diffs(let all) = directory else {
            Issue.record("not a tracked expectation")
            return
        }
        #expect(diffs.count == 2 * selection.count)
        // The directory's read is every staged diff, then every unstaged one.
        let staged = all.prefix(all.count / 2).filter { $0.displayPath != Self.bystander }
        let unstaged = all.suffix(all.count / 2).filter { $0.displayPath != Self.bystander }
        #expect(diffs == zip(staged, unstaged).flatMap { [$0, $1] })

        let trasher = try FakeTrasher()
        let receipt = try await backend.discard(
            .stagedAndUnstaged(paths: selection, expected: expected), trasher: trasher, at: repo.root)
        expectDiscarded(selection, repo, bystanderBytes: before[Self.bystander])
        #expect(try await porcelain(repo) == "MM \(Self.bystander)\0")

        #expect(try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root) == .restored)
        try await assertRepoUnchanged(repo, since: state, worktree: before)
    }

    /// A directory named beside the files under it, in another batch of the read (index 5 005,
    /// the files from 0): what one call over all of them gives — each named path its own diffs,
    /// none twice, the directory's in git's order. Read as per-path groups, that is the files'
    /// read followed by the directory's.
    @Test func aDirectoryNamedInAnotherBatchThanItsFilesReadsAsOneCall() async throws {
        let (repo, selection) = try await Self.manyFiles(staged: true)
        defer { repo.cleanUp() }

        for includingStaged in [false, true] {
            let both = try await backend.discardExpectation(
                tracked: selection + ["many"], includingStaged: includingStaged, at: repo.root)
            let files = try await backend.discardExpectation(tracked: selection, includingStaged: includingStaged, at: repo.root)
            let directory = try await backend.discardExpectation(tracked: ["many"], includingStaged: includingStaged, at: repo.root)
            guard case .diffs(let b) = both, case .diffs(let f) = files, case .diffs(let d) = directory else {
                Issue.record("not a tracked expectation")
                return
            }
            #expect(f.count == selection.count * (includingStaged ? 2 : 1))
            #expect(b.count == f.count + d.count)
            #expect(b == f + d)
        }
    }

    // MARK: - Stage and unstage

    /// Stage 5 000 selected files, then unstage them: exactly the selection staged (not the
    /// bystander a glob would add), then the index as it was.
    @Test func stagingAndUnstagingManySelectedFiles() async throws {
        let (repo, selection) = try await Self.manyFiles(staged: false)
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let state = try await RepoState.capture(repo)

        try await backend.stage(paths: selection, at: repo.root)
        let staged = try await repo.git(["diff", "--cached", "--name-only", "-z"])
        #expect(String(decoding: staged, as: UTF8.self).split(separator: "\0").map(String.init) == selection)

        try await backend.unstage(paths: selection, at: repo.root)
        try await assertRepoUnchanged(repo, since: state, worktree: before)
    }

    /// The same before the first commit, where unstaging is `rm --cached`.
    @Test func stagingAndUnstagingManySelectedFilesBeforeTheFirstCommit() async throws {
        let (repo, selection) = try await Self.manyFiles(staged: false, committed: false)
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)

        try await backend.stage(paths: selection, at: repo.root)
        let listed = try await repo.git(["ls-files", "-z"])
        #expect(String(decoding: listed, as: UTF8.self).split(separator: "\0").map(String.init) == selection)

        try await backend.unstage(paths: selection, at: repo.root)
        #expect(try await repo.git(["ls-files"]).isEmpty, "the index still holds entries")
        assertWorktreeUnchanged(repo, since: before)
    }

    // MARK: - Stash selected files

    /// Stash 5 000 selected files, then apply the entry: the files at HEAD in between, and
    /// afterwards byte for byte as before, with the index untouched.
    @Test func stashingManySelectedFilesAndApplyingThem() async throws {
        let (repo, selection) = try await Self.manyFiles(staged: false)
        defer { repo.cleanUp() }
        let before = worktreeSnapshot(repo)
        let state = try await RepoState.capture(repo)

        let outcome = try await backend.stashPaths(selection, message: "many", trasher: try FakeTrasher(), at: repo.root)
        guard case .saved(let stash) = outcome else {
            Issue.record("not saved: \(outcome)")
            return
        }
        expectDiscarded(selection, repo, bystanderBytes: before[Self.bystander])

        #expect(try await backend.apply(stash, at: repo.root) == .applied)
        assertWorktreeUnchanged(repo, since: before)
        #expect(try await RepoState.capture(repo).index == state.index)
    }

    // MARK: - All or nothing

    /// One path git does not know, last among 5 000: `add` refuses them all, and so does the
    /// unstage's `restore --staged` — nothing changes, which a write in batches would break.
    @Test func oneUnknownPathAmongManyRefusesTheWholeStageAndUnstage() async throws {
        let (repo, selection) = try await Self.manyFiles(staged: false)
        defer { repo.cleanUp() }
        let missing = "many/missing.txt"

        let before = worktreeSnapshot(repo)
        let state = try await RepoState.capture(repo)
        await #expect(throws: GitError.self) { try await backend.stage(paths: selection + [missing], at: repo.root) }
        try await assertRepoUnchanged(repo, since: state, worktree: before)

        try await backend.stage(paths: selection, at: repo.root)
        let stagedState = try await RepoState.capture(repo)
        #expect(stagedState.index != state.index)
        await #expect(throws: GitError.self) { try await backend.unstage(paths: selection + [missing], at: repo.root) }
        try await assertRepoUnchanged(repo, since: stagedState, worktree: before)
    }

    /// And a discard of 5 000 paths and one git does not know is refused before anything is
    /// written: no record, no file put back.
    @Test func oneUnknownPathAmongManyRefusesTheWholeDiscard() async throws {
        let (repo, selection) = try await Self.manyFiles(staged: false)
        defer { repo.cleanUp() }
        let missing = "many/missing.txt"
        let before = worktreeSnapshot(repo)
        let state = try await RepoState.capture(repo)

        let expected = try await backend.discardExpectation(tracked: selection, includingStaged: false, at: repo.root)
        await #expect(throws: DiscardRefusal.notTracked([missing])) {
            try await backend.discard(
                .unstaged(paths: selection + [missing], expected: expected), trasher: try FakeTrasher(), at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: before)
    }
}
