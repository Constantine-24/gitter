import Foundation
import Testing

@testable import GitCore

/// `RemoteFailureParser` against the captured stderr of every failure the design document
/// tables — the fixtures, not the network.
///
/// Where each fixture comes from is recorded on the test that uses it. Most were measured on
/// **git 2.54.0 (Apple Git-157)** with `LC_ALL=C` and `GIT_TERMINAL_PROMPT=0` during Task 4;
/// the handful that need a credential or a broken network are marked **VERIFY** and are the
/// design document's wording, unchanged. Nothing here runs git and nothing here reaches a
/// host: a parser that could only be tested against a live server would be untestable.
@Suite struct RemoteFailureParserTests {
    // MARK: - Measured

    /// Measured: a remote at `git@nosuchhost.invalid:acme/repo.git` fetched with
    /// `GIT_SSH_COMMAND="ssh -o BatchMode=yes …"`, exit 128. `.invalid` is reserved by RFC 2606
    /// and resolves nowhere, so this needed no network at all.
    @Test func sshCannotResolveAHostname() {
        let stderr = """
            ssh: Could not resolve hostname nosuchhost.invalid: nodename nor servname provided, or not known
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            and the repository exists.

            """
        #expect(RemoteFailureParser.parse(stderr: stderr) == .unreachable("nosuchhost.invalid"))
    }

    /// Measured: a remote at `https://nonexistent.invalid/repo.git`, exit 128. git appends a
    /// slash to the URL it reports; the host is what the parser carries, so that does not
    /// matter here.
    @Test func httpsCannotResolveAHost() {
        let stderr = """
            fatal: unable to access 'https://nonexistent.invalid/repo.git/': Could not resolve host: nonexistent.invalid

            """
        #expect(RemoteFailureParser.parse(stderr: stderr) == .unreachable("nonexistent.invalid"))
    }

    /// Measured against `github.com` with `StrictHostKeyChecking=yes`,
    /// `UserKnownHostsFile=/dev/null` and no identity at all
    /// (`IdentitiesOnly=yes -o IdentityFile=/dev/null -o IdentityAgent=none`): one anonymous
    /// TCP connection, no key offered, nothing authenticated. The design document's guessed
    /// wording — `Host key verification failed.` — is confirmed, and git 2.54 prints ssh's
    /// more specific line above it.
    @Test func anUnknownHostKey() {
        let stderr = """
            No ED25519 host key is known for github.com and you have requested strict checking.
            Host key verification failed.
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            and the repository exists.

            """
        #expect(RemoteFailureParser.parse(stderr: stderr) == .hostKeyNotTrusted)
    }

