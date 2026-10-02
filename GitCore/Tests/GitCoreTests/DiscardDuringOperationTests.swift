import Foundation
import Testing

@testable import GitCore

/// A2 Task 4: discard while a merge, squash, cherry-pick, revert, rebase or `git am -3` is
/// stopped (M 20, M 21). Every kind is allowed and leaves the operation's state alone — every
/// file of it but the index (`OperationState`) — and the operation still concludes. The
/// staged side of a path the operation itself changed is refused (`.partOfOperation`): it
/// would drop that change from the commit being made (M 21). The stash stays refused.
///
/// Undo during the operation (measured, Task 4): the forward patch of a line discard and the
/// Trash's way back leave the operation alone, and run. A whole-file discard's undo goes
/// through `stash apply`, which git refuses over a conflict (`could not write index`) and
/// which otherwise rewrites `AUTO_MERGE`, so it is refused while the operation lasts
/// (`.operationInProgress`) and restores once the operation is concluded.
@Suite struct DiscardDuringOperationTests {
    private let backend = CLIGitBackend()

    enum Stop: String, CaseIterable, Sendable {
        case merge, squash, cherryPick, revert, rebase, am

        var operation: RepositoryOperation {
            switch self {
            case .merge: return .merge
            case .squash: return .squash
            case .cherryPick: return .cherryPick
            case .revert: return .revert
            case .rebase: return .rebase
            case .am: return .applyingPatches
            }
        }

        /// The git command that concludes the stop once `f.txt` is resolved.
        var conclusion: [String] {
            switch self {
            case .merge, .squash: return ["commit", "-q", "--no-edit"]
            case .cherryPick: return ["cherry-pick", "--continue"]
            case .revert: return ["revert", "--continue"]
            case .rebase: return ["rebase", "--continue"]
            case .am: return ["am", "--continue"]
            }
        }
    }

    // MARK: - The repository

    static let xBase = numbered(30)
    static let xEdited = numbered(30, [3: "3 A", 20: "20 B\n20a\n20b"])
    static let yBase = "y1\ny2\ny3\ny4\ny5\ny6\ny7\ny8\ny9\n"
    static let yStaged = "y1\ny2\ny3 STAGED\ny4\ny5\ny6\ny7\ny8\ny9\n"
    static let yBoth = "y1\ny2\ny3 STAGED\ny4\ny5\ny6\ny7 UNSTAGED\ny8\ny9\n"
    static let zBase = "z1\nz2\nz3\nz4\nz5\nz6\nz7\nz8\nz9\n"
    /// What the operation brings into `z.txt`, cleanly: it is staged by the operation itself.
    static let zTheirs = "z1\nz2\nz3\nz4\nz5 THEIRS\nz6\nz7\nz8\nz9\n"

    /// `f.txt` conflicted (UU) and `z.txt` staged by the operation (M 20's lab), stopped in
    /// `stop`.
    private func stopped(_ stop: Stop) async throws -> TestRepo {
        let prepare: ConflictFixtures.Prepare = { repo in
            try repo.write("x.txt", Self.xBase)
            try repo.write("y.txt", Self.yBase)
            try repo.write("z.txt", Self.zBase)
        }
        let onTheirs: ConflictFixtures.Prepare = { repo in try repo.write("z.txt", Self.zTheirs) }
        let repo: TestRepo
        switch stop {
        case .merge: repo = try await ConflictFixtures.merge(kind: .bothModified, prepare: prepare, onTheirs: onTheirs)
        case .squash: repo = try await ConflictFixtures.squash(kind: .bothModified, prepare: prepare, onTheirs: onTheirs)
        case .cherryPick:
            repo = try await ConflictFixtures.cherryPick(kind: .bothModified, prepare: prepare, onTheirs: onTheirs)
        case .revert: repo = try await ConflictFixtures.revert(kind: .bothModified, prepare: prepare, onTheirs: onTheirs)
        case .rebase: repo = try await ConflictFixtures.rebase(kind: .bothModified, prepare: prepare, onTheirs: onTheirs)
        case .am: repo = try await ConflictFixtures.am(kind: .bothModified, prepare: prepare, onTheirs: onTheirs)
        }
        // The stop is what the tests below rely on: an operation, f.txt unmerged, z.txt staged
        // by the operation and listed among its paths.
        #expect(try await backend.operationInProgress(at: repo.root) == stop.operation)
        #expect(try await repo.indexContent(of: "z.txt") == Data(Self.zTheirs.utf8))
        let own = try #require(try await backend.operationPaths(at: repo.root))
        #expect(Set(own) == ["f.txt", "z.txt"])
        return repo
    }

