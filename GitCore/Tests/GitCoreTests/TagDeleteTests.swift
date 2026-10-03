import Foundation
import Testing

@testable import GitCore

/// `GitTagBackend.deleteTag` — a compare-and-delete on the id the sheet showed — and
/// `restoreTag` (B19, RF1).
@Suite struct TagDeleteTests {
    /// `makeBranched()` (lightweight `v1` on the root commit) plus an annotated `ann` on `main`'s
    /// second commit.
    static func makeRepo() async throws -> TestRepo {
        let repo = try await TestRepo.makeBranched()
        _ = try await repo.commit("b.txt", "two", "second")
        try await repo.git(["tag", "-a", "ann", "-m", "Annotated\n\nbody"])
        return repo
    }

    /// Every ref but `refs/tags/<name>` is as it was, and that one is gone.
    static func assertOnlyTagGone(
        _ repo: TestRepo, _ name: String, since before: RepoState,
        sourceLocation: SourceLocation = #_sourceLocation
    ) async throws {
        let now = try await RepoState.capture(repo)
        let kept = before.refs.split(separator: "\n").filter { !$0.hasSuffix("\trefs/tags/\(name)") }
        #expect(kept.count == before.refs.split(separator: "\n").count - 1, sourceLocation: sourceLocation)
        #expect(now.refs.split(separator: "\n") == kept, sourceLocation: sourceLocation)
        #expect(now.head == before.head, sourceLocation: sourceLocation)
        #expect(now.index == before.index, sourceLocation: sourceLocation)
    }

    @Test func aLightweightTagIsDeleted() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let tag = try await repo.listedTag("v1")
        let commit = try await repo.revParse("refs/tags/v1")
        let before = try await RepoState.capture(repo)

        let receipt = try await CLIGitBackend().deleteTag(tag, at: repo.root)

