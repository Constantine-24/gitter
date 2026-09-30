import Darwin
import Foundation
import Testing

@testable import GitCore

// MARK: - A Trash that is a scratch folder

/// Moves an item into a scratch folder instead of the user's Trash, and back, with
/// `FileManagerTrasher`'s rules: a missing parent directory is made again, and an existing
/// item is never overwritten (`moveItem` fails with Cocoa error 516).
///
/// The folder goes when the trasher does (`deinit`), so one passed inline —
/// `trasher: try FakeTrasher()` — leaves nothing in `$TMPDIR` either.
final class FakeTrasher: Trasher, @unchecked Sendable {
    let folder: URL

    init() throws {
        folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-fake-trash-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    func trash(_ url: URL) throws -> URL {
        // A fresh directory per item, keeping the name: two `a` from different folders can both
        // be in the Trash, as in the real one.
        let bin = folder.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: bin, withIntermediateDirectories: true)
        let destination = bin.appendingPathComponent(url.lastPathComponent)
        try FileManager.default.moveItem(at: url, to: destination)
        return destination
    }

    func restore(_ trashed: URL, to original: URL) throws {
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: trashed, to: original)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: folder) }

    deinit { cleanUp() }
}

// MARK: - The whole worktree, as lstat sees it

/// One worktree entry: its type, permission bits, and its bytes (a file) or its target (a
/// link). Unlike `worktreeSnapshot`, a symlink is itself, a dangling one is not skipped, the
/// executable bit counts, and a directory is an entry, so an emptied one shows.
struct WorktreeEntry: Hashable, CustomStringConvertible {
    enum Kind: Hashable { case file, directory, link }
    let kind: Kind
    let permissions: Int
    let content: Data

    var description: String {
        let text = String(decoding: content, as: UTF8.self).debugDescription
        return "\(kind) \(String(permissions, radix: 8)) \(text)"
    }
}

func worktreeState(_ repo: TestRepo) -> [String: WorktreeEntry] {
    var result: [String: WorktreeEntry] = [:]
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: repo.root.path) else { return result }
    for case let relative as String in enumerator {
        if relative == ".git" {
            enumerator.skipDescendants()
            continue
        }
        let path = repo.root.appendingPathComponent(relative).path
        var info = stat()
        guard lstat(path, &info) == 0 else { continue }
        let permissions = Int(info.st_mode & 0o777)
        switch info.st_mode & S_IFMT {
        case S_IFLNK:
            let target = (try? fm.destinationOfSymbolicLink(atPath: path)) ?? ""
            result[relative] = WorktreeEntry(kind: .link, permissions: 0, content: Data(target.utf8))
        case S_IFDIR:
            result[relative] = WorktreeEntry(kind: .directory, permissions: permissions, content: Data())
        default:
            let bytes = (try? Data(contentsOf: URL(fileURLWithPath: path))) ?? Data()
            result[relative] = WorktreeEntry(kind: .file, permissions: permissions, content: bytes)
        }
    }
    return result
}

/// Asserts the worktree is exactly `before`, entry by entry. Fails on an empty baseline.
func assertWorktreeState(
    _ repo: TestRepo, equals before: [String: WorktreeEntry], _ what: String = "the worktree",
    sourceLocation: SourceLocation = #_sourceLocation
) {
    #expect(!before.isEmpty, "the worktree baseline is empty, so comparing against it proves nothing",
            sourceLocation: sourceLocation)
    let now = worktreeState(repo)
    for path in Set(before.keys).union(now.keys).sorted() where before[path] != now[path] {
        Issue.record(
            "\(what): \(path) was \(before[path]?.description ?? "<absent>"), is \(now[path]?.description ?? "<absent>")",
            sourceLocation: sourceLocation)
    }
}

// MARK: - RF1: the bystanders

/// `h` with two layers (index `h/hstagedA`, worktree `h/hstagedA/hunstagedB`) and `k` with an
/// unstaged edit: present in every discard test, and never touched by one (RF1, M B).
struct Bystanders: Equatable {
    let hIndex: Data
    let hWorktree: Data
    let kIndex: Data
    let kWorktree: Data

