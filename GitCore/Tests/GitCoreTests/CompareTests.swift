import Foundation
import Testing

@testable import GitCore

/// `GitCompareBackend` (B3 Task 1): two branches read to ids once, then the counts, both commit
/// lists, the merge bases and the merge-base diff from those ids only — against real git in
/// scratch repositories, with git's own answers as the ground truth (R1–R12).
@Suite struct CompareTests {
    private let backend = CLIGitBackend()

    // MARK: - Divergent branches (R1, R2, R3, R5)

    @Test func divergentBranchesHaveExactCountsAndListsNewestFirstWithTheMergeOnItsOwnSide() async throws {
        let fixture = try await CompareFixture.divergent()
        defer { fixture.repo.cleanUp() }
        let repo = fixture.repo

        let c = try await backend.compare("refs/heads/A", "refs/heads/B", at: repo.root)

        #expect(c.a == RefTip(ref: "refs/heads/A", id: fixture.a2))
        #expect(c.b == RefTip(ref: "refs/heads/B", id: fixture.merge))
        #expect(c.onlyA == 2)
        #expect(c.onlyB == 4)
        #expect(c.commitsOnlyA.map(\.sha) == [fixture.a2, fixture.a1])
        // Newest first as git orders it: the tip, then the rest as `rev-list` walks them.
        let walked = try await repo.lines(["rev-list", fixture.merge, "^" + fixture.a2])
        #expect(c.commitsOnlyB.map(\.sha) == walked)
        #expect(c.commitsOnlyB.first?.sha == fixture.merge)
        #expect(Set(c.commitsOnlyB.map(\.sha)) == [fixture.b1, fixture.s1, fixture.b2, fixture.merge])
        #expect(c.commitsOnlyB.first?.isMerge == true)
        #expect(c.commitsOnlyA.allSatisfy { !$0.isMerge })
        #expect(c.mergeBases == [fixture.root])

        // The other way round is the mirror image.
        let back = try await backend.compare("refs/heads/B", "refs/heads/A", at: repo.root)
        #expect((back.onlyA, back.onlyB) == (4, 2))
        #expect(back.commitsOnlyA == c.commitsOnlyB)
        #expect(back.commitsOnlyB == c.commitsOnlyA)
    }

    /// What B brings: `diff-tree` from the merge base to B's id, which is `git diff A...B` with
    /// the working-copy pins, parsed — names, kinds and the rename included.
    @Test func theChangesAreTheMergeBaseDiffOfB() async throws {
        let fixture = try await CompareFixture.divergent()
        defer { fixture.repo.cleanUp() }
        let repo = fixture.repo

        let c = try await backend.compare("refs/heads/A", "refs/heads/B", at: repo.root)
        let files = try await backend.comparisonFiles(c, at: repo.root)
        let diff = try await backend.comparisonDiff(c, path: nil, at: repo.root)

        #expect(files.map(\.path) == ["b.txt", "f.txt", "renamed.txt", "s.txt"])
        #expect(files.map(\.staged) == [.added, .modified, .renamed, .added])
        #expect(files.first { $0.path == "renamed.txt" }?.originalPath == "r.txt")
        let gitsFiles = try await repo.git(["diff", "--name-status", "-z", "-M", "refs/heads/A...refs/heads/B"])
        let gitsDiff = try await repo.pinnedDiff("refs/heads/A...refs/heads/B")
        #expect(files == backend.parseNameStatus(gitsFiles))
        #expect(diff == DiffParser.parse(gitsDiff))
        #expect(!diff.isEmpty)

        // One path: that file's diff alone.
        let one = try await backend.comparisonDiff(c, path: "f.txt", at: repo.root)
        #expect(one.map(\.displayPath) == ["f.txt"])
        #expect(one == diff.filter { $0.displayPath == "f.txt" })
    }

