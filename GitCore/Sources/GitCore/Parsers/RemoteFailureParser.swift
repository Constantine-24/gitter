import Foundation

/// Turns git's stderr from a failed network operation into a `RemoteOperationError`.
///
/// Pure and total, on `BranchRefusalParser`'s terms: it never runs anything, and it returns
/// `nil` for anything it does not recognise so the caller falls back to
/// `GitError.commandFailed` with git's own words. `ProcessRunner` sets `LC_ALL=C`, so the
/// English wordings below are what git always prints.
///
/// **Priority, not line order.** The checks are made in a fixed order of specificity over the
/// whole text rather than by walking the lines and taking the first hit, for one measured
/// reason: every ssh failure — an unknown host key, a refused key, a host that does not resolve
/// — ends with the same four lines,
///
/// ```
/// fatal: Could not read from remote repository.
///
/// Please make sure you have the correct access rights
/// and the repository exists.
/// ```
///
/// so a rule that read "the repository exists" as "repository not found" would swallow three
/// different causes at once. That block is deliberately keyed on by nothing here: on its own it
/// says only that *something* went wrong, which is git's words and not a diagnosis.
///
/// The same argument applies in the other direction. `git fetch --all` prints the successful
/// remotes' `From …` blocks *above* the failure (measured on git 2.54), so a scan that stopped
/// at the first line it understood would report a success for a failed fetch.
///
/// **Where the wordings come from.** Measured on git 2.54.0 (Apple Git-157) with `LC_ALL=C`,
/// against `.invalid` host names (RFC 2606: they resolve nowhere, so no packet leaves the
/// machine) and one anonymous ssh connection to a public host made with no key and no agent:
///
/// | cause | measured line |
/// |---|---|
/// | ssh, host does not resolve | `ssh: Could not resolve hostname nosuchhost.invalid: nodename nor servname provided, or not known` |
/// | HTTPS, host does not resolve | `fatal: unable to access 'https://nonexistent.invalid/repo.git/': Could not resolve host: nonexistent.invalid` |
/// | host key not in `known_hosts` | `No ED25519 host key is known for github.com and you have requested strict checking.` / `Host key verification failed.` |
/// | ssh key refused | `git@github.com: Permission denied (publickey).` |
/// | no repository there | `fatal: 'nosuch' does not appear to be a git repository` |
///
/// Three rows of the design document's table remain **VERIFY** and are keyed on its wording
/// unchanged, because producing them needs something this task will not do: a credential the
/// server rejects (`Authentication failed for '<url>'`), an authenticated session with a host
/// that hides the repository (`ERROR: Repository not found.`), and a network that is down or
/// filtered (`Connection timed out` / `Operation timed out` / `Network is unreachable` /
/// `Connection refused`). `RemoteFailureParserTests` marks each of those fixtures as unmeasured.
///
/// **No payload carries a credential.** A remote URL may have the credential written into it —
/// `https://<user>:<token>@host/repo.git`, which is what every "clone with a token" guide says
/// to do — and git quotes that URL back verbatim when the operation fails, so every payload
/// produced here goes through `redactingCredentials` first. That function is public for the
/// other half of the problem: anything this parser does *not* recognise is shown in git's own
/// words, and those words carry the same URL.
///
/// **`remote:` lines are the server talking, and diagnose nothing about this connection.** They
/// are dropped before any cause is looked for — see `isServerOutput`. So is ssh's
/// `ssh_askpass: exec(…)` line, which says only that it could not ask — see `isAskpassNoise`.
///
/// **An unknown remote name is not distinguishable here, and is not guessed at.** Measured:
/// `git fetch nosuch` and a configured remote whose path holds no repository print the *same*
/// sentence, differing only in whether the quoted token is a name or a path — which the parser
/// cannot tell apart, since a remote may be configured with any string as its URL. Both are
/// therefore `.repositoryNotFound`, which is true of both. `.noRemote` is reserved for the
/// names `CLIGitBackend` refuses before git runs, where the answer is known without asking.
public enum RemoteFailureParser {
    public static func parse(stderr: String) -> RemoteOperationError? {
        // Lines beginning `remote:` are dropped before anything is diagnosed: see
        // `isServerOutput`. Everything below therefore speaks about *this* connection.
        let lines = Self.lines(of: stderr)
            .filter { !isServerOutput($0) && !isAskpassNoise($0) }

        // Most specific first. Each `first(where:)` walks the whole text, so a success block
        // above the failure cannot end the search early.
        if let line = lines.first(where: { $0.contains("could not read Username for ") }),
            let url = quoted(in: line, after: "could not read Username for ") {
            return .authenticationNeeded(url: url)
        }
        if let line = lines.first(where: { $0.contains("could not read Password for ") }),
            let url = quoted(in: line, after: "could not read Password for ") {
            return .authenticationNeeded(url: url)
        }
        if let line = lines.first(where: { $0.contains("Authentication failed for ") }),
            let url = quoted(in: line, after: "Authentication failed for ") {
            return .authenticationFailed(url: url)
        }
        // Checked before the refused-key case: a strict-checking failure also aborts the
        // authentication, and "we do not trust this host" is the thing to tell the user.
        if lines.contains(where: { $0.contains("Host key verification failed.") }) {
            return .hostKeyNotTrusted
        }
        if let address = lines.compactMap(refusedKeyAddress).first {
            return .authenticationFailed(url: address)
        }
        if let host = lines.compactMap(unreachableHost).first {
            return .unreachable(host)
        }
        if lines.contains(where: { $0.contains("ERROR: Repository not found.") })
            || lines.contains(where: { $0.contains("does not appear to be a git repository") }) {
            return .repositoryNotFound
        }
        return nil
    }

