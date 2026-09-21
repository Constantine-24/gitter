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
/// **Extra result lines are not an error and not our business.** Gitter always passes one
/// explicit refspec, but the user's own configuration can add refs to the same push: measured,
/// `push.followTags=true` with an annotated tag on the commit being pushed adds
/// `*\trefs/tags/v9:refs/tags/v9\t[new tag]` beside our branch's line. Those refs were not
/// asked about, nothing in Gitter shows them, and they are skipped. (`remote.<name>.push` does
/// *not* add any: measured, an explicit refspec on the command line replaces it outright.)
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
public enum PushPorcelainParser {
    /// The outcome for `destinationRef`, or `nil` when no result line names it.
    ///
    /// `nil` and `.rejected` are different answers and must never be conflated: `nil` means git
    /// said nothing at all about this ref — it failed before it got that far, and stderr is
    /// where the reason is — while a `.rejected` is the server having considered it and refused.
    public static func parse(stdout: String, destinationRef: String) -> PushOutcome? {
        for line in stdout.split(separator: "\n", omittingEmptySubsequences: false) {
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
        stderr
            // `"\r\n"` is listed beside the two singles because Swift reads a CR immediately
            // followed by an LF as **one** `Character` — a grapheme cluster that equals neither
            // `"\r"` nor `"\n"`, so a server's final counter line would otherwise have kept its
            // terminator and come through as `"… (2/2)\r\n"`.
            .split(whereSeparator: { $0 == "\n" || $0 == "\r" || $0 == "\r\n" })
            .compactMap { line in
                guard line.hasPrefix(serverPrefix) else { return nil }
                var body = line.dropFirst(serverPrefix.count)
                if body.first == " " { body = body.dropFirst() }
                while body.last == " " || body.last == "\t" { body = body.dropLast() }
                return RemoteFailureParser.redactingCredentials(String(body))
            }
    }

    private static let serverPrefix = "remote:"

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