    static func capture(_ repo: TestRepo) async throws -> Bystanders {
        Bystanders(
            hIndex: try await repo.indexContent(of: "h"), hWorktree: try repo.bytes("h"),
            kIndex: try await repo.indexContent(of: "k"), kWorktree: try repo.bytes("k"))
    }

    func assertUnchanged(_ repo: TestRepo, _ when: String, sourceLocation: SourceLocation = #_sourceLocation) async throws {
        // The baseline is the lab's: two distinct layers for h, an edit for k.
        #expect(hIndex == Data("h\nhstagedA\n".utf8) && hWorktree == Data("h\nhstagedA\nhunstagedB\n".utf8)
                    && kWorktree == Data("k\nkunstaged\n".utf8),
                "the bystanders' baseline is not the lab's", sourceLocation: sourceLocation)
        let now = try await Bystanders.capture(repo)
        #expect(now == self, "a bystander changed \(when)", sourceLocation: sourceLocation)
    }
}

// MARK: - The lab

/// Everything the discard cases need, committed: `p` (12 lines), `f3` (30 lines, for hunks),
/// `old` (for a rename), `d` (for a deletion), `s.sh` (for a mode), `link` → `h`, `ws` (lines
/// with trailing spaces). Then the bystanders: `h` staged and unstaged, `k` unstaged.
func makeDiscardLab() async throws -> TestRepo {
    let repo = try await TestRepo.makeEmpty()
    try repo.write("p", numbered(12))
    try repo.write("f3", numbered(30))
    try repo.write("old", "o1\no2\no3\no4\no5\n")
    try repo.write("d", "d\n")
    try repo.write("s.sh", "echo s\n")
    try repo.write("h", "h\n")
    try repo.write("k", "k\n")
    try repo.write("ws", "a\nx   \nb\n")
    try FileManager.default.createSymbolicLink(
        atPath: repo.root.appendingPathComponent("link").path, withDestinationPath: "h")
    try await repo.commitAll("root")
    try repo.write("h", "h\nhstagedA\n")
    try await repo.git(["add", "h"])
    try repo.write("h", "h\nhstagedA\nhunstagedB\n")
    try repo.write("k", "k\nkunstaged\n")
    return repo
}

func numbered(_ count: Int, _ changes: [Int: String] = [:]) -> String {
    (1...count).map { (changes[$0] ?? "\($0)") + "\n" }.joined()
}

extension TestRepo {
    func chmod(_ path: String, _ mode: Int) throws {
        try FileManager.default.setAttributes(
            [.posixPermissions: mode], ofItemAtPath: root.appendingPathComponent(path).path)
    }

    func remove(_ path: String) throws {
        try FileManager.default.removeItem(at: root.appendingPathComponent(path))
    }

    /// `path` under the worktree, its directory made: where to write bytes that are not text.
    func url(_ path: String) throws -> URL {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        return url
    }

    func relink(_ path: String, to target: String) throws {
        try remove(path)
        try FileManager.default.createSymbolicLink(
            atPath: root.appendingPathComponent(path).path, withDestinationPath: target)
    }

    /// Every sha the stash list holds, newest first.
    func stashShas() async throws -> [String] {
        guard try await stashRef() != nil else { return [] }
        let data = try await git(["stash", "list", "--format=%H"])
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// `ls-files -s -- <path>` (mode, blob and stage), empty when the index has no entry.
    func indexLine(_ path: String) async throws -> String {
        String(decoding: try await git(["ls-files", "-s", "--", ":(literal)" + path]), as: UTF8.self)
    }
}

// MARK: - The cases every kind is tried on

/// One discard of each kind and shape the spec's table measured (M A.1, A.2, A.4, B), set up
/// on the lab and requested the way the app will: with the expectation `discard` re-reads.
enum DiscardCase: String, CaseIterable, Sendable, CustomTestStringConvertible {
    case unstagedModified, unstagedDeletion, unstagedMode, unstagedSymlink, unstagedBothLayers
    case stagedBothLayers, stagedNewFile, stagedRename, stagedDeletion, stagedMode
    case linesOneHunkOfThree, linesTwoLinesOfAHunk
    case untrackedFile, untrackedDirectory