    /// Whether git gave up on one remote out of several: a line that **begins**
    /// `error: could not fetch `, which is what `fetch --all` prints at the end when one of
    /// them failed (measured on git 2.54, exit 1, with the others' refs already updated).
    ///
    /// It is a predicate rather than a cause because that is exactly what it means: several
    /// operations happened and at least one of them did not. `CLIGitBackend.fetch` uses it to
    /// decide whether a single diagnosed cause would be an honest summary.
    ///
    /// `remote:` lines are excluded — a server-side hook may print anything at all, this
    /// sentence included — and the phrase must begin the line, so `hint: error: could not fetch
    /// …` is git quoting itself rather than reporting.
    static func reportsARemoteThatCouldNotBeFetched(stderr: String) -> Bool {
        lines(of: stderr)
            .contains { !isServerOutput($0) && $0.hasPrefix("error: could not fetch ") }
    }

    /// git's refusals of a remote-management command (B2 Task 3) that mean a refusal Gitter
    /// makes itself before git runs — read, should git get there first (a remote added from a
    /// terminal since the check) — or nil for anything else, which stays git's words. `name` is
    /// the remote the command named. Measured on git 2.54 (R19, R21, R22), each with nothing
    /// written:
    ///
    /// | line | exit | refusal |
    /// |---|---|---|
    /// | `error: remote <n> already exists.` (add, rename) | 3 | `.nameProblem(.exists)` |
    /// | `fatal: '<n>' is not a valid remote name` | 128 | `.nameProblem(.invalid)` |
    /// | `fatal: remote name '<n>' is a subset of existing remote '<x>'` (or `superset`) | 128 | `.nameProblem(.nested(x))` |
    /// | `error: No such remote: '<n>'` (rename, remove) / `error: No such remote '<n>'` (set-url) | 2 | `.noSuchRemote(name)` |
    /// | `warning: remote.<n>.url has multiple values` + `fatal: could not set …` (set-url) | 128 | `.severalURLs` |
    public static func remoteAdminRefusal(stderr: String, name: String) -> RemoteAdminRefusal? {
        let lines = Self.lines(of: stderr).filter { !isServerOutput($0) }
        if lines.contains(where: { $0.hasPrefix("error: remote ") && $0.hasSuffix(" already exists.") }) {
            return .nameProblem(.exists)
        }
        if lines.contains(where: { $0.hasPrefix("fatal: ") && $0.hasSuffix("is not a valid remote name") }) {
            return .nameProblem(.invalid)
        }
        for marker in ["is a subset of existing remote ", "is a superset of existing remote "] {
            if let line = lines.first(where: { $0.hasPrefix("fatal: remote name ") && $0.contains(marker) }),
                let other = quoted(in: line, after: marker) {
                return .nameProblem(.nested(other))
            }
        }
        if lines.contains(where: { $0.hasPrefix("error: No such remote") }) { return .noSuchRemote(name) }
        if lines.contains(where: { $0.hasPrefix("warning: ") && $0.hasSuffix("has multiple values") }),
            lines.contains(where: { $0.hasPrefix("fatal: could not set ") }) {
            return .severalURLs
        }
        return nil
    }

