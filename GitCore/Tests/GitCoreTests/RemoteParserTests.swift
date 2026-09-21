import Foundation
import Testing

@testable import GitCore

/// `git remote -v` prints one line per URL: `<name>\t<url> (fetch)` / `<name>\t<url> (push)`.
/// The separator after the name is a TAB; the URL itself is **not** quoted, so it may contain
/// spaces and only the trailing ` (fetch)` / ` (push)` marks where it ends.
@Suite struct RemoteParserTests {
    @Test func theTwoLineFixtureBecomesOneRemoteWithBothURLs() {
        let output = """
            origin\tgit@github.com:penzin/gitter.git (fetch)
            origin\tgit@github.com:penzin/gitter.git (push)

            """
        let remotes = RemoteParser.parse(output)
        #expect(remotes == [Remote(name: "origin",
                                   fetchURL: "git@github.com:penzin/gitter.git",
                                   pushURL: "git@github.com:penzin/gitter.git")])
        #expect(remotes.first?.id == "origin")
    }

    @Test func aDifferentPushURLIsKeptApartFromTheFetchURL() {
        let output = """
            up\t/tmp/up.git (fetch)
            up\t/tmp/pushA.git (push)

            """
        let remote = RemoteParser.parse(output).first
        #expect(remote?.fetchURL == "/tmp/up.git")
        #expect(remote?.pushURL == "/tmp/pushA.git")
    }

    /// `git remote set-url --add --push` gives one remote several push URLs. Gitter pushes to
    /// the remote by name and lets git fan out, so the first one is what it shows.
    @Test func severalPushURLsKeepTheFirst() {
        let output = """
            up\t/tmp/up.git (fetch)
            up\t/tmp/pushA.git (push)
            up\t/tmp/pushB.git (push)

            """
        let remote = RemoteParser.parse(output).first
        #expect(remote?.fetchURL == "/tmp/up.git")
        #expect(remote?.pushURL == "/tmp/pushA.git")
    }

    /// Each URL is exactly what git printed on that kind of line; neither is copied into the
    /// other. A remote Gitter cannot fetch from must not look as though it can.
    @Test func aRemoteWithOnlyAFetchLineHasNoPushURL() {
        let remote = RemoteParser.parse("origin\t/tmp/o.git (fetch)\n").first
        #expect(remote == Remote(name: "origin", fetchURL: "/tmp/o.git", pushURL: nil))
    }

    @Test func aRemoteWithOnlyAPushLineHasNoFetchURL() {
        let remote = RemoteParser.parse("origin\t/tmp/o.git (push)\n").first
        #expect(remote == Remote(name: "origin", fetchURL: nil, pushURL: "/tmp/o.git"))
    }

    /// Measured: `git config --add remote.pushonly.pushurl <path>` makes `git remote -v` print
    /// a bare name-only line *and* a `(push)` line for that remote — the name-only line is the
    /// fetch side saying there is no fetch URL.
    @Test func aPushURLOnlyRemoteHasNoFetchURL() {
        let output = """
            pushonly\t
            pushonly\t/tmp/o.git (push)

            """
        #expect(RemoteParser.parse(output)
                == [Remote(name: "pushonly", fetchURL: nil, pushURL: "/tmp/o.git")])
    }

    /// Measured: a remote configured without any `url` (only a fetch refspec) prints one
    /// name-only line. It has no URL of either kind, so nothing can be fetched or pushed
    /// through it; it is left out, and the remotes around it are unaffected.
    @Test func aRemoteWithNoURLAtAllIsLeftOut() {
        let output = """
            nourl\t
            origin\t/tmp/o.git (fetch)
            origin\t/tmp/o.git (push)

            """
        #expect(RemoteParser.parse(output).map(\.name) == ["origin"])
    }

    /// A stray carriage return before the newline must not end up inside the URL — or, on a
    /// `(fetch)`/`(push)` line, stop the suffix from matching and drop the remote entirely.
    @Test func aTrailingCarriageReturnIsIgnored() {
        let output = "origin\t/tmp/o.git (fetch)\r\norigin\t/tmp/o.git (push)\r\n"
        #expect(RemoteParser.parse(output)
                == [Remote(name: "origin", fetchURL: "/tmp/o.git", pushURL: "/tmp/o.git")])
    }

    @Test func noRemotesProducesAnEmptyArray() {
        #expect(RemoteParser.parse("") == [])
        #expect(RemoteParser.parse("\n") == [])
    }

    /// A remote's name may contain a slash, which is exactly what the old
    /// "split the branch name on `/`" rule got wrong.
    @Test func aNameContainingASlashIsKeptWhole() {
        let output = """
            up/stream\t/tmp/upstream.git (fetch)
            up/stream\t/tmp/upstream.git (push)

            """
        #expect(RemoteParser.parse(output).map(\.name) == ["up/stream"])
    }

    /// Measured: git does not quote a URL containing spaces.
    @Test func aURLContainingSpacesSurvives() {
        let remote = RemoteParser.parse("spacey\t/tmp/dir with spaces.git (fetch)\n").first
        #expect(remote?.fetchURL == "/tmp/dir with spaces.git")
    }

    @Test func severalRemotesKeepGitsOrder() {
        let output = """
            origin\t/tmp/o.git (fetch)
            origin\t/tmp/o.git (push)
            up/stream\t/tmp/u.git (fetch)
            up/stream\t/tmp/u.git (push)

            """
        #expect(RemoteParser.parse(output).map(\.name) == ["origin", "up/stream"])
    }

    @Test func linesWithoutATabOrAKindSuffixAreSkipped() {
        #expect(RemoteParser.parse("no-tab-here (fetch)\n") == [])
        #expect(RemoteParser.parse("origin\t/tmp/o.git\n") == [])
    }
}
