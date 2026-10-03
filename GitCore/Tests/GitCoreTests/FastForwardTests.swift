import Foundation
import Testing

@testable import GitCore

/// A clone of a local bare server with a branch `keep` that is **not checked out** (HEAD stays
/// on `main`) and tracks `origin/keep`.
///
/// - `keep` = `main` + `K1`, `K2`, `K3` (commit-tree commits: no worktree is touched), pushed,
///   with `branch.keep.remote/merge` set to `origin` / `refs/heads/keep`. `old` is its tip.
/// - With `serverMoves`, the server's `keep` gains `S` on top of `old` and the clone fetches it:
///   `new` is `origin/keep`'s tip, and `keep` is one commit behind. Without, `new == old`.
struct FastForwardFixture {
    let repo: TestRepo
    let origin: URL
    let old: String
    let new: String

    static let message = "Gitter: fast-forward keep to origin/keep"

    static func make(serverMoves: Bool = true) async throws -> FastForwardFixture {
        let repo = try await TestRepo.makeBranched()
        let origin = try await repo.addOriginWithFeatureBranch()
        var tip = try await repo.revParse("refs/heads/main")
        for subject in ["K1", "K2", "K3"] { tip = try await repo.commitTree(on: tip, subject) }
        try await repo.git(["branch", "keep", tip])
        try await repo.git(["push", "-q", "origin", "keep"])
        try await repo.git(["branch", "-q", "--set-upstream-to=refs/remotes/origin/keep", "keep"])
        let new = serverMoves ? try await repo.advanceServerBranch("keep", subject: "S") : tip
        return FastForwardFixture(repo: repo, origin: origin, old: tip, new: new)
    }

    func cleanUp() {
        repo.cleanUp()
        try? FileManager.default.removeItem(at: origin)
    }
}