    /// Git's stderr as it is shown when it is not diagnosed — a partial `fetch --all`, or words
    /// the parser does not recognise: redacted (`redactingCredentials`), and without ssh's
    /// askpass line (`isAskpassNoise`), every other line kept as git wrote it.
    public static func gitsOwnWords(_ stderr: String) -> String {
        let kept = lines(of: stderr).filter { !isAskpassNoise($0) }
        return redactingCredentials(kept.joined(separator: "\n"))
    }

    /// `text`'s lines, ending at `\n` **or `\r\n`**, which Swift reads as one `Character` — so
    /// a split on `"\n"` alone does not break there. ssh ends every line `\r\n` (measured
    /// through `git fetch`, stderr a pipe), and those lines came out glued to git's next one: a
    /// refused key was then no longer a line of its own, and nothing found it. A lone `\r` —
    /// git's progress redrawing itself — stays inside its line, as before.
    static func lines(of text: String) -> [String] {
        text.split(omittingEmptySubsequences: false) { $0 == "\n" || $0 == "\r\n" }
            .map(String.init)
    }

    /// Whether `line` is ssh saying that it could not run its askpass program — `ssh_askpass:
    /// exec(/usr/X11R6/bin/ssh-askpass): No such file or directory`, measured in Task 11's
    /// review with real, isolated OpenSSH.
    ///
    /// The streaming runner sets `SSH_ASKPASS_REQUIRE=force` when the environment names no
    /// askpass, so that ssh never stops on a terminal (see `ProcessRunner.runStreaming`); on a
    /// Mac with no askpass installed every passphrase or host-key question then prints this
    /// line, **above** the real cause (`Permission denied (publickey).`, `Host key verification
    /// failed.`). It says only that ssh could not ask, so it is dropped before anything is
    /// diagnosed or shown. A `remote:` line is the server's, and is not this.
    static func isAskpassNoise(_ line: some StringProtocol) -> Bool {
        line.hasPrefix("ssh_askpass: ")
    }

