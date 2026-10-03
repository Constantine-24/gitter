import Foundation
import GitCore
import Testing

@testable import Gitter

/// The store's half of Restore Tag (fix round 1, I1): the receipts of deleted tags live in the
/// store (`deletedTags`), not in the one sticky notice slot, so another sticky notice — a second
/// Delete Tag, a discard, a pushed branch's link, × — never takes the only way back with it.
/// No repository, no git: the restore's git half is GitCore's, and what the store does with
/// each answer is `finishTagRestore`.
@MainActor @Suite struct TagStoreTests {
    static let commit = "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d"
    static let object = "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432"
    static let other = "8e7d6c5b4a39281706f5e4d3c2b1a09876543210"
    static let r1 = TagReceipt(name: "v1", objectID: object, target: commit)
    static let r2 = TagReceipt(name: "v2", objectID: commit, target: commit)

    static func snapshot(tags: [GitCore.Tag]) -> RepoSnapshot {
        RepoSnapshot(
            root: URL(fileURLWithPath: "/nonexistent"),
            status: WorkingCopyStatus(
                headSha: commit, branch: "main", upstream: nil, ahead: 0, behind: 0, files: []),
            refs: RefCollection(localBranches: [], remoteBranches: [], tags: tags),
            commits: [], graph: [])
    }

    @Test func deletingTwoTagsLeavesBothRestorable() {
        let store = RepositoryStore()
        store.recordTagDeleted(Self.r1)
        store.recordTagDeleted(Self.r2)
        #expect(store.deletedTags.receipts == [Self.r1, Self.r2])
        #expect(store.stickyNotice == TagWording.deletedNotice([Self.r1, Self.r2]))
    }

    /// Another sticky notice replaces the slot, not the receipts; the next delete's notice names
    /// both again.
    @Test func anotherStickyNoticeInBetweenLosesNothing() {
        let store = RepositoryStore()
        store.recordTagDeleted(Self.r1)
        let other = Notice(text: "Discarded f.txt.")
        store.showStickyNotice(other)
        #expect(store.deletedTags.receipts == [Self.r1])
        #expect(store.stickyNotice == other)
        store.recordTagDeleted(Self.r2)
        #expect(store.stickyNotice == TagWording.deletedNotice([Self.r1, Self.r2]))
    }

    /// × on the notice: the receipts stay, and a later restore does not bring the notice back.
    @Test func aDismissedNoticeLeavesTheReceipts() {
        let store = RepositoryStore()
        store.recordTagDeleted(Self.r1)
        store.recordTagDeleted(Self.r2)
        store.dismissStickyNotice()
        #expect(store.deletedTags.receipts == [Self.r1, Self.r2])
        store.finishTagRestore([(Self.r1, .success(()))])
        #expect(store.deletedTags.receipts == [Self.r2])
        #expect(store.stickyNotice == nil)
    }

    @Test func restoringOneRemovesOnlyIt() {
        let store = RepositoryStore()
        store.recordTagDeleted(Self.r1)
        store.recordTagDeleted(Self.r2)
        store.finishTagRestore([(Self.r1, .success(()))])
        #expect(store.deletedTags.receipts == [Self.r2])
        #expect(store.stickyNotice == TagWording.deletedNotice([Self.r2]))
        #expect(store.notice?.text == TagWording.restored([Self.r1]))
        store.finishTagRestore([(Self.r2, .success(()))])
        #expect(store.deletedTags.receipts == [])
        #expect(store.stickyNotice == nil)
    }

    /// A tag of that name exists again: refused, and the receipt — the only way back — stays.
    @Test func aRefusedRestoreKeepsTheReceipt() {
        let store = RepositoryStore()
        store.recordTagDeleted(Self.r1)
        let refusal = TagOperationError.nameProblem(.exists)
        store.finishTagRestore([(Self.r1, .failure(refusal))])
        #expect(store.deletedTags.receipts == [Self.r1])
        #expect(store.stickyNotice == TagWording.deletedNotice([Self.r1]))
        #expect(store.lastError == TagWording.failure(refusal, .restore("v1")))
    }

    /// One back, one refused: each says its own, and only the restored one goes.
    @Test func aPartRestoreSaysBoth() {
        let store = RepositoryStore()
        store.recordTagDeleted(Self.r1)
        store.recordTagDeleted(Self.r2)
        let refusal = TagOperationError.nameProblem(.exists)
        store.finishTagRestore([(Self.r1, .success(())), (Self.r2, .failure(refusal))])
        #expect(store.deletedTags.receipts == [Self.r2])
        #expect(store.notice?.text == TagWording.restored([Self.r1]))
        #expect(store.lastError == TagWording.failure(refusal, .restore("v2")))
    }

    /// A fetch brought the tag back exactly: its receipt ends, and the notice with it; a tag of
    /// that name at another object leaves it.
    @Test func aTagBackAsItWasEndsItsReceiptAndNotice() {
        let store = RepositoryStore()
        store.recordTagDeleted(Self.r1)
        store.setSnapshot(Self.snapshot(tags: [Tag(name: "v1", sha: Self.other, isAnnotated: false)]))
        #expect(store.deletedTags.receipts == [Self.r1])
        store.setSnapshot(
            Self.snapshot(tags: [Tag(name: "v1", sha: Self.commit, isAnnotated: true, objectID: Self.object)]))
        #expect(store.deletedTags.receipts == [])
        #expect(store.stickyNotice == nil)
    }
}
