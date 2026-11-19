import Foundation

/// Parses the output of `git log --exclude=refs/stash --all --topo-order -z
/// --format='%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%D'` into an array of `Commit`.
///
/// `-z` NUL-terminates each record and `%x00` separates fields within a record, so the
/// stream is a flat sequence of NUL-separated fields, 7 per commit, with no distinct
/// record separator.
public enum LogParser {
    public static func parse(_ data: Data) -> [Commit] {
        let text = String(decoding: data, as: UTF8.self)
        var fields = text.split(separator: "\u{0}", omittingEmptySubsequences: false)
        if fields.last == "" {
            fields.removeLast()
        }

        var commits: [Commit] = []
        var index = 0
        while index + 7 <= fields.count {
            commits.append(makeCommit(
                sha: String(fields[index]), parents: String(fields[index + 1]), authorName: String(fields[index + 2]),
                authorEmail: String(fields[index + 3]), date: String(fields[index + 4]),
                summary: String(fields[index + 5]), refs: String(fields[index + 6])))
            index += 7
        }
        return commits
    }

    private static func makeCommit(
        sha: String, parents: String, authorName: String, authorEmail: String, date: String,
        summary: String, refs: String
    ) -> Commit {
        Commit(
            sha: sha,
            parents: parents.split(separator: " ", omittingEmptySubsequences: true).map(String.init),
            authorName: authorName,
            authorEmail: authorEmail,
            authorDate: parseDate(date),
            summary: summary,
            refs: refs.split(separator: ", ", omittingEmptySubsequences: true).map(String.init)
        )
    }

    /// One 8-field record of `scanWithMessages`, as byte ranges of the whole output: no `String`
    /// exists until `commit()` is asked for.
    public struct Record {
        let base: UnsafePointer<UInt8>
        let starts: UnsafePointer<Int>
        let ends: UnsafePointer<Int>

        /// Field `index` (0 sha, 1 parents, 2 author name, 3 author email, 4 date, 5 summary,
        /// 6 refs, 7 message) as bytes.
        public func bytes(_ index: Int) -> UnsafeBufferPointer<UInt8> {
            UnsafeBufferPointer(start: base + starts[index], count: ends[index] - starts[index])
        }

        private func string(_ index: Int) -> String { String(decoding: bytes(index), as: UTF8.self) }

        public var message: String { string(7) }

        public func commit() -> Commit {
            makeCommit(sha: string(0), parents: string(1), authorName: string(2), authorEmail: string(3),
                       date: string(4), summary: string(5), refs: string(6))
        }
    }

    /// `parseWithMessages`' records, offered to `keep` as bytes; a `Commit` is built only for a
    /// record `keep` accepts, and the scan stops once `limit` are kept. Searching 100,000 commits
    /// built a `Commit` and a message `String` for every one before (measured, F1 fix round 2).
    public static func scanWithMessages(_ data: Data, limit: Int = .max, keep: (Record) -> Bool) -> [Commit] {
        var kept: [Commit] = []
        guard limit > 0 else { return kept }
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
            let count = raw.count
            var starts = [Int](repeating: 0, count: 8)
            var ends = [Int](repeating: 0, count: 8)
            var position = 0
            starts.withUnsafeMutableBufferPointer { startBuffer in
                ends.withUnsafeMutableBufferPointer { endBuffer in
                    let record = Record(base: base, starts: UnsafePointer(startBuffer.baseAddress!),
                                        ends: UnsafePointer(endBuffer.baseAddress!))
                    scan: while position < count {
                        // 8 NUL-terminated fields; an incomplete tail is dropped, as `parse` does.
                        for field in 0..<8 {
                            guard position <= count,
                                  let nul = memchr(base + position, 0, count - position) else { break scan }
                            let end = base.distance(to: nul.assumingMemoryBound(to: UInt8.self))
                            startBuffer[field] = position
                            endBuffer[field] = end
                            position = end + 1
                        }
                        if keep(record) {
                            kept.append(record.commit())
                            if kept.count >= limit { break }
                        }
                    }
                }
            }
        }
        return kept
    }

    /// The same read with `%x00%B` appended to the format: 8 fields per commit, the 8th the whole
    /// message (commit search matches it in the app). The 7 fields before it are `parse`'s.
    public static func parseWithMessages(_ data: Data) -> [(commit: Commit, message: String)] {
        let text = String(decoding: data, as: UTF8.self)
        var fields = text.split(separator: "\u{0}", omittingEmptySubsequences: false)
        if fields.last == "" { fields.removeLast() }
        var rows: [(commit: Commit, message: String)] = []
        var index = 0
        while index + 8 <= fields.count {
            let seven = fields[index..<index + 7].joined(separator: "\u{0}") + "\u{0}"
            if let commit = parse(Data(seven.utf8)).first {
                rows.append((commit, String(fields[index + 7])))
            }
            index += 8
        }
        return rows
    }

    /// `%aI`'s strict ISO 8601 (`2026-10-26T10:00:00+02:00`, or `Z`), read by one shared style.
    /// An `ISO8601DateFormatter` made per commit was most of a deep read's cost (H1, measured:
    /// 11.9 s of LogParser for 100,001 commits, the dates 4.3 s even with one shared formatter;
    /// this style, 27 ms). `LogParserDateTests` pins it to the old formatter's answers.
    static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: false)

    private static func parseDate(_ string: String) -> Date {
        (try? dateStyle.parse(string)) ?? Date(timeIntervalSince1970: 0)
    }
}