    /// `text` with the credentials taken out of every URL and address in it — the one place
    /// that knows how, and the one every payload above goes through.
    ///
    /// **Why this exists.** `https://<user>:<token>@host/repo.git` is how every "clone with a
    /// personal access token" guide tells people to write a remote, and git quotes the URL back
    /// verbatim when the fetch fails: `fatal: Authentication failed for
    /// 'https://alice:ghp_s3cr3t@github.com/acme/p.git/'`. A `RemoteOperationError` ends up in a
    /// banner, in a log, and in whatever the user copies out of one to ask for help with.
    ///
    /// **It is public because raw stderr needs it too.** Anything this parser does not
    /// recognise is shown in git's own words, and those words carry the same URL. Every banner
    /// built from network stderr — including the progress segments and the stderr of a
    /// *successful* operation — must pass through here first.
    ///
    /// **What counts as userinfo**, in the three shapes git and ssh produce:
    ///
    /// - `scheme://userinfo@host/…` — always stripped, whatever the userinfo *and the host* look
    ///   like, because a token is routinely the *whole* of it
    ///   (`https://ghp_s3cr3t@github.com/…`). "Whatever the host looks like" includes an IP
    ///   literal in square brackets (`ssh://u:p@[::1]:22/x`): that shape used to come back
    ///   unchanged, credential and all — see `isRunDelimiter`.
    /// - `user:secret@host` with no scheme — stripped: a two-part userinfo is a credential
    ///   whatever surrounds it.
    /// - `user@host:path`, scp-style — stripped, recognised by the `:` and a non-empty path
    ///   after the host.
    ///
    /// A userinfo containing a `/` is none of those: it is a local path git is quoting, and
    /// `/tmp/gitter-test/a:b@origin.git` is a directory rather than a credential.
    ///
    /// And what is deliberately **left alone**: `user@host` with nothing after it, which is
    /// both `git@github.com` (the ssh login every remote in the world uses, and no secret) and
    /// the shape of an email address, which a hook's output may well contain. Nothing is lost
    /// by keeping it: a bare ssh username carries no credential, and a token can only reach
    /// that position through a scheme URL, which the first rule already covers.
    ///
    /// **Where this stops, stated out loud.** Only the *userinfo* is a credential to this
    /// function, so two other places a secret can sit in git's output survive it untouched:
    ///
    /// - a **query string** — `https://host/r.git?token=ghp_s3cr3t` comes back whole. Cutting
    ///   the query off every URL would throw away the ordinary parameters a hosting service
    ///   puts there, and telling a secret parameter from a harmless one needs a list of names
    ///   nobody can finish.
    /// - a **header value** — `http.extraHeader=Authorization: Bearer …` is how a CI token is
    ///   usually passed, and git quotes the configuration back in some diagnostics.
    ///
    /// Both are in `docs/BACKLOG.md`. Neither is reachable from anything Gitter itself writes:
    /// it never builds a URL and never sets a header, so a secret can only arrive there through
    /// the user's own configuration.
    ///
    /// Pure, total, and unanchored to any particular message: it walks the text in runs of
    /// URL-ish characters, so quotes, brackets and punctuation around an address survive.
    ///
    /// **Scalars, not `Character`s.** Every comparison here is made on Unicode scalars. A
    /// combining mark, a variation selector or a joiner written straight after `@` — or after
    /// one of the characters of `://` — joins that punctuation into a single `Character`, so a
    /// walk that compared `Character`s saw no `@` and no `://` there and handed the credential
    /// back untouched (`https://u:secret@\u{FE0F}host/y`). A scalar `@` is an `@` whatever
    /// follows it, and the marks between the scalars of `://` are looked through
    /// (`isTransparent`). Decomposed letters (`e` + U+0301, how a macOS path spells `é`) are
    /// ordinary text to this walk and come back as they were.
    ///
    /// Callers that cut a long stream into pieces before redacting — the progress relay forces
    /// a split every 64 KiB of a line with no end — redact each piece on its own, so a
    /// credential straddling such a cut is redacted piece by piece; see `docs/BACKLOG.md`.
    public static func redactingCredentials(_ text: String) -> String {
        var result = String.UnicodeScalarView()
        var run: [Unicode.Scalar] = []
        for scalar in text.unicodeScalars {
            if isRunDelimiter(scalar) {
                result.append(contentsOf: redactingUserinfo(in: run))
                run = []
                result.append(scalar)
            } else {
                run.append(scalar)
            }
        }
        result.append(contentsOf: redactingUserinfo(in: run))
        return String(result)
    }

