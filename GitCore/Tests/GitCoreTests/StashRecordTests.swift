import Darwin
import Foundation
import Testing

@testable import GitCore

// MARK: - Shared stash test support

extension TestRepo {
    /// `refs/stash`, or nil when there is none.
    func stashRef() async throws -> String? {
        let data = try await git(["rev-parse", "-q", "--verify", "refs/stash"], allowedExitCodes: [1])
        let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// How many entries the stash list holds.
    func stashCount() async throws -> Int {
        guard try await stashRef() != nil else { return 0 }
        let data = try await git(["stash", "list", "--format=%H"])
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count
    }

    /// `diff-tree -r --no-renames --name-status` between two commits, as `"<status>\t<path>"`,
    /// read with `-z` so a non-ASCII or special name comes back raw.
    func nameStatus(from: String, to: String) async throws -> [String] {
        let data = try await git(["diff-tree", "-r", "-z", "--no-renames", "--name-status", from, to])
        let fields = String(decoding: data, as: UTF8.self)
            .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        return stride(from: 0, to: fields.count - 1, by: 2).map { "\(fields[$0])\t\(fields[$0 + 1])" }
    }

    /// The bytes `rev` holds at `path`.
    func blob(_ rev: String, _ path: String) async throws -> Data {
        try await git(["cat-file", "blob", "\(rev):\(path)"])
    }

    /// The mode `rev` records for `path` (`100644`, `100755`, `120000`), or nil when absent.
    func mode(_ rev: String, _ path: String) async throws -> String? {
        let data = try await git(["ls-tree", "-z", "--full-tree", rev, "--", ":(literal)" + path])
        let record = String(decoding: data, as: UTF8.self)
        return record.isEmpty ? nil : String(record.prefix(while: { $0 != " " }))
    }

    func bytes(_ path: String) throws -> Data {
        try Data(contentsOf: root.appendingPathComponent(path))
    }
}

/// What the record must never change, beyond the worktree: the real index file — its bytes
/// *and* its nanosecond mtime, since a rewrite with the same entries still changes the file —
/// HEAD, and every ref except `refs/stash` (M A.0).
struct RecordPurity: Equatable {
    let indexBytes: Data
    let indexMtimeSeconds: Int
    let indexMtimeNanoseconds: Int
    let head: String
    let symbolicHead: String
    let refsOtherThanStash: [String]

    static func capture(_ repo: TestRepo) async throws -> RecordPurity {
        let indexPath = repo.root.appendingPathComponent(".git/index").path
        var info = stat()
        guard stat(indexPath, &info) == 0 else {
            throw CocoaError(.fileNoSuchFile)
        }
        let refs = String(
            decoding: try await repo.git(["for-each-ref", "--format=%(refname) %(objectname)"]),
            as: UTF8.self
        ).split(separator: "\n").map(String.init).filter { !$0.hasPrefix("refs/stash ") }
        return RecordPurity(
            indexBytes: try Data(contentsOf: URL(fileURLWithPath: indexPath)),
            indexMtimeSeconds: info.st_mtimespec.tv_sec,
            indexMtimeNanoseconds: info.st_mtimespec.tv_nsec,
            head: try await repo.revParse("HEAD"),
            symbolicHead: String(
                decoding: try await repo.git(["symbolic-ref", "-q", "HEAD"], allowedExitCodes: [1]),
                as: UTF8.self),
            refsOtherThanStash: refs)
    }
}

/// Asserts the record touched nothing but `refs/stash`: see `RecordPurity`. Fails on an empty
/// baseline, which would compare equal to a probe that read nothing.
func assertRecordPure(
    _ repo: TestRepo, since before: RecordPurity, worktree: [String: Data],
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    #expect(!before.indexBytes.isEmpty && !before.head.isEmpty && !before.refsOtherThanStash.isEmpty,
            "the baseline is empty, so comparing against it would prove nothing",
            sourceLocation: sourceLocation)
    assertWorktreeUnchanged(repo, since: worktree, sourceLocation: sourceLocation)
    let now = try await RecordPurity.capture(repo)
    #expect(now.indexBytes == before.indexBytes, "the real index's bytes changed",
            sourceLocation: sourceLocation)
    #expect(now.indexMtimeSeconds == before.indexMtimeSeconds
                && now.indexMtimeNanoseconds == before.indexMtimeNanoseconds,
            "the real index was rewritten (its mtime moved)", sourceLocation: sourceLocation)
    #expect(now.head == before.head, "HEAD moved", sourceLocation: sourceLocation)
    #expect(now.symbolicHead == before.symbolicHead, "HEAD points somewhere else",
            sourceLocation: sourceLocation)
    #expect(now.refsOtherThanStash == before.refsOtherThanStash, "a ref other than refs/stash changed",
            sourceLocation: sourceLocation)
}

