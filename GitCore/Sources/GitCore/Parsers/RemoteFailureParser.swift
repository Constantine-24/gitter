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
/// are dropped before any cause is looked for — see `isServerOutput`.
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
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false)
            .map(String.init)
            .filter { !isServerOutput($0) }

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
    /// - `scheme://userinfo@host/…` — always stripped, whatever the userinfo looks like,
    ///   because a token is routinely the *whole* of it (`https://ghp_s3cr3t@github.com/…`).
    /// - `user:secret@host` with no scheme — stripped: a two-part userinfo is a credential
    ///   whatever surrounds it.
    /// - `user@host:path`, scp-style — stripped, recognised by the `:` and a non-empty path
    ///   after the host.
    ///
    /// And what is deliberately **left alone**: `user@host` with nothing after it, which is
    /// both `git@github.com` (the ssh login every remote in the world uses, and no secret) and
    /// the shape of an email address, which a hook's output may well contain. Nothing is lost
    /// by keeping it: a bare ssh username carries no credential, and a token can only reach
    /// that position through a scheme URL, which the first rule already covers.
    ///
    /// Pure, total, and unanchored to any particular message: it walks the text in runs of
    /// URL-ish characters, so quotes, brackets and punctuation around an address survive.
    public static func redactingCredentials(_ text: String) -> String {
        var result = ""
        var run = ""
        for character in text {
            if isRunDelimiter(character) {
                result += redactingUserinfo(in: run)
                run = ""
                result.append(character)
            } else {
                run.append(character)
            }
        }
        return result + redactingUserinfo(in: run)
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
    private static func isServerOutput(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces).hasPrefix("remote:")
    }

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

    /// Characters that cannot be inside a URL or an scp-style address, and so end one:
    /// whitespace and the punctuation git, ssh and hooks quote addresses with.
    private static func isRunDelimiter(_ character: Character) -> Bool {
        character.isWhitespace
            || "'\"<>`()[]".contains(character)
    }

    /// One run of URL-ish text with its userinfo removed — see `redactingCredentials` for which
    /// shapes count and why `git@github.com` is not one of them.
    private static func redactingUserinfo(in run: String) -> String {
        guard run.contains("@") else { return run }

        if let scheme = run.range(of: "://") {
            let rest = run[scheme.upperBound...]
            // `\u{23}` is the number sign, spelled as an escape rather than written between
            // quotes: `ForceFlagScannerTests` refuses to scan a file in which a number sign is
            // followed by a double quote, because that opens a raw string literal its lexer
            // does not handle — and a number sign written as a one-character literal is
            // exactly that pair of characters.
            let authorityEnd =
                rest.firstIndex(where: { $0 == "/" || $0 == "?" || $0 == "\u{23}" })
                ?? rest.endIndex
            let authority = rest[..<authorityEnd]
            guard let at = authority.lastIndex(of: "@") else { return run }
            let host = authority[authority.index(after: at)...]
            guard !host.isEmpty else { return run }
            return String(run[..<scheme.upperBound]) + host + rest[authorityEnd...]
        }

        guard let at = run.lastIndex(of: "@") else { return run }
        let userinfo = run[..<at]
        let host = run[run.index(after: at)...]
        guard !userinfo.isEmpty, !host.isEmpty else { return run }
        // `user:secret@host` — a credential whatever surrounds it.
        if userinfo.contains(":") { return String(host) }
        // `user@host:path`, scp-style: a `:` with something after it. Without that something
        // this is `git@github.com` in a sentence, or an email address, and neither is redacted.
        if let colon = host.firstIndex(of: ":"), host.index(after: colon) < host.endIndex {
            return String(host)
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
