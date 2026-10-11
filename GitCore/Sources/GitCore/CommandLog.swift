import Foundation

/// Where `CLIGitBackend` reports each git call it ran, once, after it ended. Called on whatever
/// thread the call ended on; an implementation must not block.
public protocol CommandLog: Sendable {
    func record(_ entry: CommandLogEntry)
}

/// The default: records nothing.
public struct NoCommandLog: CommandLog {
    public init() {}
    public func record(_ entry: CommandLogEntry) {}
}

public struct CommandLogEntry: Sendable, Equatable {
    public enum Outcome: Sendable, Equatable {
        /// `run`'s success: an exit of 0 or of an allowed code, which `run` does not tell apart.
        case succeeded
        /// The code the streaming seams returned, or the one a `GitError.commandFailed` carries.
        case exitCode(Int32)
        /// A git ended by a signal (`CLIGitBackend.wasKilledBySignal`).
        case killed
        case launchFailed(String)
        case cancelled
        /// Thrown before git was launched (`GitError.tooManyArguments`).
        case refusedBeforeLaunch(String)
    }

    public let started: Date
    public let duration: Duration
    public let directory: String
    /// Redacted one argument at a time — a URL's userinfo stripped by structure
    /// (`strippingUserinfo`), then `RemoteFailureParser.redactingCredentials`; more than
    /// `argumentThreshold` are cut to the first `argumentsShown` plus "… and N more".
    public let arguments: [String]
    public let outcome: Outcome
    /// For an outcome other than `.succeeded` and `.exitCode(0)` only: git's stderr, redacted
    /// (`strippingURLUserinfo(inWords:)`, then the prose redactor), cut to
    /// at most `stderrLimit` UTF-8 bytes on a character boundary, with "…" appended when cut. Nil when
    /// empty.
    public let stderr: String?

    public static let argumentThreshold = 40
    public static let argumentsShown = 20
    public static let stderrLimit = 2048

    /// Applies the redaction and the cuts. The only initializer.
    public init(started: Date, duration: Duration, directory: URL, rawArguments: [String],
                outcome: Outcome, rawStderr: String) {
        self.started = started
        self.duration = duration
        self.directory = directory.path
        self.arguments = Self.shown(rawArguments)
        self.outcome = Self.shown(outcome)
        switch outcome {
        case .succeeded, .exitCode(0):
            self.stderr = nil
        default:
            self.stderr = Self.shown(stderr: rawStderr)
        }
    }

    /// `arguments` redacted one at a time; over `argumentThreshold`, only the first
    /// `argumentsShown` of them (redacted — the rest are never looked at) and a count of the rest.
    static func shown(_ arguments: [String]) -> [String] {
        guard arguments.count > argumentThreshold else {
            return arguments.map(redacted)
        }
        return arguments.prefix(argumentsShown).map(redacted)
            + ["… and \(arguments.count - argumentsShown) more"]
    }

    /// `argument` without the userinfo of a URL in it, read by structure — the argument is one
    /// token, so nothing in a password (`'`, `(`, `)`, `@`, `:`, a blank, `%28`) can end it early,
    /// as it ends a run of the prose redactor (`RemoteFailureParser.redactingCredentials`, Task 2's
    /// review I1). Compared by Unicode scalar, like that redactor.
    /// - `…scheme://authority…` anywhere in it (`--url=https://…` too): the authority runs to the
    ///   first `/`, `?` or `#`, and everything in it up to its **last** `@` goes — a username alone
    ///   too, since a token is often the whole of it.
    /// - scp-style, `[user[:password]@]host:path`, not a path (`/`, `.`, `~`) and with no `/` before
    ///   its first colon: only where userinfo is there. An `@` before that colon ends the userinfo
    ///   (`git@host:team@2024/x` keeps its path); otherwise `user:password@host…` loses everything up
    ///   to the last `@` before the next `/`. A username with a blank in it is prose, not a URL
    ///   (`Discarded by Gitter: a@b.c`), and an `@{` is a revision (`stash@{0}:a.txt`); both stay.
    /// - an option's or a setting's value (`--push-option=…`, `--url=…`, `remote.o.url=…`): where
    ///   the first `=` comes before any `:`, what follows it is read as its own argument and the
    ///   part up to the `=` kept.
    /// An IPv6 host keeps its brackets (`https://u:p@[::1]:8443/x` → `https://[::1]:8443/x`).
    /// Anything else — a path, a refspec, a revision (`HEAD@{1}`), an `@` in a path — is returned
    /// as it is.
    static func strippingUserinfo(_ argument: String) -> String {
        let scalars = Array(argument.unicodeScalars)
        if let equals = scalars.firstIndex(of: "="),
            scalars.firstIndex(of: ":").map({ equals < $0 }) ?? true
        {
            return string(scalars[...equals]) + strippingUserinfo(string(scalars[(equals + 1)...]))
        }
        if let stripped = strippingSchemeUserinfo(scalars) { return stripped }
        guard let first = scalars.first, !"/.~".unicodeScalars.contains(first),
            let colon = scalars.firstIndex(of: ":"), !scalars[..<colon].contains("/")
        else { return argument }
        func isUserinfo(_ user: ArraySlice<Unicode.Scalar>, before at: Int) -> Bool {
            !user.isEmpty && !user.contains(where: \.properties.isWhitespace)
                && at + 1 < scalars.count && scalars[at + 1] != "{"
        }
        if let at = scalars[..<colon].lastIndex(of: "@") {
            return isUserinfo(scalars[..<at], before: at) ? string(scalars[(at + 1)...]) : argument
        }
        let segmentEnd = (colon + 1..<scalars.count).first { scalars[$0] == "/" } ?? scalars.count
        guard let at = (colon + 1..<segmentEnd).last(where: { scalars[$0] == "@" }),
            isUserinfo(scalars[..<colon], before: at)
        else { return argument }
        return string(scalars[(at + 1)...])
    }