extension TestRepo {
    /// A commit with `parent`'s tree and `subject`, made with `commit-tree`: no ref, no
    /// worktree, no index touched.
    func commitTree(on parent: String, _ subject: String) async throws -> String {
        let data = try await git(["commit-tree", "-p", parent, "-m", subject, "\(parent)^{tree}"])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The server's `branch` gains one commit on top of what `origin/<branch>` holds here, and
    /// this clone fetches it. Returns the new tip.
    func advanceServerBranch(_ branch: String, subject: String) async throws -> String {
        let parent = try await revParse("refs/remotes/origin/\(branch)")
        let tip = try await commitTree(on: parent, subject)
        try await git(["push", "-q", "origin", "\(tip):refs/heads/\(branch)"])
        try await git(["fetch", "-q", "origin"])
        return tip
    }

    /// The newest reflog entry's message for `ref`, or "" when it has none.
    func newestReflogMessage(_ ref: String) async throws -> String {
        let data = try await git(["reflog", "-1", "--format=%gs", ref], allowedExitCodes: [128])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// How many reflog entries `ref` has.
    func reflogCount(_ ref: String) async throws -> Int {
        let data = try await git(["reflog", "--format=%H", ref], allowedExitCodes: [128])
        return String(decoding: data, as: UTF8.self).split(separator: "\n").count
    }

    /// The names of the refs whose value differs between two `RepoState.refs` captures.
    static func changedRefNames(_ before: String, _ after: String) -> Set<String> {
        let lines: (String) -> Set<String> = { Set($0.split(separator: "\n").map(String.init)) }
        return Set(lines(before).symmetricDifference(lines(after)).compactMap {
            $0.split(separator: "\t", maxSplits: 1).last.map(String.init)
        })
    }
}

/// The same path, compared with symlinks resolved (`/var` is `/private/var` on macOS).
private func samePath(_ path: String, _ url: URL) -> Bool {
    URL(fileURLWithPath: path).resolvingSymlinksInPath().path == url.resolvingSymlinksInPath().path
}

/// `GitRemoteAdminBackend.fastForward` (B2 Task 2): a branch that is not checked out moved to its
/// upstream with a compare-and-set on the tip the sheet showed — and refused, with nothing
/// written, whenever a local commit or a worktree would lose by it.
@Suite struct FastForwardTests {
    let backend = CLIGitBackend()

    // MARK: - Moved

    /// Behind its upstream: moved to the upstream's commit, with Gitter's reflog message — and
    /// nothing else changes: not HEAD, not the index, not the worktree of the checked-out
    /// branch, not `origin/keep`, not the server.
    @Test func aBranchBehindItsUpstreamIsFastForwarded() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try repo.write("a.txt", "a local edit on main\n")  // the checked-out branch's own work
        let worktree = worktreeSnapshot(repo)
        let before = try await RepoState.capture(repo)
        let server = try await RemoteState.capture(fixture.origin)
        #expect(fixture.new != fixture.old)

        let outcome = try await backend.fastForward("keep", expecting: fixture.old, at: repo.root)

        #expect(outcome == .fastForwarded(from: fixture.old, to: fixture.new))
        #expect(try await repo.revParse("refs/heads/keep") == fixture.new)
        #expect(try await repo.newestReflogMessage("refs/heads/keep") == FastForwardFixture.message)
        let after = try await RepoState.capture(repo)
        #expect(after.head == before.head)
        #expect(after.symbolicHead == before.symbolicHead)
        #expect(after.index == before.index)
        #expect(TestRepo.changedRefNames(before.refs, after.refs) == ["refs/heads/keep"])
        assertWorktreeUnchanged(repo, since: worktree)
        try await assertRemoteUnchanged(fixture.origin, since: server)
    }

    /// Already at its upstream: nothing is written — not even a reflog entry.
    @Test func aBranchAtItsUpstreamIsUpToDate() async throws {
        let fixture = try await FastForwardFixture.make(serverMoves: false)
        defer { fixture.cleanUp() }
        let before = try await RepoState.capture(fixture.repo)
        let entries = try await fixture.repo.reflogCount("refs/heads/keep")

        let outcome = try await backend.fastForward("keep", expecting: fixture.old, at: fixture.repo.root)

        #expect(outcome == .upToDate)
        #expect(try await RepoState.capture(fixture.repo) == before)
        #expect(try await fixture.repo.reflogCount("refs/heads/keep") == entries)
    }

    // MARK: - Refused: a local commit would lose

    /// Only ahead: refused with the count, and nothing changes.
    @Test func aBranchAheadOfItsUpstreamIsRefused() async throws {
        let fixture = try await FastForwardFixture.make(serverMoves: false)
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let l1 = try await repo.commitTree(on: fixture.old, "L1")
        let l2 = try await repo.commitTree(on: l1, "L2")
        try await repo.git(["update-ref", "refs/heads/keep", l2])
        let before = try await RepoState.capture(repo)

        let error = await thrownError { _ = try await backend.fastForward("keep", expecting: l2, at: repo.root) }

        #expect(error as? FastForwardRefusal == .ahead(2))
        #expect(try await RepoState.capture(repo) == before)
    }

    /// Both sides have commits: refused with both counts — two local, one on the server — and
    /// nothing changes.
    @Test func aDivergedBranchIsRefused() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let l1 = try await repo.commitTree(on: fixture.old, "L1")
        let l2 = try await repo.commitTree(on: l1, "L2")
        try await repo.git(["update-ref", "refs/heads/keep", l2])
        let before = try await RepoState.capture(repo)

        let error = await thrownError { _ = try await backend.fastForward("keep", expecting: l2, at: repo.root) }

        #expect(error as? FastForwardRefusal == .diverged(ahead: 2, behind: 1))
        #expect(try await RepoState.capture(repo) == before)
    }

    // MARK: - Refused: a worktree uses the branch (RF5)

