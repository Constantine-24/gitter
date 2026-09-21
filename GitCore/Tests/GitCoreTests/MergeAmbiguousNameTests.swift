import Foundation
import Testing

@testable import GitCore

/// What `merge` does when a tag and a local branch share a name.
///
/// Git's own lookup order puts `refs/tags/<name>` ahead of `refs/heads/<name>`, so a bare name
/// merges the **tag** (verified on git 2.54: `git merge dup` fast-forwarded onto the tag's
/// commit, printing only a "refname 'dup' is ambiguous" warning). The user picked a branch in
/// the sidebar, so merging the tag is merging something they did not ask for — and no banner
/// would say so, since git exits 0.
///
/// The other half of the contract is that nothing changes for the ordinary case: the merge
/// commit git writes must still read `Merge branch 'x'`, not `Merge branch 'refs/heads/x'`.
@Suite struct MergeAmbiguousNameTests {
    private let backend = CLIGitBackend()

    /// `main` at root; branch `dup` adds `branch.txt`; tag `dup` sits on a different commit that
    /// adds `tag.txt`. Checked out on `main`.
    private func makeAmbiguous() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try await repo.git(["switch", "-q", "-c", "dup"])
        try repo.write("branch.txt", "from the branch\n")
        try await repo.commitAll("branch commit")
        try await repo.git(["switch", "-q", "-c", "elsewhere", "main"])
        try repo.write("tag.txt", "from the tag\n")
        try await repo.commitAll("tag commit")
        try await repo.git(["tag", "dup"])
        try await repo.git(["switch", "-q", "main"])
        return repo
    }

    @Test(arguments: [MergeMode.fastForwardIfPossible, .alwaysMergeCommit])
    func mergesTheBranchNotTheSameNamedTag(mode: MergeMode) async throws {
        let repo = try await makeAmbiguous()
        defer { repo.cleanUp() }
        let branchTip = try await repo.revParse("refs/heads/dup")
        let tagTip = try await repo.revParse("refs/tags/dup")
        #expect(branchTip != tagTip)

        _ = try await backend.merge("dup", mode: mode, at: repo.root)

        _ = try await repo.git(["merge-base", "--is-ancestor", branchTip, "HEAD"])
        #expect(try repo.fileContents("branch.txt") == "from the branch\n")
        #expect(!FileManager.default.fileExists(
            atPath: repo.root.appendingPathComponent("tag.txt").path),
            "the tag's commit was merged instead of the branch's")
    }

    @Test func squashesTheBranchNotTheSameNamedTag() async throws {
        let repo = try await makeAmbiguous()
        defer { repo.cleanUp() }

        #expect(try await backend.merge("dup", mode: .squash, at: repo.root) == .squashed)

        let staged = try await repo.git(["diff", "--cached", "--name-only"])
        #expect(String(decoding: staged, as: UTF8.self) == "branch.txt\n")
    }

    /// `main` at root; branch `dup` adds `branch.txt`; a tag `dup` sits on **that same commit**,
    /// annotated or lightweight. Checked out on `main`.
    private func makeSameCommitTag(annotated: Bool) async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("a.txt", "one\n")
        try await repo.commitAll("root")
        try await repo.git(["switch", "-q", "-c", "dup"])
        try repo.write("branch.txt", "from the branch\n")
        try await repo.commitAll("branch commit")
        try await repo.git(["switch", "-q", "main"])
        try await repo.git(
            annotated ? ["tag", "-a", "dup", "-m", "annotated", "refs/heads/dup"]
                : ["tag", "dup", "refs/heads/dup"])
        return repo
    }

    /// An **annotated** tag on the branch's own commit is still a different object, and a bare
    /// `dup` resolves to the tag object. Git merges the same commit either way, but it writes
    /// "Merge tag 'dup'" and copies the tag's message into the body — a history entry about a
    /// tag the user never clicked. The branch spelling is what keeps the commit honest.
    @Test func spellsTheBranchWhenAnAnnotatedTagSitsOnItsOwnCommit() async throws {
        let repo = try await makeSameCommitTag(annotated: true)
        defer { repo.cleanUp() }

        #expect(try await backend.merge("dup", mode: .alwaysMergeCommit, at: repo.root) == .merged)

        #expect(try await repo.subject(of: "HEAD") == "Merge branch 'refs/heads/dup'")
        #expect(try repo.fileContents("branch.txt") == "from the branch\n")
    }

    /// A **lightweight** tag on the same commit is the same object as the branch tip, so the bare
    /// name is kept — and git then writes "Merge tag 'dup'" all by itself (verified on git 2.54:
    /// it names whichever ref it found, and the full refname is the only way to change that).
    /// Recorded rather than fixed: the commit merged is the branch's, the tag really does point
    /// at it, and buying a different subject would mean spelling every ambiguous merge
    /// `refs/heads/…`.
    @Test func keepsTheBareNameWhenALightweightTagSitsOnTheSameCommit() async throws {
        let repo = try await makeSameCommitTag(annotated: false)
        defer { repo.cleanUp() }

        #expect(try await backend.merge("dup", mode: .alwaysMergeCommit, at: repo.root) == .merged)

        #expect(try await repo.subject(of: "HEAD") == "Merge tag 'dup'")
        #expect(try repo.fileContents("branch.txt") == "from the branch\n")
    }

    /// The ordinary case must be untouched, message and all: a full refname would make git write
    /// "Merge branch 'refs/heads/feature'" (verified on git 2.54), which is not what a user
    /// reading their history should find.
    @Test func keepsGitsOwnMergeCommitSubjectWhenTheNameIsNotAmbiguous() async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }

        #expect(try await backend.merge("feature", mode: .alwaysMergeCommit, at: repo.root) == .merged)

        #expect(try await repo.subject(of: "HEAD") == "Merge branch 'feature'")
    }

    /// And the "into <branch>" half git adds on any branch but `main`/`master` — which is the
    /// part a hand-written `-m` would be most likely to get wrong.
    @Test func keepsGitsOwnIntoClauseOnABranchThatIsNotMain() async throws {
        let repo = try await TestRepo.makeDiverged()
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "-c", "topic"])

        #expect(try await backend.merge("feature", mode: .alwaysMergeCommit, at: repo.root) == .merged)

        #expect(try await repo.subject(of: "HEAD") == "Merge branch 'feature' into topic")
    }
}
