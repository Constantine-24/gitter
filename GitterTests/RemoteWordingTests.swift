import Testing

@testable import Gitter

/// Characterisation: how `RemoteWording` makes text from outside safe to show, and which server
/// lines a successful push turns into a notice.
@Suite struct RemoteWordingTests {

    // MARK: - plain

    /// An ANSI colour escape goes whole (no `[31m` left behind), a BEL goes, a tab becomes a
    /// space.
    @Test func plainStripsControls() {
        let text = "\u{1B}[31merror\u{1B}[0m:\tstop\u{07}here"
        #expect(RemoteWording.plain(text) == "error: stophere")
    }

    @Test func plainRedactsAURLsPassword() {
        let shown = RemoteWording.plain("fatal: unable to access 'https://u:p@h/x'")
        #expect(shown == "fatal: unable to access 'https://h/x'")
        #expect(!shown.contains("u:p"))
    }

    @Test func plainCapsALineAt200Characters() {
        let shown = RemoteWording.plain(String(repeating: "a", count: 250))
        #expect(shown.count == 200)
        #expect(shown == String(repeating: "a", count: 199) + "…")
    }

    @Test func plainLeavesALineOfExactly200CharactersWhole() {
        let line = String(repeating: "a", count: 200)
        #expect(RemoteWording.plain(line) == line)
    }

    // MARK: - pullRequestLines

    /// GitHub's hint after a push of a new branch, as `PushResult.remoteMessages` gives it (the
    /// `remote:` prefix already gone): the line with the link, and the line that introduces it.
    /// The link itself is `NoticeLinks`'s; these are the notice's words.
    @Test func pullRequestLinesKeepTheLinkLineAndItsIntroduction() {
        let messages = [
            "",
            "Create a pull request for 'b' on GitHub by visiting:",
            "     https://github.com/o/r/pull/new/b",
            "",
        ]
        #expect(
            RemoteWording.pullRequestLines(messages) == [
                "Create a pull request for 'b' on GitHub by visiting:",
                "https://github.com/o/r/pull/new/b",
            ])
    }

    /// The words are capped like every server line; the link `NoticeLinks` finds on the same
    /// line is not.
    @Test func pullRequestLinesCapTheTextButNotTheLink() {
        let base = "https://example.invalid/o/r/pull/new/"
        let url = base + String(repeating: "a", count: 400 - base.count)
        let lines = RemoteWording.pullRequestLines([url])
        #expect(lines.count == 1)
        #expect(lines.first?.count == 200)
        #expect(NoticeLinks.extract(fromRemoteLines: [url]).map(\.absoluteString) == [url])
    }

    /// A line is picked for the link `NoticeLinks` finds on it, not for a scheme on its own.
    @Test func pullRequestLinesPickOnlyLinesWithALink() {
        #expect(RemoteWording.pullRequestLines(["visit https:// later", "ftp://h/x"]).isEmpty)
    }
}