    /// R5: the user's diff configuration cannot reshape the changes. `diff.noprefix`,
    /// `diff.context` and an external diff in the repository, and still the pinned
    /// `git diff A...B` — byte for byte from the helper, and parsed from the backend.
    @Test func theChangesDiffIsImmuneToTheUsersDiffConfig() async throws {
        let fixture = try await CompareFixture.divergent()
        defer { fixture.repo.cleanUp() }
        let repo = fixture.repo
        try await repo.git(["config", "diff.noprefix", "true"])
        try await repo.git(["config", "diff.context", "10"])
        try await repo.git(["config", "diff.external", "/usr/bin/false"])
        try await repo.git(["config", "color.ui", "always"])
        // Not vacuous: porcelain `diff` without the pins really is reshaped here.
        let unpinned = await thrownError {
            _ = try await repo.git(["diff", "refs/heads/A...refs/heads/B"])
        }
        #expect(unpinned != nil, "the external diff did not run, so this repository proves nothing")

        let c = try await backend.compare("refs/heads/A", "refs/heads/B", at: repo.root)
        let expected = try await repo.pinnedDiff("refs/heads/A...refs/heads/B")

        let raw = try await backend.diffTree(
            at: repo.root, arguments: CLIGitBackend.comparisonPatchArguments, from: c.mergeBases[0], to: c.b.id)
        #expect(raw == expected)
        #expect(try await backend.comparisonDiff(c, path: nil, at: repo.root) == DiffParser.parse(expected))
        #expect(try await backend.comparisonFiles(c, at: repo.root).map(\.path) == ["b.txt", "f.txt", "renamed.txt", "s.txt"])
    }

    // MARK: - Ancestor, equal tips, a revert pair (R9)

    @Test func anAncestorHasOneZeroCountAndBringsNothingTheOtherWay() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let main = try await repo.commitFile("f.txt", "one\n", "root")
        try await repo.git(["switch", "-q", "-c", "B"])
        _ = try await repo.commitFile("f.txt", "two\n", "b1")
        let b2 = try await repo.commitFile("g.txt", "g\n", "b2")

        let forward = try await backend.compare("refs/heads/main", "refs/heads/B", at: repo.root)
        #expect((forward.onlyA, forward.onlyB) == (0, 2))
        #expect(forward.commitsOnlyA.isEmpty)
        #expect(forward.commitsOnlyB.first?.sha == b2)
        #expect(forward.mergeBases == [main])
        #expect(try await backend.comparisonFiles(forward, at: repo.root).map(\.path) == ["f.txt", "g.txt"])

