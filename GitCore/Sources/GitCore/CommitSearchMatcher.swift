import Foundation

/// Message, Author or ID matching, done in the app over what one `log` read returned. git's
/// `--grep` and `--author` combine by AND, and `.mailmap` changes what `--author` sees, so
/// neither can say "the text is in the message or the author or is the id's start" the way the
/// row shows it (design: Git).
public enum CommitSearchMatcher {
    /// Any run of whitespace and line breaks as one space, and nothing at either end: a phrase
    /// hard-wrapped across two lines of a body still matches.
    public static func normalized(_ s: String) -> String {
        s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
    }

    /// Whether `q` can be the start of a commit id: 4 to 40 hexadecimal characters.
    public static func isIDQuery(_ q: String) -> Bool {
        (4...40).contains(q.utf8.count) && q.utf8.allSatisfy { byte in
            (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(byte)
                || (UInt8(ascii: "a")...UInt8(ascii: "f")).contains(byte)
                || (UInt8(ascii: "A")...UInt8(ascii: "F")).contains(byte)
        }
    }

    /// The query is one literal phrase, folded for case (Unicode) and for whitespace. It matches
    /// when the message, the author's name or the author's email holds it, or when it is an id
    /// query and the full `sha` starts with it. A query of only blanks matches nothing.
    public static func matches(
        query: String, sha: String, authorName: String, authorEmail: String, message: String
    ) -> Bool {
        let needle = normalized(query)
        guard !needle.isEmpty else { return false }
        if isIDQuery(needle), sha.lowercased().hasPrefix(needle.lowercased()) { return true }
        return contains(normalized(authorName), needle)
            || contains(normalized(authorEmail), needle)
            || contains(normalized(message), needle)
    }

    private static func contains(_ haystack: String, _ needle: String) -> Bool {
        haystack.range(of: needle, options: .caseInsensitive) != nil
    }
}
