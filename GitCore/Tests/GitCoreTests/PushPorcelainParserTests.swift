import Foundation
import Testing

@testable import GitCore

/// `PushPorcelainParser` over the exact bytes git 2.54.0 (Apple Git-157) wrote.
///
/// Every fixture below was captured by Task 5 with `LC_ALL=C`, `GIT_CONFIG_GLOBAL=/dev/null`,
/// `GIT_CONFIG_NOSYSTEM=1`, against a bare repository in a temp directory — stdout and stderr
/// redirected to separate files and read back with `cat -vet`, so the tabs (`^I`) and the
/// trailing padding are what git really emitted and not what a terminal made of them.
@Suite struct PushPorcelainParserTests {
    // MARK: - The nine rows of the design document's push table

    /// A push of a new branch. The `-u` line git adds after the result line is not a result
    /// line: it has no tabs and no refspec, and reading it as one would turn a `.created` into
    /// an `.other`.
    @Test func readsANewBranch() {
        let stdout = """
            To ../origin.git
            *\trefs/heads/topic:refs/heads/topic\t[new branch]
            branch 'topic' set up to track 'origin/topic'.
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/topic")
                == .created)
    }

    @Test func readsUpToDate() {
        let stdout = """
            To ../origin.git
            =\trefs/heads/main:refs/heads/main\t[up to date]
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/main")
                == .upToDate)
    }

    /// The fast-forward flag is a **space**, which is why the flag is taken as the field before
    /// the first tab rather than as "the first non-blank character".
    @Test func readsAFastForwardAndItsTwoShas() {
        let stdout = """
            To ../origin.git
             \trefs/heads/main:refs/heads/main\tc88d49d..1f0e450
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/main")
                == .pushed(from: "c88d49d", to: "1f0e450"))
    }

    /// Three dots, not two, and a trailing `(forced update)`: a different shape from the
    /// fast-forward line and a different outcome.
    @Test func readsAForcedUpdate() {
        let stdout = """
            To ../origin.git
            +\trefs/heads/main:refs/heads/main\t9e9f6af...ece39e3 (forced update)
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/main")
                == .forced(from: "9e9f6af", to: "ece39e3"))
    }

    /// A delete has an **empty source side**, so the refspec field begins with the separator.
    /// The destination is still matched, because a ref name may not contain a `:`.
    @Test func readsADelete() {
        let stdout = """
            To ../origin.git
            -\t:refs/heads/topic\t[deleted]
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/topic")
                == .deleted)
    }

    @Test(arguments: [
        ("[rejected] (fetch first)", PushRejection.fetchFirst),
        ("[rejected] (non-fast-forward)", PushRejection.nonFastForward),
        ("[rejected] (stale info)", PushRejection.staleLease),
    ])
    func readsTheThreeRejectionsGitDiagnoses(summary: String, rejection: PushRejection) {
        let stdout = """
            To ../origin.git
            !\trefs/heads/main:refs/heads/main\t\(summary)
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/main")
                == .rejected(rejection))
    }

    /// The server said no. The reason inside the parentheses is the server's, so it is carried
    /// through — redacted, because a hook may print anything at all, a URL with a token in it
    /// included.
    @Test func readsARemoteRejectionAndKeepsTheServersReason() {
        let stdout = """
            To ../origin.git
            !\trefs/heads/hooky:refs/heads/hooky\t[remote rejected] (pre-receive hook declined)
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/hooky")
                == .rejected(.remoteRejected("pre-receive hook declined")))
    }

    /// A refused delete: the source side is the literal `(delete)` rather than empty, measured
    /// on git 2.54. Splitting the refspec at its first `:` still finds the destination.
    @Test func readsARefusedDeleteWhoseSourceSideIsTheWordDelete() {
        let stdout = """
            To ../origin.git
            !\t(delete):refs/heads/doomed\t[rejected] (stale info)
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/doomed")
                == .rejected(.staleLease))
    }

    // MARK: - Lines that are not about the ref we asked for

    /// Measured: with `push.followTags=true` and an annotated tag on the commit being pushed,
    /// git adds a **second** result line for a ref Gitter never asked about:
    ///
    /// ```
    ///  ^Irefs/heads/big:refs/heads/big^I0764596..21ea6b0
    /// *^Irefs/tags/v9:refs/tags/v9^I[new tag]
    /// ```
    ///
    /// The outcome is the line for our destination and nothing else.
    @Test func ignoresAResultLineForARefWeDidNotAskAbout() {
        let stdout = """
            To ../origin.git
             \trefs/heads/big:refs/heads/big\t0764596..21ea6b0
            *\trefs/tags/v9:refs/tags/v9\t[new tag]
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/big")
                == .pushed(from: "0764596", to: "21ea6b0"))
    }

    /// The other half of the same fact, and the reason the exit code is never consulted.
    /// Measured with two refspecs on one command line: our branch went through while the tag
    /// was rejected, and git exited **1**.
    ///
    /// ```
    ///  ^Irefs/heads/big:refs/heads/big^I655fc24..6b7d719
    /// !^Irefs/tags/v10:refs/tags/v10^I[rejected] (already exists)
    /// ```
    @Test func aRejectedExtraRefDoesNotMakeOurPushARejection() {
        let stdout = """
            To ../origin.git
             \trefs/heads/big:refs/heads/big\t655fc24..6b7d719
            !\trefs/tags/v10:refs/tags/v10\t[rejected] (already exists)
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/big")
                == .pushed(from: "655fc24", to: "6b7d719"))
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/tags/v10")
                == .rejected(.other("!\trefs/tags/v10:refs/tags/v10\t[rejected] (already exists)")))
    }

    /// A destination nothing in the output mentions: nil, which is the caller's signal to look
    /// at stderr instead. `nil` and `.rejected` are not the same answer and must never be
    /// conflated — one means "git said nothing about this ref", the other "git said no".
    @Test func answersNilWhenNoLineNamesOurDestination() {
        let stdout = """
            To ../origin.git
            =\trefs/heads/main:refs/heads/main\t[up to date]
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/other") == nil)
        #expect(PushPorcelainParser.parse(stdout: "", destinationRef: "refs/heads/main") == nil)
    }

    /// Only the destination side is matched. A different branch pushed *to* our name is our
    /// line; our name appearing on the source side of somebody else's line is not.
    @Test func matchesTheDestinationSideAndNotTheSource() {
        let stdout = """
            To ../origin.git
            *\trefs/heads/main:refs/heads/renamed\t[new branch]
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/renamed")
                == .created)
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/main") == nil)
    }

    // MARK: - Lines it cannot read

    /// A line for our ref whose flag or summary this version of Gitter does not know is
    /// `.other(line)` — git's own words, kept whole. Inventing "up to date" for a shape nobody
    /// has seen would be the one answer that could lose work.
    @Test(arguments: [
        "?\trefs/heads/main:refs/heads/main\t[something new]",
        "=\trefs/heads/main:refs/heads/main\t[surprising]",
        "*\trefs/heads/main:refs/heads/main\tnot a bracket",
        " \trefs/heads/main:refs/heads/main\tnodotshere",
        "+\trefs/heads/main:refs/heads/main\taaa..bbb",
        "-\trefs/heads/main:refs/heads/main\t[not deleted]",
        "!\trefs/heads/main:refs/heads/main\t[rejected] (some future reason)",
    ])
    func anUnreadableLineForOurRefIsTheLineItself(line: String) {
        let stdout = "To ../origin.git\n\(line)\nDone\n"
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/main")
                == .rejected(.other(line)))
    }

    /// A `[remote rejected]` whose reason is whatever the server chose to send. It is carried
    /// through, and a credential written into it is taken out on the way.
    @Test func redactsTheServersReason() {
        let stdout = """
            To ../origin.git
            !\trefs/heads/main:refs/heads/main\t[remote rejected] (see https://alice:ghp_s3cr3t@example.invalid/p)
            Done

            """
        #expect(PushPorcelainParser.parse(stdout: stdout, destinationRef: "refs/heads/main")
                == .rejected(.remoteRejected("see https://example.invalid/p")))
    }

    /// Neither the framing lines nor a `-u` notice is ever mistaken for a result line, whatever
    /// destination is asked for.
    @Test(arguments: [
        "To ../origin.git",
        "Done",
        "branch 'refs/heads/main' set up to track 'origin/main'.",
        "",
    ])
    func neverReadsAFramingLineAsAResult(line: String) {
        #expect(PushPorcelainParser.parse(stdout: line + "\n", destinationRef: "refs/heads/main")
                == nil)
    }

    // MARK: - What the server said

    /// `remoteMessages` over the exact stderr a `post-receive` hook produced. Note the trailing
    /// padding git adds to each non-empty line (eight spaces here, `cat -vet` showed them), the
    /// blank lines the hook printed, and the three-space indent in front of the URL — which is
    /// the hook's own layout and is kept, while the padding behind it is not.
    ///
    /// ```
    /// remote: Create a pull request for 'hooky' on Example:        $
    /// remote: $
    /// remote:    https://example.invalid/acme/p/pull/new/hooky        $
    /// remote: $
    /// ```
    @Test func readsTheServersLinesKeepingItsIndentAndDroppingGitsPadding() {
        let stderr = """
            remote: Create a pull request for 'hooky' on Example:\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}
            remote:\u{20}
            remote:    https://example.invalid/acme/p/pull/new/hooky\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}
            remote:\u{20}

            """
        #expect(PushPorcelainParser.remoteMessages(stderr: stderr) == [
            "Create a pull request for 'hooky' on Example:",
            "",
            "   https://example.invalid/acme/p/pull/new/hooky",
            "",
        ])
    }

    /// The `pre-receive` fixture, in git's exact bytes: one message, eight spaces of padding.
    @Test func readsADecliningHooksOneLine() {
        let stderr = """
            Enumerating objects: 15, done.
            remote: policy: no pushes on fridays\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}\u{20}
            error: failed to push some refs to '../origin.git'

            """
        #expect(PushPorcelainParser.remoteMessages(stderr: stderr)
                == ["policy: no pushes on fridays"])
    }

    /// Everything git says about *this* end is not the server talking, and does not appear.
    @Test func keepsGitsOwnLinesOutOfTheServersMessages() {
        let stderr = """
            Enumerating objects: 3, done.
            error: failed to push some refs to '../origin.git'
            hint: Updates were rejected because the remote contains work that you do not
            To ../origin.git

            """
        #expect(PushPorcelainParser.remoteMessages(stderr: stderr) == [])
    }

    /// Server-side progress is separated by `\r` rather than `\n` (that is how git's counters
    /// work everywhere else), so the split is on both. Not reachable over the local transport
    /// this suite uses, which is exactly why it is a fixture.
    @Test func splitsTheServersLinesOnCarriageReturnsToo() {
        let stderr = "remote: Resolving deltas:  50% (1/2)\rremote: Resolving deltas: 100% (2/2)\r\n"
        #expect(PushPorcelainParser.remoteMessages(stderr: stderr) == [
            "Resolving deltas:  50% (1/2)",
            "Resolving deltas: 100% (2/2)",
        ])
    }

    /// A credential written into a remote URL reaches the banner through these messages as
    /// readily as through an error, so they go through the same redaction.
    @Test func redactsTheServersMessages() {
        let stderr = "remote: pushed to https://alice:ghp_s3cr3t@example.invalid/acme/p.git\n"
        #expect(PushPorcelainParser.remoteMessages(stderr: stderr)
                == ["pushed to https://example.invalid/acme/p.git"])
    }

    /// A line that merely *contains* `remote:` is git quoting something, not the server
    /// speaking; only a line that begins with it is a message.
    @Test func onlyALineThatBeginsWithThePrefixIsAMessage() {
        let stderr = "hint: the remote: prefix is not at the start here\n"
        #expect(PushPorcelainParser.remoteMessages(stderr: stderr) == [])
    }
}
