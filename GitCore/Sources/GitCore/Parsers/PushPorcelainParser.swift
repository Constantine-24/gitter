import Foundation

/// Turns `git push --porcelain`'s stdout into a `PushOutcome`, and its stderr's `remote:` lines
/// into the server's own words.
///
/// Pure and total, on `RemoteFailureParser`'s terms: it runs nothing, and it answers `nil` for
/// output that says nothing about the ref being asked about so the caller can fall back to
/// git's stderr. `ProcessRunner` sets `LC_ALL=C`, so the wordings below are what git prints.
///
/// **The exit code is never consulted, and this is the type that makes that possible.** Every
/// rejection exits 1, so the code cannot tell a `(fetch first)` from a declining hook. Worse,
/// the code is not even *about* our ref: measured on git 2.54 with two refspecs on one command
/// line, our branch went through while a tag was refused and git exited **1** —
///
/// ```
/// $ git push --porcelain --progress origin refs/heads/big:refs/heads/big refs/tags/v10:refs/tags/v10
///  ^Irefs/heads/big:refs/heads/big^I655fc24..6b7d719
/// !^Irefs/tags/v10:refs/tags/v10^I[rejected] (already exists)
/// EXIT=1
/// ```
///
/// — so an outcome read from the exit code would have called a successful push a rejection.
/// The outcome is the line for the destination that was asked for, and nothing else.
///
/// **Extra result lines are not an error and not our business.** A push can carry result lines
/// for refs the caller never named: measured, `push.followTags=true` with an annotated tag on
/// the commit being pushed adds `*\trefs/tags/v9:refs/tags/v9\t[new tag]` beside the branch's
/// line. Those refs were not asked about, nothing in Gitter shows them, and they are skipped.
/// (`remote.<name>.push` does *not* add any: measured, an explicit refspec on the command line
/// replaces it outright.)
///
/// **Corrected in Task 6's fix round: no push *Gitter* makes can produce such a line any
/// more.** All four vectors in `CLIGitBackend+Push.swift` now carry `--no-follow-tags`, which
/// was measured to defeat `push.followTags=true` on every one of them — because a tag nobody
/// named reaching somebody's server is a change no confirmation sheet described, whatever this
/// parser does with the line. The skipping behaviour stays exactly as it is: this is a pure
/// function over stdout, it is handed output from a vector it cannot see, and a guarantee that
/// lives in another file is not one it may assume.
///
/// **The rows.** Measured by Task 5 on git 2.54.0 (Apple Git-157) with `LC_ALL=C`, stdout
/// captured to a file and read back with `cat -vet` so the tabs are git's and not a terminal's:
///
/// | situation | flag | summary | exit |
/// |---|---|---|---|
/// | new branch | `*` | `[new branch]` | 0 |
/// | up to date | `=` | `[up to date]` | 0 |
/// | fast-forward | ` ` (a space) | `c88d49d..1f0e450` | 0 |
/// | forced by a lease | `+` | `9e9f6af...ece39e3 (forced update)` | 0 |
/// | deleted | `-` | `[deleted]`, source side empty | 0 |
/// | never fetched | `!` | `[rejected] (fetch first)` | 1 |
/// | behind the tracking ref | `!` | `[rejected] (non-fast-forward)` | 1 |
/// | lease does not match | `!` | `[rejected] (stale info)` | 1 |
/// | hook said no | `!` | `[remote rejected] (pre-receive hook declined)` | 1 |
///
/// A result line is `<flag>\t<src>:<dst>\t<summary>`, between a `To <url>` line and `Done`. The
/// flag is the field before the first tab because for a fast-forward it *is a space*, which
/// "the first non-blank character" would have thrown away. Both the flag and the summary are
/// checked: `=` with a summary nobody has seen is `.other`, not "up to date".
///
/// **Why a line this cannot read is a rejection rather than a success, and why that is safe.**
/// `.rejected(.other(line))` is the honest answer only if every line reaching here is git's
/// own — a server that could write onto this stdout could otherwise forge `[up to date]` for a
/// push it had refused. It cannot: **stdout belongs to the local git, and everything the far
/// end says arrives on stderr behind a `remote:` prefix.** Measured on git 2.54 with a
/// `pre-receive` hook printing a fake porcelain line and `Done`:
///
/// ```
/// stdout: To ../origin.git
///         !^Irefs/heads/hooky:refs/heads/hooky^I[remote rejected] (pre-receive hook declined)
///         Done
/// stderr: remote: =^Irefs/heads/hooky:refs/heads/hooky^I[up to date]        $
///         remote: Done        $
///         error: failed to push some refs to '../origin.git'$
/// ```
///
/// The forgery arrived in `remoteMessages`, where it is somebody else's text and is rendered
/// as such; stdout carried git's own verdict, unchanged. So an unreadable line is a line git
/// wrote that this version does not know, and refusing to guess at it can only be over-cautious
/// — never a rejection read as a success.
public enum PushPorcelainParser {
    /// The outcome for `destinationRef`, or `nil` when no result line names it.
    ///
    /// `nil` and `.rejected` are different answers and must never be conflated: `nil` means git
    /// said nothing at all about this ref — it failed before it got that far, and stderr is
    /// where the reason is — while a `.rejected` is the server having considered it and refused.
    ///
    /// **`destinationRef` must be a full ref name**, and anything else matches nothing at all.
    /// The empty string is why the rule is written down: a delete's result line has an empty
    /// *source* side (`-\t:refs/heads/topic\t[deleted]`), and a line whose *destination* side is
    /// empty is that shape seen from the other end — so an empty destination matched
    /// `=\t:\t[up to date]` and answered `.upToDate` for a ref nobody had named.
    /// `CLIGitBackend.push` refuses such a destination before git runs, so this is a backstop;
    /// a parser that claims to be total should not need its caller to have been careful. The
    /// prefix is `refs/` rather than `refs/heads/` because a tag's line is read the same way.
    public static func parse(stdout: String, destinationRef: String) -> PushOutcome? {
        guard destinationRef.hasPrefix("refs/") else { return nil }
        for line in lines(of: stdout) {
            let fields = line.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            // Three fields is what a result line has. `To …`, `Done` and the `-u` notice
            // (`branch 'topic' set up to track 'origin/topic'.`) have no tabs at all, which is
            // what keeps them out without this having to recognise any of them by name.
            guard fields.count == 3 else { continue }
            let flag = String(fields[0])
            // A ref name may not contain a `:`, so the first one is always the separator — and
            // that is true of the two shapes a delete's source side takes as well, the empty
            // one (`:refs/heads/topic`) and the literal `(delete)`.
            guard let colon = fields[1].firstIndex(of: ":") else { continue }
            guard fields[1][fields[1].index(after: colon)...] == destinationRef else { continue }
            return outcome(flag: flag, summary: String(fields[2]), line: String(line))
        }
        return nil
    }

