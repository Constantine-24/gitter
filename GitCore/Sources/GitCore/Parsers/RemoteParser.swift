import Foundation

/// Parses the output of `git remote -v`, one line per URL:
///
///     origin\tgit@github.com:penzin/gitter.git (fetch)
///     origin\tgit@github.com:penzin/gitter.git (push)
///
/// The separator after the name is a TAB. The URL is **not** quoted — a path with spaces in it
/// is printed as-is — so the URL is everything between that TAB and the trailing ` (fetch)` or
/// ` (push)`, which is the only thing marking where it ends.
///
/// A remote may have several push URLs (`git remote set-url --add --push`). Gitter pushes to
/// the remote *by name* and lets git fan out to all of them, so `pushURL` keeps the first one
/// purely as something to show.
///
/// Neither URL is ever copied into the other: each is exactly what git printed on that kind of
/// line, and nil when git printed none. Measured on git 2.54, both halves happen —
/// `git config --add remote.pushonly.pushurl <path>` with no `url` prints a bare name-only
/// line (name, TAB, nothing) for the fetch side and one `(push)` line, and a remote configured
/// with no URL at all — or with an empty one (R20) — prints only the name-only line.
///
/// **A remote with no URL of either kind is listed, with both nil** (B2 Task 3). It used to be
/// left out — nothing can be fetched from or pushed to through it — which made it invisible
/// while `git remote` still listed it, and Edit URL is how it gets one (`set-url` works on it,
/// R22). What reads remotes to fetch from or push to reads `RefCollection.remotesWithURL`.
///
/// These URLs are the **effective** ones, after `url.<base>.insteadOf` (R20): for display and
/// for the push target's "pushes where it fetches" comparison only. An editor reads the
/// configured ones (`GitRemoteAdminBackend.remoteURLs`).
public enum RemoteParser {
    private static let fetchSuffix = " (fetch)"
    private static let pushSuffix = " (push)"

    public static func parse(_ output: String) -> [Remote] {
        // Names in git's own order (which is sorted), each with the first URL of each kind.
        var order: [String] = []
        var fetchURLs: [String: String] = [:]
        var pushURLs: [String: String] = [:]

        // Split on "\r\n" as well as "\n": Swift reads a CRLF pair as a *single* Character, so
        // splitting on "\n" alone would not break such a line at all — the whole output would
        // arrive as one line and every remote would be lost. A lone "\r" ends a line too.
        let lines = output.split(omittingEmptySubsequences: true) {
            $0 == "\n" || $0 == "\r\n" || $0 == "\r"
        }
        for line in lines {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let name = String(line[line.startIndex..<tab])
            guard !name.isEmpty else { continue }

            let rest = line[line.index(after: tab)...]
            // The name-only line: a remote with no fetch URL. Listed, with nothing filled in.
            if rest.isEmpty {
                if !order.contains(name) { order.append(name) }
                continue
            }
            let isFetch = rest.hasSuffix(Self.fetchSuffix)
            guard isFetch || rest.hasSuffix(Self.pushSuffix) else { continue }
            let url = String(rest.dropLast(isFetch ? Self.fetchSuffix.count : Self.pushSuffix.count))
            guard !url.isEmpty else { continue }

            if !order.contains(name) { order.append(name) }
            if isFetch {
                if fetchURLs[name] == nil { fetchURLs[name] = url }
            } else if pushURLs[name] == nil {
                pushURLs[name] = url
            }
        }

        return order.map { Remote(name: $0, fetchURL: fetchURLs[$0], pushURL: pushURLs[$0]) }
    }
}
