import Foundation
import GitCore
import Testing

@testable import Gitter

/// The discard sheet's live stale line (RF3) no longer re-runs the whole read after every
/// reload (final review I1): it reads git again only when what the tracked reads depend on —
/// each path, the index, HEAD, the attributes and config — changed since its last read, which
/// `lstat` answers without a process. A folder that stands in for a repository (a `.git`
/// directory with an `index` file, no git run) is enough to test it; nothing here opens a
/// repository or touches `UserDefaults`.
@Suite struct DiscardStaleLineTests {

    /// `root/.git/index`, `a.txt`, `dir/b.txt`, and a `.gitattributes` at the top.
    private struct Folder {
        let root: URL

        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitter-stale-line-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(".git"), withIntermediateDirectories: true)
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent("dir"), withIntermediateDirectories: true)
            try write(".git/index", "index")
            try write("a.txt", "one\n")
            try write("dir/b.txt", "two\n")
            try write(".gitattributes", "* text=auto\n")
        }

        func write(_ path: String, _ text: String) throws {
            try Data(text.utf8).write(to: root.appendingPathComponent(path))
        }

        func take(head: String? = "h1") -> DiscardSheetFingerprint? {
            DiscardSheetFingerprint.take(tracked: ["a.txt", "dir/b.txt"], root: root, head: head)
        }

        func cleanUp() { try? FileManager.default.removeItem(at: root) }
    }

    @Test func nothingChangedIsTheSameFingerprint() throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        let first = try #require(folder.take())
        #expect(folder.take() == first)
    }

    /// RF3's case: an edit made in a terminal while the sheet is up, the same size as before,
    /// so only the file's times and nothing about its length say it changed.
    @Test func anEditOfTheSameSizeChangesIt() throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        let before = try #require(folder.take())
        try folder.write("dir/b.txt", "TWO\n")
        #expect(folder.take() != before)
    }

    @Test(arguments: [".git/index", ".gitattributes", "a.txt"])
    func aChangeToWhatTheReadsDependOnChangesIt(_ path: String) throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        let before = try #require(folder.take())
        try folder.write(path, "changed, and longer than before\n")
        #expect(folder.take() != before, "\(path)")
    }

    @Test func aFileThatGoesOrComesChangesIt() throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        let before = try #require(folder.take())
        try FileManager.default.removeItem(at: folder.root.appendingPathComponent("a.txt"))
        let gone = folder.take()
        #expect(gone != before)
        try folder.write("dir/.gitattributes", "*.txt -text\n")
        #expect(folder.take() != gone, "a new .gitattributes on the way to a path")
    }

    @Test func anotherHeadChangesIt() throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        #expect(folder.take(head: "h1") != folder.take(head: "h2"))
    }

    /// A linked worktree's `.git` is a file naming the git directory; its index is there.
    @Test func aGitFileLeadsToItsIndex() throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        let elsewhere = folder.root.appendingPathComponent("elsewhere-gitdir")
        try FileManager.default.moveItem(at: folder.root.appendingPathComponent(".git"), to: elsewhere)
        try folder.write(".git", "gitdir: elsewhere-gitdir\n")
        let before = try #require(folder.take())
        try folder.write("elsewhere-gitdir/index", "another index, longer\n")
        #expect(folder.take() != before)
    }

    /// Without a git directory there is nothing to compare, so every reload reads again.
    @Test func noGitDirectoryIsNoFingerprint() throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        try FileManager.default.removeItem(at: folder.root.appendingPathComponent(".git"))
        #expect(folder.take() == nil)
    }

    // MARK: - When the tracked reads run again

    @Test func theReadsRunAgainOnlyWhenTheFingerprintMoved() throws {
        let folder = try Folder()
        defer { folder.cleanUp() }
        let now = try #require(folder.take())
        let last = DiscardStaleCheck(fingerprint: now, trackedStale: false, isStale: false)

        #expect(DiscardStaleCheck.mustReadTracked(after: nil, now: now), "the first check reads")
        #expect(!DiscardStaleCheck.mustReadTracked(after: last, now: now))
        try folder.write("a.txt", "one, edited\n")
        #expect(DiscardStaleCheck.mustReadTracked(after: last, now: folder.take()))
        #expect(DiscardStaleCheck.mustReadTracked(after: last, now: nil), "no fingerprint now")
        let unknown = DiscardStaleCheck(fingerprint: nil, trackedStale: false, isStale: false)
        #expect(DiscardStaleCheck.mustReadTracked(after: unknown, now: now), "none last time")
    }

    // MARK: - The confirm's own pre-check

    /// A sheet of two requests re-reads only the ones after the first before any runs: GitCore
    /// checks the first itself as it starts, and nothing has been written until then.
    @Test func theConfirmPreChecksOnlyTheRequestsAfterTheFirst() {
        let tracked = DiscardRequest.unstaged(paths: ["a.txt"], expected: .diffs([]))
        let untracked = DiscardRequest.untracked(paths: ["u.txt"], expected: .untracked([]))
        let model = DiscardSheetModel(requests: [tracked, untracked], rows: [], destination: "", isAll: true)
        let single = DiscardSheetModel(requests: [tracked], rows: [], destination: "", isAll: false)

        #expect(model.checkedBeforeTheFirstRuns == [untracked])
        #expect(single.checkedBeforeTheFirstRuns.isEmpty)
    }
}