        let back = try await backend.compare("refs/heads/B", "refs/heads/main", at: repo.root)
        #expect((back.onlyA, back.onlyB) == (2, 0))
        #expect(back.commitsOnlyB.isEmpty)
        #expect(back.mergeBases == [main])
        #expect(try await backend.comparisonFiles(back, at: repo.root).isEmpty)
        #expect(try await backend.comparisonDiff(back, path: nil, at: repo.root).isEmpty)
    }

    @Test func equalTipsAreZeroZeroWithAnEmptyDiff() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let main = try await repo.commitFile("f.txt", "one\n", "root")
        try await repo.git(["branch", "same"])

        let c = try await backend.compare("refs/heads/main", "refs/heads/same", at: repo.root)

        #expect((c.onlyA, c.onlyB) == (0, 0))
        #expect(c.a.id == main && c.b.id == main)
        #expect(c.commitsOnlyA.isEmpty && c.commitsOnlyB.isEmpty)
        #expect(c.mergeBases == [main])
        #expect(try await backend.comparisonFiles(c, at: repo.root).isEmpty)
        #expect(try await backend.comparisonDiff(c, path: nil, at: repo.root).isEmpty)
    }

    /// A non-zero count with an empty diff: the two answers are independent (R9).
    @Test func aRevertPairCountsTwoAndBringsNothing() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        _ = try await repo.commitFile("f.txt", "one\n", "root")
        try await repo.git(["switch", "-q", "-c", "E"])
        let x = try await repo.commitFile("f.txt", "two\n", "x")
        try await repo.git(["revert", "--no-edit", x])

        let c = try await backend.compare("refs/heads/main", "refs/heads/E", at: repo.root)

        #expect((c.onlyA, c.onlyB) == (0, 2))
        #expect(c.commitsOnlyB.count == 2)
        #expect(try await backend.comparisonFiles(c, at: repo.root).isEmpty)
        #expect(try await backend.comparisonDiff(c, path: nil, at: repo.root).isEmpty)
    }

    // MARK: - Unrelated histories (R7)

    @Test func unrelatedHistoriesHaveNoMergeBaseAndRefuseTheChangesBeforeGitRuns() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let c1 = try await repo.commitFile("c.txt", "1\n", "c1")
        let c2 = try await repo.commitFile("c.txt", "2\n", "c2")
        try await repo.git(["switch", "-q", "--orphan", "U"])
        let u1 = try await repo.commitFile("u.txt", "u\n", "u1")

        let c = try await backend.compare("refs/heads/main", "refs/heads/U", at: repo.root)

        #expect(c.mergeBases == [])
        #expect((c.onlyA, c.onlyB) == (2, 1))
        #expect(c.commitsOnlyA.map(\.sha) == [c2, c1])
        #expect(c.commitsOnlyB.map(\.sha) == [u1])

        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        let files = await thrownError { _ = try await git.backend.comparisonFiles(c, at: repo.root) }
        let diff = await thrownError { _ = try await git.backend.comparisonDiff(c, path: nil, at: repo.root) }
        let one = await thrownError { _ = try await git.backend.comparisonDiff(c, path: "u.txt", at: repo.root) }
        #expect(files as? CompareRefusal == .noMergeBase)
        #expect(diff as? CompareRefusal == .noMergeBase)
        #expect(one as? CompareRefusal == .noMergeBase)
        #expect(!git.launches.contains("diff-tree"))
        git.assertNothingRan()
    }

    /// The negative control for the launch log above: a comparison that has a merge base does
    /// launch `diff-tree` through the same wrapper, so "nothing ran" can fail.
    @Test func aComparisonWithAMergeBaseDoesLaunchDiffTree() async throws {
        let fixture = try await CompareFixture.divergent()
        defer { fixture.repo.cleanUp() }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }

        let c = try await git.backend.compare("refs/heads/A", "refs/heads/B", at: fixture.repo.root)
        _ = try await git.backend.comparisonFiles(c, at: fixture.repo.root)

        #expect(git.launches.contains("diff-tree"))
        #expect(Array(git.launches.prefix(2)) == ["rev-parse", "rev-parse"], "each tip resolved once, first")
        #expect(git.launches.filter { $0 == "rev-parse" }.count == 2)
        withKnownIssue("git really ran") { git.assertNothingRan() }
    }

    // MARK: - Criss-cross (R8, R5)

    @Test func crissCrossHasTwoMergeBasesAndTheDiffIsGitsOwnThreeDotDiff() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        _ = try await repo.commitFile("f.txt", "base\n", "root")
        try await repo.git(["switch", "-q", "-c", "X"])
        let x1 = try await repo.commitFile("x.txt", "x1\n", "x1")
        try await repo.git(["switch", "-q", "-c", "Y", "main"])
        let y1 = try await repo.commitFile("y.txt", "y1\n", "y1")
        try await repo.git(["switch", "-q", "X"])
        try await repo.git(["merge", "-q", "--no-ff", "-m", "X takes y1", y1])
        try await repo.git(["switch", "-q", "Y"])
        try await repo.git(["merge", "-q", "--no-ff", "-m", "Y takes x1", x1])
        _ = try await repo.commitFile("y2.txt", "y2\n", "y2")
        try await repo.git(["switch", "-q", "X"])
        _ = try await repo.commitFile("x2.txt", "x2\n", "x2")

        let c = try await backend.compare("refs/heads/X", "refs/heads/Y", at: repo.root)

        #expect(c.mergeBases.count == 2)
        #expect(Set(c.mergeBases) == [x1, y1])
        // The first is the one plain `merge-base` and `git diff X...Y` use.
        let plain = try await repo.lines(["merge-base", "refs/heads/X", "refs/heads/Y"])
        #expect(c.mergeBases.first == plain.first)
        #expect((c.onlyA, c.onlyB) == (2, 2))

        let expected = try await repo.pinnedDiff("refs/heads/X...refs/heads/Y")
        let raw = try await backend.diffTree(
            at: repo.root, arguments: CLIGitBackend.comparisonPatchArguments, from: c.mergeBases[0], to: c.b.id)
        #expect(raw == expected)
        #expect(try await backend.comparisonDiff(c, path: nil, at: repo.root) == DiffParser.parse(expected))
        let gitsFiles = try await repo.git(["diff", "--name-status", "-z", "-M", "refs/heads/X...refs/heads/Y"])
        #expect(try await backend.comparisonFiles(c, at: repo.root) == backend.parseNameStatus(gitsFiles))
    }

    // MARK: - Names (R10, R11)

    /// A tag and a branch both called `v1`: the short name is the tag; the full branch ref is
    /// the branch.
    @Test func aFullBranchRefIsTheBranchEvenWhenATagHasItsName() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let root = try await repo.commitFile("f.txt", "one\n", "root")
        try await repo.git(["tag", "-a", "-m", "tag", "v1", root])
        try await repo.git(["switch", "-q", "-c", "v1"])
        let branch = try await repo.commitFile("f.txt", "two\n", "on the branch")
        try await repo.git(["switch", "-q", "main"])
        // Not vacuous: the short name really is the tag here.
        #expect(try await repo.revParse("v1^{commit}") == root)

        let c = try await backend.compare("refs/heads/v1", "refs/heads/main", at: repo.root)

        #expect(c.a == RefTip(ref: "refs/heads/v1", id: branch))
        #expect((c.onlyA, c.onlyB) == (1, 0))
    }

    /// A branch named `heads/x` is `refs/heads/heads/x`, which a short `heads/x` would not find
    /// (it means `refs/heads/x`).
    @Test func aBranchNamedHeadsSlashXIsItself() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let root = try await repo.commitFile("f.txt", "one\n", "root")
        try await repo.git(["branch", "x", root])
        let nested = try await repo.commitFile("f.txt", "two\n", "second")
        try await repo.git(["update-ref", "refs/heads/heads/x", nested])
        try await repo.git(["reset", "-q", "--hard", root])
        #expect(try await repo.revParse("heads/x") == root, "not vacuous: the short name is the other branch")

        let c = try await backend.compare("refs/heads/heads/x", "refs/heads/main", at: repo.root)

        #expect(c.a == RefTip(ref: "refs/heads/heads/x", id: nested))
        #expect((c.onlyA, c.onlyB) == (1, 0))
    }

    /// A branch named like a tracked file: the ids go to `rev-list` before its `--`, so git
    /// never has to guess whether `f.txt` is a revision or a path.
    @Test func aBranchNamedLikeATrackedFileCompares() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        _ = try await repo.commitFile("f.txt", "one\n", "root")
        try await repo.git(["switch", "-q", "-c", "f.txt"])
        let tip = try await repo.commitFile("f.txt", "two\n", "on f.txt")
        try await repo.git(["switch", "-q", "main"])

        let c = try await backend.compare("refs/heads/main", "refs/heads/f.txt", at: repo.root)

        #expect(c.b == RefTip(ref: "refs/heads/f.txt", id: tip))
        #expect((c.onlyA, c.onlyB) == (0, 1))
        #expect(try await backend.comparisonFiles(c, at: repo.root).map(\.path) == ["f.txt"])
    }

    /// A remote-tracking branch is a branch too.
    @Test func aRemoteTrackingBranchCompares() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let root = try await repo.commitFile("f.txt", "one\n", "root")
        try await repo.git(["update-ref", "refs/remotes/origin/main", root])
        let tip = try await repo.commitFile("f.txt", "two\n", "local")

        let c = try await backend.compare("refs/remotes/origin/main", "refs/heads/main", at: repo.root)

        #expect(c.a == RefTip(ref: "refs/remotes/origin/main", id: root))
        #expect(c.b.id == tip)
        #expect((c.onlyA, c.onlyB) == (0, 1))
    }

    /// Anything but a full `refs/heads/` or `refs/remotes/` name — a short name, a tag, `HEAD`,
    /// revision syntax — is refused as `.notABranch`, on either side, before git runs.
    @Test(arguments: [
        "main", "HEAD", "refs/tags/v1", "heads/main", "refs/heads/", "refs/remotes/", "refs/headsx/main",
        "refs/notes/x", "refs/heads/main~1", "refs/heads/main^", "refs/heads/main^{tree}", "refs/heads/a..b",
        "refs/heads/main@{1}", "refs/heads/main:f.txt", "-x", "", " refs/heads/main", "refs/heads/main\n",
        "refs/remotes/origin/main~2", "@{-1}",
    ])
    func aNameThatIsNotAFullBranchRefIsRefusedBeforeGitRuns(name: String) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        _ = try await repo.commitFile("f.txt", "one\n", "root")
        try await repo.git(["tag", "v1"])
        let git = try GitLaunchLog()
        defer { git.cleanUp() }

        let first = await thrownError { _ = try await git.backend.compare(name, "refs/heads/main", at: repo.root) }
        let second = await thrownError { _ = try await git.backend.compare("refs/heads/main", name, at: repo.root) }

        #expect(first as? CompareRefusal == .notABranch(name))
        #expect(second as? CompareRefusal == .notABranch(name))
        git.assertNothingRan()
    }

    @Test func theSameRefTwiceIsRefusedBeforeGitRuns() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        _ = try await repo.commitFile("f.txt", "one\n", "root")
        let git = try GitLaunchLog()
        defer { git.cleanUp() }

        let error = await thrownError { _ = try await git.backend.compare("refs/heads/main", "refs/heads/main", at: repo.root) }

        #expect(error as? CompareRefusal == .sameRef)
        git.assertNothingRan()
    }

    /// The negative control for the two refusals above: a valid pair does launch git.
    @Test func aValidPairDoesLaunchGit() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        _ = try await repo.commitFile("f.txt", "one\n", "root")
        try await repo.git(["branch", "other"])
        let git = try GitLaunchLog()
        defer { git.cleanUp() }

        _ = try await git.backend.compare("refs/heads/main", "refs/heads/other", at: repo.root)

        #expect(!git.launches.isEmpty)
        withKnownIssue("git really ran") { git.assertNothingRan() }
    }

    @Test func aMissingRefIsNamed() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        _ = try await repo.commitFile("f.txt", "one\n", "root")

        let local = await thrownError { _ = try await backend.compare("refs/heads/nope", "refs/heads/main", at: repo.root) }
        let remote = await thrownError {
            _ = try await backend.compare("refs/heads/main", "refs/remotes/origin/nope", at: repo.root)
        }

        #expect(local as? CompareRefusal == .missing("refs/heads/nope"))
        #expect(remote as? CompareRefusal == .missing("refs/remotes/origin/nope"))
    }

    // MARK: - Refs moving after the read (R12)

    /// Both branches move after `compare` returns. The files and the diff are still the
    /// comparison's — the ids it read — and equal what was read before the move.
    @Test func theChangesStayTheComparisonsWhenBothBranchesMove() async throws {
        let fixture = try await CompareFixture.divergent()
        defer { fixture.repo.cleanUp() }
        let repo = fixture.repo
        let c = try await backend.compare("refs/heads/A", "refs/heads/B", at: repo.root)
        let filesBefore = try await backend.comparisonFiles(c, at: repo.root)
        let diffBefore = try await backend.comparisonDiff(c, path: nil, at: repo.root)
        #expect(!filesBefore.isEmpty)

        // B back to the root plus one new commit, A to B's old tip.
        try await repo.git(["switch", "-q", "--detach", fixture.root])
        let z = try await repo.commitFile("z.txt", "z\n", "z")
        try await repo.git(["update-ref", "refs/heads/B", z])
        try await repo.git(["update-ref", "refs/heads/A", fixture.merge])

        #expect(try await backend.comparisonFiles(c, at: repo.root) == filesBefore)
        #expect(try await backend.comparisonDiff(c, path: nil, at: repo.root) == diffBefore)
        #expect(c.a.id == fixture.a2 && c.b.id == fixture.merge)

        // The control: the same reads by name now describe a different state.
        let filesByName = backend.parseNameStatus(
            try await repo.git(["diff", "--name-status", "-z", "-M", "refs/heads/A...refs/heads/B"]))
        let diffByName = DiffParser.parse(try await repo.pinnedDiff("refs/heads/A...refs/heads/B"))
        let countByName = try await repo.lines(["rev-list", "--count", "--left-right", "refs/heads/A...refs/heads/B", "--"])
        withKnownIssue("by name, the reads follow the moved refs") {
            #expect(filesByName == filesBefore)
        }
        withKnownIssue("by name, the reads follow the moved refs") {
            #expect(diffByName == diffBefore)
        }
        withKnownIssue("by name, the reads follow the moved refs") {
            #expect(countByName == ["\(c.onlyA)\t\(c.onlyB)"])
        }
    }

    // MARK: - More than `listLimit` (R4)

    @Test func moreThanFiveHundredOnOneSideIsCountedExactlyAndListedToTheLimit() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let main = try await repo.commitFile("f.txt", "one\n", "root")
        try await repo.fastImportChain(onto: main, branch: "big", count: 520)
        let tip = try await repo.revParse("refs/heads/big")

        let c = try await backend.compare("refs/heads/main", "refs/heads/big", at: repo.root)

        #expect(Comparison.listLimit == 500)
        #expect((c.onlyA, c.onlyB) == (0, 520))
        #expect(c.commitsOnlyB.count == 500)
        #expect(c.commitsOnlyB.first?.sha == tip)
        let walked = try await repo.lines(["rev-list", "refs/heads/big", "^refs/heads/main"])
        #expect(walked.count == 520)
        #expect(c.commitsOnlyB.map(\.sha) == Array(walked.prefix(500)))
        #expect(c.commitsOnlyA.isEmpty, "\(c.commitsOnlyA.map(\.summary))")
    }

    // MARK: - A hand-built comparison

    /// A `Comparison` whose ids are not full object ids (built by hand, or a 3-dot range that
    /// `diff-tree` would silently answer with nothing, R6) is refused before git runs.
    @Test(arguments: ["abc123", "\(String(repeating: "a", count: 40))...\(String(repeating: "b", count: 40))", "", "-p"])
    func aComparisonWithoutFullIdsIsRefusedBeforeGitRuns(id: String) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let main = try await repo.commitFile("f.txt", "one\n", "root")
        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        let badTip = Comparison(
            a: RefTip(ref: "refs/heads/main", id: main), b: RefTip(ref: "refs/heads/x", id: id),
            onlyA: 0, onlyB: 0, commitsOnlyA: [], commitsOnlyB: [], mergeBases: [main])
        let badBase = Comparison(
            a: RefTip(ref: "refs/heads/main", id: main), b: RefTip(ref: "refs/heads/x", id: main),
            onlyA: 0, onlyB: 0, commitsOnlyA: [], commitsOnlyB: [], mergeBases: [id])

        for c in [badTip, badBase] {
            let files = await thrownError { _ = try await git.backend.comparisonFiles(c, at: repo.root) }
            let diff = await thrownError { _ = try await git.backend.comparisonDiff(c, path: nil, at: repo.root) }
            #expect(files as? BranchOperationError == .invalidName(id))
            #expect(diff as? BranchOperationError == .invalidName(id))
        }
        git.assertNothingRan()
    }
}