/// A repository with a committed `p`, `h`, `k` and `a1.txt`, then: `p` staged (`2 staged`) and
/// unstaged (`11 unstaged`) on top, `h` staged, `k` and `a1.txt` unstaged — Follow-up A's lab.
func makeRecordLab() async throws -> TestRepo {
    let repo = try await TestRepo.makeEmpty()
    try repo.write("p", (1...12).map { "\($0)\n" }.joined())
    try repo.write("h", "h\n")
    try repo.write("k", "k\n")
    try repo.write("a1.txt", "a1\n")
    try await repo.commitAll("root")
    try repo.write("p", (1...12).map { $0 == 2 ? "2 staged\n" : "\($0)\n" }.joined())
    try repo.write("h", "h\nhstaged\n")
    try await repo.git(["add", "p", "h"])
    try repo.write("p", (1...12).map { $0 == 2 ? "2 staged\n" : $0 == 11 ? "11 unstaged\n" : "\($0)\n" }.joined())
    try repo.write("k", "k\nkunstaged\n")
    try repo.write("a1.txt", "a1 dirty\n")
    return repo
}

/// Case (a): a committed file `p` replaced on disk by a directory holding `p/x`; `h` is
/// committed and unchanged.
func makeTypeSwapA() async throws -> TestRepo {
    let repo = try await TestRepo.makeEmpty()
    try repo.write("p", "p\n")
    try repo.write("h", "h\n")
    try await repo.commitAll("root")
    try FileManager.default.removeItem(at: repo.root.appendingPathComponent("p"))
    try repo.write("p/x", "precious\n")
    return repo
}

/// Case (b): a committed `d/a` whose directory was replaced on disk by a file `d`.
func makeTypeSwapB() async throws -> TestRepo {
    let repo = try await TestRepo.makeEmpty()
    try repo.write("d/a", "a\n")
    try repo.write("h", "h\n")
    try await repo.commitAll("root")
    try FileManager.default.removeItem(at: repo.root.appendingPathComponent("d"))
    try repo.write("d", "precious\n")
    return repo
}

// MARK: - The record

/// Gitter's own path-limited stash commit (M A.0): built in a temporary index, filed with
/// `stash store`, touching nothing else.
@Suite struct StashRecordTests {
    private func record(_ paths: [String], _ message: String = "Discarded by Gitter: test", in repo: TestRepo) async throws -> Stash {
        try await StashRecord.record(paths: paths, message: message, backend: CLIGitBackend(), at: repo.root)
    }

    // MARK: Purity

    @Test func theRecordWritesOnlyRefsStash() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        let before = try await RecordPurity.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let head = try await repo.headSha()

        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-record-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        let stash = try await StashRecord.make(
            paths: ["p"], message: "Discarded by Gitter: test", backend: CLIGitBackend(), at: repo.root,
            temporaryDirectory: temporary
        ).stash

