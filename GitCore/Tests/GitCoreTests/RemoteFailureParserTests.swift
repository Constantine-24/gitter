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
    ///
    /// The parser still reads this text, and still reads it correctly; what changed in fix
    /// round 1 is that `CLIGitBackend.fetch` does not *use* the answer when stderr also says
    /// `error: could not fetch <name>`, because one cause cannot speak for several remotes.
    /// The reading matters anyway: the same "do not stop at the first recognised line" rule is
    /// what keeps a single-remote failure honest, since its stderr has a success block in it too.
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

    // MARK: - ssh's askpass line is not a cause

    /// Measured in Task 11's review with real OpenSSH, isolated (no config, no agent, a scratch
    /// passphrase key, `sshd -i` over a pipe): with `SSH_ASKPASS_REQUIRE=force` — which the
    /// streaming runner sets when the environment names no askpass — and no askpass program
    /// installed, ssh prints this line *above* the real cause. It says only that ssh could not
    /// ask; what failed is the line after it, and that is what the parser must find.
    static let askpassCouldNotStart =
        "ssh_askpass: exec(/usr/X11R6/bin/ssh-askpass): No such file or directory"

    static let couldNotRead = """
        fatal: Could not read from remote repository.

        Please make sure you have the correct access rights
        and the repository exists.

        """

    @Test func aRefusedKeyUnderTheAskpassLineIsStillARefusedKey() {
        let stderr = Self.askpassCouldNotStart + "\n"
            + "git@fake.invalid: Permission denied (publickey).\n" + Self.couldNotRead
        #expect(
            RemoteFailureParser.parse(stderr: stderr)
                == .authenticationFailed(url: "git@fake.invalid"))
    }

    @Test func anUnknownHostKeyUnderTheAskpassLineIsStillAnUnknownHostKey() {
        let stderr = Self.askpassCouldNotStart + "\n" + "Host key verification failed.\n"
            + Self.couldNotRead
        #expect(RemoteFailureParser.parse(stderr: stderr) == .hostKeyNotTrusted)
    }

    /// Git's own words — what is shown when the parser recognises nothing, or when `fetch --all`
    /// failed for some remotes only — leave the askpass line out, keep every other line, and
    /// are redacted as before.
    @Test func gitsOwnWordsLeaveTheAskpassLineOut() {
        let stderr = Self.askpassCouldNotStart + "\n"
            + "fatal: unable to access 'https://alice:s3cr3t@host.invalid/x.git/': boom\n"
            + "error: could not fetch broken\n"
        let shown = RemoteFailureParser.gitsOwnWords(stderr)
        #expect(!shown.contains("ssh_askpass"), "\(shown)")
        #expect(!shown.contains("s3cr3t"), "\(shown)")
        #expect(shown.contains("error: could not fetch broken"), "\(shown)")
        #expect(shown.contains("boom"), "\(shown)")
    }

    /// Only ssh's own line: a `remote:` line is the server's, and says what it says.
    @Test func aServerLineThatMentionsTheAskpassIsKept() {
        let stderr = "remote: " + Self.askpassCouldNotStart + "\n"
        #expect(RemoteFailureParser.gitsOwnWords(stderr) == stderr)
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

    // MARK: - Credentials never reach a payload

    /// A remote URL may carry the credential in it — `https://<user>:<token>@host/…` is what
    /// every "clone with a personal access token" guide tells people to write — and git quotes
    /// that URL back verbatim when the fetch fails. Every payload this parser produces is
    /// therefore redacted, because a `RemoteOperationError` ends up in a banner, in a log and
    /// in whatever the user copies out of one.
    ///
    /// Each fixture below is the measured wording with a credential substituted into the URL,
    /// so what is being tested is the redaction and not a new wording.
    @Test(arguments: [
        (
            "fatal: Authentication failed for 'https://alice:ghp_s3cr3t@github.com/acme/p.git/'",
            RemoteOperationError.authenticationFailed(url: "https://github.com/acme/p.git/")
        ),
        (
            "fatal: could not read Username for 'https://alice:ghp_s3cr3t@github.com/acme/p.git': terminal prompts disabled",
            .authenticationNeeded(url: "https://github.com/acme/p.git")
        ),
        (
            "fatal: could not read Password for 'https://ghp_s3cr3t@github.com/acme/p.git': terminal prompts disabled",
            .authenticationNeeded(url: "https://github.com/acme/p.git")
        ),
        ("alice:hunter2@github.com: Permission denied (publickey).", .authenticationFailed(url: "github.com")),
        (
            "fatal: unable to access 'https://alice:hunter2@nope.invalid/r.git/': Could not resolve host: nope.invalid",
            .unreachable("nope.invalid")
        ),
    ])
    func aCredentialInTheURLNeverReachesThePayload(line: String, expected: RemoteOperationError) {
        let parsed = RemoteFailureParser.parse(stderr: line + "\n")
        #expect(parsed == expected)
        #expect(!"\(String(describing: parsed))".contains("s3cr3t"))
        #expect(!"\(String(describing: parsed))".contains("hunter2"))
    }

    /// The `.unreachable` fallback carries git's *whole line* when it can name no host, which
    /// is the one payload that is not a URL — and it is exactly where a URL with a credential
    /// in it rides along. The line survives; the secret does not.
    @Test func theWholeLineFallbackIsRedactedToo() throws {
        let line =
            "fatal: unable to access 'https://alice:hunter2@example.invalid/r.git/': Failed to connect to example.invalid port 443: Network is unreachable"
        guard case .unreachable(let payload)? = RemoteFailureParser.parse(stderr: line + "\n") else {
            Issue.record("expected .unreachable")
            return
        }
        #expect(!payload.contains("hunter2"))
        #expect(!payload.contains("alice"))
        #expect(payload.contains("Network is unreachable"), "\(payload)")
        #expect(payload.contains("https://example.invalid/r.git/"), "\(payload)")
    }

    /// `redactingCredentials` is public because a banner built from raw stderr — which Task 8
    /// shows when this parser recognises nothing — needs the same treatment as a payload, and
    /// a second implementation of it would be a second thing to get wrong.
    @Test(arguments: [
        ("https://alice:ghp_s3cr3t@github.com/acme/p.git", "https://github.com/acme/p.git"),
        ("ssh://alice:hunter2@example.com:22/acme/p.git", "ssh://example.com:22/acme/p.git"),
        // A token as the *whole* userinfo: how GitHub's own instructions spell it.
        ("https://ghp_s3cr3t@github.com/acme/p.git", "https://github.com/acme/p.git"),
        ("'https://alice:hunter2@host/p.git/'", "'https://host/p.git/'"),
        // scp-style, which has no scheme at all.
        ("git@github.com:acme/p.git", "github.com:acme/p.git"),
        ("alice:hunter2@github.com", "github.com"),
        // Not addresses, and not to be mangled: an ssh login in prose, and an email.
        ("git@github.com: Permission denied (publickey).", "git@github.com: Permission denied (publickey)."),
        // A local path that happens to contain a colon and an `@`: userinfo has no `/` in it,
        // so this is a path git is quoting and not an address.
        ("/tmp/gitter-test/a:b@origin.git", "/tmp/gitter-test/a:b@origin.git"),
        ("Author: Colleague <colleague@example.invalid>", "Author: Colleague <colleague@example.invalid>"),
        ("https://github.com/acme/p.git", "https://github.com/acme/p.git"),
        // Ragged input: nothing to redact, nothing to crash on.
        ("@", "@"), ("a@", "a@"), ("@b", "@b"), ("", ""),
    ])
    func redactionStripsUserinfoAndLeavesEverythingElseAlone(text: String, expected: String) {
        #expect(RemoteFailureParser.redactingCredentials(text) == expected)
    }

    /// The doc comment promises that a scheme URL loses its userinfo **whatever the userinfo
    /// looks like**, and it did not: a host written as an IP literal is bracketed
    /// (`scheme://user:pass@[::1]:22/x`, RFC 3986's `IP-literal`), the run walk ended the run at
    /// the `[`, and what was left — `ssh://u:p@` — had an empty host, so it was handed back
    /// **unchanged, credential and all**. Every shape below is one that used to survive or that
    /// guards the fix's edges: a bracketed host, a password with a `%40` or a literal `@` in it,
    /// a URL inside quotes or parentheses, two on one line, and one that a sentence's own
    /// punctuation follows.
    @Test(arguments: [
        ("ssh://u:p@[::1]:22/x", "ssh://[::1]:22/x"),
        ("https://tok@[2001:db8::1]:8443/r.git", "https://[2001:db8::1]:8443/r.git"),
        ("https://alice:hunter2@[fe80::1%25en0]/r.git", "https://[fe80::1%25en0]/r.git"),
        // Percent-encoded `@` in the password: the *last* `@` in the authority is the separator.
        ("https://user:p%40ss@host/", "https://host/"),
        // A literal `@` in the password, with no scheme at all — the same rule, same reason.
        ("user:p@ss@host:path", "host:path"),
        ("'https://u:p@[::1]/x'", "'https://[::1]/x'"),
        ("(https://u:p@[::1]/x)", "(https://[::1]/x)"),
        ("<ssh://u:p@[::1]/x>", "<ssh://[::1]/x>"),
        (
            "tried https://a:b@[::1]/x and https://c:d@[::2]/y",
            "tried https://[::1]/x and https://[::2]/y"
        ),
        ("see https://u:p@[::1]/x.", "see https://[::1]/x."),
        ("see https://u:p@[::1]/x,", "see https://[::1]/x,"),
        ("see 'https://u:p@[::1]/x'", "see 'https://[::1]/x'"),
        // A bracketed host with nothing to redact is not mangled either.
        ("ssh://[::1]:22/x", "ssh://[::1]:22/x"),
        ("[::1]", "[::1]"),
        // Prose in square brackets: the `@` is an ssh login or an email, and neither is a
        // credential — see the rule about `user@host` with nothing after it.
        ("[git@github.com]", "[git@github.com]"),
        ("[see alice@example.invalid]", "[see alice@example.invalid]"),
        // …but a two-part userinfo inside brackets is one, and the bracket survives the strip.
        ("[https://u:p@host/x]", "[https://host/x]"),
        ("[u:p@host:path]", "[host:path]"),
        // Ragged bracket input: nothing to crash on.
        ("[", "["), ("]", "]"), ("[@]", "[@]"), ("[:@]", "[:@]"),
    ])
    func redactionStripsUserinfoWhateverTheHostLooksLike(text: String, expected: String) {
        #expect(RemoteFailureParser.redactingCredentials(text) == expected)
    }

    /// A combining mark, a variation selector or a joiner right after the `@` (or inside the
    /// `://`) glues onto the punctuation as one `Character`, so a walk that compared
    /// `Character`s no longer saw an `@` or a `://` there and handed the run back **with the
    /// password in it**. The walk compares Unicode scalars now, and a mark between the scalars
    /// of `://` is looked through. Each shape below survived before the fix; the last three
    /// guard the other side: decomposed letters (a macOS path is NFD) are not touched.
    @Test(arguments: [
        // A variation selector (Mn) after the `@`.
        ("https://u:secret@\u{FE0F}host/y", "https://host/y"),
        // A combining acute accent (Mn) and a combining grapheme joiner (Mn).
        ("https://u:secret@\u{301}host/y", "https://host/y"),
        ("https://u:secret@\u{34F}host/y", "https://host/y"),
        // An enclosing mark (Me) and a zero-width joiner (Cf, grapheme-extending).
        ("https://u:secret@\u{20E3}host/y", "https://host/y"),
        ("https://u:secret@\u{200D}host/y", "https://host/y"),
        // A mark inside the `://`, in either gap.
        ("https:\u{301}//u:secret@host/y", "https:\u{301}//host/y"),
        ("https:/\u{301}/u:secret@host/y", "https:/\u{301}/host/y"),
        // No scheme: a two-part userinfo, and scp-style.
        ("u:secret@\u{301}host", "host"),
        ("tok@\u{FE0F}host:acme/p.git", "host:acme/p.git"),
        // A mark on the delimiter before the run: it must not glue the run onto the text
        // before it, which here has a `/` that made the userinfo look like a local path.
        ("/tmp/x \u{301}u:secret@host", "/tmp/x host"),
        ("'\u{301}https://u:secret@host/y'", "'\u{301}https://host/y'"),
        // Decomposed letters are text, not an attack, and come back as they were.
        ("/tmp/cafe\u{301}/a:b@origin.git", "/tmp/cafe\u{301}/a:b@origin.git"),
        ("https://host/cafe\u{301}.git", "https://host/cafe\u{301}.git"),
        ("see jose\u{301}@example.invalid", "see jose\u{301}@example.invalid"),
    ])
    func redactionLooksThroughMarksGluedOntoItsPunctuation(text: String, expected: String) {
        let redacted = RemoteFailureParser.redactingCredentials(text)
        #expect(redacted.unicodeScalars.elementsEqual(expected.unicodeScalars), "\(redacted.debugDescription)")
        #expect(!redacted.contains("secret"))
    }

    /// A bracketed host inside the message git actually prints: the whole point of the fix is
    /// that a payload built from such a line carries no secret.
    @Test func aCredentialBeforeABracketedHostNeverReachesThePayload() {
        let line =
            "fatal: Authentication failed for 'https://alice:ghp_s3cr3t@[2001:db8::1]:8443/acme/p.git/'"
        let parsed = RemoteFailureParser.parse(stderr: line + "\n")
        #expect(parsed == .authenticationFailed(
            url: "https://[2001:db8::1]:8443/acme/p.git/"))
        #expect(!"\(String(describing: parsed))".contains("s3cr3t"))
    }

    /// Multi-line stderr is what Task 8 will hand it: every line is treated, the line structure
    /// is kept, and a line with nothing to redact comes back identical.
    @Test func redactionWorksOverWholeStderr() {
        let stderr = """
            Cloning into 'p'...
            remote: Counting objects: 100% (12/12), done.
            fatal: unable to access 'https://alice:ghp_s3cr3t@github.com/acme/p.git/': The requested URL returned error: 403
            fatal: Authentication failed for 'https://alice:ghp_s3cr3t@github.com/acme/p.git/'

            """
        let redacted = RemoteFailureParser.redactingCredentials(stderr)
        #expect(!redacted.contains("s3cr3t"))
        #expect(!redacted.contains("alice"))
        #expect(redacted.contains("remote: Counting objects: 100% (12/12), done."))
        #expect(redacted.contains("fatal: Authentication failed for 'https://github.com/acme/p.git/'"))
        #expect(redacted.split(separator: "\n").count == stderr.split(separator: "\n").count)
    }

    // MARK: - Words that are not a diagnosis

    /// Everything after `remote:` is the *server* talking — a hook's output, a hosting
    /// service's advice — and Tasks 5–7 push through this same parser, where such lines are
    /// routine. A hook that prints `Permission denied (publickey)` is describing its own world,
    /// not this connection, and reading it as a cause gave `.authenticationFailed(url:
    /// "remote")`: a payload that is not even an address.
    @Test(arguments: [
        "remote: Permission denied (publickey).\n",
        "remote: Host key verification failed.\n",
        "remote: fatal: 'x' does not appear to be a git repository\n",
        "remote: ssh: Could not resolve hostname deploy.internal: nodename nor servname provided, or not known\n",
        "remote: error: Authentication failed for 'https://internal/x.git'\n",
    ])
    func aServersOwnOutputIsNeverReadAsThisConnectionsFailure(stderr: String) {
        #expect(RemoteFailureParser.parse(stderr: stderr) == nil)
    }

    /// The refused-key rule took *everything* before `: Permission denied (publickey` as an
    /// address, so any sentence that happened to end that way became one. An address is
    /// `[user@]host`: one word, no spaces, no quotes, no path.
    @Test(arguments: [
        "Warning: the agent said something odd: Permission denied (publickey).\n",
        "debug1: trying key '/x/y': Permission denied (publickey).\n",
        ": Permission denied (publickey).\n",
    ])
    func aSentenceThatMerelyEndsInPermissionDeniedIsNotAnAddress(stderr: String) {
        #expect(RemoteFailureParser.parse(stderr: stderr) == nil)
    }

    /// The unreachable rules read forwards from the first `Could not resolve host: ` in the
    /// text — and a URL is part of that text, so a repository whose *path* contains the phrase
    /// wrote the rest of the sentence into the payload. The payload stops at the first
    /// whitespace or quote, which is where a host name stops.
    @Test func aHostNameStopsWhereAHostNameStops() throws {
        let line =
            "fatal: unable to access 'https://real.invalid/Could not resolve host: sneaky.invalid/x.git/': Could not resolve host: real.invalid"
        guard case .unreachable(let payload)? = RemoteFailureParser.parse(stderr: line + "\n") else {
            Issue.record("expected .unreachable")
            return
        }
        #expect(!payload.contains(" "), "\(payload)")
        #expect(!payload.contains("'"), "\(payload)")
        #expect(!payload.contains("Could not resolve"), "\(payload)")
    }

    /// The same for ssh's wording, which ends its host at a colon — unless the injected text
    /// gets there first.
    @Test func anSSHHostNameStopsAtWhitespaceAsWellAsAtItsColon() throws {
        let line =
            "ssh: Could not resolve hostname real.invalid extra words here: nodename nor servname provided, or not known"
        guard case .unreachable(let payload)? = RemoteFailureParser.parse(stderr: line + "\n") else {
            Issue.record("expected .unreachable")
            return
        }
        #expect(payload == "real.invalid", "\(payload)")
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
