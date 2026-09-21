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
/// **An unknown remote name is not distinguishable here, and is not guessed at.** Measured:
/// `git fetch nosuch` and a configured remote whose path holds no repository print the *same*
/// sentence, differing only in whether the quoted token is a name or a path — which the parser
/// cannot tell apart, since a remote may be configured with any string as its URL. Both are
/// therefore `.repositoryNotFound`, which is true of both. `.noRemote` is reserved for the
/// names `CLIGitBackend` refuses before git runs, where the answer is known without asking.
public enum RemoteFailureParser {
    public static func parse(stderr: String) -> RemoteOperationError? {
        let lines = stderr.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)

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
        if let line = lines.first(where: { $0.contains(": Permission denied (publickey") }) {
            // git prints `<user>@<host>: Permission denied (publickey).`; the address is
            // everything before the colon that begins the message.
            let address = line.components(separatedBy: ": Permission denied (publickey").first ?? ""
            return .authenticationFailed(url: address.trimmingCharacters(in: .whitespaces))
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

    /// The host `line` says could not be reached, or git's whole line when it named no host —
    /// half a sentence would be worse than all of git's. `nil` when the line is not about
    /// reachability at all.
    private static func unreachableHost(in line: String) -> String? {
        // HTTPS (curl, via git): `… Could not resolve host: nonexistent.invalid`. Measured.
        if let range = line.range(of: "Could not resolve host: ") {
            let host = line[range.upperBound...].trimmingCharacters(in: .whitespaces)
            return host.isEmpty ? line.trimmed : host
        }
        // ssh: `ssh: Could not resolve hostname nosuchhost.invalid: nodename nor servname …`.
        // Measured. The host ends at the colon that introduces the resolver's own reason.
        if let range = line.range(of: "Could not resolve hostname ") {
            let rest = line[range.upperBound...]
            let host = (rest.firstIndex(of: ":").map { String(rest[..<$0]) } ?? String(rest))
                .trimmingCharacters(in: .whitespaces)
            return host.isEmpty ? line.trimmed : host
        }
        // VERIFY, unmeasured: a network that is down, filtered or silent. ssh's shape is
        // `ssh: connect to host <host> port 22: <reason>`; git's HTTPS shape names the host
        // inside a longer curl sentence, so that one falls back to the whole line.
        guard line.contains("Connection timed out") || line.contains("Operation timed out")
            || line.contains("Network is unreachable") || line.contains("Connection refused")
        else { return nil }
        guard let range = line.range(of: "connect to host ") else { return line.trimmed }
        let rest = line[range.upperBound...]
        let host = (rest.firstIndex(of: " ").map { String(rest[..<$0]) } ?? String(rest))
            .trimmingCharacters(in: .whitespaces)
        return host.isEmpty ? line.trimmed : host
    }

    /// The text inside the single quotes that follow `prefix`. git quotes URLs in these
    /// messages and a URL cannot itself contain a `'`, so the closing quote is the last one on
    /// the line — found backwards, which keeps a trailing `: terminal prompts disabled` out of
    /// the result without the parser having to know about it.
    private static func quoted(in line: String, after prefix: String) -> String? {
        guard let start = line.range(of: prefix),
            let open = line[start.upperBound...].firstIndex(of: "'"),
            let close = line.range(of: "'", options: .backwards),
            open < close.lowerBound
        else { return nil }
        return String(line[line.index(after: open)..<close.lowerBound])
    }
}

extension String {
    fileprivate var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