        try await assertRecordPure(repo, since: before, worktree: worktree)
        #expect(stash.index == 0)
        #expect(stash.sha == (try await repo.stashRef()))
        #expect(stash.reflogSubject == "Discarded by Gitter: test")
        #expect(stash.kind == .discarded)
        #expect(stash.parents.count == 2)
        #expect(stash.parents.first == head)
        #expect(try await repo.stashCount() == 1)
        // The temporary index is gone.
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path) == [])
    }

    /// A record that fails half-way — `update-index` refuses a tracked directory by name ("is a
    /// directory") after `read-tree` made the temporary index — files nothing and leaves no
    /// temporary index behind.
    @Test func aRecordThatFailsHalfWayFilesNothingAndRemovesItsIndex() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        try repo.write("d/e", "e\n")
        try await repo.git(["add", "d/e"])
        try await repo.git(["commit", "-q", "-m", "d", "--", "d/e"])
        try repo.write("d/e", "e\nchanged\n")
        let before = try await RecordPurity.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-record-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }

        await #expect(throws: GitError.self) {
            _ = try await StashRecord.make(
                paths: ["d"], message: "m", backend: CLIGitBackend(), at: repo.root, temporaryDirectory: temporary)
        }

        try await assertRecordPure(repo, since: before, worktree: worktree)
        #expect(try await repo.stashRef() == nil)
        #expect(try FileManager.default.contentsOfDirectory(atPath: temporary.path) == [])
    }

    /// Fix round 2: no way through a record leaves its temporary index (or a `.lock` beside it)
    /// behind — a success, a refusal, a failure after `read-tree` made the file, a failure at
    /// the very last step (`stash store` against a locked `refs/stash`), and a cancelled one.
    /// Every refusal comes before the file exists; the `defer` that removes it is registered
    /// before the first git call that could create it.
    @Test func noWayThroughARecordLeavesItsTemporaryIndex() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        try repo.write("d/e", "e\n")
        try await repo.git(["add", "d/e"])
        try await repo.git(["commit", "-q", "-m", "d", "--", "d/e"])
        try repo.write("d/e", "e\nchanged\n")
        try repo.write("n", "n\n")
        try await repo.git(["add", "-N", "n"])
        let temporary = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-record-dir-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: temporary) }
        func record(_ paths: [String]) async throws -> StashRecord {
            try await StashRecord.make(
                paths: paths, message: "Discarded by Gitter: m", backend: CLIGitBackend(), at: repo.root,
                temporaryDirectory: temporary)
        }
        func leftBehind() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: temporary.path) }

        _ = try await record(["p"])
        #expect(try leftBehind() == [], "after a success")
        await #expect(throws: StashRefusal.intentToAdd(["n"])) { _ = try await record(["n"]) }
        #expect(try leftBehind() == [], "after a refusal")
        await #expect(throws: GitError.self) { _ = try await record(["d"]) }
        #expect(try leftBehind() == [], "after update-index failed half-way")
        let lock = repo.root.appendingPathComponent(".git/refs/stash.lock")
        try Data().write(to: lock)
        await #expect(throws: GitError.self) { _ = try await record(["k"]) }
        try FileManager.default.removeItem(at: lock)
        #expect(try leftBehind() == [], "after stash store failed")
        let task = Task { try await record(["k"]) }
        task.cancel()
        _ = await task.result
        #expect(try leftBehind() == [], "after a cancelled record")
    }

    /// The negative control for `assertRecordPure`: an index rewritten with the very same bytes
    /// (only its mtime moves) must fail it, and so must a new branch.
    @Test func assertRecordPureNoticesARewrittenIndexAndANewRef() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        let before = try await RecordPurity.capture(repo)
        let worktree = worktreeSnapshot(repo)

        let index = repo.root.appendingPathComponent(".git/index")
        let bytes = try Data(contentsOf: index)
        try bytes.write(to: index)
        #expect(try Data(contentsOf: index) == bytes)
        await withKnownIssue("the index file was rewritten with the same bytes") {
            try await assertRecordPure(repo, since: before, worktree: worktree)
        }

        let rewritten = try await RecordPurity.capture(repo)
        try await repo.git(["branch", "extra"])
        await withKnownIssue("a branch was created") {
            try await assertRecordPure(repo, since: rewritten, worktree: worktree)
        }
    }

    // MARK: Scope

    @Test func theEntryHoldsOnlyTheNamedPathInBothLayers() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        let staged = try await repo.indexContent(of: "p")
        let worktree = try repo.bytes("p")

        let stash = try await record(["p"], in: repo)

        #expect(try await repo.nameStatus(from: "\(stash.sha)^1", to: stash.sha) == ["M\tp"])
        #expect(try await repo.nameStatus(from: "\(stash.sha)^1", to: "\(stash.sha)^2") == ["M\tp"])
        #expect(try await repo.blob(stash.sha, "p") == worktree)
        #expect(try await repo.blob("\(stash.sha)^2", "p") == staged)
    }

    /// RF4: a glob, brackets, a leading dash, a space, non-ASCII, and a comma (which
    /// `--cacheinfo` must not split on — **VERIFY**, and it does not). Each neighbour is dirty
    /// too, so a pattern that matched more than its own name would show up.
    @Test func namesThatLookLikePatternsOrFlagsHoldExactlyTheirOwnFile() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let names = ["a*.txt", "a1.txt", "[x].txt", "x.txt", "-lead.txt", "sp ace.txt", "ünï.txt", "x,y,z.txt"]
        for name in names { try repo.write(name, "\(name)\n") }
        try await repo.commitAll("root")
        for name in names { try repo.write(name, "\(name)\ndirty\n") }
        try repo.write("x,y,z.txt", "x,y,z.txt\nstaged\n")
        try await repo.git(["add", "--", "x,y,z.txt"])
        try repo.write("x,y,z.txt", "x,y,z.txt\nstaged\nunstaged\n")

        for name in ["a*.txt", "[x].txt", "-lead.txt", "sp ace.txt", "ünï.txt", "x,y,z.txt"] {
            let stash = try await record([name], in: repo)
            #expect(try await repo.nameStatus(from: "\(stash.sha)^1", to: stash.sha) == ["M\t\(name)"],
                    "\(name)")
            #expect(try await repo.blob(stash.sha, name) == (try repo.bytes(name)), "\(name)")
        }
        let comma = try #require(try await CLIGitBackend().stashes(at: repo.root).first)
        #expect(try await repo.nameStatus(from: "\(comma.sha)^1", to: "\(comma.sha)^2") == ["M\tx,y,z.txt"])
        #expect(try await repo.blob("\(comma.sha)^2", "x,y,z.txt") == Data("x,y,z.txt\nstaged\n".utf8))
    }

    // MARK: What it records (M A.0)

    @Test func aStagedRenameIsAnAdditionAndADeletionInBothLayers() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("old", "same\nsame\nsame\n")
        try repo.write("h", "h\n")
        try await repo.commitAll("root")
        try await repo.git(["mv", "old", "new"])
        try repo.write("new", "same\nsame\nsame\nedited\n")

        let stash = try await record(["old", "new"], in: repo)

        #expect(Set(try await repo.nameStatus(from: "\(stash.sha)^1", to: "\(stash.sha)^2")) == ["A\tnew", "D\told"])
        #expect(Set(try await repo.nameStatus(from: "\(stash.sha)^1", to: stash.sha)) == ["A\tnew", "D\told"])
        #expect(try await repo.blob(stash.sha, "new") == Data("same\nsame\nsame\nedited\n".utf8))
        #expect(try await repo.blob("\(stash.sha)^2", "new") == Data("same\nsame\nsame\n".utf8))
    }

    @Test func aStagedDeletionIsADeletionInBothLayers() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("p", "p\n")
        try repo.write("h", "h\n")
        try await repo.commitAll("root")
        try await repo.git(["rm", "-q", "p"])

        let stash = try await record(["p"], in: repo)

        #expect(try await repo.nameStatus(from: "\(stash.sha)^1", to: "\(stash.sha)^2") == ["D\tp"])
        #expect(try await repo.nameStatus(from: "\(stash.sha)^1", to: stash.sha) == ["D\tp"])
    }

    @Test func aModeOnlyChangeIsTheExecutableBitInTheWorktreeLayer() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("s.sh", "echo\n")
        try await repo.commitAll("root")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755], ofItemAtPath: repo.root.appendingPathComponent("s.sh").path)

        let stash = try await record(["s.sh"], in: repo)

        #expect(try await repo.mode(stash.sha, "s.sh") == "100755")
        #expect(try await repo.mode("\(stash.sha)^2", "s.sh") == "100644")
    }

    /// The link itself, not what it points at: `update-index --add` reads the worktree as git
    /// would, where `hash-object` would follow the link (M 8).
    @Test func aRetargetedSymlinkIsRecordedAsTheLink() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("h", "h\n")
        try repo.write("k", "k\n")
        try FileManager.default.createSymbolicLink(
            atPath: repo.root.appendingPathComponent("link").path, withDestinationPath: "h")
        try await repo.commitAll("root")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(
            atPath: repo.root.appendingPathComponent("link").path, withDestinationPath: "k")

        let stash = try await record(["link"], in: repo)

        #expect(try await repo.mode(stash.sha, "link") == "120000")
        #expect(try await repo.blob(stash.sha, "link") == Data("k".utf8))
        #expect(try await repo.blob("\(stash.sha)^2", "link") == Data("h".utf8))
    }

    @Test func aDeletionInTheWorktreeIsADeletionInTheWorktreeLayerOnly() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("p", "p\n")
        try repo.write("h", "h\n")
        try await repo.commitAll("root")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("p"))

        let stash = try await record(["p"], in: repo)

        #expect(try await repo.nameStatus(from: "\(stash.sha)^1", to: stash.sha) == ["D\tp"])
        #expect(try await repo.nameStatus(from: "\(stash.sha)^1", to: "\(stash.sha)^2") == [])
    }

    @Test func anUntrackedFileIsAnAdditionInTheWorktreeLayerOnly() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("h", "h\n")
        try await repo.commitAll("root")
        try repo.write("u", "untracked\n")

        let stash = try await record(["u"], in: repo)

        #expect(try await repo.nameStatus(from: "\(stash.sha)^1", to: stash.sha) == ["A\tu"])
        #expect(try await repo.nameStatus(from: "\(stash.sha)^1", to: "\(stash.sha)^2") == [])
    }

    /// An ordinary tracked file deleted from the worktree, which git pairs with an
    /// intent-to-add file of the same content as a rename (`2 .R … b` then `t`). The deleted
    /// half is *not* intent-to-add — it is in HEAD — so it is recorded, as a deletion.
    @Test func theTrackedHalfOfAnIntentToAddPairIsRecorded() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("t", "same\nsame\nsame\n")
        try await repo.commitAll("root")
        try FileManager.default.moveItem(
            at: repo.root.appendingPathComponent("t"), to: repo.root.appendingPathComponent("b"))
        try await repo.git(["add", "-N", "b"])
        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        #expect(status.files.contains { $0.path == "b" && $0.originalPath == "t" && $0.isIntentToAdd },
                "the pairing this test is about did not happen: \(status.files)")

        let stash = try await record(["t"], in: repo)

        #expect(try await repo.nameStatus(from: "\(stash.sha)^1", to: stash.sha) == ["D\tt"])
    }

    // MARK: The same sha twice (a `stash store` git answers by filing nothing)

    /// `stash store` of the sha already at `stash@{0}` exits 0 and files nothing — not even the
    /// new message. Two records made in the same second from the same state are the same commit,
    /// so that is what a second record meets. It is success: the entry holding exactly this is
    /// listed at `stash@{0}`.
    @Test func filingTheShaAlreadyOnTopIsSuccessAndFilesNothingNew() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        try await repo.git(["stash", "push", "-q", "-m", "top"])
        let top = try #require(try await repo.stashRef())

        let stash = try await StashRecord.file(top, message: "again", backend: CLIGitBackend(), at: repo.root)

        #expect(stash.sha == top)
        #expect(stash.index == 0)
        #expect(stash.reflogSubject == "On main: top")
        #expect(try await repo.stashCount() == 1)
    }

    /// The other side of the same rule: a sha that is *not* on top is filed, even one listed
    /// lower down.
    @Test func filingAShaListedLowerDownFilesItOnTop() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        try await repo.git(["stash", "push", "-q", "-m", "first"])
        let first = try #require(try await repo.stashRef())
        try repo.write("h", "h\nagain\n")
        try await repo.git(["stash", "push", "-q", "-m", "second"])

        let stash = try await StashRecord.file(first, message: "again", backend: CLIGitBackend(), at: repo.root)

        #expect(stash.sha == first)
        #expect(stash.index == 0)
        #expect(stash.reflogSubject == "again")
        #expect(try await repo.stashCount() == 3)
    }

    @Test func aShaThatIsNotStashLikeIsAnErrorAndFilesNothing() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        let head = try await repo.headSha()

        await #expect(throws: GitError.self) {
            _ = try await StashRecord.file(head, message: "bad", backend: CLIGitBackend(), at: repo.root)
        }
        #expect(try await repo.stashRef() == nil)
    }

    // MARK: Refusals — before anything is written

    private func expectRefusal(
        _ refusal: StashRefusal, recording paths: [String], in repo: TestRepo,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let state = try await RepoState.capture(repo)
        let purity = try await RecordPurity.capture(repo)
        let worktree = worktreeSnapshot(repo)
        let stashBefore = try await repo.stashRef()

        await #expect(throws: refusal, sourceLocation: sourceLocation) {
            _ = try await record(paths, in: repo)
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree, sourceLocation: sourceLocation)
        try await assertRecordPure(repo, since: purity, worktree: worktree, sourceLocation: sourceLocation)
        #expect(try await repo.stashRef() == stashBefore, "refs/stash changed", sourceLocation: sourceLocation)
    }

    @Test func anUnmergedPathIsRefused() async throws {
        let repo = try await TestRepo.makeConflicting()
        defer { repo.cleanUp() }
        try await repo.git(["merge", "feature"], allowedExitCodes: [1])
        #expect(!(try await repo.unmergedEntries()).isEmpty)

        try await expectRefusal(.unmergedPaths(["a.txt"]), recording: ["a.txt", "keep.txt"], in: repo)
    }

    @Test func anIntentToAddPathIsRefused() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        try repo.write("n", "new\n")
        try await repo.git(["add", "-N", "n"])

        try await expectRefusal(.intentToAdd(["n"]), recording: ["p", "n"], in: repo)
    }

    /// `1 .D N... 100644 100644 000000 e69de29… e69de29… q` — porcelain v2 cannot tell this
    /// from a committed empty file deleted from the worktree. HEAD can: `q` is not in it.
    @Test func aDeletedIntentToAddPathIsRefused() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        try repo.write("q", "q\n")
        try await repo.git(["add", "-N", "q"])
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("q"))

        try await expectRefusal(.intentToAdd(["q"]), recording: ["q"], in: repo)
    }

    /// And the committed empty file deleted from the worktree, which looks the same in
    /// porcelain v2, is recorded.
    @Test func aDeletedCommittedEmptyFileIsNotMistakenForIntentToAdd() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("empty", "")
        try repo.write("h", "h\n")
        try await repo.commitAll("root")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("empty"))

        let stash = try await record(["empty"], in: repo)

        #expect(try await repo.nameStatus(from: "\(stash.sha)^1", to: stash.sha) == ["D\tempty"])
    }

    /// A deleted intent-to-add `q` and an empty intent-to-add `e` are paired by git as a rename
    /// (`2 .R … e` then `q`): `q` has no status line of its own, only the pair's original path.
    @Test func bothHalvesOfAnIntentToAddRenameAreRefused() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        try repo.write("q", "")
        try repo.write("e", "")
        try await repo.git(["add", "-N", "q", "e"])
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("q"))
        let status = try await CLIGitBackend().snapshot(at: repo.root).status
        #expect(status.files.contains { $0.path == "e" && $0.originalPath == "q" },
                "the pairing this test is about did not happen: \(status.files)")

        try await expectRefusal(.intentToAdd(["q"]), recording: ["q"], in: repo)
        try await expectRefusal(.intentToAdd(["e"]), recording: ["e"], in: repo)
    }

    @Test func aSubmoduleIsRefused() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("h", "h\n")
        try repo.write("sub/s", "s\n")
        let sub = TestRepo(root: repo.root.appendingPathComponent("sub"))
        try await sub.git(["init", "-q", "-b", "main"])
        try await sub.git(["-c", "user.name=T", "-c", "user.email=t@t", "add", "s"])
        try await sub.git(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", "s"])
        try await repo.git(["add", "h", "sub"])
        try await repo.git(["commit", "-q", "-m", "root"])
        try repo.write("sub/s", "s\ndirty\n")
        try repo.write("h", "h\ndirty\n")

        try await expectRefusal(.submodules(["sub"]), recording: ["h", "sub"], in: repo)
    }

    @Test func aNestedRepositoryOrAPathInsideOneIsRefused() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }
        try repo.write("nested/x", "x\n")
        try await TestRepo(root: repo.root.appendingPathComponent("nested")).git(["init", "-q"])

        try await expectRefusal(.nestedRepositories(["nested/"]), recording: ["p", "nested/"], in: repo)
        try await expectRefusal(.nestedRepositories(["nested/x"]), recording: ["nested/x"], in: repo)
    }

    // MARK: A file and a directory swapped (fix round 1)

    /// A tracked file `p` replaced by a directory holding `p/x`. Status shows only ` D p`, and
    /// `update-index --add --remove -- p` would drop `p` without recording `p/x`; the restore
    /// would then put the file back over the directory. Refused before anything runs.
    @Test func aTrackedFileReplacedByADirectoryIsRefused() async throws {
        let repo = try await makeTypeSwapA()
        defer { repo.cleanUp() }
        #expect(worktreeSnapshot(repo)["p/x"] == Data("precious\n".utf8))

        try await expectRefusal(.pathTypeChanged(["p"]), recording: ["p", "h"], in: repo)
    }

    /// A tracked `d/a` whose directory was replaced by an untracked file `d`: ` D d/a` and
    /// `? d`. The restore of `d/a` would delete the file `d`. Refused before anything runs.
    @Test func aPathUnderAFileIsRefused() async throws {
        let repo = try await makeTypeSwapB()
        defer { repo.cleanUp() }
        #expect(worktreeSnapshot(repo)["d"] == Data("precious\n".utf8))

        try await expectRefusal(.pathTypeChanged(["d/a"]), recording: ["d/a"], in: repo)
    }

    /// A tracked symlink that now points at a directory is a symlink, not a directory: it is
    /// recorded as the link.
    @Test func aSymlinkToADirectoryAtATrackedSymlinkIsRecorded() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("dirA/a", "a\n")
        try repo.write("dirB/b", "b\n")
        try FileManager.default.createSymbolicLink(
            atPath: repo.root.appendingPathComponent("link").path, withDestinationPath: "dirA")
        try await repo.commitAll("root")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("link"))
        try FileManager.default.createSymbolicLink(
            atPath: repo.root.appendingPathComponent("link").path, withDestinationPath: "dirB")

        let stash = try await record(["link"], in: repo)

        #expect(try await repo.mode(stash.sha, "link") == "120000")
        #expect(try await repo.blob(stash.sha, "link") == Data("dirB".utf8))
    }

    /// Naming the untracked file inside the swapped directory (`p/x`, where the index still
    /// holds the file `p`): git refuses to put both into one index ("appears as both a file and
    /// as a directory", exit 128), so the record fails loudly and writes nothing.
    @Test func aFileInsideTheSwappedDirectoryFailsLoudlyAndWritesNothing() async throws {
        let repo = try await makeTypeSwapA()
        defer { repo.cleanUp() }
        let state = try await RepoState.capture(repo)
        let purity = try await RecordPurity.capture(repo)
        let worktree = worktreeSnapshot(repo)

        await #expect(throws: (any Error).self) {
            _ = try await record(["p/x"], in: repo)
        }

        try await assertRepoUnchanged(repo, since: state, worktree: worktree)
        try await assertRecordPure(repo, since: purity, worktree: worktree)
        #expect(try await repo.stashRef() == nil)
    }

    @Test func noPathsIsNothingSelected() async throws {
        let repo = try await makeRecordLab()
        defer { repo.cleanUp() }

        try await expectRefusal(.nothingSelected, recording: [], in: repo)
    }
}