    /// The server's own lines, in order: everything git prefixed with `remote:`, with that
    /// prefix and git's trailing padding removed, and credentials taken out.
    ///
    /// **What is removed and what is not.** git writes `remote: ` — the word, a colon and one
    /// space — and then pads the line out with spaces to erase the longer one before it
    /// (measured: `remote: policy: no pushes on fridays        ` with eight of them). The
    /// prefix, that one space and the trailing padding go. Leading spaces *after* the padding's
    /// counterpart do not: they are the server's own indentation, and a hosting service's
    /// pull-request block is laid out with them —
    ///
    /// ```
    /// remote: Create a pull request for 'hooky' on Example:        $
    /// remote: $
    /// remote:    https://example.invalid/acme/p/pull/new/hooky        $
    /// ```
    ///
    /// A line the server left blank comes through as `""`, kept in place rather than dropped:
    /// it is that block's layout, and joining the two paragraphs would be this parser editing
    /// somebody else's text.
    ///
    /// The split is on `\r` as well as `\n` because that is how git separates its counters
    /// everywhere else, and a server's `Resolving deltas:` progress arrives the same way. (Not
    /// over the local transport the test suite uses, which never produces one — hence the
    /// fixture in `PushPorcelainParserTests`.)
    ///
    /// Redaction is not optional here. These lines go straight into a banner, and a hook is
    /// free to print a URL with a token in it; `RemoteFailureParser.redactingCredentials` is the
    /// one place that knows how to take one out.
    public static func remoteMessages(stderr: String) -> [String] {
        lines(of: stderr).compactMap { line in
            guard RemoteFailureParser.isServerOutput(line) else { return nil }
            // Whatever git put in front of the prefix is git's, not the server's; the server's
            // own indentation begins after it.
            var body = line.drop(while: { $0.isWhitespace })
                .dropFirst(RemoteFailureParser.serverPrefix.count)
            if body.first == " " { body = body.dropFirst() }
            while body.last == " " || body.last == "\t" { body = body.dropLast() }
            return RemoteFailureParser.redactingCredentials(String(body))
        }
    }

