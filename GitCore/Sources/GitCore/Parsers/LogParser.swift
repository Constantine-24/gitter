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
            let sha = String(fields[index])
            let parentsField = fields[index + 1]
            let authorName = String(fields[index + 2])
            let authorEmail = String(fields[index + 3])
            let dateField = String(fields[index + 4])
            let summary = String(fields[index + 5])
            let refsField = fields[index + 6]
            index += 7

            let parents = parentsField.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
            let refs = refsField.split(separator: ", ", omittingEmptySubsequences: true).map(String.init)
            let date = parseDate(dateField)

            commits.append(
                Commit(
                    sha: sha,
                    parents: parents,
                    authorName: authorName,
                    authorEmail: authorEmail,
                    authorDate: date,
                    summary: summary,
                    refs: refs
                )
            )
        }
        return commits
    }

    private static func parseDate(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string) ?? Date(timeIntervalSince1970: 0)
    }
}
