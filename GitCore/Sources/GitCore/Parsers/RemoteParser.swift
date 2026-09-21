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
/// purely as something to show. A remote that has only one of the two kinds of line uses that
/// URL for both.
public enum RemoteParser {
    private static let fetchSuffix = " (fetch)"
    private static let pushSuffix = " (push)"

    public static func parse(_ output: String) -> [Remote] {
        // Names in git's own order (which is sorted), each with the first URL of each kind.
        var order: [String] = []
        var fetchURLs: [String: String] = [:]
        var pushURLs: [String: String] = [:]

        for line in output.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let tab = line.firstIndex(of: "\t") else { continue }
            let name = String(line[line.startIndex..<tab])
            guard !name.isEmpty else { continue }

            let rest = line[line.index(after: tab)...]
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

        return order.compactMap { name in
            guard let known = fetchURLs[name] ?? pushURLs[name] else { return nil }
            return Remote(name: name,
                          fetchURL: fetchURLs[name] ?? known,
                          pushURL: pushURLs[name] ?? known)
        }
    }
}
