import Foundation
import Testing

@testable import Gitter

/// Which links a push's `remote:` lines hand the notice (RF5): whole, trimmed, http(s) only,
/// with no userinfo — and the words the notice's buttons carry.
@Suite struct NoticeLinksTests {

    // MARK: - The hosting services' own hints

    /// GitHub's hint after a push of a new branch, as `PushResult.remoteMessages` gives it
    /// (the `remote:` prefix already gone).
    @Test func gitHubsHintGivesItsOneLink() {
        let lines = [
            "",
            "Create a pull request for 'b' on GitHub by visiting:",
            "     https://github.com/o/r/pull/new/b",
            "",
        ]
        #expect(
            NoticeLinks.extract(fromRemoteLines: lines) == [
                URL(string: "https://github.com/o/r/pull/new/b")!
            ])
    }

    @Test func gitLabsHintGivesItsOneLink() {
        let lines = [
            "",
            "To create a merge request for b, visit:",
            "  https://gitlab.com/o/r/-/merge_requests/new?merge_request%5Bsource_branch%5D=b",
            "",
        ]
        #expect(
            NoticeLinks.extract(fromRemoteLines: lines) == [
                URL(
                    string:
                        "https://gitlab.com/o/r/-/merge_requests/new?merge_request%5Bsource_branch%5D=b"
                )!
            ])
    }

    // MARK: - RF5

    /// Longer than `RemoteWording.plain`'s 200-character cap by far: the link is never capped.
    @Test func aFourHundredCharacterURLComesBackWhole() {
        let base = "https://example.invalid/o/r/pull/new/"
        let url = base + String(repeating: "a", count: 400 - base.count)
        #expect(url.count == 400)
        let found = NoticeLinks.extract(fromRemoteLines: ["Open a pull request: \(url)"])
        #expect(found.map(\.absoluteString) == [url])
    }

    @Test func aSentencesFullStopIsNotPartOfTheLink() {
        let found = NoticeLinks.extract(
            fromRemoteLines: ["Create one at https://example.invalid/o/r/pull/new/b."])
        #expect(found.map(\.absoluteString) == ["https://example.invalid/o/r/pull/new/b"])
    }

    @Test func aClosingParenthesisIsNotPartOfTheLink() {
        let found = NoticeLinks.extract(
            fromRemoteLines: ["(https://example.invalid/o/r/-/merge_requests/new?x=1)"])
        #expect(found.map(\.absoluteString) == ["https://example.invalid/o/r/-/merge_requests/new?x=1"])
    }

    @Test func everyTrailingPunctuationMarkIsTrimmed() {
        let found = NoticeLinks.extract(fromRemoteLines: ["see https://example.invalid/x/y),;:."])
        #expect(found.map(\.absoluteString) == ["https://example.invalid/x/y"])
    }

    /// The lines are redacted already; the link drops its userinfo on its own as well.
    @Test func userinfoIsRemoved() {
        let found = NoticeLinks.extract(fromRemoteLines: ["https://user:tok@host/o/r/pull/1"])
        #expect(found.map(\.absoluteString) == ["https://host/o/r/pull/1"])
        #expect(!found.map(\.absoluteString).joined().contains("tok"))
    }

    @Test func aUserNameWithoutAPasswordIsRemovedToo() {
        let found = NoticeLinks.extract(fromRemoteLines: ["https://user@host/o/r/pull/1"])
        #expect(found.map(\.absoluteString) == ["https://host/o/r/pull/1"])
    }

    @Test func plainHTTPIsAccepted() {
        let found = NoticeLinks.extract(fromRemoteLines: ["http://example.invalid/o/r/pull/new/b"])
        #expect(found.map(\.absoluteString) == ["http://example.invalid/o/r/pull/new/b"])
    }

    @Test func otherSchemesAreIgnored() {
        let found = NoticeLinks.extract(fromRemoteLines: [
            "ftp://example.invalid/o/r",
            "javascript:alert(1)",
            "file:///etc/passwd",
            "ssh://git@example.invalid/o/r.git",
        ])
        #expect(found.isEmpty)
    }

    /// A scheme with nothing after it is not a link.
    @Test func aSchemeWithoutAHostIsIgnored() {
        #expect(NoticeLinks.extract(fromRemoteLines: ["visit https:// later"]).isEmpty)
    }

    @Test func twoIdenticalURLsGiveOne() {
        let url = "https://example.invalid/o/r/pull/new/b"
        let found = NoticeLinks.extract(fromRemoteLines: [url, "again: \(url)"])
        #expect(found.map(\.absoluteString) == [url])
    }

    @Test func differentURLsKeepTheirOrder() {
        let found = NoticeLinks.extract(fromRemoteLines: [
            "https://example.invalid/2 and https://example.invalid/1",
            "https://example.invalid/3",
        ])
        #expect(
            found.map(\.absoluteString) == [
                "https://example.invalid/2", "https://example.invalid/1",
                "https://example.invalid/3",
            ])
    }

    /// A colour escape around the address is not part of it.
    @Test func anEscapeSequenceAroundTheLinkIsNotPartOfIt() {
        let found = NoticeLinks.extract(
            fromRemoteLines: ["\u{1B}[1mhttps://example.invalid/o/r/pull/new/b\u{1B}[0m"])
        #expect(found.map(\.absoluteString) == ["https://example.invalid/o/r/pull/new/b"])
    }

    @Test func noURLGivesNothing() {
        #expect(NoticeLinks.extract(fromRemoteLines: []).isEmpty)
        #expect(NoticeLinks.extract(fromRemoteLines: ["Resolving deltas: 100% (3/3)", ""]).isEmpty)
    }

    // MARK: - The notice a push makes of them

    @Test func aNoticeWithLinksOffersOpenAndCopyForTheFirst() {
        let first = URL(string: "https://example.invalid/1")!
        let second = URL(string: "https://example.invalid/2")!
        let notice = Notice.linked(text: "Pushed.", links: [first, second])
        #expect(notice.text == "Pushed.")
        #expect(notice.links == [first, second])
        #expect(notice.actions == [.openLink(first), .copyLink(first)])
    }

    @Test func aNoticeWithoutLinksOffersNothing() {
        let notice = Notice.linked(text: "Pushed.", links: [])
        #expect(notice == Notice(text: "Pushed."))
        #expect(notice.actions.isEmpty)
    }

    @Test func theButtonsAreCalledOpenAndCopyLink() {
        let url = URL(string: "https://example.invalid/1")!
        #expect(NoticeWording.title(.openLink(url)) == "Open")
        #expect(NoticeWording.title(.copyLink(url)) == "Copy Link")
    }

    @Test func onlyHTTPAndHTTPSCanBeOpened() {
        #expect(NoticeLinks.canOpen(URL(string: "https://example.invalid/1")!))
        #expect(NoticeLinks.canOpen(URL(string: "HTTP://example.invalid/1")!))
        #expect(!NoticeLinks.canOpen(URL(string: "javascript:alert(1)")!))
        #expect(!NoticeLinks.canOpen(URL(string: "file:///etc/passwd")!))
        #expect(!NoticeLinks.canOpen(URL(string: "ftp://example.invalid/x")!))
    }
}