    /// The checked-out branch keeps today's Pull: refused, naming this worktree.
    @Test func aBranchCheckedOutHereIsRefused() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["switch", "-q", "keep"])
        let worktree = worktreeSnapshot(repo)
        let before = try await RepoState.capture(repo)

        let error = await thrownError { _ = try await backend.fastForward("keep", expecting: fixture.old, at: repo.root) }

        guard case .checkedOut(let path) = error as? FastForwardRefusal else {
            Issue.record("expected .checkedOut, got \(String(describing: error))")
            return
        }
        #expect(samePath(path, repo.root))
        try await assertRepoUnchanged(repo, since: before, worktree: worktree)
    }

    /// Checked out in another worktree: `update-ref` would move it and leave that worktree
    /// showing a staged reversal (R15). Refused, naming that worktree; it stays clean.
    @Test func aBranchCheckedOutInAnotherWorktreeIsRefused() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let other = repo.root.deletingLastPathComponent()
            .appendingPathComponent("\(repo.root.lastPathComponent)-wt", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try await repo.git(["worktree", "add", "-q", other.path, "keep"])
        let before = try await RepoState.capture(repo)

        let error = await thrownError { _ = try await backend.fastForward("keep", expecting: fixture.old, at: repo.root) }

        guard case .checkedOut(let path) = error as? FastForwardRefusal else {
            Issue.record("expected .checkedOut, got \(String(describing: error))")
            return
        }
        #expect(samePath(path, other))
        #expect(try await RepoState.capture(repo) == before)
        let status = try await TestRepo(root: other).git(["status", "--porcelain"])
        #expect(status.isEmpty, "the other worktree: \(String(decoding: status, as: UTF8.self))")
    }

    /// Being rebased or bisected in another worktree, whose HEAD is detached so
    /// `%(worktreepath)` is empty (measured): git counts the branch as in use there (`branch -f`
    /// refuses it), and moving it would break that rebase's finish. Refused, naming the worktree.
    @Test(arguments: ["rebase", "bisect"])
    func aBranchInUseByARebaseOrBisectInAnotherWorktreeIsRefused(operation: String) async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let other = repo.root.deletingLastPathComponent()
            .appendingPathComponent("\(repo.root.lastPathComponent)-wt", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try await repo.git(["worktree", "add", "-q", other.path, "keep"])
        let otherRepo = TestRepo(root: other)
        if operation == "rebase" {
            // Replays K3 and stops at the failing exec: HEAD detached, `keep` not yet rewritten.
            try await otherRepo.git(["rebase", "-q", "-x", "false", "keep~1"], allowedExitCodes: [1])
        } else {
            try await otherRepo.git(["bisect", "start", "keep", "keep~3"])
        }
        #expect(try await otherRepo.symbolicRef("HEAD") == nil, "the other worktree's HEAD is detached")
        let before = try await RepoState.capture(repo)

        let error = await thrownError { _ = try await backend.fastForward("keep", expecting: fixture.old, at: repo.root) }

        guard case .checkedOut(let path) = error as? FastForwardRefusal else {
            Issue.record("expected .checkedOut, got \(String(describing: error))")
            return
        }
        #expect(samePath(path, other))
        #expect(try await repo.revParse("refs/heads/keep") == fixture.old)
        #expect(TestRepo.changedRefNames(before.refs, try await RepoState.capture(repo).refs).isEmpty)
    }

    /// Fix round 1, I1: a stacked branch that another worktree's `rebase --update-refs` will
    /// move when it finishes is in use there (`rebase-merge/update-refs` lists it; git's
    /// `branch -f` refuses it). Moving it would make that rebase's last step fail ("is at X but
    /// expected Y") and leave the rebase stuck. Refused, naming the worktree.
    @Test func aBranchAnotherWorktreesRebaseWillUpdateIsRefused() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let top = try await repo.commitTree(on: fixture.old, "T1")
        try await repo.git(["branch", "top", top])
        let other = repo.root.deletingLastPathComponent()
            .appendingPathComponent("\(repo.root.lastPathComponent)-wt", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try await repo.git(["worktree", "add", "-q", other.path, "top"])
        let otherRepo = TestRepo(root: other)
        // Rewrites K1…K3 and T1 onto `feature`; `keep` (at K3) is listed to be moved at the end.
        try await otherRepo.git(["rebase", "-q", "--update-refs", "-x", "false", "feature"], allowedExitCodes: [1])
        let updateRefs = try String(
            contentsOf: repo.root.appendingPathComponent(".git/worktrees/\(other.lastPathComponent)/rebase-merge/update-refs"),
            encoding: .utf8)
        #expect(updateRefs.hasPrefix("refs/heads/keep\n"), "\(updateRefs)")

        let error = await thrownError { _ = try await backend.fastForward("keep", expecting: fixture.old, at: repo.root) }

        guard case .checkedOut(let path) = error as? FastForwardRefusal else {
            Issue.record("expected .checkedOut, got \(String(describing: error))")
            return
        }
        #expect(samePath(path, other))
        #expect(try await repo.revParse("refs/heads/keep") == fixture.old)
    }

    /// Fix round 1, I1: a worktree whose directory is gone (prunable) still holds its rebase in
    /// `.git/worktrees/<id>/`, and git still counts the branch as in use there. Refused.
    @Test func aBranchBeingRebasedInAWorktreeWhoseDirectoryIsGoneIsRefused() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let other = repo.root.deletingLastPathComponent()
            .appendingPathComponent("\(repo.root.lastPathComponent)-wt", isDirectory: true)
        let moved = repo.root.deletingLastPathComponent()
            .appendingPathComponent("\(repo.root.lastPathComponent)-wt-moved", isDirectory: true)
        defer {
            try? FileManager.default.removeItem(at: other)
            try? FileManager.default.removeItem(at: moved)
        }
        try await repo.git(["worktree", "add", "-q", other.path, "keep"])
        try await TestRepo(root: other).git(["rebase", "-q", "-x", "false", "keep~1"], allowedExitCodes: [1])
        try FileManager.default.moveItem(at: other, to: moved)

        let error = await thrownError { _ = try await backend.fastForward("keep", expecting: fixture.old, at: repo.root) }

        guard case .checkedOut(let path) = error as? FastForwardRefusal else {
            Issue.record("expected .checkedOut, got \(String(describing: error))")
            return
        }
        // The directory is gone, so symlinks resolve only up to its parent (`/var` → `/private/var`).
        #expect(samePath(URL(fileURLWithPath: path).deletingLastPathComponent().path, other.deletingLastPathComponent()))
        #expect(URL(fileURLWithPath: path).lastPathComponent == other.lastPathComponent, "\(path)")
        #expect(try await repo.revParse("refs/heads/keep") == fixture.old)
    }

    /// Fix round 1, M4: the worktree checks run last, just before the compare-and-set (the
    /// narrowest window, R15) — so a branch both diverged and checked out elsewhere is told as
    /// diverged, and nothing is written either way.
    @Test func theWorktreeChecksRunLastJustBeforeTheWrite() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let local = try await repo.commitTree(on: fixture.old, "L1")
        try await repo.git(["update-ref", "refs/heads/keep", local])
        let other = repo.root.deletingLastPathComponent()
            .appendingPathComponent("\(repo.root.lastPathComponent)-wt", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: other) }
        try await repo.git(["worktree", "add", "-q", other.path, "keep"])
        let before = try await RepoState.capture(repo)

        let error = await thrownError { _ = try await backend.fastForward("keep", expecting: local, at: repo.root) }

        #expect(error as? FastForwardRefusal == .diverged(ahead: 1, behind: 1))
        #expect(try await RepoState.capture(repo) == before)
    }

    // MARK: - Refused: no upstream

    /// No upstream configured, or one that is gone: refused, nothing changes.
    @Test(arguments: ["none", "gone"])
    func aBranchWithNoUpstreamIsRefused(kind: String) async throws {
        let fixture = try await FastForwardFixture.make(serverMoves: false)
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        if kind == "none" {
            try await repo.git(["branch", "-q", "--unset-upstream", "keep"])
        } else {
            try await repo.git(["update-ref", "-d", "refs/remotes/origin/keep"])
        }
        let before = try await RepoState.capture(repo)

        let error = await thrownError { _ = try await backend.fastForward("keep", expecting: fixture.old, at: repo.root) }

        #expect(error as? FastForwardRefusal == .noUpstream)
        #expect(try await RepoState.capture(repo) == before)
    }

    // MARK: - The race (RF1)

    /// The branch no longer holds the tip the sheet showed: refused up front, nothing changes.
    @Test func aBranchThatMovedBeforeTheCheckIsRefused() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let shown = try await repo.revParse("refs/heads/keep~1")  // what an older sheet showed
        let before = try await RepoState.capture(repo)

        let error = await thrownError { _ = try await backend.fastForward("keep", expecting: shown, at: repo.root) }

        #expect(error as? FastForwardRefusal == .moved)
        #expect(try await RepoState.capture(repo) == before)
    }

    /// Moved between the check and the compare-and-set (a git wrapper moves it just before
    /// `update-ref` runs): git's compare-and-set refuses, the outcome is `.moved`, and the
    /// branch holds what moved it — not the upstream.
    @Test func aBranchMovedBetweenTheCheckAndTheSetIsReportedMoved() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let racer = try await repo.commitTree(on: fixture.old, "racer")
        let git = try RacingGit(before: "update-ref", runs: "update-ref refs/heads/keep \(racer)")
        defer { git.cleanUp() }

        let error = await thrownError { _ = try await git.backend.fastForward("keep", expecting: fixture.old, at: repo.root) }

        #expect(error as? FastForwardRefusal == .moved)
        #expect(git.raced, "the wrapper never ran its racing command")
        #expect(try await repo.revParse("refs/heads/keep") == racer)
    }

    /// A `reference-transaction` hook refusing the update: git's own words, and the branch is
    /// where it was.
    @Test func aReferenceTransactionHookRefusingIsGitsWords() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try repo.writeExecutable(
            ".git/hooks/reference-transaction",
            "#!/bin/sh\ncat >/dev/null\n[ \"$1\" = preparing ] && exit 1\nexit 0\n")
        let before = try await RepoState.capture(repo)

        let error = await thrownError { _ = try await backend.fastForward("keep", expecting: fixture.old, at: repo.root) }

        guard case .commandFailed(_, let stderr)? = error as? GitError else {
            Issue.record("expected git's words, got \(String(describing: error))")
            return
        }
        #expect(stderr.contains("reference-transaction hook"), "\(stderr)")
        #expect(try await RepoState.capture(repo) == before)
    }

    /// Cancelled while the compare-and-set runs: the outcome is unknown, never "nothing
    /// changed" (Task 1's rule for a cancelled write).
    @Test func aFastForwardCancelledWhileWritingHasAnUnknownOutcome() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let git = try RacingGit(before: "update-ref", runs: nil, thenSleeps: true)
        defer { git.cleanUp() }
        let backend = git.backend
        let root = fixture.repo.root
        let old = fixture.old

        let task = Task { try await backend.fastForward("keep", expecting: old, at: root) }
        for _ in 0..<500 where !git.raced { try await Task.sleep(for: .milliseconds(10)) }
        #expect(git.raced, "update-ref never started")
        task.cancel()
        let result = await task.result

        guard case .failure(let error) = result else {
            Issue.record("expected an error, got \(result)")
            return
        }
        #expect(error as? RemoteAdminPartial
            == .fastForwardOutcomeUnknown(branch: "keep", from: fixture.old, to: fixture.new))
    }

    // MARK: - Refused before git runs

    /// An expected tip that is not a full, non-zero id would make the compare-and-set a plain
    /// move (R6); a branch name that is empty or an option. Nothing is launched.
    @Test(arguments: [
        ("keep", ""), ("keep", "0000000000000000000000000000000000000000"), ("keep", "abc123"),
        ("keep", "HEAD"), ("-x", nil), ("", nil),
    ] as [(String, String?)])
    func aBadNameOrTipIsRefusedBeforeGitRuns(branch: String, tip: String?) async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }

        let error = await thrownError {
            _ = try await git.backend.fastForward(branch, expecting: tip ?? fixture.old, at: fixture.repo.root)
        }

        if tip != nil {
            #expect(error as? RemoteAdminRefusal == .invalidObjectID)
        } else {
            #expect(error as? BranchOperationError == .invalidName(branch))
        }
        git.assertNothingRan()
    }

    /// A symbolic branch (an alias of the checked-out `main`): `update-ref` would follow it and
    /// move `main` under its worktree. Refused; neither moves.
    @Test func aSymbolicBranchIsRefused() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["symbolic-ref", "refs/heads/alias", "refs/heads/main"])
        try await repo.git(["config", "branch.alias.remote", "origin"])
        try await repo.git(["config", "branch.alias.merge", "refs/heads/keep"])
        let main = try await repo.revParse("refs/heads/main")
        let before = try await RepoState.capture(repo)

        let error = await thrownError { _ = try await backend.fastForward("alias", expecting: main, at: repo.root) }

        #expect(error as? BranchOperationError == .invalidName("alias"))
        #expect(try await RepoState.capture(repo) == before)
        #expect(try await repo.symbolicRef("refs/heads/alias") == "refs/heads/main")
    }
}

