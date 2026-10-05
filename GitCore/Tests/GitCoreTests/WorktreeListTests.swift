import Foundation
import Testing

@testable import GitCore

/// `GitWorktreeBackend.worktrees` and `worktreeChanges`, and the branch rows' `checkedOutAt`
/// (B3 Task 2): `worktree list --porcelain -z` read record by record (R13), the branch a rebase or
/// bisect holds from its state files (R14), and `%(worktreepath)` on every local branch — against
/// real git in a fixture of its own, with git's output as the ground truth.
@Suite struct WorktreeListTests {

    // MARK: - The list (R13)

    /// The main worktree first, then the linked ones in git's order, each field as git printed it:
    /// a branch, a detached HEAD, a lock with no reason, a lock whose reason holds a newline and a
    /// tab, and a worktree whose folder is gone.
    @Test func everyKindOfWorktreeIsListedAsGitPrintsIt() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let main = try await repo.headSha()
        try await fixture.addOnNewBranch("wt-feat", "feat")
        try await fixture.addRaw("wt-det", ["--detach", "main"])
        try await fixture.addOnNewBranch("wt-lk1", "lk1")
        try await fixture.addOnNewBranch("wt-lk2", "lk2")
        try await fixture.addOnNewBranch("wt-gone", "gone")
        try await repo.git(["worktree", "lock", fixture.path("wt-lk1")])
        try await repo.git(["worktree", "lock", "--reason", "line one\nline two\ttab \"q\"", fixture.path("wt-lk2")])
        try FileManager.default.removeItem(atPath: fixture.path("wt-gone"))

        let listed = try await fixture.backend.worktrees(at: repo.root)

