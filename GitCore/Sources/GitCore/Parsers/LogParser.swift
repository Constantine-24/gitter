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
    /// exists until `commit()` is asked for. Valid only inside the `keep` closure it is handed
    /// to — its pointers are into the output and the scan's own buffers — so it is internal, and
    /// never kept.
    struct Record {
        enum Field: Int {
            case sha, parents, authorName, authorEmail, date, summary, refs, message
        }

        let base: UnsafePointer<UInt8>
        let starts: UnsafePointer<Int>
        let ends: UnsafePointer<Int>

        func bytes(_ field: Field) -> UnsafeBufferPointer<UInt8> {
            let index = field.rawValue
            return UnsafeBufferPointer(start: base + starts[index], count: ends[index] - starts[index])
        }

        private func string(_ field: Field) -> String { String(decoding: bytes(field), as: UTF8.self) }

        func commit() -> Commit {
            makeCommit(sha: string(.sha), parents: string(.parents), authorName: string(.authorName),
                       authorEmail: string(.authorEmail), date: string(.date), summary: string(.summary),
                       refs: string(.refs))
        }
    }

    /// The records of a read with `%x00%B` appended to the format — 8 NUL-terminated fields per
    /// commit, the 8th its whole message — offered to `keep` as bytes. A `Commit` is built only for
    /// a record `keep` accepts, and the scan stops once `limit` are kept, so a search of 100,000
    /// commits builds a `Commit` only for its matches.
    static func scanWithMessages(_ data: Data, limit: Int = .max, keep: (Record) -> Bool) -> [Commit] {
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

    /// The same records read the plain way, through `parse` and a `String` per message: the
    /// reference `scanWithMessages` is tested against. The app reads with `scanWithMessages`.
    static func parseWithMessages(_ data: Data) -> [(commit: Commit, message: String)] {
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