    /// Whether `line` is the *server* talking rather than this connection.
    ///
    /// Everything git prints with a `remote:` prefix came back over the wire from the other
    /// end — a hook's output, a hosting service's advice — and from Task 5 on, when push joins
    /// this parser, such lines are routine rather than exceptional. A `pre-receive` hook that
    /// prints `Permission denied (publickey)` is describing *its* world, and reading it as a
    /// cause here produced `.authenticationFailed(url: "remote")`: a payload that is not even
    /// an address. They are dropped before any cause is looked for; `PushPorcelainParser` is
    /// where they are read, as the messages they are.
    ///
    /// **Internal rather than private because `PushPorcelainParser` asks the same question.**
    /// It used to ask its own way — `remote:` at column 0, where this one trims first — so a
    /// line git had indented was the server talking to one of them and this connection to the
    /// other. One predicate, one answer: the leading whitespace is not part of the question.
    static func isServerOutput(_ line: some StringProtocol) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix(serverPrefix)
    }

    /// The `remote:` prefix itself, shared with `PushPorcelainParser`, which strips it.
    static let serverPrefix = "remote:"

    /// The address in `<user>@<host>: Permission denied (publickey).`, or `nil` when what
    /// precedes that phrase is not an address at all.
    ///
    /// The check is the point. Taking *everything* before the phrase made an address out of any
    /// sentence that happened to end in it — `debug1: trying key '/x/y': Permission denied
    /// (publickey).` gave `.authenticationFailed(url: "debug1: trying key '/x/y'")`. An address
    /// is `[user@]host`: one word, no spaces, no quotes and no path.
    private static func refusedKeyAddress(in line: String) -> String? {
        guard let range = line.range(of: ": Permission denied (publickey") else { return nil }
        let address = redactingCredentials(String(line[..<range.lowerBound])).trimmed
        return looksLikeAnAddress(address) ? address : nil
    }

    private static func looksLikeAnAddress(_ text: String) -> Bool {
        !text.isEmpty
            && !text.contains(where: { $0.isWhitespace || $0 == "'" || $0 == "\"" || $0 == "/" })
    }

    /// The host `line` says could not be reached, or git's whole line when it named no host —
    /// half a sentence would be worse than all of git's. `nil` when the line is not about
    /// reachability at all.
    private static func unreachableHost(in line: String) -> String? {
        // HTTPS (curl, via git): `… Could not resolve host: nonexistent.invalid`. Measured.
        if let range = line.range(of: "Could not resolve host: ") {
            return hostName(startingAt: line[range.upperBound...]) ?? redactedLine(line)
        }
        // ssh: `ssh: Could not resolve hostname nosuchhost.invalid: nodename nor servname …`.
        // Measured. The host ends at the colon that introduces the resolver's own reason.
        if let range = line.range(of: "Could not resolve hostname ") {
            return hostName(startingAt: line[range.upperBound...]) ?? redactedLine(line)
        }
        // VERIFY, unmeasured: a network that is down, filtered or silent. ssh's shape is
        // `ssh: connect to host <host> port 22: <reason>`; git's HTTPS shape names the host
        // inside a longer curl sentence, so that one falls back to the whole line.
        guard line.contains("Connection timed out") || line.contains("Operation timed out")
            || line.contains("Network is unreachable") || line.contains("Connection refused")
        else { return nil }
        guard let range = line.range(of: "connect to host ") else { return redactedLine(line) }
        return hostName(startingAt: line[range.upperBound...]) ?? redactedLine(line)
    }

    /// The host name at the start of `rest`: everything up to the first whitespace, quote or
    /// colon, and `nil` when that is nothing.
    ///
    /// The bound matters because these rules read *forwards* from a phrase, and the text they
    /// read forwards into includes a URL git is quoting. A repository whose path contains
    /// `Could not resolve host: ` — a file name may — put the rest of git's sentence into the
    /// payload, since the search found the phrase inside the URL and then took everything
    /// after it. A host name stops where a host name stops.
    private static func hostName(startingAt rest: Substring) -> String? {
        let end =
            rest.firstIndex(where: { $0.isWhitespace || $0 == "'" || $0 == "\"" || $0 == ":" })
            ?? rest.endIndex
        let host = redactingCredentials(String(rest[..<end])).trimmed
        return host.isEmpty ? nil : host
    }

    private static func redactedLine(_ line: String) -> String {
        redactingCredentials(line).trimmed
    }

    /// Scalars that cannot be inside a URL or an scp-style address, and so end one:
    /// whitespace and the punctuation git, ssh and hooks quote addresses with.
    ///
    /// **`[` is not one of them, and that is the whole of the IPv6 fix.** A URL's host may be an
    /// IP literal, which RFC 3986 writes in square brackets (`ssh://u:p@[::1]:22/x`); with `[`
    /// ending the run, the run handed to `redactingUserinfo` was `ssh://u:p@`, whose host is
    /// empty — so it bailed and the credential was returned untouched. `]` stays a delimiter,
    /// which costs nothing: it can only appear after the host, so the run that carries the
    /// userinfo is intact, and the walk puts the `]` back itself.
    private static func isRunDelimiter(_ scalar: Unicode.Scalar) -> Bool {
        scalar.properties.isWhitespace || "'\"<>`()]".unicodeScalars.contains(scalar)
    }

    /// Scalars the address matching looks through: combining and enclosing marks (Mn, Me —
    /// variation selectors and U+034F are Mn), spacing marks (Mc) and format characters (Cf —
    /// the joiners, the tag characters), plus the emoji skin-tone modifiers. They are exactly
    /// what can glue onto a preceding `:`, `/` or `@` as one grapheme, and none of them can
    /// turn a credential into something that is not one. Looking through them only ever finds
    /// *more* of an address, so the cost of the list being generous is a redaction, never a
    /// leak.
    private static func isTransparent(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark, .format: true
        default: scalar.properties.isEmojiModifier
        }
    }

    /// One run of URL-ish text with its userinfo removed — see `redactingCredentials` for which
    /// shapes count and why `git@github.com` is not one of them.
    ///
    /// The shapes are matched on `seen`, the run's positions with the transparent scalars left
    /// out, and cut on the run itself: what is kept is the original text, marks included,
    /// except that the userinfo goes together with the `@` and any marks glued onto it.
    private static func redactingUserinfo(in run: [Unicode.Scalar]) -> [Unicode.Scalar] {
        guard run.contains("@") else { return run }
        let seen = run.indices.filter { !isTransparent(run[$0]) }
        func scalar(_ position: Int) -> Unicode.Scalar { run[seen[position]] }
        // Where `seen[position]` starts in the run, or the run's end past the last one.
        func start(_ position: Int) -> Int { position < seen.count ? seen[position] : run.count }

        if let colon = seen.indices.dropLast(2).first(where: {
            scalar($0) == ":" && scalar($0 + 1) == "/" && scalar($0 + 2) == "/"
        }) {
            let rest = colon + 3
            // `\u{23}` is the number sign, spelled as an escape rather than written between
            // quotes: `ForceFlagScannerTests` refuses to scan a file in which a number sign is
            // followed by a double quote, because that opens a raw string literal its lexer
            // does not handle — and a number sign written as a one-character literal is
            // exactly that pair of characters.
            let authorityEnd =
                (rest..<seen.count).first(where: {
                    scalar($0) == "/" || scalar($0) == "?" || scalar($0) == "\u{23}"
                }) ?? seen.count
            guard let at = (rest..<authorityEnd).last(where: { scalar($0) == "@" }),
                at + 1 < authorityEnd
            else { return run }
            return Array(run[..<start(rest)] + run[start(at + 1)...])
        }

        guard let at = seen.indices.last(where: { scalar($0) == "@" }) else { return run }
        var userinfo = 0..<at
        let host = (at + 1)..<seen.count
        // A `[` before the `@` is punctuation the message was written with rather than part of
        // the credential: RFC 3986 excludes `[` from userinfo, and only `]` ends a run here, so
        // a run like `[u:p@host:path` is a bracketed sentence and not an address that begins
        // with a bracket. Everything up to the last one is kept and handed back untouched, so
        // `[u:p@host:path]` redacts to `[host:path]` rather than to `host:path]`.
        var prefix = 0
        if let bracket = userinfo.last(where: { scalar($0) == "[" }) {
            prefix = seen[bracket] + 1
            userinfo = (bracket + 1)..<at
        }
        // A `/` in the userinfo means this is not an authority at all but a path git is
        // quoting — `/tmp/gitter-test/a:b@origin.git` is a directory, not a credential.
        guard !userinfo.isEmpty, !host.isEmpty, !userinfo.contains(where: { scalar($0) == "/" })
        else { return run }
        let redacted = Array(run[..<prefix] + run[start(at + 1)...])
        // `user:secret@host` — a credential whatever surrounds it.
        if userinfo.contains(where: { scalar($0) == ":" }) { return redacted }
        // `user@host:path`, scp-style: a `:` with something after it. Without that something
        // this is `git@github.com` in a sentence, or an email address, and neither is redacted.
        if let colon = host.first(where: { scalar($0) == ":" }), colon + 1 < host.upperBound {
            return redacted
        }
        return run
    }

    /// The text inside the single quotes that follow `prefix`, with any credential taken out of
    /// it. git quotes URLs in these messages and a URL cannot itself contain a `'`, so the
    /// closing quote is the last one on the line — found backwards, which keeps a trailing
    /// `: terminal prompts disabled` out of the result without the parser having to know about
    /// it.
    private static func quoted(in line: String, after prefix: String) -> String? {
        guard let start = line.range(of: prefix),
            let open = line[start.upperBound...].firstIndex(of: "'"),
            let close = line.range(of: "'", options: .backwards),
            open < close.lowerBound
        else { return nil }
        return redactingCredentials(String(line[line.index(after: open)..<close.lowerBound]))
    }
}

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