    /// git's own `error:` lines — the other half of what a push writes to stderr, and the half
    /// nothing used to read.
    ///
    /// **Why they are carried at all.** `push -u` whose configuration could not be written
    /// exits **0** with the branch on the server and the whole failure in two lines that are
    /// not `remote:` and not a porcelain result (measured on git 2.54 with `.git/config` made
    /// unwritable):
    ///
    /// ```
    /// error: could not lock config file .git/config: Permission denied
    /// error: unable to write upstream branch configuration
    /// ```
    ///
    /// A caller that read only the result line was told `.created`, which is true, beside an
    /// upstream that does not exist. See `PushResult.errorLines`.
    ///
    /// The line is kept **whole**, `error: ` and all: the prefix is what says these are git's
    /// words about this end rather than the server's, and a banner that dropped it would read
    /// as Gitter's own sentence. Server lines are excluded by the shared predicate — a hook may
    /// print `error:` too, and that is `remoteMessages`' business — and the prefix must begin
    /// the line, so `hint: error: …` is git quoting itself. Trailing padding goes, and the line
    /// is redacted: git quotes the remote's URL in these, and a URL can carry a token.
    public static func errorLines(stderr: String) -> [String] {
        lines(of: stderr).compactMap { line in
            guard !RemoteFailureParser.isServerOutput(line), line.hasPrefix(errorPrefix) else {
                return nil
            }
            var body = line[...]
            while body.last == " " || body.last == "\t" { body = body.dropLast() }
            return RemoteFailureParser.redactingCredentials(String(body))
        }
    }

    private static let errorPrefix = "error: "

    /// `text` in lines, split on `\n`, `\r` **and** `\r\n`.
    ///
    /// The last one is listed beside the two singles because Swift reads a CR immediately
    /// followed by an LF as **one** `Character` — a grapheme cluster that equals neither `"\r"`
    /// nor `"\n"` — so neither single would split it. git separates its counters with `\r`
    /// everywhere, a server's `Resolving deltas:` progress arrives the same way, and stdout
    /// from a git on another platform can arrive CRLF-terminated.
    private static func lines(of text: String) -> [Substring] {
        text.split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
    }

    /// One result line's flag and summary, as the table above reads them. Anything else is the
    /// line itself: see `PushRejection.other` for why nothing is guessed here.
    private static func outcome(flag: String, summary: String, line: String) -> PushOutcome {
        switch flag {
        case "=" where summary == "[up to date]":
            return .upToDate
        // `[new branch]` for a branch, `[new tag]` for a tag, `[new reference]` for anything
        // else: the family, because the flag has already said "this ref did not exist".
        case "*" where summary.hasPrefix("[new "):
            return .created
        case "-" where summary == "[deleted]":
            return .deleted
        case " ":
            guard let range = summary.range(of: ".."), !summary.contains("...") else { break }
            return .pushed(from: String(summary[..<range.lowerBound]),
                           to: String(summary[range.upperBound...]))
        case "+":
            guard summary.hasSuffix(forcedSuffix) else { break }
            let shas = summary.dropLast(forcedSuffix.count)
            guard let range = shas.range(of: "...") else { break }
            return .forced(from: String(shas[..<range.lowerBound]),
                           to: String(shas[range.upperBound...]))
        case "!":
            if let rejection = rejection(summary: summary) { return .rejected(rejection) }
        default:
            break
        }
        return .rejected(.other(RemoteFailureParser.redactingCredentials(line)))
    }

    private static let forcedSuffix = " (forced update)"

    /// The four refusals git spells out, and nothing beyond them: a `[rejected]` reason this
    /// version has never seen falls through to `.other`, which keeps git's whole line.
    private static func rejection(summary: String) -> PushRejection? {
        switch summary {
        case "[rejected] (fetch first)": return .fetchFirst
        case "[rejected] (non-fast-forward)": return .nonFastForward
        case "[rejected] (stale info)": return .staleLease
        default: break
        }
        // `[remote rejected] (<reason>)`. The reason is the server's own text — a hook may put
        // anything in it — so it is redacted on the way through.
        let prefix = "[remote rejected] ("
        guard summary.hasPrefix(prefix), summary.hasSuffix(")") else { return nil }
        let reason = summary.dropFirst(prefix.count).dropLast()
        return .remoteRejected(RemoteFailureParser.redactingCredentials(String(reason)))
    }
}
