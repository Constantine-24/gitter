import Foundation

/// Commit search (F1): one `log` read per search, whose vectors and measured facts are on
/// `GitBackend.searchCommits`.
extension CLIGitBackend {
    public func searchCommits(_ search: CommitSearch, limit: Int, at root: URL) async throws -> CommitSearchResult {
        let nothing = CommitSearchResult(search: search, commits: [], isCut: false)
        guard !search.isEmpty else { return nothing }
        let limit = max(limit, 0)
        // A query git could not take as typed finds nothing, and git is not run: a NUL cannot be
        // in an argument (Foundation raises an uncatchable exception launching one), and git
        // collapses a File query's interior empty, `.` or `..` segment into a looser pattern
        // (measured: `a//b` and `a/./b` match as `a/b`, `docs/../` matches every path), which
        // finds paths that do not hold the query as typed — and no path holds such a segment.
        if (search.mode != .messageAuthorOrID && search.query.contains("\u{0}"))
            || (search.mode == .file && Self.hasUnreachableSegment(search.query))
        {
            return nothing
        }
        let arguments = Self.searchArguments(for: search)
        let matched: [Commit]
        switch search.mode {
        case .messageAuthorOrID:
            // One more than `limit` tells whether the list is cut, and stops the scan there.
            let session = CommitSearchMatcher.Session(query: search.query)
            let output = try await searchRead(arguments, at: root)
            matched = LogParser.scanWithMessages(output, limit: limit == .max ? .max : limit + 1) { record in
                session.matches(sha: record.bytes(.sha), authorName: record.bytes(.authorName),
                                authorEmail: record.bytes(.authorEmail), message: record.bytes(.message))
            }
        case .code:
            matched = LogParser.parse(try await searchRead(arguments, at: root))
        case .file:
            // History's order (Ruling P6), read beside the log rather than after it, and always
            // awaited: one cancelled at the scope's end would be logged as a cancelled git.
            async let walk = searchRead(["rev-list", "--exclude=refs/stash", "--all", "--topo-order"], at: root)
            let matches = Self.fileMatches(try await searchRead(arguments, at: root))
            let order = try await walk
            matched = matches.count > 1 ? Self.inHistoryOrder(matches, walk: order) : matches
        }
        return CommitSearchResult(search: search, commits: Array(matched.prefix(limit)), isCut: matched.count > limit)
    }

    /// Every search read. `runWithEnvironment` goes through the streaming runner, so a cancelled
    /// task kills git (`cancellingKillsTheRead`); `GIT_NO_LAZY_FETCH=1` keeps a partial clone from
    /// fetching what it lacks — a search only reads (Ruling P20). git then fails at once instead,
    /// which is `CommitSearchError.contentsNotDownloaded`.
    private func searchRead(_ arguments: [String], at root: URL) async throws -> Data {
        do {
            return try await runWithEnvironment(arguments, cwd: root, extra: ["GIT_NO_LAZY_FETCH": "1"]).stdout
        } catch let GitError.commandFailed(_, stderr) where Self.lacksContents(stderr) {
            throw CommitSearchError.contentsNotDownloaded(gitsWords: stderr)
        }
    }

    /// git's words when `GIT_NO_LAZY_FETCH` stopped a read that needed an object a partial clone
    /// has not downloaded (measured, git 2.54).
    static func lacksContents(_ stderr: String) -> Bool {
        stderr.contains("lazy fetching disabled") || stderr.contains("from promisor remote")
    }