    var testDescription: String { rawValue }

    var paths: [String] {
        switch self {
        case .unstagedModified, .unstagedDeletion, .unstagedBothLayers, .stagedBothLayers: return ["p"]
        case .unstagedMode, .stagedMode: return ["s.sh"]
        case .unstagedSymlink: return ["link"]
        case .stagedNewFile: return ["n"]
        case .stagedRename: return ["old", "new"]
        case .stagedDeletion: return ["d"]
        case .linesOneHunkOfThree, .linesTwoLinesOfAHunk: return ["f3"]
        case .untrackedFile: return ["u.txt"]
        case .untrackedDirectory: return ["ud/"]
        }
    }

    var isUntracked: Bool { self == .untrackedFile || self == .untrackedDirectory }

    func prepare(_ repo: TestRepo) async throws {
        switch self {
        case .unstagedModified: try repo.write("p", numbered(12, [5: "5 mod"]))
        case .unstagedDeletion: try repo.remove("p")
        case .unstagedMode: try repo.chmod("s.sh", 0o755)
        case .unstagedSymlink: try repo.relink("link", to: "k")
        case .unstagedBothLayers, .stagedBothLayers:
            try repo.write("p", numbered(12, [2: "2 staged"]))
            try await repo.git(["add", "p"])
            try repo.write("p", numbered(12, [2: "2 staged", 11: "11 unstaged"]))
        case .stagedNewFile:
            try repo.write("n", "n1\n")
            try await repo.git(["add", "n"])
            try repo.write("n", "n1\nn2\n")
        case .stagedRename:
            try await repo.git(["mv", "old", "new"])
            try repo.write("new", "o1\no2\no3\no4\no5\no6\n")
        case .stagedDeletion: try await repo.git(["rm", "-q", "d"])
        case .stagedMode:
            try repo.chmod("s.sh", 0o755)
            try await repo.git(["add", "s.sh"])
        case .linesOneHunkOfThree:
            try repo.write("f3", numbered(30, [3: "3 A", 15: "15 B", 27: "27 C"]))
        case .linesTwoLinesOfAHunk:
            try repo.write("f3", numbered(30, [3: "3 A", 15: "15 B\n15a\n15b"]))
        case .untrackedFile: try repo.write("u.txt", "u\n")
        case .untrackedDirectory:
            try repo.write("ud/a", "a\n")
            try repo.write("ud/deeper/b", "b\n")
        }
    }

    func request(_ repo: TestRepo) async throws -> DiscardRequest {
        let backend = CLIGitBackend()
        switch self {
        case .unstagedModified, .unstagedDeletion, .unstagedMode, .unstagedSymlink, .unstagedBothLayers:
            return .unstaged(
                paths: paths,
                expected: try await backend.discardExpectation(tracked: paths, includingStaged: false, at: repo.root))
        case .stagedBothLayers, .stagedNewFile, .stagedRename, .stagedDeletion, .stagedMode:
            return .stagedAndUnstaged(
                paths: paths,
                expected: try await backend.discardExpectation(tracked: paths, includingStaged: true, at: repo.root))
        case .linesOneHunkOfThree:
            let file = try await loadDiff(repo, "f3")
            return try linesRequest(file, hunks: [try hunkID(file, containing: "15 B")], lines: nil)
        case .linesTwoLinesOfAHunk:
            let file = try await loadDiff(repo, "f3")
            return try linesRequest(
                file, hunks: [try hunkID(file, containing: "15a")], lines: changedLineIDs(file, "15a", "15b"))
        case .untrackedFile, .untrackedDirectory:
            return .untracked(
                paths: paths, expected: try await backend.discardExpectation(untracked: paths, at: repo.root))
        }
    }

