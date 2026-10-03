import Foundation
import Testing

@testable import GitCore

/// A clone of a local bare server whose `gone1` and `gone2` the server has since deleted.
///
/// - `gone1` = `main` + `G1only`; `gone2` = `gone1` + `G2only` (so the two share `G1only`);
///   `keep` = `main` + `K`. All three pushed, then the local branches deleted: the commits are
///   held by `refs/remotes/origin/*` alone.
/// - `addOriginWithFeatureBranch`'s `feat/x` is on the server too.
/// - Then the server deletes `gone1` and `gone2`.
struct PruneFixture {
    let repo: TestRepo
    let origin: URL
    let gone1: String
    let gone2: String

    static let gone1Ref = "refs/remotes/origin/gone1"
    static let gone2Ref = "refs/remotes/origin/gone2"

    static func make() async throws -> PruneFixture {
        let repo = try await TestRepo.makeBranched()
        let origin = try await repo.addOriginWithFeatureBranch()
        try await repo.git(["switch", "-q", "-c", "gone1"])
        let gone1 = try await repo.commit("g1.txt", "g1", "G1only", date: "2024-01-01T00:00:00Z")
        try await repo.git(["switch", "-q", "-c", "gone2"])
        let gone2 = try await repo.commit("g2.txt", "g2", "G2only", date: "2024-01-02T00:00:00Z")
        try await repo.git(["switch", "-q", "-c", "keep", "main"])
        _ = try await repo.commit("k.txt", "k", "K", date: "2024-01-03T00:00:00Z")
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["push", "-q", "origin", "gone1", "gone2", "keep"])
        try await repo.git(["branch", "-q", "-D", "gone1", "gone2", "keep"])
        try await repo.git(["fetch", "-q", "origin"])
        try await bareGit(origin, ["branch", "-q", "-D", "gone1", "gone2"])
        return PruneFixture(repo: repo, origin: origin, gone1: gone1, gone2: gone2)
    }

    var expectedRefs: [RefTip] {
        [RefTip(ref: Self.gone1Ref, id: gone1), RefTip(ref: Self.gone2Ref, id: gone2)]
    }

    func cleanUp() {
        repo.cleanUp()
        try? FileManager.default.removeItem(at: origin)
    }
}

/// Runs `body` and returns what it threw, failing the test when it threw nothing.
func thrownError(
    sourceLocation: SourceLocation = #_sourceLocation, _ body: () async throws -> Void
) async -> Error? {
    do {
        try await body()
        Issue.record("expected an error, but nothing was thrown", sourceLocation: sourceLocation)
        return nil
    } catch {
        return error
    }
}

/// `GitRemoteAdminBackend.prunePlan`, `stranded` and `prune` (B2 Task 1): the dry-run list, the
/// union of stranded commits, and the compare-and-delete of exactly what the sheet showed.
@Suite struct PruneTests {
    let backend = CLIGitBackend()

    // MARK: - The list

    /// The list is exactly the branches the server deleted, with the ids the tracking refs hold —
    /// loose or packed — and listing changes nothing here or on the server.
    @Test(arguments: [false, true])
    func theListIsExactlyTheBranchesTheServerDeleted(packed: Bool) async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        if packed { try await fixture.repo.git(["pack-refs", "--all"]) }
        let before = try await RepoState.capture(fixture.repo)
        let server = try await RemoteState.capture(fixture.origin)

        let plan = try await backend.prunePlan("origin", at: fixture.repo.root)

