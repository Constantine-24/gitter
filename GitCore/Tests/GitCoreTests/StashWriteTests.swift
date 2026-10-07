import Foundation
import Testing

@testable import GitCore

/// Moves an item into a scratch folder instead of the user's Trash, keeping the URL it went to.
/// Every stash test uses this one; only `FileManagerTrasherTests` touches the real Trash.
private final class FolderTrasher: Trasher, @unchecked Sendable {
    let folder: URL
    private let lock = NSLock()
    private var moved: [String: URL] = [:]

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func trash(_ url: URL) throws -> URL {
        let destination = folder.appendingPathComponent(UUID().uuidString)
        try FileManager.default.moveItem(at: url, to: destination)
        lock.withLock { moved[url.standardizedFileURL.path] = destination }
        return destination
    }

    func restore(_ trashed: URL, to original: URL) throws {
        try FileManager.default.moveItem(at: trashed, to: original)
    }

    /// Original path → where it went.
    var trashed: [String: URL] { lock.withLock { moved } }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }
}

/// Pushing, applying, popping and dropping, against real repositories.
@Suite struct StashWriteTests {
    private let backend = CLIGitBackend()

    private func makeRepo() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("f", "f1\nf2\nf3\n")
        try repo.write("g", "g\n")
        try await repo.commitAll("root")
        return repo
    }

    // MARK: stashAll

    @Test func aCleanTreeHasNothingToSave() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }

        #expect(try await backend.stashAll(message: "m", includeUntracked: true, at: repo.root) == .nothingToSave)
        #expect(try await repo.stashRef() == nil)
    }

    @Test func aChangeIsSavedWithItsMessage() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("f", "f1\nchanged\nf3\n")

        let outcome = try await backend.stashAll(message: "my message", includeUntracked: false, at: repo.root)

        guard case .saved(let stash) = outcome else {
            Issue.record("expected .saved, got \(outcome)")
            return
        }
        #expect(stash.sha == (try await repo.stashRef()))
        #expect(stash.index == 0)
        #expect(stash.reflogSubject == "On main: my message")
        #expect(stash.parents.count == 2)
        #expect(try repo.bytes("f") == Data("f1\nf2\nf3\n".utf8))
    }

    @Test func noMessageIsGitsOwnWIPLine() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("f", "changed\n")

        let outcome = try await backend.stashAll(message: nil, includeUntracked: false, at: repo.root)

        guard case .saved(let stash) = outcome else {
            Issue.record("expected .saved, got \(outcome)")
            return
        }
        #expect(stash.reflogSubject.hasPrefix("WIP on main: "), "\(stash.reflogSubject)")
    }

    @Test func includeUntrackedGivesAThirdParent() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("f", "changed\n")
        try repo.write("u.txt", "untracked\n")

        let outcome = try await backend.stashAll(message: "m", includeUntracked: true, at: repo.root)

        guard case .saved(let stash) = outcome else {
            Issue.record("expected .saved, got \(outcome)")
            return
        }
        #expect(stash.parents.count == 3)
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("u.txt").path))
    }

    /// git files an entry holding nothing when the only untracked thing is a nested repository
    /// (M A.7); Gitter drops it again and says there was nothing to save.
    @Test func onlyANestedRepositoryWithUntrackedIsNothingToSave() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("nested/x", "x\n")
        try await TestRepo(root: repo.root.appendingPathComponent("nested")).git(["init", "-q"])

        let outcome = try await backend.stashAll(message: "m", includeUntracked: true, at: repo.root)

        #expect(outcome == .nothingToSave)
        #expect(try await repo.stashRef() == nil)
        #expect(FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("nested/x").path))
    }

    /// A staged change whose worktree was put back to HEAD: W's tree is HEAD's, but the index
    /// commit is not. That entry holds something, and must not be taken for an empty one.
    @Test func anEntryHoldingOnlyAStagedChangeIsKept() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("f", "staged\n")
        try await repo.git(["add", "f"])
        try repo.write("f", "f1\nf2\nf3\n")

        let outcome = try await backend.stashAll(message: "m", includeUntracked: true, at: repo.root)

        guard case .saved = outcome else {
            Issue.record("expected .saved, got \(outcome)")
            return
        }
        #expect(try await repo.stashCount() == 1)
    }

    /// A push can file its entry and then fail (M A.7): here a `reference-transaction` hook
    /// aborts the `ORIG_HEAD` update of the push's reset, after `refs/stash` was written. The
    /// exit code says failure; `refs/stash` says the entry exists, and both are reported.
    @Test func aPushThatFilesAndThenFailsIsSavedWithError() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.writeExecutable(".git/hooks/reference-transaction", """
            #!/bin/sh
            [ "$1" = prepared ] || exit 0
            grep -q ' ORIG_HEAD$' && exit 1
            exit 0

            """)
        try repo.write("f", "changed\n")

        let outcome = try await backend.stashAll(message: "m", includeUntracked: false, at: repo.root)

        guard case .savedWithError(let stash, let words, _) = outcome else {
            Issue.record("expected .savedWithError, got \(outcome)")
            return
        }
        #expect(stash.sha == (try await repo.stashRef()))
        #expect(words.contains("aborted by the reference-transaction hook"), "\(words)")
    }

    /// Nothing filed and a non-zero exit: git's own words, and no entry.
    @Test func aLockedIndexFilesNothingAndSaysSo() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("f", "changed\n")
        try Data().write(to: repo.root.appendingPathComponent(".git/index.lock"))
        defer { try? FileManager.default.removeItem(at: repo.root.appendingPathComponent(".git/index.lock")) }
        let worktree = worktreeSnapshot(repo)

        do {
            _ = try await backend.stashAll(message: "m", includeUntracked: false, at: repo.root)
            Issue.record("expected a failure")
        } catch GitError.commandFailed(_, let stderr) {
            #expect(stderr.contains("index.lock"), "\(stderr)")
        }
        #expect(try await repo.stashRef() == nil)
        assertWorktreeUnchanged(repo, since: worktree)
    }

    // MARK: stashAll and a file/directory swap (fix round 1)

    /// Measured (git 2.54): a plain `stash push` over case (a) exits 0 and puts the file `p`
    /// back over the directory — `p/x` is in no entry and gone. With `-u`, `p/x` is saved in
    /// the third parent, but applying it back fails (`fatal: cannot create directory at 'p':
    /// File exists`). Refused either way.
    @Test(arguments: [false, true])
    func stashAllRefusesATrackedFileReplacedByADirectory(includeUntracked: Bool) async throws {
        let repo = try await makeTypeSwapA()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        #expect(worktree["p/x"] == Data("precious\n".utf8))

        await #expect(throws: StashRefusal.pathTypeChanged(["p"])) {
            _ = try await backend.stashAll(message: "m", includeUntracked: includeUntracked, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.stashRef() == nil)
    }

    /// Case (b): a tracked `d/a` whose directory is now a file `d`. Refused whether or not
    /// untracked files are included — one rule. Measured: a plain push puts the directory back
    /// and the file `d` is in no entry; with `-u` a non-ignored `d` happens to be saved in the
    /// third parent, but an ignored one is not (`-u` never takes ignored files), and the push's
    /// reset puts `d/a` back over it all the same (fix round 2).
    @Test(arguments: [false, true])
    func stashAllRefusesAPathUnderAFile(includeUntracked: Bool) async throws {
        let repo = try await makeTypeSwapB()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        #expect(worktree["d"] == Data("precious\n".utf8))

        await #expect(throws: StashRefusal.pathTypeChanged(["d/a"])) {
            _ = try await backend.stashAll(message: "m", includeUntracked: includeUntracked, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.stashRef() == nil)
    }

    /// The reviewer's probe: the file `d` is ignored (by `.gitignore` or by
    /// `.git/info/exclude`), so `-u` would not save it and the push's reset would delete it.
    @Test(arguments: [".gitignore", ".git/info/exclude"])
    func stashAllWithUntrackedRefusesAnIgnoredFileWhereADirectoryWas(ignoreFile: String) async throws {
        let repo = try await makeTypeSwapB()
        defer { repo.cleanUp() }
        try repo.write(ignoreFile, "/d\n")
        let ignored = String(decoding: try await repo.git(["status", "--porcelain", "--ignored"]), as: UTF8.self)
        #expect(ignored.contains("!! d\n"), "d is not ignored: \(ignored)")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        #expect(worktree["d"] == Data("precious\n".utf8))

        await #expect(throws: StashRefusal.pathTypeChanged(["d/a"])) {
            _ = try await backend.stashAll(message: "m", includeUntracked: true, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.stashRef() == nil)
        #expect(try repo.bytes("d") == Data("precious\n".utf8))
    }

    @Test func stashPathsRefusesATrackedFileReplacedByADirectory() async throws {
        let repo = try await makeTypeSwapA()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: StashRefusal.pathTypeChanged(["p"])) {
            _ = try await backend.stashPaths(["p"], message: "m", at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.stashRef() == nil)
    }

    // MARK: The identical entry (fix round 1)

    /// Pushed, applied back, pushed again in the same second: the second entry is the very
    /// commit already at `stash@{0}`, which git files by adding nothing (measured), while the
    /// files are cleaned all the same. That is a save, of the listed entry.
    ///
    /// "The same second" is git's dates, so git runs with them pinned
    /// (`pinnedDateGitPath`) and the case is reached by construction, at any load. It used to
    /// be raced for: five tries to fit push, apply and push into one wall-clock second, which a
    /// full parallel `swift test` missed 0 times in 5 (E1 survey S16).
    @Test func anIdenticalPushInTheSameSecondIsSavedAsTheListedEntry() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        let pinned = CLIGitBackend(
            gitPath: try pinnedDateGitPath(at: "2026-01-01T00:00:00Z", in: repo.root.appendingPathComponent(".git")))
        try repo.write("f", "f1\nchanged\nf3\n")

        guard case .saved(let first) = try await pinned.stashAll(message: "m", includeUntracked: false, at: repo.root)
        else {
            Issue.record("the first push did not save")
            return
        }
        #expect(try await pinned.apply(first, at: repo.root) == .applied)
        let second = try await pinned.stashAll(message: "m", includeUntracked: false, at: repo.root)

        guard case .saved(let stash) = second else {
            Issue.record("expected .saved, got \(second)")
            return
        }
        #expect(stash.sha == first.sha, "the second push was not the identical commit")
        #expect(try await repo.stashCount() == 1)
        #expect(try repo.bytes("f") == Data("f1\nf2\nf3\n".utf8), "the files were not cleaned")
        #expect(stash.index == 0)
        #expect(stash.sha == (try await repo.stashRef()))
    }

    /// The other side, which the raced version above used to meet whenever an attempt
    /// straddled a second: the same push one second later is a different commit, so git lists
    /// a new entry, and that is `.saved` of the new `stash@{0}`, files cleaned. Pinned too, a
    /// second apart.
    @Test func anIdenticalPushInALaterSecondIsSavedAsANewEntry() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        let gitDirectory = repo.root.appendingPathComponent(".git")
        let early = CLIGitBackend(gitPath: try pinnedDateGitPath(at: "2026-01-01T00:00:00Z", in: gitDirectory))
        let late = CLIGitBackend(gitPath: try pinnedDateGitPath(at: "2026-01-01T00:00:01Z", in: gitDirectory))
        try repo.write("f", "f1\nchanged\nf3\n")

        guard case .saved(let first) = try await early.stashAll(message: "m", includeUntracked: false, at: repo.root)
        else {
            Issue.record("the first push did not save")
            return
        }
        #expect(try await early.apply(first, at: repo.root) == .applied)
        let second = try await late.stashAll(message: "m", includeUntracked: false, at: repo.root)

        guard case .saved(let stash) = second else {
            Issue.record("expected .saved, got \(second)")
            return
        }
        #expect(stash.sha != first.sha, "a second later is a new commit")
        #expect(try await repo.stashCount() == 2)
        #expect(try repo.bytes("f") == Data("f1\nf2\nf3\n".utf8), "the files were not cleaned")
        #expect(stash.index == 0)
        #expect(stash.sha == (try await repo.stashRef()))
    }

    /// And the other side: changes git will not save (a submodule's moved commit only, M 14)
    /// stay `.nothingToSave` even with an entry already listed.
    @Test func onlyAMovedSubmoduleIsStillNothingToSaveWithAnEntryListed() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        let sub = TestRepo(root: repo.root.appendingPathComponent("sub"))
        try repo.write("sub/s", "s\n")
        try await sub.git(["init", "-q", "-b", "main"])
        try await sub.git(["-c", "user.name=T", "-c", "user.email=t@t", "add", "s"])
        try await sub.git(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "s"])
        try await repo.git(["add", "sub"])
        try await repo.git(["commit", "-q", "-m", "sub"])
        try repo.write("f", "changed\n")
        try await repo.git(["stash", "push", "-q", "-m", "listed"])
        try repo.write("sub/s", "s2\n")
        try await sub.git(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-am", "s2"])

        #expect(try await backend.stashAll(message: "m", includeUntracked: false, at: repo.root) == .nothingToSave)
        #expect(try await repo.stashCount() == 1)
    }

    @Test func anIntentToAddEntryIsRefused() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("f", "changed\n")
        try repo.write("n", "n\n")
        try await repo.git(["add", "-N", "n"])
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: StashRefusal.intentToAdd(["n"])) {
            _ = try await backend.stashAll(message: "m", includeUntracked: false, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.stashRef() == nil)
    }

    /// git itself would push this one, and quietly drop the entry from the index (measured).
    @Test func aDeletedIntentToAddEntryIsRefused() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("f", "changed\n")
        try repo.write("q", "q\n")
        try await repo.git(["add", "-N", "q"])
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("q"))
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: StashRefusal.intentToAdd(["q"])) {
            _ = try await backend.stashAll(message: "m", includeUntracked: true, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.stashRef() == nil)
    }

    /// Unmerged entries with no operation in progress: what a conflicted stash apply leaves
    /// (no MERGE_HEAD, M 6), so only the unmerged check can refuse. (`stashPaths` refuses only
    /// an unmerged path it is *given*: the record of another path builds fine.)
    @Test func unmergedPathsAreRefused() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }
        try repo.write("f", "f1\ncommitted\nf3\n")
        try await repo.commitAll("moves f")
        try await repo.git(["stash", "apply", "-q", stash.sha], allowedExitCodes: [1])
        #expect(!(try await repo.unmergedEntries()).isEmpty)
        #expect(try await backend.operationInProgress(at: repo.root) == nil)
        try repo.write("g", "g changed\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: StashRefusal.unmergedPaths(["f"])) {
            _ = try await backend.stashAll(message: "m", includeUntracked: false, at: repo.root)
        }
        await #expect(throws: StashRefusal.unmergedPaths(["f"])) {
            _ = try await backend.apply(stash, at: repo.root)
        }
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.stashCount() == 1)
    }

    enum Stopped: String, CaseIterable, Sendable { case merge, cherryPick, squash, rebase }

    /// A stopped operation with its conflict resolved and staged, and an unrelated edit: the
    /// state in which a full push silently ends the operation (M 13).
    private func makeStopped(_ kind: Stopped) async throws -> (TestRepo, marker: String, RepositoryOperation) {
        switch kind {
        case .merge:
            let repo = try await TestRepo.makeConflicting()
            try await repo.git(["merge", "feature"], allowedExitCodes: [1])
            try repo.write("a.txt", "resolved\n")
            try await repo.git(["add", "a.txt"])
            try repo.write("keep.txt", "keep\ndirty\n")
            return (repo, "MERGE_HEAD", .merge)
        case .cherryPick:
            let repo = try await TestRepo.makeConflicting()
            try await repo.git(["cherry-pick", "feature"], allowedExitCodes: [1])
            try repo.write("a.txt", "resolved\n")
            try await repo.git(["add", "a.txt"])
            try repo.write("keep.txt", "keep\ndirty\n")
            return (repo, "CHERRY_PICK_HEAD", .cherryPick)
        case .squash:
            let repo = try await TestRepo.makeDiverged()
            try await repo.git(["merge", "--squash", "feature"])
            try repo.write("keep.txt", "keep\ndirty\n")
            return (repo, "SQUASH_MSG", .squash)
        case .rebase:
            let repo = try await TestRepo.makeConflicting()
            try await repo.git(["switch", "-q", "feature"])
            try await repo.git(["rebase", "main"], allowedExitCodes: [1])
            try repo.write("a.txt", "resolved\n")
            try await repo.git(["add", "a.txt"])
            try repo.write("keep.txt", "keep\ndirty\n")
            return (repo, "rebase-merge", .rebase)
        }
    }

    @Test(arguments: Stopped.allCases)
    func everyWriteIsRefusedWhileAnOperationIsInProgress(_ kind: Stopped) async throws {
        let (repo, marker, operation) = try await makeStopped(kind)
        defer { repo.cleanUp() }
        try await repo.git(["stash", "push", "-q", "--", "keep.txt"])
        try repo.write("keep.txt", "keep\ndirty again\n")
        #expect(try await repo.gitFileExists(marker), "the test's own setup ended the \(kind)")
        let stash = try #require(try await backend.stashes(at: repo.root).first)
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: StashRefusal.operationInProgress(operation)) {
            _ = try await backend.stashAll(message: "m", includeUntracked: true, at: repo.root)
        }
        await #expect(throws: StashRefusal.operationInProgress(operation)) {
            _ = try await backend.stashPaths(["keep.txt"], message: "m", at: repo.root)
        }
        await #expect(throws: StashRefusal.operationInProgress(operation)) {
            _ = try await backend.apply(stash, at: repo.root)
        }
        await #expect(throws: StashRefusal.operationInProgress(operation)) {
            _ = try await backend.pop(stash, at: repo.root)
        }

        #expect(try await repo.gitFileExists(marker), "\(marker) is gone")
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.stashCount() == 1)
    }

    // MARK: stashPaths

    /// Only `p` goes; `h`'s two layers and `k` stay byte-identical.
    @Test func stashingOnePathLeavesEveryOtherLayerAlone() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        try repo.write("h", "h\nhstaged\nhunstaged\n")
        let hIndex = try await repo.indexContent(of: "h")
        let hWorktree = try repo.bytes("h")
        let kIndex = try await repo.indexContent(of: "k")
        let kWorktree = try repo.bytes("k")
        #expect(hIndex != hWorktree)
        let pBefore = try repo.bytes("p")

        let outcome = try await backend.stashPaths(["p"], message: "selected", at: repo.root)

        guard case .saved(let stash) = outcome else {
            Issue.record("expected .saved, got \(outcome)")
            return
        }
        #expect(stash.reflogSubject == "On main: selected")
        #expect(try await repo.nameStatus(from: "\(stash.sha)^1", to: stash.sha) == ["M\tp"])
        #expect(try await repo.blob(stash.sha, "p") == pBefore)
        // p is back to HEAD in both layers.
        #expect(try await repo.indexContent(of: "p") == (try await repo.blob("HEAD", "p")))
        #expect(try repo.bytes("p") == (try await repo.blob("HEAD", "p")))
        // h and k untouched, both layers.
        #expect(try await repo.indexContent(of: "h") == hIndex)
        #expect(try repo.bytes("h") == hWorktree)
        #expect(try await repo.indexContent(of: "k") == kIndex)
        #expect(try repo.bytes("k") == kWorktree)
    }

    /// **VERIFY (measured):** `restore --source=HEAD --staged --worktree` of an untracked path
    /// fails (`error: pathspec ':(literal)u' did not match any file(s) known to git`, exit 1)
    /// and restores none of the other paths with it (M A.5). So the tracked paths are restored
    /// and the untracked ones — already held by the record — go to the Trash.
    @Test func anUntrackedPathIsRecordedAndThenTrashed() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        let trasher = try FolderTrasher()
        defer { trasher.cleanUp() }
        try repo.write("u", "untracked\n")
        try repo.write("ud/a", "a\n")
        try repo.write("ud/sub/b", "b\n")

        let outcome = try await backend.stashPaths(["p", "u", "ud/"], message: "m", trasher: trasher, at: repo.root)

        guard case .saved(let stash) = outcome else {
            Issue.record("expected .saved, got \(outcome)")
            return
        }
        #expect(Set(try await repo.nameStatus(from: "\(stash.sha)^1", to: stash.sha))
                == ["M\tp", "A\tu", "A\tud/a", "A\tud/sub/b"])
        #expect(try await repo.blob(stash.sha, "u") == Data("untracked\n".utf8))
        #expect(Set(trasher.trashed.keys.map { URL(fileURLWithPath: $0).lastPathComponent }) == ["u", "a", "b"])
        for (_, url) in trasher.trashed { #expect(FileManager.default.fileExists(atPath: url.path)) }
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("u").path))
        #expect(try repo.bytes("p") == (try await repo.blob("HEAD", "p")))
    }

    /// A staged rename and a staged deletion: `old` and `p` are only in HEAD, and `restore
    /// --source=HEAD` knows them; `new` goes from the index and the disk (M A.2).
    @Test func aRenameAndAStagedDeletionGoBackToHEAD() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("old", "same\nsame\nsame\n")
        try repo.write("p", "p\n")
        try repo.write("h", "h\n")
        try await repo.commitAll("root")
        try await repo.git(["mv", "old", "new"])
        try await repo.git(["rm", "-q", "p"])
        try repo.write("h", "h\nstaged\n")
        try await repo.git(["add", "h"])

        let outcome = try await backend.stashPaths(["old", "new", "p"], message: "m", at: repo.root)

        guard case .saved(let stash) = outcome else {
            Issue.record("expected .saved, got \(outcome)")
            return
        }
        #expect(Set(try await repo.nameStatus(from: "\(stash.sha)^1", to: stash.sha)) == ["A\tnew", "D\told", "D\tp"])
        let status = String(decoding: try await repo.git(["status", "--porcelain"]), as: UTF8.self)
        #expect(status == "M  h\n", "\(status)")
        #expect(try repo.bytes("old") == Data("same\nsame\nsame\n".utf8))
        #expect(try repo.bytes("p") == Data("p\n".utf8))
    }

    /// The record is filed, then the restore fails (a stale `index.lock`): the changes are in
    /// the entry *and* still in the files, and the outcome says so.
    @Test func aRestoreThatFailsAfterTheRecordIsSavedWithError() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        let pBefore = try repo.bytes("p")
        try Data().write(to: repo.root.appendingPathComponent(".git/index.lock"))
        defer { try? FileManager.default.removeItem(at: repo.root.appendingPathComponent(".git/index.lock")) }

        let outcome = try await backend.stashPaths(["p"], message: "m", at: repo.root)

        guard case .savedWithError(let stash, let words, _) = outcome else {
            Issue.record("expected .savedWithError, got \(outcome)")
            return
        }
        #expect(words.contains("index.lock"), "\(words)")
        #expect(try await repo.blob(stash.sha, "p") == pBefore)
        #expect(try repo.bytes("p") == pBefore)
    }

    private struct FailingTrasher: Trasher {
        func trash(_ url: URL) throws -> URL { throw CocoaError(.fileWriteNoPermission) }
        func restore(_ trashed: URL, to original: URL) throws { throw CocoaError(.fileWriteNoPermission) }
    }

    /// Moves the first item into a folder and fails on every later one.
    private final class FailsOnSecondTrasher: Trasher, @unchecked Sendable {
        let inner: FolderTrasher
        private let lock = NSLock()
        private var calls = 0
        init() throws { inner = try FolderTrasher() }
        func trash(_ url: URL) throws -> URL {
            let call = lock.withLock { calls += 1; return calls }
            guard call == 1 else { throw CocoaError(.fileWriteNoPermission) }
            return try inner.trash(url)
        }
        func restore(_ trashed: URL, to original: URL) throws { try inner.restore(trashed, to: original) }
    }

    /// A Trash that fails part-way: the outcome says which items already went, and where, so
    /// they can be found and put back (Task 5's undo needs the URLs).
    @Test func aTrashThatFailsPartWayReportsWhatItAlreadyMoved() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        let trasher = try FailsOnSecondTrasher()
        defer { trasher.inner.cleanUp() }
        try repo.write("u1", "one\n")
        try repo.write("u2", "two\n")

        let outcome = try await backend.stashPaths(["u1", "u2"], message: "m", trasher: trasher, at: repo.root)

        guard case .savedWithError(let stash, let words, let trashed) = outcome else {
            Issue.record("expected .savedWithError, got \(outcome)")
            return
        }
        #expect(Set(try await repo.nameStatus(from: "\(stash.sha)^1", to: stash.sha)) == ["A\tu1", "A\tu2"])
        #expect(Array(trashed.keys) == ["u1"])
        let moved = try #require(trashed["u1"])
        #expect(try Data(contentsOf: moved) == Data("one\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("u1").path))
        #expect(try repo.bytes("u2") == Data("two\n".utf8))
        #expect(words.contains("u2"), "\(words)")
    }

    @Test func aTrashThatFailsLeavesTheFileAndSaysSo() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        try repo.write("u", "untracked\n")

        let outcome = try await backend.stashPaths(["u"], message: "m", trasher: FailingTrasher(), at: repo.root)

        guard case .savedWithError(let stash, _, _) = outcome else {
            Issue.record("expected .savedWithError, got \(outcome)")
            return
        }
        #expect(try await repo.blob(stash.sha, "u") == Data("untracked\n".utf8))
        #expect(try repo.bytes("u") == Data("untracked\n".utf8))
    }

    @Test func pathsWithoutChangesHaveNothingToSave() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        try repo.write("clean", "clean\n")
        try await repo.git(["add", "clean"])
        try await repo.git(["commit", "-q", "-m", "clean", "--", "clean"])

        #expect(try await backend.stashPaths(["clean"], message: "m", at: repo.root) == .nothingToSave)
        #expect(try await repo.stashRef() == nil)
    }

    @Test func noPathsIsNothingSelected() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }

        await #expect(throws: StashRefusal.nothingSelected) {
            _ = try await backend.stashPaths([], message: "m", at: repo.root)
        }
    }

    // MARK: apply

    /// A repo with one entry that changes `f`'s middle line, and `f` back to HEAD.
    private func makeRepoWithEntry() async throws -> (TestRepo, Stash) {
        let repo = try await makeRepo()
        try repo.write("f", "f1\nstashed\nf3\n")
        try await repo.git(["stash", "push", "-q", "-m", "entry"])
        let stash = try #require(try await backend.stashes(at: repo.root).first)
        return (repo, stash)
    }

    @Test func aCleanApplyIsApplied() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }

        #expect(try await backend.apply(stash, at: repo.root) == .applied)
        #expect(try repo.bytes("f") == Data("f1\nstashed\nf3\n".utf8))
        #expect(try await repo.stashCount() == 1)
    }

    @Test func aDirtyFileIsRefusedAndNothingChanges() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }
        try repo.write("f", "f1\nf2\nf3 local\n")
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        #expect(try await backend.apply(stash, at: repo.root) == .refused(wouldOverwrite: ["f"]))
        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
    }

    @Test func aConflictIsReportedWithItsPathsAndTheEntryKept() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }
        try repo.write("f", "f1\ncommitted\nf3\n")
        try await repo.commitAll("moves f")

        #expect(try await backend.apply(stash, at: repo.root) == .conflicts(["f"]))
        #expect(!(try await repo.unmergedEntries()).isEmpty)
        #expect(try await repo.stashCount() == 1)
    }

    @Test func anUntrackedFileThatExistsIsAPartialApply() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("f", "f1\nstashed\nf3\n")
        try repo.write("u.txt", "stashed\n")
        try await repo.git(["stash", "push", "-q", "--include-untracked", "-m", "entry"])
        let stash = try #require(try await backend.stashes(at: repo.root).first)
        try repo.write("u.txt", "made again\n")

        #expect(try await backend.apply(stash, at: repo.root) == .partiallyApplied(untrackedNotRestored: ["u.txt"]))
        // The tracked part landed; the existing file was not overwritten.
        #expect(try repo.bytes("f") == Data("f1\nstashed\nf3\n".utf8))
        #expect(try repo.bytes("u.txt") == Data("made again\n".utf8))
    }

    @Test func anApplyGitRefusesForAnotherReasonIsFailedInItsOwnWords() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }
        try Data().write(to: repo.root.appendingPathComponent(".git/index.lock"))
        defer { try? FileManager.default.removeItem(at: repo.root.appendingPathComponent(".git/index.lock")) }
        let worktree = worktreeSnapshot(repo)

        let outcome = try await backend.apply(stash, at: repo.root)

        guard case .failed(let words) = outcome else {
            Issue.record("expected .failed, got \(outcome)")
            return
        }
        #expect(words.contains("index.lock"), "\(words)")
        assertWorktreeUnchanged(repo, since: worktree)
    }

    /// `stash.index=true` would make a plain apply restore the index; `--no-index` wins (M 11).
    @Test func stashIndexInConfigDoesNotRestoreTheIndex() async throws {
        let repo = try await makeRepo()
        defer { repo.cleanUp() }
        try repo.write("f", "f1\nstaged\nf3\n")
        try await repo.git(["add", "f"])
        try await repo.git(["stash", "push", "-q", "-m", "entry"])
        let stash = try #require(try await backend.stashes(at: repo.root).first)
        try await repo.git(["config", "stash.index", "true"])

        #expect(try await backend.apply(stash, at: repo.root) == .applied)
        #expect(try await repo.indexContent(of: "f") == Data("f1\nf2\nf3\n".utf8))
        #expect(try repo.bytes("f") == Data("f1\nstaged\nf3\n".utf8))
    }

    // MARK: pop

    @Test func aCleanPopDropsTheEntry() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }

        #expect(try await backend.pop(stash, at: repo.root) == .applied)
        #expect(try await repo.stashRef() == nil)
        #expect(try repo.bytes("f") == Data("f1\nstashed\nf3\n".utf8))
    }

    @Test func aConflictedPopKeepsTheEntry() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }
        try repo.write("f", "f1\ncommitted\nf3\n")
        try await repo.commitAll("moves f")

        #expect(try await backend.pop(stash, at: repo.root) == .conflicts(["f"]))
        #expect(try await repo.stashRef() == stash.sha)
    }

    @Test func aRefusedPopKeepsTheEntry() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }
        try repo.write("f", "f1\nf2\nf3 local\n")

        #expect(try await backend.pop(stash, at: repo.root) == .refused(wouldOverwrite: ["f"]))
        #expect(try await repo.stashRef() == stash.sha)
    }

    /// RF2: the list shifts under a `Stash` value (another push, from anywhere). The old
    /// value's position now names a different entry, and neither may be dropped.
    @Test func popOfAStashWhosePositionMovedIsRefusedAndBothEntriesRemain() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }
        try repo.write("g", "g changed\n")
        try await repo.git(["stash", "push", "-q", "-m", "newer"])
        let newer = try #require(try await repo.stashRef())
        let state = try await RepoState.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: StashRefusal.stashListChanged) {
            _ = try await backend.pop(stash, at: repo.root)
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        #expect(try await repo.stashCount() == 2)
        #expect(try await repo.revParse("stash@{0}") == newer)
        #expect(try await repo.revParse("stash@{1}") == stash.sha)
    }

    /// The list moves between a clean apply and the drop (a push from a terminal, reached
    /// through `pop`'s `beforeDrop` seam). The changes are in the files, the entry is not
    /// dropped — and the outcome must not read as a pop.
    @Test func aPopWhoseListMovesBeforeTheDropKeepsTheEntryAndSaysSo() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }

        let outcome = try await backend.pop(stash, at: repo.root, beforeDrop: {
            try repo.write("g", "g changed\n")
            try await repo.git(["stash", "push", "-q", "-m", "newer", "--", "g"])
        })

        guard case .appliedButKept(let reason) = outcome else {
            Issue.record("expected .appliedButKept, got \(outcome)")
            return
        }
        #expect(reason.contains("stash list changed"), "\(reason)")
        #expect(try repo.bytes("f") == Data("f1\nstashed\nf3\n".utf8))
        #expect(try await repo.stashCount() == 2)
        #expect(try await repo.revParse("stash@{1}") == stash.sha)
    }

    /// The drop itself fails after a clean apply: `refs/stash.lock` is held, as by another git
    /// process. git's words come back, and the entry stays.
    @Test func aPopWhoseDropFailsKeepsTheEntryInGitsWords() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }
        let lock = repo.root.appendingPathComponent(".git/refs/stash.lock")

        let outcome = try await backend.pop(stash, at: repo.root, beforeDrop: {
            try Data().write(to: lock)
        })
        try? FileManager.default.removeItem(at: lock)

        guard case .appliedButKept(let reason) = outcome else {
            Issue.record("expected .appliedButKept, got \(outcome)")
            return
        }
        #expect(reason.contains("stash.lock"), "\(reason)")
        #expect(try repo.bytes("f") == Data("f1\nstashed\nf3\n".utf8))
        #expect(try await repo.stashRef() == stash.sha)
        #expect(try await repo.stashCount() == 1)
    }

    // MARK: drop

    @Test func dropRemovesTheEntryItNames() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }

        try await backend.drop(stash, at: repo.root)

        #expect(try await repo.stashRef() == nil)
    }

    @Test func dropOfAStashWhosePositionMovedIsRefusedAndBothEntriesRemain() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }
        try repo.write("g", "g changed\n")
        try await repo.git(["stash", "push", "-q", "-m", "newer"])
        let newer = try #require(try await repo.stashRef())

        await #expect(throws: StashRefusal.stashListChanged) {
            try await backend.drop(stash, at: repo.root)
        }

        #expect(try await repo.stashCount() == 2)
        #expect(try await repo.revParse("stash@{0}") == newer)
        #expect(try await repo.revParse("stash@{1}") == stash.sha)
    }

    /// `rev-parse -q --verify stash@{n}` exits 128 past the end of the list and 1 with no list
    /// at all; both are a mismatch.
    @Test func dropOfAVanishedEntryIsRefused() async throws {
        let (repo, stash) = try await makeRepoWithEntry()
        defer { repo.cleanUp() }
        try await repo.git(["stash", "drop", "-q"])

        await #expect(throws: StashRefusal.stashListChanged) {
            try await backend.drop(stash, at: repo.root)
        }

        try repo.write("g", "g changed\n")
        try await repo.git(["stash", "push", "-q", "-m", "other"])
        let moved = Stash(sha: stash.sha, index: 3, reflogSubject: stash.reflogSubject,
                          parents: stash.parents, date: stash.date)
        await #expect(throws: StashRefusal.stashListChanged) {
            try await backend.drop(moved, at: repo.root)
        }
        #expect(try await repo.stashCount() == 1)
    }
}

