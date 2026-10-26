import AppKit
import Foundation
import GitCore
import Testing

@testable import Gitter

/// The two notice slots, on a store with **no repository**: nothing here opens one, and the
/// store's defaults are a scratch suite (`makeTestStore`), never the user's.
@MainActor @Suite struct NoticeLifetimeTests {

    private let link = URL(string: "https://example.invalid/o/r/pull/new/b")!

    private func linkNotice(_ text: String = "Published \"b\".") -> Notice {
        Notice.linked(text: text, links: [link])
    }

    @Test func aStoreStartsWithNeitherSlot() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        #expect(store.root == nil)
        #expect(store.notice == nil)
        #expect(store.stickyNotice == nil)
    }

    @Test func aTransientNoticeLeavesTheStickyOne() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        let sticky = linkNotice()
        store.showStickyNotice(sticky)
        store.showNotice("Fetched from \"origin\".")
        #expect(store.stickyNotice == sticky)
        #expect(store.notice == Notice(text: "Fetched from \"origin\"."))
    }

    @Test func dismissingTheTransientNoticeLeavesTheStickyOne() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        let sticky = linkNotice()
        store.showStickyNotice(sticky)
        store.showNotice("Fetched.")
        store.dismissNotice()
        #expect(store.notice == nil)
        #expect(store.stickyNotice == sticky)
    }

    @Test func aSecondStickyNoticeReplacesTheFirst() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        store.showStickyNotice(linkNotice("first"))
        let second = Notice.linked(
            text: "second", links: [URL(string: "https://example.invalid/2")!])
        store.showStickyNotice(second)
        #expect(store.stickyNotice == second)
    }

    @Test func dismissingTheStickyNoticeClearsIt() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        store.showStickyNotice(linkNotice())
        #expect(store.stickyNotice != nil)
        store.dismissStickyNotice()
        #expect(store.stickyNotice == nil)
    }

    /// A private, named pasteboard: the test never touches the user's clipboard.
    @Test func copyLinkPutsTheWholeURLOnThePasteboard() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        pasteboard.setString("before", forType: .string)
        let base = "https://example.invalid/o/r/pull/new/"
        let long = URL(string: base + String(repeating: "a", count: 400 - base.count))!
        store.perform(.copyLink(long), pasteboard: pasteboard, openURL: { _ in })
        #expect(pasteboard.string(forType: .string) == long.absoluteString)
        #expect(long.absoluteString.count == 400)
    }

    /// Opening goes through the injected opener only, so no browser starts under test.
    @Test func openLinkOpensHTTPAndHTTPSOnly() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        var opened: [URL] = []
        let record: (URL) -> Void = { opened.append($0) }
        store.perform(.openLink(link), pasteboard: pasteboard, openURL: record)
        store.perform(
            .openLink(URL(string: "javascript:alert(1)")!), pasteboard: pasteboard,
            openURL: record)
        store.perform(
            .openLink(URL(string: "file:///etc/passwd")!), pasteboard: pasteboard,
            openURL: record)
        #expect(opened == [link])
    }

    // MARK: - Which slot (`NoticeSlot.choose`, B4 item 2)

    private static let stashed = Stash(
        sha: String(repeating: "a", count: 40), index: 0, reflogSubject: "On main: wip", parents: [],
        date: Date(timeIntervalSince1970: 0))
    /// A sticky notice with a button: Stash and Continue's Pop Stash.
    private static let popStash = Notice(text: "Your changes are in stash@{0}.", actions: [.popStash(stashed)])
    /// A sticky notice without one: a prune's record.
    private static let record = Notice(text: "Pruned \"origin\".", keep: true)
    private static let undo = Notice(text: "Rebased. To undo: git reset --keep 1a2b3c4", keep: true)

    @Test func plainTextFades() {
        #expect(NoticeSlot.choose(for: Notice(text: "Fetched."), replacing: nil) == .fading)
        #expect(NoticeSlot.choose(for: Notice(text: "Fetched."), replacing: Self.record) == .fading)
    }

    @Test func aLinkStays() {
        #expect(NoticeSlot.choose(for: linkNotice(), replacing: nil) == .sticky)
        // As today, a link replaces whatever sticky notice is up.
        #expect(NoticeSlot.choose(for: Notice(text: "x", links: [link]), replacing: Self.popStash) == .sticky)
    }

    @Test func aButtonStays() {
        #expect(NoticeSlot.choose(for: Self.popStash, replacing: nil) == .sticky)
    }

    @Test func aKeptNoticeStaysWithNothingUp() {
        #expect(NoticeSlot.choose(for: Self.undo, replacing: nil) == .sticky)
    }

    @Test func aWarningStaysWithNothingUp() {
        let warning = Notice(text: "Pushed, but the upstream could not be set.", tone: .warning)
        #expect(NoticeSlot.choose(for: warning, replacing: nil) == .sticky)
    }

    /// RF1: Pop Stash is up, then the retried action's kept notice comes. Pop Stash stays; the
    /// kept one shows in the fading slot instead.
    @Test func aKeptNoticeNeverReplacesOneWithAButton() {
        #expect(NoticeSlot.choose(for: Self.undo, replacing: Self.popStash) == .fading)
        let warning = Notice(text: "Pushed, but the upstream could not be set.", tone: .warning)
        #expect(NoticeSlot.choose(for: warning, replacing: Self.popStash) == .fading)
    }

    @Test func aKeptNoticeReplacesOneWithoutAButton() {
        #expect(NoticeSlot.choose(for: Self.undo, replacing: Self.record) == .sticky)
    }

    @Test func aButtonReplacesAButton() {
        let added = Notice(text: "Added worktree.", actions: [.openWorktree("/tmp/x")])
        #expect(NoticeSlot.choose(for: added, replacing: Self.popStash) == .sticky)
    }

    /// The store side of RF1: `show` puts the kept notice in `notice` and leaves Pop Stash up.
    @Test func showLeavesPopStashUpAndFadesTheKeptNotice() {
        let (store, _, cleanup) = makeTestStore()
        defer { cleanup() }
        store.show(Self.popStash)
        store.show(Self.undo)
        #expect(store.stickyNotice == Self.popStash)
        #expect(store.notice == Self.undo)
        // Control: with nothing that has a button up, the kept notice takes the sticky slot.
        store.dismissStickyNotice()
        store.dismissNotice()
        store.show(Self.undo)
        #expect(store.stickyNotice == Self.undo)
        #expect(store.notice == nil)
    }

    // MARK: - A lane's ending (Ruling 1: `runOnLane`'s choice, tested purely)

    /// "Pushed, but the upstream could not be set" (`mustBeRead`): a warning, and it stays.
    @Test func aLaneEndingThatMustBeReadIsAWarningThatStays() throws {
        let ending = LaneEnding(notice: Notice(text: "Pushed, but the upstream could not be set."), mustBeRead: true)
        let shown = try #require(ending.shownNotice)
        #expect(shown.tone == .warning)
        #expect(NoticeSlot.choose(for: shown, replacing: nil) == .sticky)
    }

    @Test func aLaneEndingsOwnStickyRecordIsKept() throws {
        let ending = LaneEnding(notice: Notice(text: "Pruned."), sticky: true)
        let shown = try #require(ending.shownNotice)
        #expect(shown.keep && shown.tone == .done)
        #expect(NoticeSlot.choose(for: shown, replacing: nil) == .sticky)
    }

    /// The control: a plain "it worked" from the lane fades, and an empty one shows nothing.
    @Test func aPlainLaneEndingFades() throws {
        let shown = try #require(LaneEnding(notice: "Fetched.").shownNotice)
        #expect(shown.tone == .done && !shown.keep)
        #expect(NoticeSlot.choose(for: shown, replacing: nil) == .fading)
        #expect(LaneEnding(notice: "").shownNotice == nil)
    }
}