    /// The `scheme://` rule of `strippingUserinfo` on one token: nil when the token holds no `://`;
    /// otherwise the token, its authority's userinfo gone — the authority runs to the first `/`, `?`
    /// or `#`, and everything in it up to its last `@` goes.
    private static func strippingSchemeUserinfo(_ scalars: [Unicode.Scalar]) -> String? {
        guard let colon = scalars.indices.dropLast(2).first(where: {
            scalars[$0] == ":" && scalars[$0 + 1] == "/" && scalars[$0 + 2] == "/"
        }) else { return nil }
        let rest = colon + 3
        let end = (rest..<scalars.count).first { "/?\u{23}".unicodeScalars.contains(scalars[$0]) } ?? scalars.count
        guard let at = (rest..<end).last(where: { scalars[$0] == "@" }) else { return string(scalars[...]) }
        return string(scalars[..<rest]) + string(scalars[(at + 1)...])
    }

    /// git's words (stderr, a launch failure's message, a refusal's description) with each
    /// blank-separated token's `scheme://` userinfo stripped by structure (`strippingSchemeUserinfo`),
    /// so a password holding `'`, `(`, `)`, `@` or `:` cannot end the run early as it ends the prose
    /// redactor's (the final review's I1). The blanks, tabs and line ends between tokens, and the
    /// quotes and punctuation around a URL, are kept as they were. Only the `://` rule: the scp rule
    /// would cut a file name such as `'a:b@c.txt'` in a message. Left as they are: a password with a
    /// blank (it ends the token) or an unencoded `/`, `?` or `#` (it ends the authority), and an
    /// scp-form address (`me:p(ss)@host: Permission denied`), which only the prose redactor sees.
    static func strippingURLUserinfo(inWords text: String) -> String {
        var result = String.UnicodeScalarView()
        var token: [Unicode.Scalar] = []
        func flush() {
            guard !token.isEmpty else { return }
            if let stripped = strippingSchemeUserinfo(token) {
                result.append(contentsOf: stripped.unicodeScalars)
            } else {
                result.append(contentsOf: token)
            }
            token = []
        }
        for scalar in text.unicodeScalars {
            if scalar.properties.isWhitespace {
                flush()
                result.append(scalar)
            } else {
                token.append(scalar)
            }
        }
        flush()
        return String(result)
    }

    private static func string(_ slice: ArraySlice<Unicode.Scalar>) -> String {
        var view = String.UnicodeScalarView()
        view.append(contentsOf: slice)
        return String(view)
    }

    /// One argument: a URL's userinfo stripped by structure (`strippingUserinfo`), then the prose
    /// redactor over what is left.
    private static func redacted(_ argument: String) -> String {
        RemoteFailureParser.redactingCredentials(strippingUserinfo(argument))
    }

    /// The outcome's own strings (a launch failure's message, a refusal's description) redacted and
    /// cut like stderr, so no field carries a raw credential.
    static func shown(_ outcome: Outcome) -> Outcome {
        switch outcome {
        case .launchFailed(let message): .launchFailed(shown(stderr: message) ?? "")
        case .refusedBeforeLaunch(let message): .refusedBeforeLaunch(shown(stderr: message) ?? "")
        default: outcome
        }
    }

    /// `stderr` redacted — each token's `scheme://` userinfo stripped by structure
    /// (`strippingURLUserinfo(inWords:)`), then the prose redactor — and cut to `stderrLimit` UTF-8
    /// bytes on a character boundary, "…" after a cut; nil when empty.
    static func shown(stderr: String) -> String? {
        let redacted = RemoteFailureParser.redactingCredentials(strippingURLUserinfo(inWords: stderr))
        guard !redacted.isEmpty else { return nil }
        guard redacted.utf8.count > stderrLimit else { return redacted }
        var kept = ""
        var bytes = 0
        for character in redacted {
            let size = character.utf8.count
            if bytes + size > stderrLimit { break }
            kept.append(character)
            bytes += size
        }
        return kept + "…"
    }
}
