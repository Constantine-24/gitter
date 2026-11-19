import Foundation

/// Commit search (F1): one `log` read per search, whose vectors and measured facts are on
/// `GitBackend.searchCommits`.
extension CLIGitBackend {
    public func searchCommits(_ search: CommitSearch, limit: Int, at root: URL) async throws -> CommitSearchResult {
        guard !search.isEmpty else { return CommitSearchResult(search: search, commits: [], isCut: false) }
        let limit = max(limit, 0)
        // A query git could not take as typed finds nothing, and git is not run: a NUL cannot be
        // in an argument (Foundation raises an uncatchable exception launching one), and a File
        // query with an interior empty, `.` or `..` segment is normalised by git into a pattern
        // that matches every path, while no path holds such a segment.
        if search.mode != .messageAuthorOrID, search.query.contains("\u{0}") {
            return CommitSearchResult(search: search, commits: [], isCut: false)
        }
        if search.mode == .file, Self.hasUnreachableSegment(search.query) {
            return CommitSearchResult(search: search, commits: [], isCut: false)
        }
        do {
            // `runStreaming`, not `run`: it is the seam that kills git when the task is
            // cancelled. Its stdout is the whole output; the progress callback hears stderr only.
            let result = try await runStreaming(Self.searchArguments(for: search), cwd: root, progress: { _ in })
            let matched: [Commit]
            switch search.mode {
            case .messageAuthorOrID:
                // One more than `limit` tells whether the list is cut, and stops the scan there.
                let session = CommitSearchMatcher.Session(query: search.query)
                matched = LogParser.scanWithMessages(result.stdout, limit: limit == .max ? .max : limit + 1) { record in
                    session.matches(sha: record.bytes(0), authorName: record.bytes(2),
                                    authorEmail: record.bytes(3), message: record.bytes(7))
                }
            case .code:
                matched = LogParser.parse(result.stdout)
            case .file:
                matched = try await inHistoryOrder(LogParser.parse(result.stdout), at: root)
            }
            return CommitSearchResult(search: search, commits: Array(matched.prefix(limit)), isCut: matched.count > limit)
        } catch let GitError.commandFailed(_, stderr) where stderr.contains("does not have any commits") {
            return CommitSearchResult(search: search, commits: [], isCut: false)
        }
    }

    /// File mode's commits in History's own order. A pathspec makes git simplify a merge to the one
    /// parent its tree equals, and `--topo-order` then sorts by the simplified parents: the match
    /// set is right but the order can differ from History's (measured: a `-s ours` merge with a ref
    /// continuing past it). So the set is kept and ordered by one `rev-list` over History's walk.
    private func inHistoryOrder(_ commits: [Commit], at root: URL) async throws -> [Commit] {
        guard commits.count > 1 else { return commits }
        let walk = try await runStreaming(
            ["rev-list", "--exclude=refs/stash", "--all", "--topo-order"], cwd: root, progress: { _ in })
        var row: [String: Int] = [:]
        for (index, line) in GitLines.split(walk.stdout).enumerated() { row[String(line)] = index }
        return commits.sorted { (row[$0.sha] ?? .max) < (row[$1.sha] ?? .max) }
    }

    /// Whether a File query has, between two slashes, a segment that is empty, `.` or `..`.
    static func hasUnreachableSegment(_ query: String) -> Bool {
        let segments = query.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count > 2 else { return false }
        return segments[1..<(segments.count - 1)].contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// The vector of one search. `--exclude` before `--all` and `--topo-order` are History's own
    /// walk (`commitLog`); `--no-show-signature` and `--no-notes` keep `log.showSignature` and
    /// notes config out of the records. `-z` and the format are History's, plus `%B` for the mode
    /// that matches in the app.
    static func searchArguments(for search: CommitSearch) -> [String] {
        let common = ["log", "--exclude=refs/stash", "--all", "--topo-order", "--no-show-signature", "--no-notes", "-z"]
        switch search.mode {
        case .messageAuthorOrID:
            return common + ["--format=\(logFormat)%x00%B"]
        case .file:
            // The glob pair: `**/*q*` (a path whose last component holds the query, or a
            // query spanning folders) and `**/*q*/**` (everything under a folder that does).
            // `glob` magic makes the pair independent of `GIT_GLOB_PATHSPECS` and
            // `GIT_NOGLOB_PATHSPECS`; the query's own glob characters are escaped.
            let glob = escapedGlob(search.query)
            return common + ["--format=\(logFormat)", "--no-follow", "--",
                             ":(glob,icase)**/*\(glob)*", ":(glob,icase)**/*\(glob)*/**"]
        case .code:
            // `-S` is literal; `-i` folds case; `--no-textconv --no-ext-diff` keep a configured
            // driver from changing the text that is searched. The query is attached to `-S` so a
            // leading `-` cannot be read as an option.
            return common + ["--format=\(logFormat)", "--no-textconv", "--no-ext-diff", "--find-renames", "-i", "-S" + search.query]
        }
    }

    /// `\`, `*`, `?`, `[` and `]` made literal for a pathspec's wildcard matching.
    private static func escapedGlob(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\*?[]".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
