import Foundation

/// Commit search (F1): one `log` read per search, whose vectors and measured facts are on
/// `GitBackend.searchCommits`.
extension CLIGitBackend {
    public func searchCommits(_ search: CommitSearch, limit: Int, at root: URL) async throws -> CommitSearchResult {
        guard !search.isEmpty else { return CommitSearchResult(search: search, commits: [], isCut: false) }
        let limit = max(limit, 0)
        do {
            // `runStreaming`, not `run`: it is the seam that kills git when the task is
            // cancelled. Its stdout is the whole output; the progress callback hears stderr only.
            let result = try await runStreaming(Self.searchArguments(for: search), cwd: root, progress: { _ in })
            let matched: [Commit]
            switch search.mode {
            case .messageAuthorOrID:
                matched = LogParser.parseWithMessages(result.stdout).filter { row in
                    CommitSearchMatcher.matches(
                        query: search.query, sha: row.commit.sha, authorName: row.commit.authorName,
                        authorEmail: row.commit.authorEmail, message: row.message)
                }.map(\.commit)
            case .file, .code:
                matched = LogParser.parse(result.stdout)
            }
            return CommitSearchResult(search: search, commits: Array(matched.prefix(limit)), isCut: matched.count > limit)
        } catch let GitError.commandFailed(_, stderr) where stderr.contains("does not have any commits") {
            return CommitSearchResult(search: search, commits: [], isCut: false)
        }
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
            // `:(icase)` and no `glob`: without `glob` a `*` crosses `/`, so `*<query>*` is "the
            // path contains the query" for a fragment, a folder or `Views/Sidebar`. The query's
            // own glob characters are escaped so they match themselves.
            return common + ["--format=\(logFormat)", "--no-follow", "--", ":(icase)*" + escapedGlob(search.query) + "*"]
        case .code:
            // `-S` is literal; `-i` folds case; `--no-textconv --no-ext-diff` keep a configured
            // driver from changing the text that is searched. The query is attached to `-S` so a
            // leading `-` cannot be read as an option.
            return common + ["--format=\(logFormat)", "--no-textconv", "--no-ext-diff", "-i", "-S" + search.query]
        }
    }

    /// `\`, `*`, `?` and `[` made literal for a pathspec's wildcard matching.
    private static func escapedGlob(_ text: String) -> String {
        var out = ""
        for character in text {
            if "\\*?[".contains(character) { out.append("\\") }
            out.append(character)
        }
        return out
    }
}
