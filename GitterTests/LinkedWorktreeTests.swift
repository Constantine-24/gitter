import Foundation
import GitCore
import Testing

@testable import Gitter

/// B3 Task 3, the linked-worktree fixes (R28): where a worktree's own git directory and the
/// common one are (`RepositoryDirectories`, read as git reads them — the `.git` file's `gitdir:`
/// line, then that directory's `commondir` file), what the watcher watches for one, the discard
/// fingerprint's `config` and `info/attributes`, a lane's own `FETCH_HEAD` there, and which
/// operation holds a worktree's branches. The layouts are folders that stand in for repositories,
/// laid out as git 2.54 lays them out (measured in the watcher VERIFY): no git runs.
@Suite struct LinkedWorktreeTests {

    /// `<base>/main/.git/` (config, info/attributes, index) with a linked worktree `<base>/wt`
    /// whose admin directory is `main/.git/worktrees/wt` (index, HEAD, `commondir` = `../..`).
    private struct Layout {
        let base: URL
        var main: URL { base.appendingPathComponent("main") }
        var common: URL { main.appendingPathComponent(".git") }
        var admin: URL { common.appendingPathComponent("worktrees/wt") }
        var linked: URL { base.appendingPathComponent("wt") }

        init(relativeGitdir: Bool = false) throws {
            let made = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitter-linked-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: made, withIntermediateDirectories: true)
            // The real path, as git prints it (`/private/var/…`).
            base = URL(fileURLWithPath: made.resolvingSymlinksInPath().path, isDirectory: true)
            for folder in [common.appendingPathComponent("info"), common.appendingPathComponent("refs/heads"), admin, linked] {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            }
            try write(common.appendingPathComponent("config"), "[core]\n")
            try write(common.appendingPathComponent("info/attributes"), "")
            try write(common.appendingPathComponent("index"), "main index")
            try write(admin.appendingPathComponent("index"), "wt index")
            try write(admin.appendingPathComponent("HEAD"), "ref: refs/heads/feat\n")
            try write(admin.appendingPathComponent("commondir"), "../..\n")
            try write(
                linked.appendingPathComponent(".git"),
                "gitdir: \(relativeGitdir ? "../main/.git/worktrees/wt" : admin.path)\n")
            try write(linked.appendingPathComponent("a.txt"), "one\n")
        }