    /// The user's own changes on top of the stop: `x.txt` edited (two hunks), `y.txt` staged
    /// and edited again, `z.txt` edited over the operation's staged change, `u.txt` untracked.
    private func userChanges(_ repo: TestRepo) async throws {
        try repo.write("x.txt", Self.xEdited)
        try repo.write("y.txt", Self.yStaged)
        try await repo.git(["add", "--", "y.txt"])
        try repo.write("y.txt", Self.yBoth)
        try repo.write("z.txt", Self.zTheirs + "z10 USER\n")
        try repo.write("u.txt", "u\n")
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

    private func text(_ repo: TestRepo, _ path: String) throws -> String {
        String(decoding: try repo.bytes(path), as: UTF8.self)
    }

    /// `request` refused with `refusal` before anything was written: the worktree, HEAD, the
    /// index, every ref, `refs/stash` and the operation's files as they were, the Trash empty.
    private func expectRefused(
        _ request: DiscardRequest, _ refusal: DiscardRefusal, in repo: TestRepo,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let stash = try await repo.stashRef()
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }

        await #expect(throws: refusal, sourceLocation: sourceLocation) {
            _ = try await backend.discard(request, trasher: trasher, at: repo.root)
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree, sourceLocation: sourceLocation)
        try await assertOperationUnchanged(repo, since: operation, sourceLocation: sourceLocation)
        #expect(try await repo.stashRef() == stash, "refs/stash moved", sourceLocation: sourceLocation)
        #expect(try FileManager.default.contentsOfDirectory(atPath: trasher.folder.path).isEmpty,
                "something went to the Trash", sourceLocation: sourceLocation)
    }

    // MARK: - Allowed, and the operation concludes

    /// Each kind — a hunk, a line, a whole file's unstaged side (also over the operation's own
    /// staged change), a user-staged unrelated file's both sides, an untracked file — runs
    /// during the stop and leaves the operation's files alone; the operation then concludes
    /// with its own change and without the discarded ones.
    @Test(arguments: Stop.allCases)
    func everyKindRunsAndTheOperationConcludes(_ stop: Stop) async throws {
        let repo = try await stopped(stop)
        defer { repo.cleanUp() }
        try await userChanges(repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let operation = try await OperationState.capture(repo)
        #expect(operation.fingerprint["AUTO_MERGE"] != nil)

        // A hunk, and its undo (the forward patch).
        let x = try await loadDiff(repo, "x.txt")
        let hunk = try await backend.discard(
            try linesRequest(x, hunks: [try hunkID(x, containing: "3 A")], lines: nil), trasher: trasher, at: repo.root)
        #expect(try text(repo, "x.txt") == numbered(30, [20: "20 B\n20a\n20b"]))
        try await assertOperationUnchanged(repo, since: operation)
        #expect(try await backend.undoDiscard(hunk, trasher: trasher, at: repo.root) == .restored)
        #expect(try text(repo, "x.txt") == Self.xEdited)
        try await assertOperationUnchanged(repo, since: operation)

        // One line of a hunk, and its undo.
        let x2 = try await loadDiff(repo, "x.txt")
        let line = try await backend.discard(
            try linesRequest(x2, hunks: [try hunkID(x2, containing: "20a")], lines: changedLineIDs(x2, "20a")),
            trasher: trasher, at: repo.root)
        #expect(try text(repo, "x.txt") == numbered(30, [3: "3 A", 20: "20 B\n20b"]))
        try await assertOperationUnchanged(repo, since: operation)
        #expect(try await backend.undoDiscard(line, trasher: trasher, at: repo.root) == .restored)
        #expect(try text(repo, "x.txt") == Self.xEdited)
        try await assertOperationUnchanged(repo, since: operation)

        // The whole file's unstaged side.
        let file = try await backend.discard(try await unstaged(["x.txt"], repo), trasher: trasher, at: repo.root)
        #expect(try text(repo, "x.txt") == Self.xBase)
        try await assertOperationUnchanged(repo, since: operation)

        // The unstaged side of a path the operation staged: its staged change stays.
        _ = try await backend.discard(try await unstaged(["z.txt"], repo), trasher: trasher, at: repo.root)
        #expect(try text(repo, "z.txt") == Self.zTheirs)
        #expect(try await repo.indexContent(of: "z.txt") == Data(Self.zTheirs.utf8))
        try await assertOperationUnchanged(repo, since: operation)

        // Both sides of a file the user staged, which the operation never touched.
        let both = try await backend.discard(try await staged(["y.txt"], repo), trasher: trasher, at: repo.root)
        #expect(try text(repo, "y.txt") == Self.yBase)
        #expect(try await repo.indexContent(of: "y.txt") == Data(Self.yBase.utf8))
        try await assertOperationUnchanged(repo, since: operation)

        // An untracked file to the Trash, and back.
        let trashed = try await backend.discard(try await untracked(["u.txt"], repo), trasher: trasher, at: repo.root)
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("u.txt").path))
        try await assertOperationUnchanged(repo, since: operation)
        #expect(try await backend.undoDiscard(trashed, trasher: trasher, at: repo.root) == .restored)
        #expect(try text(repo, "u.txt") == "u\n")
        try await assertOperationUnchanged(repo, since: operation)

        // The whole-file undos wait for the operation (`stash apply` would rewrite AUTO_MERGE,
        // or is refused by git over the conflict): refused before anything is written, and
        // each record stays listed.
        for receipt in [file, both] {
            let record = try #require(receipt.record)
            let state = try await RepoState.capture(repo)
            let worktree = worktreeSnapshot(repo)
            let stashes = try await repo.stashShas()
            #expect(stashes.contains(record.sha))
            await #expect(throws: DiscardRefusal.operationInProgress(stop.operation)) {
                _ = try await backend.undoDiscard(receipt, trasher: trasher, at: repo.root)
            }
            try await assertRepoUnchanged(repo, since: state, worktree: worktree)
            try await assertOperationUnchanged(repo, since: operation)
            #expect(try await repo.stashShas() == stashes)
        }

        // The operation concludes, with its own change to z.txt and none of the discarded ones.
        try repo.write("f.txt", ConflictFixtures.oursText)
        try await repo.git(["add", "--", "f.txt"])
        try await repo.git(stop.conclusion)
        #expect(try await backend.operationInProgress(at: repo.root) == nil)
        #expect(try await repo.blob("HEAD", "z.txt") == Data(Self.zTheirs.utf8))
        #expect(try await repo.blob("HEAD", "y.txt") == Data(Self.yBase.utf8))
        #expect(try await repo.blob("HEAD", "x.txt") == Data(Self.xBase.utf8))

        // And then the whole-file undos restore: x.txt's edit, y.txt's content (HEAD moved,
        // so not its staged split).
        #expect(try await backend.undoDiscard(file, trasher: trasher, at: repo.root) == .restored)
        #expect(try text(repo, "x.txt") == Self.xEdited)
        #expect(try await backend.undoDiscard(both, trasher: trasher, at: repo.root) == .restoredUnstaged)
        #expect(try text(repo, "y.txt") == Self.yBoth)
    }

    // MARK: - The staged side of the operation's own paths

    /// M 21: `restore --source=HEAD --staged` of a path the operation staged drops that change
    /// from the commit it makes — in a rebase, part of the user's own commit. Refused, naming
    /// only those paths, before any record is filed. An unmerged path keeps `.unmerged`.
    @Test(arguments: Stop.allCases)
    func aStagedSideDiscardOfTheOperationsOwnPathIsRefused(_ stop: Stop) async throws {
        let repo = try await stopped(stop)
        defer { repo.cleanUp() }
        try await userChanges(repo)

        try await expectRefused(try await staged(["z.txt"], repo), .partOfOperation(["z.txt"]), in: repo)
        try await expectRefused(try await staged(["y.txt", "z.txt"], repo), .partOfOperation(["z.txt"]), in: repo)
        try await expectRefused(try await staged(["f.txt"], repo), .unmerged(["f.txt"]), in: repo)
        try await expectRefused(try await unstaged(["f.txt"], repo), .unmerged(["f.txt"]), in: repo)
    }

    /// A squash that fast-forwards writes no `AUTO_MERGE` (measured, Task 4; a clean squash
    /// that merges does write one), so the operation's paths are unknown: every path with a
    /// staged change is refused on the staged side, and one with none is not named.
    @Test func aSquashWithoutAutoMergeRefusesEveryStagedPath() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("x.txt", Self.xBase)
        try repo.write("y.txt", Self.yBase)
        try repo.write("z.txt", Self.zBase)
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "theirs"])
        try repo.write("z.txt", Self.zTheirs)
        try await repo.commitAll("theirs change")
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["merge", "-q", "--squash", "theirs"])
        #expect(try await backend.operationInProgress(at: repo.root) == .squash)
        #expect(try await repo.git(["rev-parse", "-q", "--verify", "AUTO_MERGE"], allowedExitCodes: [1]).isEmpty)
        #expect(try await backend.operationPaths(at: repo.root) == nil)
        try repo.write("x.txt", Self.xEdited)
        try repo.write("y.txt", Self.yStaged)
        try await repo.git(["add", "--", "y.txt"])

        try await expectRefused(try await staged(["z.txt"], repo), .partOfOperation(["z.txt"]), in: repo)
        try await expectRefused(try await staged(["x.txt", "y.txt"], repo), .partOfOperation(["y.txt"]), in: repo)

        // The unstaged side is not the operation's.
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        let operation = try await OperationState.capture(repo)
        _ = try await backend.discard(try await unstaged(["x.txt"], repo), trasher: trasher, at: repo.root)
        #expect(try text(repo, "x.txt") == Self.xBase)
        try await assertOperationUnchanged(repo, since: operation)
    }

    // MARK: - The stash stays refused

    @Test(arguments: Stop.allCases)
    func theStashIsStillRefused(_ stop: Stop) async throws {
        let repo = try await stopped(stop)
        defer { repo.cleanUp() }
        try await userChanges(repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }
        // An entry to apply and pop: the record a discard filed during the stop.
        let receipt = try await backend.discard(try await unstaged(["x.txt"], repo), trasher: trasher, at: repo.root)
        let record = try #require(receipt.record)
        try repo.write("x.txt", Self.xEdited)
        let state = try await RepoState.capture(repo)
        let operation = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let stashes = try await repo.stashShas()
        let refused = StashRefusal.operationInProgress(stop.operation)

        await #expect(throws: refused) {
            _ = try await backend.stashAll(message: nil, includeUntracked: false, at: repo.root)
        }
        await #expect(throws: refused) {
            _ = try await backend.stashAll(message: "m", includeUntracked: true, at: repo.root)
        }
        await #expect(throws: refused) {
            _ = try await backend.stashPaths(["x.txt"], message: "m", trasher: trasher, at: repo.root)
        }
        await #expect(throws: refused) { _ = try await backend.apply(record, at: repo.root) }
        await #expect(throws: refused) { _ = try await backend.pop(record, at: repo.root) }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operation)
        #expect(try await repo.stashShas() == stashes)
    }
}