/// Two branches that diverged from `root`:
/// - `A` = root + `a1` (adds a.txt) + `a2` (edits f.txt's first line);
/// - `B` = root + `b1` (adds b.txt, renames r.txt) + `b2` (edits f.txt's last line), merged
///   with `side` = b1 + `s1` (adds s.txt) as `merge`.
private struct CompareFixture {
    let repo: TestRepo
    let root, a1, a2, b1, s1, b2, merge: String

    static func divergent() async throws -> CompareFixture {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("r.txt", (1...30).map { "line \($0)\n" }.joined())
        let root = try await repo.commitFile("f.txt", (1...10).map { "\($0)\n" }.joined(), "root")
        try await repo.git(["switch", "-q", "-c", "A"])
        let a1 = try await repo.commitFile("a.txt", "a\n", "a1 on A")
        let a2 = try await repo.commitFile("f.txt", "ONE\n" + (2...10).map { "\($0)\n" }.joined(), "a2 on A")
        try await repo.git(["switch", "-q", "-c", "B", "main"])
        try await repo.git(["mv", "r.txt", "renamed.txt"])
        let b1 = try await repo.commitFile("b.txt", "b\n", "b1 on B")
        try await repo.git(["switch", "-q", "-c", "side"])
        let s1 = try await repo.commitFile("s.txt", "s\n", "s1 on side")
        try await repo.git(["switch", "-q", "B"])
        let b2 = try await repo.commitFile("f.txt", (1...9).map { "\($0)\n" }.joined() + "TEN\n", "b2 on B")
        try await repo.git(["merge", "-q", "--no-ff", "-m", "merge side into B", "side"])
        let merge = try await repo.headSha()
        try await repo.git(["switch", "-q", "main"])
        return CompareFixture(repo: repo, root: root, a1: a1, a2: a2, b1: b1, s1: s1, b2: b2, merge: merge)
    }
}

