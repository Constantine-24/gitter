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

    // MARK: - Delete on a remote (final fix wave, Minor 3)

    /// Confirm on Delete from <remote>… that the lane refuses — quitting here; a lane or a slot
    /// already taken alike — says so with the sheet still up, as New Tag and Delete Tag do, so
    /// the answer can be given again. It used to close the sheet first, and the refusal (or,
    /// with no lane to ask, nothing at all) came after.
    @Test func aRefusedRemoteDeleteKeepsItsSheet() {
        let store = RepositoryStore()
        let sheet = BranchSheet.deleteRemoteTag(name: "v1", remote: "origin", id: Self.object)
        store.activeSheet = sheet
        store.beginTerminating()

        store.confirmDeleteRemoteTag("v1", on: "origin", expecting: Self.object)

        #expect(store.activeSheet == sheet)
        #expect(store.lastError == RemoteWording.refusedWhileQuitting)
        #expect(store.remoteActivity == nil)
    }

    /// The question Confirm asks before the sheet closes refuses exactly what `beginRemote`
    /// refuses: quitting, a lane taken by anything but the automatic fetch (which the claim
    /// stops), the mutation slot held — and nothing otherwise.
    @Test func theClaimIsRefusedAsTheLaneRefusesIt() {
        let push = RemoteActivity(kind: .pushTag, remote: "origin", progress: nil)
        let auto = RemoteActivity(kind: .autoFetch, remote: nil, progress: nil)
        func refusal(terminating: Bool = false, lane: RemoteActivity? = nil, mutating: Bool = false) -> String? {
            RepositoryStore.laneClaimRefusal(
                .deleteRemoteTag, holdingMutation: true, isTerminating: terminating,
                remoteActivity: lane, isMutating: mutating)
        }
        #expect(refusal() == nil)
        #expect(refusal(terminating: true) == RemoteWording.refusedWhileQuitting)
        #expect(refusal(lane: push) == RemoteWording.laneBusy(push))
        #expect(refusal(lane: auto) == nil)
        #expect(refusal(mutating: true) == RemoteWording.mutationBusy)
        #expect(
            RepositoryStore.laneClaimRefusal(
                .fetch, holdingMutation: false, isTerminating: false, remoteActivity: nil, isMutating: true)
                == nil)
    }
}
