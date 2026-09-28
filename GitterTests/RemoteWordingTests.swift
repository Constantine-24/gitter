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

    // MARK: - pullRequestLinks

    /// GitHub's hint after a push of a new branch: the link, and the line that introduces it.
    @Test func pullRequestLinksKeepsTheLinkAndItsIntroduction() {
        let messages = [
            "remote: ",
            "remote: Create a pull request for 'b' on GitHub by visiting:",
            "remote:      https://github.com/o/r/pull/new/b",
            "remote: ",
        ]
        #expect(
            RemoteWording.pullRequestLinks(messages) == [
                "remote: Create a pull request for 'b' on GitHub by visiting:",
                "remote:      https://github.com/o/r/pull/new/b",
            ])
    }
}