        func write(_ url: URL, _ text: String) throws {
            try Data(text.utf8).write(to: url)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: base) }
    }

    // MARK: - RepositoryDirectories

    @Test func aMainWorktreesDirectoriesAreBothItsDotGit() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        let directories = try #require(RepositoryDirectories.resolve(root: layout.main))
        #expect(directories.gitDirectory.path == layout.common.path)
        #expect(directories.commonDirectory.path == layout.common.path)
        #expect(!directories.isLinkedWorktree)
    }

    @Test(arguments: [false, true])
    func aLinkedWorktreesGitDirectoryIsItsAdminDirectoryAndTheCommonOneMains(relative: Bool) throws {
        let layout = try Layout(relativeGitdir: relative)
        defer { layout.cleanUp() }
        let directories = try #require(RepositoryDirectories.resolve(root: layout.linked))
        #expect(directories.gitDirectory.path == layout.admin.path)
        #expect(directories.commonDirectory.path == layout.common.path)
        #expect(directories.isLinkedWorktree)
    }

    @Test func noDotGitIsNoDirectories() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        #expect(RepositoryDirectories.resolve(root: layout.base) == nil)
    }

    // MARK: - The watcher's paths (R28, measured in the VERIFY)

    @Test func aMainWorktreeIsWatchedAtItsRootAlone() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        let directories = RepositoryDirectories.resolve(root: layout.main)
        #expect(RepositoryWatcher.paths(root: layout.main, directories: directories) == [layout.main.path])
        #expect(RepositoryWatcher.paths(root: layout.main, directories: nil) == [layout.main.path])
    }

    /// Its HEAD, index and FETCH_HEAD are in its own git directory; the refs, `packed-refs` (a
    /// file, watched even before it exists), the shared `config` and the main worktree's `HEAD`
    /// in the common one. Never the whole common directory: not its objects, not the other
    /// worktrees' index files.
    @Test func aLinkedWorktreeIsWatchedWhereGitWritesForIt() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        let directories = RepositoryDirectories.resolve(root: layout.linked)
        let common = layout.common.path
        #expect(
            RepositoryWatcher.paths(root: layout.linked, directories: directories) == [
                layout.linked.path, layout.admin.path, common + "/refs", common + "/packed-refs", common + "/config",
                common + "/HEAD",
            ])
    }

    // MARK: - The discard fingerprint (R28)

    /// Before the fix both stamps were taken at `<admin>/config` and `<admin>/info/attributes`,
    /// which do not exist: a change to the shared files was never seen.
    @Test(arguments: ["config", "info/attributes"])
    func aLinkedWorktreesFingerprintSeesTheSharedFiles(_ file: String) throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        let before = try #require(DiscardSheetFingerprint.take(tracked: ["a.txt"], root: layout.linked, head: "h"))
        try layout.write(layout.common.appendingPathComponent(file), "changed, and longer than before\n")
        let after = try #require(DiscardSheetFingerprint.take(tracked: ["a.txt"], root: layout.linked, head: "h"))
        #expect(after != before, "\(file)")
    }

    /// Its index is its own, not the main worktree's.
    @Test func aLinkedWorktreesFingerprintStampsItsOwnIndex() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        let before = try #require(DiscardSheetFingerprint.take(tracked: ["a.txt"], root: layout.linked, head: "h"))
        try layout.write(layout.common.appendingPathComponent("index"), "the main worktree's index, rewritten")
        #expect(DiscardSheetFingerprint.take(tracked: ["a.txt"], root: layout.linked, head: "h") == before)
        try layout.write(layout.admin.appendingPathComponent("index"), "this worktree's index, rewritten")
        #expect(DiscardSheetFingerprint.take(tracked: ["a.txt"], root: layout.linked, head: "h") != before)
    }

    // MARK: - A lane's own writes

    /// A fetch run in a linked worktree writes its `FETCH_HEAD` in its admin directory.
    @MainActor @Test func aLinkedWorktreesFetchHeadIsTheLanesOwnWrite() {
        #expect(RepositoryStore.isLaneOwnWrite("/r/main/.git/worktrees/wt/FETCH_HEAD", during: .fetch))
        #expect(RepositoryStore.isLaneOwnWrite("/r/main/.git/FETCH_HEAD", during: .fetch))
        #expect(!RepositoryStore.isLaneOwnWrite("/r/main/.git/worktrees/wt/HEAD", during: .fetch))
        #expect(!RepositoryStore.isLaneOwnWrite("/r/main/.git/worktrees/wt/index", during: .fetch))
        #expect(!RepositoryStore.isLaneOwnWrite("/r/main/.git/worktrees/FETCH_HEAD/index", during: .fetch))
    }

    // MARK: - Which operation holds a worktree's branches

    @Test func theOperationIsReadFromTheWorktreesOwnGitDirectory() throws {
        let layout = try Layout()
        defer { layout.cleanUp() }
        #expect(WorktreeOperationKind.read(worktreePath: layout.linked.path) == nil)
        try FileManager.default.createDirectory(
            at: layout.admin.appendingPathComponent("rebase-merge"), withIntermediateDirectories: true)
        #expect(WorktreeOperationKind.read(worktreePath: layout.linked.path) == .rebase)
        try FileManager.default.removeItem(at: layout.admin.appendingPathComponent("rebase-merge"))
        try FileManager.default.createDirectory(
            at: layout.admin.appendingPathComponent("rebase-apply"), withIntermediateDirectories: true)
        #expect(WorktreeOperationKind.read(worktreePath: layout.linked.path) == .rebase)
        try FileManager.default.removeItem(at: layout.admin.appendingPathComponent("rebase-apply"))
        try layout.write(layout.admin.appendingPathComponent("BISECT_START"), "bis\n")
        #expect(WorktreeOperationKind.read(worktreePath: layout.linked.path) == .bisect)
        // A worktree whose folder is gone has no `.git` to follow.
        #expect(WorktreeOperationKind.read(worktreePath: layout.base.appendingPathComponent("gone").path) == nil)
    }
}