        #expect(plan.remote == "origin")
        #expect(plan.refs == fixture.expectedRefs)
        #expect(try await RepoState.capture(fixture.repo) == before)
        try await assertRemoteUnchanged(fixture.origin, since: server)
    }

    /// Nothing to prune: an empty list, and nothing stranded.
    @Test func aRemoteWithNothingStaleListsNothing() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let plan = try await backend.prunePlan("origin", at: repo.root)

        #expect(plan == PrunePlan(remote: "origin", refs: [], stranded: .none))
    }

    /// RF3: `fetch.pruneTags` / `remote.<r>.pruneTags` make a pruning fetch list — and delete —
    /// local tags that were never on the server (R8). `v1` is such a tag here. The list holds
    /// remote-tracking refs only, and a prune leaves every tag where it was.
    @Test(arguments: ["fetch.pruneTags", "remote.origin.pruneTags"])
    func pruneTagsConfigNeitherListsNorDeletesATag(key: String) async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["config", key, "true"])
        let v1 = try await fixture.repo.revParse("refs/tags/v1")

        let plan = try await backend.prunePlan("origin", at: fixture.repo.root)
        #expect(plan.refs == fixture.expectedRefs)
        _ = try await backend.prune(plan, keeping: [:], at: fixture.repo.root)

        #expect(try await fixture.repo.gitRefExists("refs/tags/v1"))
        #expect(try await fixture.repo.revParse("refs/tags/v1") == v1)
    }

    /// A custom refspec: only refs under its destination are considered (R3).
    @Test func aCustomRefspecListsItsOwnDestination() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "--replace-all", "remote.origin.fetch", "+refs/heads/*:refs/remotes/origin/x/*"])
        // `keep` is the branch the server deletes now; `x/keep` is the one ref the custom refspec
        // maps that the server no longer has. The default-mapped `origin/gone1`/`gone2` are
        // outside this refspec's destination and are not listed (R3).
        try await repo.git(["fetch", "-q", "origin"])
        try await bareGit(fixture.origin, ["branch", "-q", "-D", "keep"])
        let keep = try await repo.revParse("refs/remotes/origin/x/keep")

        let plan = try await backend.prunePlan("origin", at: repo.root)

        #expect(plan.refs == [RefTip(ref: "refs/remotes/origin/x/keep", id: keep)])
    }

    /// A mirror remote's refspec writes local branches (`+refs/*:refs/*`): its dry run lists
    /// `refs/heads/…` as prunable (R3). Refused before the dry run, and nothing changes.
    @Test func aMirrorRemoteIsRefused() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["remote", "add", "--mirror=fetch", "m", fixture.origin.path])
        let before = try await RepoState.capture(fixture.repo)

        let error = await thrownError { _ = try await backend.prunePlan("m", at: fixture.repo.root) }

        #expect(error as? RemoteAdminRefusal == .unsafeRefspec("+refs/*:refs/*"))
        #expect(try await RepoState.capture(fixture.repo) == before)
    }

    /// A remote that is not configured is refused by name; a name that is an option is refused
    /// before git runs.
    @Test func anUnknownRemoteIsRefused() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }

        let unknown = await thrownError { _ = try await backend.prunePlan("nosuch", at: fixture.repo.root) }
        #expect(unknown as? RemoteAdminRefusal == .noSuchRemote("nosuch"))

        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        let option = await thrownError { _ = try await git.backend.prunePlan("-x", at: fixture.repo.root) }
        #expect(option as? RemoteOperationError == .noRemote)
        git.assertNothingRan()
    }

    // MARK: - Stranded commits

    /// RF2: the two refs share `G1only`; deleting both strands two commits. Counted as one
    /// union — per ref it would be 0 (`gone2` holds `G1only`) plus 1 (R5).
    @Test func strandedCommitsAreOneUnion() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }

        let plan = try await backend.prunePlan("origin", at: fixture.repo.root)

        #expect(plan.stranded.count == 2)
        #expect(plan.stranded.commits == [
            CommitRef(sha: fixture.gone2, subject: "G2only"),
            CommitRef(sha: fixture.gone1, subject: "G1only"),
        ])
        #expect(plan.stranded.holders == [PruneFixture.gone1Ref, PruneFixture.gone2Ref])
        // The per-ref answer that the union replaces: `gone2` still holds `G1only`.
        let gone1Alone = try await backend.stranded(by: [PruneFixture.gone1Ref], at: fixture.repo.root)
        #expect(gone1Alone == .none)
    }

    /// A commit is not stranded while anything else holds it: a tag, a local branch, the stash,
    /// another worktree's HEAD, or this worktree's detached HEAD. Each holder sits on `gone2`'s
    /// tip, which reaches both commits.
    @Test(arguments: ["tag", "branch", "stash", "worktree", "detached"])
    func aCommitHeldElsewhereIsNotStranded(holder: String) async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let worktree = repo.root.deletingLastPathComponent()
            .appendingPathComponent("\(repo.root.lastPathComponent)-wt", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: worktree) }
        switch holder {
        case "tag": try await repo.git(["tag", "holder", fixture.gone2])
        case "branch": try await repo.git(["branch", "holder", fixture.gone2])
        case "stash":
            try await repo.git(["switch", "-q", "--detach", fixture.gone2])
            try repo.write("g2.txt", "changed\n")
            try await repo.git(["stash", "-q"])
            try await repo.git(["switch", "-q", "main"])
        case "worktree": try await repo.git(["worktree", "add", "-q", "--detach", worktree.path, fixture.gone2])
        default: try await repo.git(["switch", "-q", "--detach", fixture.gone2])
        }

        let stranded = try await backend.stranded(
            by: [PruneFixture.gone1Ref, PruneFixture.gone2Ref], at: repo.root)

        #expect(stranded == .none)
    }

    /// A symbolic `refs/remotes/origin/HEAD` pointing at a pruned ref holds nothing of its own:
    /// excluded, or the count would be 0 (R5).
    @Test func aSymrefToAPrunedRefDoesNotHoldItsCommits() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["symbolic-ref", "refs/remotes/origin/HEAD", PruneFixture.gone2Ref])

        let stranded = try await backend.stranded(
            by: [PruneFixture.gone1Ref, PruneFixture.gone2Ref], at: fixture.repo.root)

        #expect(stranded.count == 2)
    }

    /// The listing is capped; the count is not.
    @Test func theListingIsCappedAndTheCountExact() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["switch", "-q", "-c", "many", fixture.gone2])
        for n in 1...22 { _ = try await repo.commit("m.txt", "\(n)", "M\(n)") }
        try await repo.git(["update-ref", "refs/remotes/origin/many", "HEAD"])
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(["branch", "-q", "-D", "many"])

        let stranded = try await backend.stranded(by: ["refs/remotes/origin/many"], at: repo.root)

        // `gone2`'s own two commits are still held by `origin/gone1` and `origin/gone2`.
        #expect(stranded.count == 22)
        #expect(stranded.commits.count == StrandedCommits.displayLimit)
        #expect(stranded.commits.first?.subject == "M22")
    }

    /// A name that is not a full `refs/remotes/` ref, or that carries revision syntax, is refused
    /// before git runs: it would ask `rev-list` a different question (`a..b` is a range).
    @Test(arguments: ["origin/gone1", "refs/heads/main", "refs/remotes/origin/a..b", "refs/remotes/origin/*", "refs/remotes/", "-x"])
    func strandedRefusesANameThatIsNotARemoteTrackingRef(ref: String) async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }

        let error = await thrownError { _ = try await git.backend.stranded(by: [ref], at: fixture.repo.root) }

        #expect(error as? BranchOperationError == .invalidName(ref))
        git.assertNothingRan()
    }

    // MARK: - The prune

    /// Exactly the listed refs are deleted, each at its listed id; every other ref, here and on
    /// the server, stays. Loose and packed.
    @Test(arguments: [false, true])
    func pruneDeletesExactlyTheListedRefs(packed: Bool) async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        if packed { try await fixture.repo.git(["pack-refs", "--all"]) }
        let plan = try await backend.prunePlan("origin", at: fixture.repo.root)
        let before = try await RepoState.capture(fixture.repo)
        let server = try await RemoteState.capture(fixture.origin)

        let result = try await backend.prune(plan, keeping: [:], at: fixture.repo.root)

        #expect(result == PruneResult(deleted: fixture.expectedRefs, skippedMoved: [], keptBranches: []))
        let lines = { (refs: String) in refs.split(separator: "\n").map(String.init) }
        let expected = lines(before.refs).filter {
            !$0.hasSuffix("\t" + PruneFixture.gone1Ref) && !$0.hasSuffix("\t" + PruneFixture.gone2Ref)
        }
        #expect(expected.count == lines(before.refs).count - 2)
        #expect(lines(try await RepoState.capture(fixture.repo).refs) == expected)
        try await assertRemoteUnchanged(fixture.origin, since: server)
    }

    /// RF1: the server deletes another branch after the list — it is not pruned (a plain
    /// `fetch --prune` deleted it, R6).
    @Test func aBranchTheServerDeletesAfterTheListIsNotPruned() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let plan = try await backend.prunePlan("origin", at: fixture.repo.root)
        try await bareGit(fixture.origin, ["branch", "-q", "-D", "keep"])
        let keep = try await fixture.repo.revParse("refs/remotes/origin/keep")

        let result = try await backend.prune(plan, keeping: [:], at: fixture.repo.root)

        #expect(result.deleted == fixture.expectedRefs)
        #expect(try await fixture.repo.revParse("refs/remotes/origin/keep") == keep)
    }

    /// RF1: a tracking ref moved — or was deleted — after the list: skipped and named, left as
    /// it is now; the other is still deleted.
    @Test(arguments: [false, true])
    func aRefThatMovedAfterTheListIsSkippedAndNamed(deleted: Bool) async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let plan = try await backend.prunePlan("origin", at: repo.root)
        let main = try await repo.revParse("main")
        if deleted {
            try await repo.git(["update-ref", "-d", PruneFixture.gone2Ref])
        } else {
            try await repo.git(["update-ref", PruneFixture.gone2Ref, main])
        }

        let result = try await backend.prune(plan, keeping: [:], at: repo.root)

        #expect(result.deleted == [RefTip(ref: PruneFixture.gone1Ref, id: fixture.gone1)])
        #expect(result.skippedMoved == [RefTip(ref: PruneFixture.gone2Ref, id: fixture.gone2)])
        #expect(result.failed.isEmpty)
        #expect(try await repo.gitRefExists(PruneFixture.gone2Ref) == !deleted)
        if !deleted { #expect(try await repo.revParse(PruneFixture.gone2Ref) == main) }
    }

    /// A delete git refuses for a reason of its own (a held lock) is `failed`, with git's
    /// words; the refs after it are still tried, and the ref stays at the listed id.
    @Test func aDeleteGitRefusesIsFailedWithItsWordsAndTheRestAreTried() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let plan = try await backend.prunePlan("origin", at: repo.root)
        let lock = repo.root.appendingPathComponent(".git/\(PruneFixture.gone1Ref).lock")
        try Data().write(to: lock)
        defer { try? FileManager.default.removeItem(at: lock) }

        let result = try await backend.prune(plan, keeping: [:], at: repo.root)

        #expect(result.deleted == [RefTip(ref: PruneFixture.gone2Ref, id: fixture.gone2)])
        #expect(result.failed.map(\.tip) == [RefTip(ref: PruneFixture.gone1Ref, id: fixture.gone1)])
        #expect(result.failed.first?.gitsWords.contains("cannot lock ref") == true, "\(result.failed)")
        #expect(try await repo.revParse(PruneFixture.gone1Ref) == fixture.gone1)
    }

    /// RF2: a kept branch is created at the id the sheet showed, with no upstream, **before**
    /// anything is deleted — the reference-transaction hook sees the order.
    @Test func aKeptBranchIsCreatedBeforeAnyDelete() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "branch.autoSetupMerge", "always"])
        let log = repo.root.appendingPathComponent("transactions.log")
        try repo.writeExecutable(".git/hooks/reference-transaction", """
            #!/bin/sh
            [ "$1" = committed ] || exit 0
            while read old new ref; do echo "$ref" >> '\(log.path)'; done
            """)
        let plan = try await backend.prunePlan("origin", at: repo.root)
        try? FileManager.default.removeItem(at: log)

        let result = try await backend.prune(plan, keeping: [PruneFixture.gone2Ref: "rescued"], at: repo.root)

        #expect(result.keptBranches == ["rescued"])
        #expect(result.deleted == fixture.expectedRefs)
        #expect(try await repo.revParse("refs/heads/rescued") == fixture.gone2)
        #expect(try await repo.configValue("branch.rescued.remote") == "")
        #expect(try await repo.configValue("branch.rescued.merge") == "")
        let order = try String(contentsOf: log, encoding: .utf8).split(separator: "\n").map(String.init)
        #expect(order.first == "refs/heads/rescued", "\(order)")
        #expect(Set(order.dropFirst()) == [PruneFixture.gone1Ref, PruneFixture.gone2Ref], "\(order)")
    }

    /// Ruling 1: a name that is taken — a branch, a tag, a remote, a remote-tracking branch,
    /// ignoring case — is `.branchExists`, and nothing is created or deleted.
    @Test(arguments: ["main", "MAIN", "v1", "origin", "origin/keep", "feature"])
    func aTakenKeepNameIsRefusedWithNothingDeleted(name: String) async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let plan = try await backend.prunePlan("origin", at: fixture.repo.root)
        let before = try await RepoState.capture(fixture.repo)

        let error = await thrownError {
            _ = try await backend.prune(plan, keeping: [PruneFixture.gone2Ref: name], at: fixture.repo.root)
        }

        #expect(error as? RemoteAdminRefusal == .branchExists(name))
        #expect(try await RepoState.capture(fixture.repo) == before)
        #expect(try await backend.keepBranchNameProblem(name, at: fixture.repo.root) == .branchExists(name))
    }

    /// Two refs kept under one name: refused, nothing created or deleted.
    @Test func twoRefsKeptUnderOneNameAreRefused() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let plan = try await backend.prunePlan("origin", at: fixture.repo.root)
        let before = try await RepoState.capture(fixture.repo)

        let error = await thrownError {
            _ = try await backend.prune(
                plan, keeping: [PruneFixture.gone1Ref: "same", PruneFixture.gone2Ref: "Same"], at: fixture.repo.root)
        }

        #expect(error as? RemoteAdminRefusal == .branchExists("Same") || error as? RemoteAdminRefusal == .branchExists("same"))
        #expect(try await RepoState.capture(fixture.repo) == before)
    }

    /// Ruling 1: a name New Branch refuses, or a root-ref name, is `.invalidBranchName`.
    @Test(arguments: ["a..b", "HEAD", "MERGE_HEAD", "-x", "refs/heads/x", "heads/x", "@", "x@{1}", "", "trail/"])
    func anInvalidKeepNameIsRefusedWithNothingDeleted(name: String) async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let plan = try await backend.prunePlan("origin", at: fixture.repo.root)
        let before = try await RepoState.capture(fixture.repo)

        let error = await thrownError {
            _ = try await backend.prune(plan, keeping: [PruneFixture.gone2Ref: name], at: fixture.repo.root)
        }

        #expect(error as? RemoteAdminRefusal == .invalidBranchName(name))
        #expect(try await RepoState.capture(fixture.repo) == before)
        #expect(try await backend.keepBranchNameProblem(name, at: fixture.repo.root) == .invalidBranchName(name))
    }

    /// A free name passes the live check.
    @Test func aFreeKeepNamePasses() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        #expect(try await backend.keepBranchNameProblem("gone2", at: fixture.repo.root) == nil)
        #expect(try await backend.keepBranchNameProblem("gone2-kept", at: fixture.repo.root) == nil)
    }

    /// An empty, all-zero, short or upper-case id — or a ref that is not under `refs/remotes/` —
    /// is refused before any git process runs (an empty old value deletes unconditionally, R6).
    @Test(arguments: [
        "", "0000000000000000000000000000000000000000", "abc1234",
        "ABCDEF0123456789ABCDEF0123456789ABCDEF01",
    ])
    func anIdThatIsNotFullIsRefusedBeforeGitRuns(id: String) async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        let plan = PrunePlan(
            remote: "origin",
            refs: [RefTip(ref: PruneFixture.gone1Ref, id: fixture.gone1), RefTip(ref: PruneFixture.gone2Ref, id: id)],
            stranded: .none)

        let error = await thrownError { _ = try await git.backend.prune(plan, keeping: [:], at: fixture.repo.root) }

        #expect(error as? RemoteAdminRefusal == .invalidObjectID)
        git.assertNothingRan()
        #expect(try await fixture.repo.gitRefExists(PruneFixture.gone1Ref))
    }

    @Test(arguments: ["refs/heads/main", "refs/tags/v1", "origin/gone1", "refs/remotes/origin/a..b"])
    func aRefOutsideRefsRemotesIsRefusedBeforeGitRuns(ref: String) async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        let plan = PrunePlan(remote: "origin", refs: [RefTip(ref: ref, id: fixture.gone1)], stranded: .none)

        let error = await thrownError { _ = try await git.backend.prune(plan, keeping: [:], at: fixture.repo.root) }

        #expect(error as? BranchOperationError == .invalidName(ref))
        git.assertNothingRan()
    }

    /// RF1/RF2: a holder the sheet counted on is gone, so deleting the refs would now strand more
    /// than the sheet said — refused, and nothing is created or deleted.
    @Test func strandedGrewIsRefusedWithNothingChanged() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["branch", "holder", fixture.gone2])
        let plan = try await backend.prunePlan("origin", at: repo.root)
        #expect(plan.stranded == .none)
        try await repo.git(["branch", "-q", "-D", "holder"])
        let before = try await RepoState.capture(repo)

        let error = await thrownError {
            _ = try await backend.prune(plan, keeping: [PruneFixture.gone2Ref: "rescued"], at: repo.root)
        }

        #expect(error as? RemoteAdminRefusal == .strandedGrew)
        #expect(try await RepoState.capture(repo) == before)
    }
}
