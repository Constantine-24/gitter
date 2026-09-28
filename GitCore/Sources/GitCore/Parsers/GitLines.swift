import Foundation

/// Lines of text git printed, cut where git cut them: at the `\n` byte and nowhere else.
///
/// Neither of Swift's obvious splits does that. `split(separator: "\n")` compares
/// `Character`s, and `"\r\n"` is ONE `Character`, so a line git ends with a `\r` (a quoted
/// config value may, measured) is not cut from the next one. `split(whereSeparator:
/// \.isNewline)` goes the other way: it also cuts at a `\r`, a vertical tab, a form feed,
/// U+0085 and U+2028/U+2029, all of which can sit inside a name or a path git prints on one
/// line — a remote called `m\u{2028}x`, a linked worktree whose main checkout lives in such a
/// directory. Each line keeps every byte but its `\n`, `\r` included.
enum GitLines {
    /// `data` cut at every `\n` byte. A trailing `\n` does not start one more, empty, line;
    /// empty lines anywhere else are kept.
    static func split(_ data: Data) -> [String] {
        var lines = [UInt8](data).split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        if lines.last?.isEmpty == true { lines.removeLast() }
        return lines.map { String(decoding: $0, as: UTF8.self) }
    }
}