extension TestRepo {
    /// Writes `path`, commits everything, and returns the new commit's id.
    fileprivate func commitFile(_ path: String, _ contents: String, _ message: String) async throws -> String {
        try write(path, contents)
        try await commitAll(message)
        return try await headSha()
    }

    /// git's output cut into lines.
    fileprivate func lines(_ arguments: [String]) async throws -> [String] {
        GitLines.split(try await git(arguments))
    }

    /// `git diff <range>` with the working-copy pins: the bytes no diff configuration can change.
    fileprivate func pinnedDiff(_ range: String) async throws -> Data {
        try await git([
            "diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/",
            "--dst-prefix=b/", "--full-index", "-U3", range,
        ])
    }

    /// `count` empty-tree-changing commits on a new `refs/heads/<branch>` from `parent`, in one
    /// `fast-import` (one process rather than `count` commits), each a second newer than the last.
    fileprivate func fastImportChain(onto parent: String, branch: String, count: Int) async throws {
        // Committed after `parent`, as a real history is: with dates older than the parent's,
        // `git log big..main` walks past the skew and lists `main`'s root (measured), while the
        // count stays right.
        let start = Int(Date().timeIntervalSince1970) + 60
        var stream = ""
        for n in 1...count {
            let message = "c\(n)\n"
            stream += "commit refs/heads/\(branch)\n"
            stream += "committer Tester <t@t> \(start + n) +0000\n"
            stream += "data \(message.utf8.count)\n\(message)"
            if n == 1 { stream += "from \(parent)\n" }
            let blob = "\(n)\n"
            stream += "M 100644 inline n.txt\ndata \(blob.utf8.count)\n\(blob)\n"
        }
        let file = root.appendingPathComponent(".git/chain.fi")
        try stream.write(to: file, atomically: true, encoding: .utf8)
        _ = try await isolatedRunner().run(
            "/bin/sh", ["-c", "exec /usr/bin/git fast-import --quiet < \"$1\"", "sh", file.path], cwd: root)
    }
}
