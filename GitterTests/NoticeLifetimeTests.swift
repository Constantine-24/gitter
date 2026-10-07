import AppKit
import Foundation
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
}