    /// File mode's read, one line per header: a commit that changed a matching path once, and a
    /// merge once for each parent it differs from on those paths (`--diff-merges=separate`). A
    /// merge is kept only when it differs from every parent (Ruling P19). The header lines start
    /// with `\u{1}`, which a path line never holds: git quotes a path with a control character
    /// in it whatever `core.quotePath` says (measured), and the format's fields hold no newline.
    static func fileMatches(_ data: Data) -> [Commit] {
        var headers = Data()
        var seen: [Data: Int] = [:]
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            var start = 0
            while start < count {
                let end = memchr(base + start, 0x0A, count - start)
                    .map { base.distance(to: $0.assumingMemoryBound(to: UInt8.self)) } ?? count
                if base[start] == 0x01 {
                    let header = UnsafeBufferPointer(start: base + start + 1, count: end - start - 1)
                    let sha = Data(header.prefix { $0 != 0 })
                    if seen[sha] == nil {
                        headers.append(header)
                        headers.append(0)
                    }
                    seen[sha, default: 0] += 1
                }
                start = end + 1
            }
        }
        return LogParser.parse(headers).filter { $0.parents.count < 2 || seen[Data($0.sha.utf8)] == $0.parents.count }
    }

    /// File mode's commits in History's own order, by `walk`, one `rev-list` over History's walk
    /// (Ruling P6). Default simplification reordered the walk (a `-s ours` merge); with
    /// `--full-history` the log's own order was a subsequence of History's in every one of 400
    /// random small histories (measured, F1 final fix wave), which is not a proof, so the sort stays. A match the `rev-list` does not have (a ref
    /// moved between the two reads) goes last, in the log's order; the refresh after that move
    /// searches again.
    static func inHistoryOrder(_ commits: [Commit], walk: Data) -> [Commit] {
        var row: [String: Int] = [:]
        for (index, line) in GitLines.split(walk).enumerated() { row[String(line)] = index }
        return commits.enumerated()
            .sorted { (row[$0.element.sha] ?? .max, $0.offset) < (row[$1.element.sha] ?? .max, $1.offset) }
            .map(\.element)
    }

    /// Whether a File query has, between two slashes, a segment that is empty, `.` or `..`.
    static func hasUnreachableSegment(_ query: String) -> Bool {
        let segments = query.split(separator: "/", omittingEmptySubsequences: false)
        guard segments.count > 2 else { return false }
        return segments[1..<(segments.count - 1)].contains { $0.isEmpty || $0 == "." || $0 == ".." }
    }

    /// The vector of one search. `--exclude` before `--all` and `--topo-order` are History's own
    /// walk (`commitLog`); `--no-show-signature` and `--no-notes` keep `log.showSignature` and
    /// notes config out of the records, `--encoding=UTF-8` keeps `i18n.logOutputEncoding` from
    /// re-encoding them, and `--root` keeps `log.showRoot=false` from hiding a root commit's
    /// changes. The format is History's, plus `%B` for the mode that matches in the app.
    static func searchArguments(for search: CommitSearch) -> [String] {
        let common = [
            "log", "--exclude=refs/stash", "--all", "--topo-order", "--no-show-signature", "--no-notes",
            "--encoding=UTF-8", "--root",
        ]
        switch search.mode {
        case .messageAuthorOrID:
            return common + ["-z", "--format=\(logFormat)%x00%B"]
        case .file:
            // `--full-history`: every commit that changed a matching path, on whichever parent of
            // a merge it lies, not only the history that explains the files as they are now.
            // `--diff-merges=separate --name-only` print a merge once per parent it differs from
            // (`fileMatches`); `--diff-merges` is explicit because `log.diffMerges` changes what
            // `-m` means, and `--no-renames` because a name list needs no rename detection (it
            // would read blobs). The glob pair: `**/*q*` (a path whose last component holds the
            // query, or a query spanning folders) and `**/*q*/**` (everything under a folder that
            // does). `glob` magic makes the pair independent of `GIT_GLOB_PATHSPECS` and
            // `GIT_NOGLOB_PATHSPECS`; the query's own glob characters are escaped.
            let glob = escapedGlob(search.query)
            return common + ["--full-history", "--diff-merges=separate", "--name-only", "--no-renames",
                             "--format=%x01\(logFormat)", "--no-follow", "--",
                             ":(glob,icase)**/*\(glob)*", ":(glob,icase)**/*\(glob)*/**"]
        case .code:
            // `-S` is literal; `-i` folds case; `--no-textconv --no-ext-diff` keep a configured
            // driver from changing the text that is searched. The query is attached to `-S` so a
            // leading `-` cannot be read as an option.
            return common + ["-z", "--format=\(logFormat)", "--no-textconv", "--no-ext-diff", "--find-renames", "-i",
                             "-S" + search.query]
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
