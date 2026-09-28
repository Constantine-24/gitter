import Foundation

/// Parses `git stash list -z --format=%H%x1f%gd%x1f%gs%x1f%ct%x1f%P` into `[Stash]`.
///
/// Each record ends in NUL (`-z`, M 1), and its five fields are split by US (0x1f). Four of
/// them cannot contain a US — a sha, `stash@{N}`, a number, and space-separated shas — but the
/// reflog subject is the user's message and can. So the subject is read as everything between
/// the second separator and the last two, and a US inside it stays part of it. A record with
/// fewer than five fields, or whose `%gd` is not `stash@{N}`, is skipped.
public enum StashListParser {
    public static func parse(_ data: Data) -> [Stash] {
        let text = String(decoding: data, as: UTF8.self)
        return text.split(separator: "\u{0}", omittingEmptySubsequences: true).compactMap(record)
    }

    private static func record(_ line: Substring) -> Stash? {
        let fields = line.split(separator: "\u{1f}", omittingEmptySubsequences: false)
        guard fields.count >= 5 else { return nil }
        let sha = String(fields[0])
        guard !sha.isEmpty, let index = position(fields[1]),
            let seconds = TimeInterval(fields[fields.count - 2])
        else { return nil }
        let subject = fields[2..<(fields.count - 2)].joined(separator: "\u{1f}")
        let parents = fields[fields.count - 1].split(separator: " ").map(String.init)
        return Stash(
            sha: sha, index: index, reflogSubject: subject, parents: parents,
            date: Date(timeIntervalSince1970: seconds))
    }

    /// `stash@{N}` → N. git prints a date here only when given `--date`, which Gitter never
    /// passes (M 1); anything else is not a position.
    private static func position(_ field: Substring) -> Int? {
        let prefix = "stash@{"
        guard field.hasPrefix(prefix), field.hasSuffix("}") else { return nil }
        return Int(field.dropFirst(prefix.count).dropLast())
    }
}