    /// Measured with the same no-identity options as above: ssh offers nothing, the server
    /// refuses, and git prints the address it tried. Confirms the design document's guess.
    ///
    /// A key that exists but whose passphrase cannot be asked for ends the same way — with no
    /// tty and no askpass there is no third outcome — which is why one case covers both halves
    /// of the "ssh key refused / passphrase needed" row.
    @Test func anSSHKeyTheServerRefuses() {
        let stderr = """
            git@github.com: Permission denied (publickey).
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            and the repository exists.

            """
        #expect(
            RemoteFailureParser.parse(stderr: stderr) == .authenticationFailed(url: "git@github.com"))
    }

    /// Measured twice, with identical wording: `git fetch nosuch` (no such remote configured)
    /// and a configured remote whose path holds no repository. The quoted token is whatever
    /// git was given — a bare name in the first case, a path in the second — so **the wording
    /// cannot tell "no such remote" from "that path is not a repository"**, and neither can
    /// this parser. It answers the question both really are: there is no repository there.
    @Test(arguments: [
        "fatal: 'nosuch' does not appear to be a git repository",
        "fatal: '/tmp/gitter-test-1234/not-a-repo' does not appear to be a git repository",
    ])
    func aPathThatIsNotARepository(firstLine: String) {
        let stderr = """
            \(firstLine)
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            and the repository exists.

            """
        #expect(RemoteFailureParser.parse(stderr: stderr) == .repositoryNotFound)
    }

    /// Measured: `git fetch --all` with one good local remote and one on an unresolvable host.
    /// git exits **1** (not 128), the good remote's refs are already updated, and its `From …`
    /// block sits in stderr *above* the failure. The parser must read past it — a line-by-line
    /// scan that stopped at the first thing it recognised would report the success.
    @Test func aPartialFetchOfEveryRemoteIsReadPastItsSuccesses() {
        let stderr = """
            From /tmp/gitter-test-1234-origin
               cd39b56..7fdb355  main       -> origin/main
            fatal: unable to access 'https://nonexistent.invalid/repo.git/': Could not resolve host: nonexistent.invalid
            error: could not fetch broken

            """
        #expect(RemoteFailureParser.parse(stderr: stderr) == .unreachable("nonexistent.invalid"))
    }

    /// Every ssh failure above ends with the same four lines — "Please make sure you have the
    /// correct access rights / and the repository exists." — so keying `.repositoryNotFound` on
    /// *that* sentence would swallow the host key, the refused key and the unresolvable host
    /// all at once. This is the regression test for that: the specific cause wins.
    @Test func theGenericAccessRightsBlockNeverOutranksTheRealCause() {
        let tail = """
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            and the repository exists.

            """
        #expect(
            RemoteFailureParser.parse(stderr: "Host key verification failed.\n" + tail)
                == .hostKeyNotTrusted)
        #expect(
            RemoteFailureParser.parse(stderr: "git@github.com: Permission denied (publickey).\n" + tail)
                == .authenticationFailed(url: "git@github.com"))
        // The tail on its own says only that *something* went wrong, which is git's words and
        // not a case this parser claims to know.
        #expect(RemoteFailureParser.parse(stderr: tail) == nil)
    }

    // MARK: - From the design document, not re-measured

    /// The design document's measured row, unchanged: a credential git cannot ask for because
    /// `GIT_TERMINAL_PROMPT=0` and stdin is `/dev/null`. Not re-measured in Task 4 — the only
    /// reachable probe would have gone through this machine's own `url.…insteadOf` rewrite and
    /// its ssh agent, which is exactly what a measurement must not touch.
    @Test(arguments: ["Username", "Password"])
    func aCredentialGitCannotAskFor(field: String) {
        let stderr = """
            fatal: could not read \(field) for 'https://github.com/acme/private.git': terminal prompts disabled

            """
        #expect(
            RemoteFailureParser.parse(stderr: stderr)
                == .authenticationNeeded(url: "https://github.com/acme/private.git"))
    }

    /// **VERIFY** — still unmeasured: producing it means presenting a credential the server
    /// rejects, which needs credentials this task has none of and must not invent.
    @Test func aRejectedHTTPSCredential() {
        let stderr = """
            fatal: Authentication failed for 'https://github.com/acme/private.git/'

            """
        #expect(
            RemoteFailureParser.parse(stderr: stderr)
                == .authenticationFailed(url: "https://github.com/acme/private.git/"))
    }

    /// **VERIFY** — still unmeasured: GitHub answers `ERROR: Repository not found.` only to an
    /// *authenticated* ssh session, which this task cannot open. The local half of the same row
    /// (`does not appear to be a git repository`) is measured above.
    @Test func aRepositoryTheServerWillNotAdmitTo() {
        let stderr = """
            ERROR: Repository not found.
            fatal: Could not read from remote repository.

            Please make sure you have the correct access rights
            and the repository exists.

            """
        #expect(RemoteFailureParser.parse(stderr: stderr) == .repositoryNotFound)
    }

    /// **VERIFY** — still unmeasured: a dropped or filtered network cannot be staged from a
    /// test, and faking one with a firewall rule is not something this task does to a
    /// developer's machine. Three wordings are keyed on, and the payload falls back to git's
    /// own line whenever no host name can be read out of it.
    @Test(arguments: [
        ("ssh: connect to host example.invalid port 22: Operation timed out", "example.invalid"),
        ("ssh: connect to host example.invalid port 22: Connection refused", "example.invalid"),
        (
            "fatal: unable to access 'https://example.invalid/r.git/': Failed to connect to example.invalid port 443: Network is unreachable",
            "fatal: unable to access 'https://example.invalid/r.git/': Failed to connect to example.invalid port 443: Network is unreachable"
        ),
    ])
    func aHostThatCannotBeReached(line: String, payload: String) {
        #expect(RemoteFailureParser.parse(stderr: line + "\n") == .unreachable(payload))
    }

    // MARK: - Everything else

    /// Total and honest: anything the tables do not cover is `nil`, and the caller rethrows
    /// `GitError.commandFailed` with git's own words rather than a guess.
    @Test(arguments: [
        "",
        "\n\n",
        "fatal: the remote end hung up unexpectedly\n",
        "error: RPC failed; curl 92 HTTP/2 stream 5 was not closed cleanly\n",
        "fatal: early EOF\n",
        "fatal: index-pack failed\n",
        "From /tmp/x\n   aaaaaaa..bbbbbbb  main       -> origin/main\n",
    ])
    func anythingUnrecognisedIsNil(stderr: String) {
        #expect(RemoteFailureParser.parse(stderr: stderr) == nil)
    }

    /// Pure and total in the strong sense: no input crashes it and no input runs anything.
    @Test func survivesTruncatedAndRaggedInput() {
        for stderr in [
            "fatal: could not read Username for '",
            "fatal: could not read Username for 'https://x/': ",
            "ssh: Could not resolve hostname ",
            "ssh: Could not resolve hostname :",
            ": Permission denied (publickey).",
            "fatal: Authentication failed for ",
            "fatal: '' does not appear to be a git repository",
        ] {
            _ = RemoteFailureParser.parse(stderr: stderr)
        }
    }
}