        #expect(listed.map(\.path) == [
            realPath(repo.root.path), fixture.listedPath("wt-det"), fixture.listedPath("wt-feat"),
            fixture.listedPath("wt-gone"), fixture.listedPath("wt-lk1"), fixture.listedPath("wt-lk2"),
        ])
        #expect(listed[0] == Worktree(
            path: realPath(repo.root.path), head: main, branch: "refs/heads/main", isMain: true, isBare: false,
            lock: nil, missingReason: nil))
        #expect(listed[1] == Worktree(
            path: fixture.listedPath("wt-det"), head: main, branch: nil, isMain: false, isBare: false, lock: nil,
            missingReason: nil))
        #expect(listed[2].branch == "refs/heads/feat")
        #expect(listed[3].branch == "refs/heads/gone")
        #expect(listed[3].missingReason == "gitdir file points to non-existent location")
        #expect(listed[3].isMissing)
        #expect(listed[4].lock == WorktreeLock(reason: nil))
        #expect(listed[5].lock == WorktreeLock(reason: "line one\nline two\ttab \"q\""))
        #expect(listed.dropFirst().allSatisfy { !$0.isMain && !$0.isBare && $0.operationBranch == nil })
        #expect(listed.allSatisfy { $0.head == main })
        // The same list from a linked worktree.
        #expect(try await fixture.backend.worktrees(at: URL(fileURLWithPath: fixture.path("wt-feat"))) == listed)
    }

    /// `-z` keeps a path whole: a space, a newline and non-ASCII letters come back exactly as git
    /// stored them (without `-z` the newline splits the record, R13).
    @Test func pathsWithASpaceANewlineAndNonASCIIAreKeptWhole() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.addOnNewBranch("wt with space", "sp")
        try await fixture.addOnNewBranch("wt\nnewline", "nl")
        try await fixture.addOnNewBranch("wt-ünï", "uni")

        let listed = try await fixture.backend.worktrees(at: fixture.repo.root)

        #expect(listed.count == 4)
        let byBranch = Dictionary(uniqueKeysWithValues: listed.map { ($0.branch ?? "", $0.path) })
        #expect(byBranch["refs/heads/sp"] == fixture.listedPath("wt with space"))
        #expect(byBranch["refs/heads/nl"] == fixture.listedPath("wt\nnewline"))
        #expect(byBranch["refs/heads/uni"] == fixture.listedPath("wt-ünï"))
        // Not vacuous: without `-z` git really does split the newline path across two lines.
        let plain = String(decoding: try await fixture.repo.git(["worktree", "list", "--porcelain"]), as: UTF8.self)
        #expect(!plain.split(separator: "\n").contains { $0 == "worktree " + fixture.listedPath("wt\nnewline") })
    }

    /// A bare main repository is listed first with no HEAD and no branch, then its worktrees.
    @Test func aBareMainIsListedWithoutAHead() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        let bare = fixture.base.appendingPathComponent("bare.git")
        try await fixture.repo.git(["clone", "-q", "--bare", fixture.repo.root.path, bare.path])
        let bareRepo = TestRepo(root: bare)
        try await bareRepo.git(["worktree", "add", "-q", fixture.path("bw"), "main"])

        let listed = try await fixture.backend.worktrees(at: URL(fileURLWithPath: fixture.path("bw")))

        #expect(listed.count == 2)
        #expect(listed[0] == Worktree(
            path: realPath(bare.path), head: nil, branch: nil, isMain: true, isBare: true, lock: nil, missingReason: nil))
        #expect(listed[1].path == fixture.listedPath("bw"))
        #expect(listed[1].branch == "refs/heads/main")
    }

    // MARK: - Branches held by an operation (R14)

    /// A rebase or a bisect in another worktree detaches its HEAD, so `list` shows no branch
    /// there — and git still refuses the branch elsewhere. `operationBranch` names it, from the
    /// worktree's state files.
    @Test(arguments: ["rebase", "bisect"])
    func aRebaseOrBisectInAnotherWorktreeNamesTheBranchItHolds(operation: String) async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.addOnNewBranch("wt-op", "op")
        let other = fixture.repo(at: "wt-op")
        try other.write("o.txt", "1\n")
        try await other.commitAll("o1")
        try other.write("o.txt", "2\n")
        try await other.commitAll("o2")
        if operation == "rebase" {
            try await other.git(["rebase", "-q", "-x", "false", "op~1"], allowedExitCodes: [1])
        } else {
            try await other.git(["bisect", "start", "op", "op~2"])
        }
        #expect(try await other.symbolicRef("HEAD") == nil, "the worktree's HEAD is detached")

        let listed = try await fixture.listed("wt-op")

        #expect(listed.branch == nil)
        #expect(listed.operationBranch == "refs/heads/op")
        // The main worktree holds nothing.
        #expect(try await fixture.backend.worktrees(at: fixture.repo.root)[0].operationBranch == nil)
        // Not vacuous: git itself counts the branch as in use there.
        let refusal = try await fixture.repo.git(["branch", "-d", "op"], allowedExitCodes: [1])
        #expect(refusal.isEmpty)
        #expect(try await fixture.repo.revParse("refs/heads/op") != "")
    }

    /// Fix round 1 (m6): one state-file reader. A `rebase --update-refs` in another worktree holds
    /// the branch it rebases and every branch it will move at the end — the same set B2's
    /// `worktreeUsing` refuses.
    @Test func aRebaseWithUpdateRefsHoldsEveryBranchItWillMove() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let c1 = try await repo.headSha()
        let low = String(decoding: try await repo.git(["commit-tree", "-p", c1, "-m", "L1", "\(c1)^{tree}"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let top = String(decoding: try await repo.git(["commit-tree", "-p", low, "-m", "T1", "\(c1)^{tree}"]), as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try await repo.git(["branch", "low", low])
        try await repo.git(["branch", "top", top])
        try repo.write("m.txt", "m\n")
        try await repo.commitAll("M1")
        try await fixture.addRaw("wt-top", ["top"])
        let other = fixture.repo(at: "wt-top")
        try await other.git(["rebase", "-q", "--update-refs", "-x", "false", "main"], allowedExitCodes: [1])
        let updateRefs = try String(
            contentsOf: repo.root.appendingPathComponent(".git/worktrees/wt-top/rebase-merge/update-refs"), encoding: .utf8)
        #expect(updateRefs.hasPrefix("refs/heads/low\n"), "\(updateRefs)")

        let listed = try await fixture.listed("wt-top")

        #expect(listed.operationBranches == ["refs/heads/top", "refs/heads/low"])
        #expect(listed.operationBranch == "refs/heads/top")
        // The same reader refuses an add for `low`.
        let error = await thrownError {
            _ = try await fixture.backend.addWorktree(path: fixture.path("new"), branch: "low", at: repo.root)
        }
        #expect(error as? AddWorktreeRefusal == .branchHeldByOperation(path: fixture.listedPath("wt-top")))
    }

    // MARK: - Changes (R15)

    /// Staged, unstaged, untracked and conflicted entries, counted from `status` run in the
    /// worktree's folder; ignored files are not changes. The user's `status.showUntrackedFiles=no`
    /// does not hide an untracked file.
    @Test func changesAreCountedInTheWorktreesOwnFolder() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.addOnNewBranch("wt", "w")
        let wt = try await fixture.listed("wt")
        #expect(try await fixture.backend.worktreeChanges(wt, at: fixture.repo.root) == .none)
        #expect(try await fixture.backend.worktreeChanges(wt, at: fixture.repo.root).isClean)

        try await fixture.repo.git(["config", "status.showUntrackedFiles", "no"])
        let other = fixture.repo(at: "wt")
        try other.write("f.txt", "changed\n")
        try other.write("g.txt", "staged\n")
        try await other.git(["add", "g.txt"])
        try other.write("new.txt", "n\n")
        try other.write("x.log", "ignored\n")
        // Main's own changes are not the worktree's.
        try fixture.repo.write("main-only.txt", "m\n")

        let changes = try await fixture.backend.worktreeChanges(wt, at: fixture.repo.root)

        #expect(changes == WorktreeChanges(staged: 1, unstaged: 1, untracked: 1, conflicted: 0))
        #expect(!changes.isClean)
    }

    @Test func aConflictIsCountedAsConflicted() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.addOnNewBranch("wt", "w")
        let other = fixture.repo(at: "wt")
        try other.write("f.txt", "w\n")
        try await other.commitAll("w")
        try fixture.repo.write("f.txt", "m\n")
        try await fixture.repo.commitAll("m")
        try await other.git(["merge", "-q", "main"], allowedExitCodes: [1])

        let changes = try await fixture.backend.worktreeChanges(try await fixture.listed("wt"), at: fixture.repo.root)

        #expect(changes.conflicted == 1)
    }

    /// A worktree whose folder is gone has no changes to read: an error, never "clean".
    @Test func aMissingWorktreesChangesAreAnError() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.addOnNewBranch("wt", "w")
        try FileManager.default.removeItem(atPath: fixture.path("wt"))
        let wt = try await fixture.listed("wt")

        let error = await thrownError { _ = try await fixture.backend.worktreeChanges(wt, at: fixture.repo.root) }

        #expect(error != nil)
    }

    // MARK: - Branch rows: `checkedOutAt` (R14)

    /// Set for a branch checked out in another worktree — a missing one included, and a path with
    /// a newline whole — and nil for this window's own branch, whichever worktree is open.
    @Test func checkedOutAtNamesAnotherWorktreeAndNeverThisOne() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.addOnNewBranch("wt-feat", "feat")
        try await fixture.addOnNewBranch("wt-gone", "gone")
        try await fixture.addOnNewBranch("wt\nnl", "nl")
        try await fixture.repo.git(["branch", "free"])
        try await fixture.addRaw("wt-det", ["--detach", "main"])
        try FileManager.default.removeItem(atPath: fixture.path("wt-gone"))

        let fromMain = try await fixture.backend.snapshot(at: fixture.repo.root).refs.localBranches
        let at = { (name: String) in fromMain.first { $0.name == name }?.checkedOutAt }
        #expect(at("feat") == fixture.listedPath("wt-feat"))
        #expect(at("gone") == fixture.listedPath("wt-gone"))
        #expect(at("nl") == fixture.listedPath("wt\nnl"))
        #expect(at("main") == nil)
        #expect(at("free") == nil)
        #expect(fromMain.map(\.name).sorted() == ["feat", "free", "gone", "main", "nl"], "a newline path splits no branch row")

        let fromFeat = try await fixture.backend.snapshot(at: URL(fileURLWithPath: fixture.path("wt-feat"))).refs.localBranches
        #expect(fromFeat.first { $0.name == "main" }?.checkedOutAt == realPath(fixture.repo.root.path))
        #expect(fromFeat.first { $0.name == "feat" }?.checkedOutAt == nil)
        #expect(fromFeat.first { $0.name == "feat" }?.isHead == true)
    }

    /// A bare main repository's HEAD branch is not a checkout — git adds a worktree for it
    /// (measured) — although `%(worktreepath)` prints the bare repository's path for it.
    @Test func aBareRepositorysHeadBranchIsNotCheckedOut() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        let bare = fixture.base.appendingPathComponent("bare.git")
        try await fixture.repo.git(["clone", "-q", "--bare", fixture.repo.root.path, bare.path])
        let bareRepo = TestRepo(root: bare)
        try await bareRepo.git(["branch", "side", "main"])
        try await bareRepo.git(["worktree", "add", "-q", fixture.path("bw"), "side"])
        let linked = URL(fileURLWithPath: fixture.path("bw"))
        // Not vacuous: git prints the bare path for `main`.
        let raw = String(decoding: try await TestRepo(root: linked).git(
            ["for-each-ref", "--format=%(refname)%00%(worktreepath)", "refs/heads/main"]), as: UTF8.self)
        #expect(raw == "refs/heads/main\u{0}\(realPath(bare.path))\n")

        let branches = try await fixture.backend.snapshot(at: linked).refs.localBranches

        #expect(branches.first { $0.name == "main" }?.checkedOutAt == nil)
    }

    // MARK: - The parser

    /// Output recorded before `%(worktreepath)` was appended still parses, with nothing checked
    /// out; a sixteenth field sets `checkedOutAt` unless the row is this worktree's HEAD; and a
    /// path holding newlines — the only field that can — is read whole, a trailing one included.
    @Test func refParserReadsTheWorktreePathAsAnOptionalLastField() {
        let id = String(repeating: "a", count: 40)
        let fifteen = "refs/heads/old\0\(id)\0 \0\0commit\0\0\0\0\0\0\0\0\0\0subject\n"
        let other = "refs/heads/feat\0\(id)\0 \0\0commit\0\0\0\0\0\0\0\0\0\0s\0/w/a\nb\n\nc\n"
        let trailing = "refs/heads/tail\0\(id)\0 \0\0commit\0\0\0\0\0\0\0\0\0\0s\0/w/t\n\n"
        let head = "refs/heads/main\0\(id)\0*\0\0commit\0\0\0\0\0\0\0\0\0\0s\0/w/main\n"
        let free = "refs/heads/free\0\(id)\0 \0\0commit\0\0\0\0\0\0\0\0\0\0s\0\n"

        let refs = RefParser.parse(Data((fifteen + other + trailing + head + free).utf8))

        let at = Dictionary(uniqueKeysWithValues: refs.localBranches.map { ($0.name, $0.checkedOutAt) })
        #expect(refs.localBranches.map(\.name) == ["feat", "free", "main", "old", "tail"])
        #expect(at["old"] == .some(nil))
        #expect(at["feat"] == "/w/a\nb\n\nc")
        #expect(at["tail"] == "/w/t\n")
        #expect(at["main"] == .some(nil))
        #expect(at["free"] == .some(nil))
    }

    /// The `-z` list parser on its own: unknown keys are skipped, a record without a `worktree`
    /// line is dropped, and the first record is the main one.
    @Test func worktreeListParserReadsRecordsAtTheirEmptyField() {
        let id = String(repeating: "b", count: 40)
        let text = "worktree /m\0HEAD \(id)\0branch refs/heads/main\0\0"
            + "worktree /w\nx\0HEAD \(id)\0detached\0locked\0future-key v\0\0"
            + "HEAD \(id)\0\0"
            + "worktree /p\0HEAD \(id)\0branch refs/heads/p\0prunable gone away\0\0"

        let listed = WorktreeListParser.parse(Data(text.utf8))

        #expect(listed == [
            Worktree(path: "/m", head: id, branch: "refs/heads/main", isMain: true, isBare: false, lock: nil, missingReason: nil),
            Worktree(path: "/w\nx", head: id, branch: nil, isMain: false, isBare: false, lock: WorktreeLock(reason: nil), missingReason: nil),
            Worktree(path: "/p", head: id, branch: "refs/heads/p", isMain: false, isBare: false, lock: nil, missingReason: "gone away"),
        ])
    }
}
