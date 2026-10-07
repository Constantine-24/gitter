import GitCore
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

    /// E1 promise 4: a git killed by a signal arrives as `commandFailed` with no exit code (-1)
    /// and words that name the signal, so the banner says the signal — never "git exited with
    /// code -1" — and, for a write, that the remote may have changed.
    @Test func aKilledGitIsWordedAsItsSignalNeverAsAnExitCode() {
        let text = RemoteWording.failure(
            GitError.commandFailed(exitCode: -1, stderr: "git was killed by signal 1."),
            attempt: "push \"v1\" to \"origin\"", isWrite: true)
        #expect(text == "Couldn't push \"v1\" to \"origin\": git was killed by signal 1. The remote may or may not have been updated.")
        #expect(!text.contains("exited with code"))
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

    // MARK: - Final review (B2)

    /// I1: the Publish sheet's caption under each remote is its push (else fetch) URL with the
    /// credential taken out by the URL's structure — the prose redactor stopped at `(`, `'` and
    /// a space, and showed the password (measured in the app).
    @Test(arguments: [
        ("https://u:pa(ss)@example.invalid/o/r.git", "https://example.invalid/o/r.git"),
        ("https://u:pa'ss@example.invalid/o/r.git", "https://example.invalid/o/r.git"),
        ("https://u:pa ss@example.invalid/o/r.git", "https://example.invalid/o/r.git"),
        ("https://u:p)ss@example.invalid/o/r.git", "https://example.invalid/o/r.git"),
        ("ssh://git@example.invalid/o/r.git", "ssh://git@example.invalid/o/r.git"),
        ("/srv/repos/o.git", "/srv/repos/o.git"),
    ])
    func thePublishCaptionHidesTheCredential(url: String, shown: String) {
        let pushOnly = Remote(name: "cred", fetchURL: nil, pushURL: url)
        #expect(RemoteWording.publishRemoteCaption(pushOnly) == shown)
        let fetchOnly = Remote(name: "cred", fetchURL: url, pushURL: nil)
        #expect(RemoteWording.publishRemoteCaption(fetchOnly) == shown)
    }

    /// The push URL is the one shown when there are both: Publish pushes.
    @Test func thePublishCaptionIsThePushURL() {
        let both = Remote(name: "o", fetchURL: "/srv/f.git", pushURL: "https://u:p(w)@example.invalid/p.git")
        #expect(RemoteWording.publishRemoteCaption(both) == "https://example.invalid/p.git")
        #expect(RemoteWording.publishRemoteCaption(Remote(name: "n", fetchURL: nil, pushURL: nil)) == nil)
    }

    /// m9a: Pull acts only on the checked-out branch, so a branch published from its own menu
    /// while another is checked out is not promised Pull.
    @Test func publishingABranchThatIsNotCheckedOutDoesNotPromisePull() {
        #expect(
            RemoteWording.publishWillTrack(remote: "origin", branch: "b", checkedOut: true)
                == "It will then track \"origin/b\", and Pull and Push will use it.")
        let other = RemoteWording.publishWillTrack(remote: "origin", branch: "b", checkedOut: false)
        #expect(other == "It will then track \"origin/b\", and pushing \"b\" will use it; Pull will too once it is checked out.")
        #expect(!other.contains("Pull and Push"))
    }

    /// M1: with Set Upstream… and Edit URL… in the app, no sentence sends the user to a
    /// terminal for them.
    @Test func theUpstreamAndURLSentencesNameTheMenuItems() {
        let noUpstream = RemoteWording.noUpstream("main")
        #expect(noUpstream == "\"main\" has no upstream to pull from. Publish it first, or choose Set Upstream… on \"main\".")
        let branch = Branch(name: "main", sha: String(repeating: "a", count: 40), isHead: true, upstream: "origin/main")
        let gone = RemoteWording.upstreamGone(branch)
        #expect(
            gone == "\"origin/main\", the upstream of \"main\", no longer exists on the remote. Re-publish the branch, "
                + "or choose another with Change Upstream… on \"main\".")
        let noURL = RemoteWording.refused(.noURL("vendor"), branch: "main")
        #expect(noURL.contains("(\(RemoteAdminWording.editURLTitle) on \"vendor\")"))
        for text in [noUpstream, gone] { #expect(!text.contains("terminal"), "\(text)") }
        #expect(!noURL.contains("Edit the remote's URLs"))
    }
}
