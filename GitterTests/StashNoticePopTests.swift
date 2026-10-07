import AppKit
import Foundation
import GitCore
import Testing

@testable import Gitter

/// The sticky notice's Pop Stash, which may be pressed long after the notice went up. It holds
/// the `Stash` from `.saved` — `stash@{0}` — and any later push (a terminal, a discard's record)
/// moves that entry down, so the entry is found again by its sha before it is popped.
///
/// The resolution is pure and tested here directly. The store half is tested only where it
/// needs no repository: a store with none lists no stashes, which is exactly the "no longer in
/// the list" case, and nothing here opens a repository or touches `UserDefaults`. The popping
/// half — the right entry popped after a push from a terminal — is verified in the harness.
@MainActor @Suite struct StashNoticePopTests {

    private static func stash(_ sha: String, index: Int, _ message: String) -> Stash {
        Stash(
            sha: sha, index: index, reflogSubject: "On main: \(message)", parents: ["p1", "p2"],
            date: Date(timeIntervalSince1970: 1_800_000_000))
    }

    private static let offered = stash(String(repeating: "a", count: 40), index: 0, "offered")
    private static let pushedLater = stash(String(repeating: "b", count: 40), index: 0, "later")

    // MARK: - StashList.resolve

    /// The offered entry was `stash@{0}`; after one push it is `stash@{1}`, and that — its
    /// position now — is what comes back.
    @Test func resolvesTheEntryAtItsPositionNow() {
        let list = [
            Self.pushedLater,
            Self.stash(Self.offered.sha, index: 1, "offered"),
        ]
        let resolved = StashList.resolve(sha: Self.offered.sha, in: list)
        #expect(resolved?.sha == Self.offered.sha)
        #expect(resolved?.index == 1)
    }

    /// By sha, never by position: the entry now at the offered position is someone else's.
    @Test func neverResolvesToAnotherEntryAtTheOfferedPosition() {
        #expect(StashList.resolve(sha: Self.offered.sha, in: [Self.pushedLater]) == nil)
    }

    @Test func resolvesNothingInAnEmptyList() {
        #expect(StashList.resolve(sha: Self.offered.sha, in: []) == nil)
    }

    // MARK: - The notice's button

    @Test func theGoneStashSentenceIsPinned() {
        #expect(StashWording.offeredStashGone == "That stash is no longer in the list.")
    }

    /// No entry with the offered sha: the notice with the dead button is replaced by the sentence,
    /// and nothing is attempted (no refusal, no busy line).
    @Test func popOnANoticeWhoseStashIsGoneSaysSoAndEndsTheNotice() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        #expect(store.root == nil)
        #expect(store.stashes.isEmpty)
        store.showStickyNotice(Notice(text: "Stashed.", actions: [.popStash(Self.offered)]))
        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        store.perform(.popStash(Self.offered), pasteboard: pasteboard, openURL: { _ in })

        #expect(store.stickyNotice == Notice(text: StashWording.offeredStashGone))
        #expect(store.lastError == nil)
        #expect(!store.isMutating)
    }

    // MARK: - After a clean apply or pop from the Stashes list (final review M1)

    private static func receipt(
        _ request: DiscardRequest, record: Stash?, trashed: [String: URL] = [:]
    ) -> DiscardReceipt {
        DiscardReceipt(request: request, record: record, headAtDiscard: "h", trashed: trashed)
    }

    private static let record = stash(String(repeating: "c", count: 40), index: 0, "Discarded by Gitter: p")
    private static let tracked = receipt(.unstaged(paths: ["p"], expected: .diffs([])), record: record)
    private static let trashed = receipt(
        .untracked(paths: ["u"], expected: .untracked([])), record: nil,
        trashed: ["u": URL(fileURLWithPath: "/tmp/Trash/u")])

    /// The record the notice's Undo would bring back was popped or applied: the Undo would
    /// then be refused, or put it back twice. The notice goes.
    @Test(arguments: [false, true])
    func anUndoNoticeWhoseRecordWasRestoredGoes(popping: Bool) {
        let notice = Notice(text: "Discarded p.", actions: [.undoDiscard([Self.tracked])])
        #expect(RepositoryStore.stickyNoticeChange(notice, afterRestoring: Self.record, popping: popping) == .dismiss)
    }

    /// Discard All…'s notice also holds what went to the Trash: that part stays undoable, and
    /// the notice says only it.
    @Test(arguments: [false, true])
    func theTrashedPartOfAnUndoNoticeStays(popping: Bool) {
        let notice = Notice(text: "Discarded p; moved u to the Trash.", actions: [.undoDiscard([Self.tracked, Self.trashed])])
        #expect(
            RepositoryStore.stickyNoticeChange(notice, afterRestoring: Self.record, popping: popping)
                == .replace(Notice(text: DiscardWording.done([Self.trashed]), actions: [.undoDiscard([Self.trashed])])))
    }

    /// Another entry, or no sticky notice: nothing to do. Matched by sha, never by position.
    @Test func anotherEntryLeavesTheNoticeAlone() {
        let notice = Notice(text: "Discarded p.", actions: [.undoDiscard([Self.tracked])])
        let other = Self.stash(String(repeating: "d", count: 40), index: 0, "Discarded by Gitter: p")
        #expect(RepositoryStore.stickyNoticeChange(notice, afterRestoring: other, popping: true) == .keep)
        #expect(RepositoryStore.stickyNoticeChange(nil, afterRestoring: Self.record, popping: true) == .keep)
        #expect(RepositoryStore.stickyNoticeChange(Notice(text: "Pushed."), afterRestoring: Self.record, popping: true) == .keep)
    }

    /// The Pop Stash notice goes after a pop of its entry, as before; after an apply it stays —
    /// the entry is still listed.
    @Test func aPopStashNoticeGoesOnlyAfterAPop() {
        let notice = Notice(text: "Stashed.", actions: [.popStash(Self.offered)])
        #expect(RepositoryStore.stickyNoticeChange(notice, afterRestoring: Self.offered, popping: true) == .dismiss)
        #expect(RepositoryStore.stickyNoticeChange(notice, afterRestoring: Self.offered, popping: false) == .keep)
    }
}
