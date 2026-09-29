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
        let store = RepositoryStore()
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
}