    /// The worktree right after the discard, for the paths it names.
    func expectDiscarded(_ repo: TestRepo, head: [String: WorktreeEntry], sourceLocation: SourceLocation = #_sourceLocation) async throws {
        let now = worktreeState(repo)
        func expect(_ path: String, _ entry: WorktreeEntry?) {
            #expect(now[path] == entry, "\(path) is \(now[path]?.description ?? "<absent>")",
                    sourceLocation: sourceLocation)
        }
        switch self {
        case .unstagedModified, .unstagedDeletion, .stagedBothLayers: expect("p", head["p"])
        case .unstagedMode, .stagedMode: expect("s.sh", head["s.sh"])
        case .unstagedSymlink: expect("link", head["link"])
        case .unstagedBothLayers:
            // Only the unstaged layer goes: the worktree is the staged content.
            expect("p", WorktreeEntry(kind: .file, permissions: 0o644, content: Data(numbered(12, [2: "2 staged"]).utf8)))
            #expect(try await repo.indexContent(of: "p") == Data(numbered(12, [2: "2 staged"]).utf8),
                    sourceLocation: sourceLocation)
        case .stagedNewFile:
            expect("n", nil)
            #expect(try await repo.indexLine("n").isEmpty, sourceLocation: sourceLocation)
        case .stagedRename:
            expect("old", head["old"])
            expect("new", nil)
            #expect(try await repo.indexLine("new").isEmpty, sourceLocation: sourceLocation)
        case .stagedDeletion: expect("d", head["d"])
        case .linesOneHunkOfThree:
            expect("f3", WorktreeEntry(kind: .file, permissions: 0o644, content: Data(numbered(30, [3: "3 A", 27: "27 C"]).utf8)))
        case .linesTwoLinesOfAHunk:
            expect("f3", WorktreeEntry(kind: .file, permissions: 0o644, content: Data(numbered(30, [3: "3 A", 15: "15 B"]).utf8)))
        case .untrackedFile: expect("u.txt", nil)
        case .untrackedDirectory:
            expect("ud", nil)
            expect("ud/a", nil)
        }
        // The staged side of these goes back to HEAD in the index too.
        switch self {
        case .stagedBothLayers, .stagedMode, .stagedDeletion, .stagedRename:
            for path in paths where head[path] != nil {
                #expect(try await repo.indexContent(of: path) == (try await repo.blob("HEAD", path)),
                        sourceLocation: sourceLocation)
                #expect(try await repo.indexLine(path).hasPrefix(try await repo.mode("HEAD", path) ?? "?"),
                        sourceLocation: sourceLocation)
            }
        default: break
        }
    }
}

/// A `.lines` request for a selection, built as the app is to build it.
func linesRequest(_ file: FileDiff, hunks: Set<Hunk.ID>, lines: Set<DiffLine.ID>?) throws -> DiscardRequest {
    let patch = try #require(PatchBuilder.discardPatch(file: file, hunkIDs: hunks, lineIDs: lines))
    let count = PatchBuilder.selectedLineCount(file: file, hunkIDs: hunks, lineIDs: lines)
    return .lines(path: file.displayPath, patch: patch, lineCount: count, expected: .diffs([file]))
}

/// A clone of `repo` with the record fetched and applied with `--index` onto its clean
/// checkout — where nothing else is staged, which is when `--index` is exact (M A.2). What the
/// record holds, read back through git rather than trusted.
func cloneApplyingRecord(_ repo: TestRepo, _ sha: String) async throws -> TestRepo {
    let clone = TestRepo(root: FileManager.default.temporaryDirectory
        .appendingPathComponent("gitter-clone-\(UUID().uuidString)", isDirectory: true))
    _ = try await isolatedRunner().run(
        "/usr/bin/git", ["clone", "-q", repo.root.path, clone.root.path],
        cwd: FileManager.default.temporaryDirectory)
    try await clone.git(["fetch", "-q", repo.root.path, "refs/stash:refs/remotes/origin/record"])
    try await clone.git(["stash", "apply", "-q", "--index", sha])
    return clone
}