        #expect(receipt == TagReceipt(name: "v1", objectID: commit, target: commit))
        #expect(try await repo.tagObject("v1") == nil)
        try await Self.assertOnlyTagGone(repo, "v1", since: before)
    }

    /// The expected value is the **tag object**: an annotated tag's ref holds that, not the
    /// commit (B19).
    @Test func anAnnotatedTagIsDeletedOnItsTagObject() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let tag = try await repo.listedTag("ann")
        let object = try #require(try await repo.tagObject("ann"))
        let commit = try await repo.revParse("refs/tags/ann^{commit}")
        #expect(tag.objectID == object)
        let before = try await RepoState.capture(repo)

        let receipt = try await CLIGitBackend().deleteTag(tag, at: repo.root)

        #expect(receipt == TagReceipt(name: "ann", objectID: object, target: commit))
        #expect(try await repo.tagObject("ann") == nil)
        try await Self.assertOnlyTagGone(repo, "ann", since: before)
    }

    /// A packed-only tag (`pack-refs --all`) is deleted from `packed-refs` as well.
    @Test func aPackedTagIsDeleted() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        try await repo.git(["pack-refs", "--all"])
        let tag = try await repo.listedTag("ann")

        _ = try await CLIGitBackend().deleteTag(tag, at: repo.root)

        #expect(try await repo.tagObject("ann") == nil)
    }

    /// RF1: the tag was moved after the sheet read it — refused, and the tag stays where it is
    /// now. The same for a tag deleted meanwhile, and for an annotated tag recreated with the
    /// same commit (a new tag object).
    @Test(arguments: ["move", "delete", "recreate"])
    func aTagThatChangedAfterTheReadIsRefusedAndKept(change: String) async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let tag = try await repo.listedTag("ann")
        switch change {
        case "move": try await repo.git(["tag", "-f", "ann", "refs/heads/feature"])
        case "delete": try await repo.git(["tag", "-d", "ann"])
        default: try await repo.git(["tag", "-f", "-a", "ann", "-m", "again", "main"])
        }
        let snapshot = try await HistorySnapshot.capture(repo)
        #expect(try await repo.tagObject("ann") != tag.objectID)

        await #expect(throws: TagOperationError.tagMoved(name: "ann")) {
            _ = try await CLIGitBackend().deleteTag(tag, at: repo.root)
        }
        try await snapshot.assertUnchanged(repo)
    }

    /// An all-zero or empty expected value makes `update-ref -d` delete with no check at all
    /// (B19); a short one is resolved rather than compared. Each is refused before any process.
    @Test(arguments: ["", "0000000000000000000000000000000000000000", "short"])
    func anExpectedIDThatIsNotFullAndNonZeroIsRefusedBeforeGit(kind: String) async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let listed = try await repo.listedTag("ann")
        let id: String
        switch kind {
        case "short": id = String(listed.objectID.prefix(7))
        default: id = kind
        }
        let tag = GitCore.Tag(name: "ann", sha: listed.sha, isAnnotated: true, objectID: id)
        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        let snapshot = try await HistorySnapshot.capture(repo)

        await #expect(throws: TagOperationError.invalidObjectID(id)) {
            _ = try await git.backend.deleteTag(tag, at: repo.root)
        }
        await #expect(throws: TagOperationError.invalidObjectID(listed.objectID.uppercased())) {
            _ = try await git.backend.deleteTag(
                GitCore.Tag(name: "ann", sha: listed.sha, isAnnotated: true, objectID: listed.objectID.uppercased()),
                at: repo.root)
        }
        git.assertNothingRan()
        try await snapshot.assertUnchanged(repo)
    }

    /// Restore Tag recreates the identical annotated tag: the same tag object, so the same
    /// message, tagger and date (B19).
    @Test func restoreRecreatesTheIdenticalAnnotatedTag() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let tag = try await repo.listedTag("ann")
        let before = try await RepoState.capture(repo)
        let receipt = try await CLIGitBackend().deleteTag(tag, at: repo.root)
        #expect(try await repo.tagObject("ann") == nil)

        try await CLIGitBackend().restoreTag(receipt, at: repo.root)

        #expect(try await repo.tagObject("ann") == tag.objectID)
        #expect(try await repo.objectType("refs/tags/ann") == "tag")
        #expect(try await RepoState.capture(repo) == before)
        #expect(try await repo.listedTag("ann") == tag)
    }

    @Test func restoreRecreatesALightweightTag() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let tag = try await repo.listedTag("v1")
        let before = try await RepoState.capture(repo)
        let receipt = try await CLIGitBackend().deleteTag(tag, at: repo.root)

        try await CLIGitBackend().restoreTag(receipt, at: repo.root)

        #expect(try await RepoState.capture(repo) == before)
    }

    /// Signing config cannot turn the restore into a new, signed tag (B17): the restore names
    /// the tag object and passes no message.
    @Test(arguments: ["tag.gpgSign", "tag.forceSignAnnotated"])
    func restoreIgnoresSigningConfig(key: String) async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let tag = try await repo.listedTag("ann")
        let receipt = try await CLIGitBackend().deleteTag(tag, at: repo.root)
        let gpgLog = try await repo.failTagSigning(key)

        try await CLIGitBackend().restoreTag(receipt, at: repo.root)

        #expect(try await repo.tagObject("ann") == tag.objectID)
        #expect(!FileManager.default.fileExists(atPath: gpgLog.path), "gpg was called")
    }

    /// A tag of that name exists again: the restore is refused and the new tag kept.
    @Test func restoreOverATagMadeMeanwhileIsRefused() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let receipt = try await CLIGitBackend().deleteTag(try await repo.listedTag("ann"), at: repo.root)
        try await repo.git(["tag", "ann", "refs/heads/feature"])
        let snapshot = try await HistorySnapshot.capture(repo)

        await #expect(throws: TagOperationError.nameProblem(.exists)) {
            try await CLIGitBackend().restoreTag(receipt, at: repo.root)
        }
        try await snapshot.assertUnchanged(repo)
    }

    @Test func restoreOfAReceiptWithAZeroIDIsRefusedBeforeGit() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        let zero = String(repeating: "0", count: 40)

        await #expect(throws: TagOperationError.invalidObjectID(zero)) {
            try await git.backend.restoreTag(TagReceipt(name: "gone", objectID: zero, target: zero), at: repo.root)
        }
        git.assertNothingRan()
    }

    /// A reference-transaction hook refusing the delete (B19): git's words, and the tag is
    /// still there — nothing lost.
    @Test func aRefusingReferenceTransactionHookIsGitsWordsAndTheTagIsKept() async throws {
        let repo = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let tag = try await repo.listedTag("ann")
        try repo.writeExecutable(
            ".git/hooks/reference-transaction",
            "#!/bin/sh\nif [ \"$1\" = prepared ]; then echo RT-NO >&2; exit 1; fi\nexit 0\n")
        let snapshot = try await HistorySnapshot.capture(repo)

        do {
            _ = try await CLIGitBackend().deleteTag(tag, at: repo.root)
            Issue.record("the delete went through")
        } catch GitError.commandFailed(_, let stderr) {
            #expect(stderr.contains("RT-NO"), "\(stderr)")
            #expect(stderr.contains("aborted by the reference-transaction hook"), "\(stderr)")
        }
        #expect(try await repo.tagObject("ann") == tag.objectID)
        try await snapshot.assertUnchanged(repo)
    }
}