/// The one suite that uses the real Trash: it moves a scratch file there and back, and checks
/// by the exact URL `trashItem` returned that nothing of it is left behind (M 15).
@Suite struct FileManagerTrasherTests {
    @Test func trashAndRestoreRoundTripsAndLeavesNothingInTheTrash() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-trasher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let original = folder.appendingPathComponent("gitter-trash-probe-\(UUID().uuidString).txt")
        try Data("probe\n".utf8).write(to: original)
        let trasher = FileManagerTrasher()

        let trashed = try trasher.trash(original)
        defer {
            // Whatever happened above, the exact item the Trash received goes.
            if FileManager.default.fileExists(atPath: trashed.path) {
                try? FileManager.default.removeItem(at: trashed)
            }
        }
        #expect(!FileManager.default.fileExists(atPath: original.path))
        #expect(FileManager.default.fileExists(atPath: trashed.path))
        #expect(trashed.path.contains("/.Trash/"), "not the user's Trash: \(trashed.path)")

        try trasher.restore(trashed, to: original)

        #expect(try Data(contentsOf: original) == Data("probe\n".utf8))
        #expect(!FileManager.default.fileExists(atPath: trashed.path), "left in the Trash: \(trashed.path)")
    }

    /// Restore never overwrites: Cocoa error 516 (M 15), and both files keep their bytes.
    /// No real Trash here — any two files will do.
    @Test func restoreOntoAnExistingPathFailsAndOverwritesNothing() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-trasher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let trashed = folder.appendingPathComponent("trashed.txt")
        let original = folder.appendingPathComponent("original.txt")
        try Data("old\n".utf8).write(to: trashed)
        try Data("made again\n".utf8).write(to: original)

        #expect(throws: CocoaError.self) {
            try FileManagerTrasher().restore(trashed, to: original)
        }

        #expect(try Data(contentsOf: original) == Data("made again\n".utf8))
        #expect(try Data(contentsOf: trashed) == Data("old\n".utf8))
    }

    /// A parent directory that went away is made again; nothing is overwritten by that.
    @Test func restoreRemakesAMissingParentDirectory() throws {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-trasher-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let trashed = folder.appendingPathComponent("trashed.txt")
        try Data("old\n".utf8).write(to: trashed)
        let original = folder.appendingPathComponent("gone/deeper/original.txt")

        try FileManagerTrasher().restore(trashed, to: original)

        #expect(try Data(contentsOf: original) == Data("old\n".utf8))
    }
}