/// A shell script standing in for `/usr/bin/git` that, the first time it is launched with the
/// subcommand `before`, records that it was, runs `runs` (a real git command, in the same
/// directory) and then either runs the real git or — `thenSleeps` — sleeps instead, so that a
/// test can cancel the call while that git "runs". What a race between Gitter's check and its
/// write is staged with.
struct RacingGit {
    let directory: URL
    var wrapper: URL { directory.appendingPathComponent("git") }
    private var marker: URL { directory.appendingPathComponent("raced") }

    init(before subcommand: String, runs command: String?, thenSleeps: Bool = false) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-racing-git-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let race = command.map { "/usr/bin/git \($0) || exit 97\n" } ?? ""
        let tail = thenSleeps ? "exec /bin/sleep 30\n" : ""
        let script = "#!/bin/sh\n"
            + "if [ \"$1\" = '\(subcommand)' ] && [ ! -e '\(marker.path)' ]; then\n"
            + "  : > '\(marker.path)'\n" + race + tail + "fi\n"
            + "exec /usr/bin/git \"$@\"\n"
        try script.write(to: wrapper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    }

    /// A backend that runs git through the wrapper.
    var backend: CLIGitBackend { CLIGitBackend(gitPath: wrapper.path) }

    /// Whether the wrapper has seen `before` yet.
    var raced: Bool { FileManager.default.fileExists(atPath: marker.path) }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }
}
