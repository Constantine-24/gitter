import Foundation

// How git spells paths in a diff, and how to read them back.
//
// Two renderings have to be undone. git terminates a name on a `---`/`+++` line with a TAB
// as soon as the rendered name contains a space, and it C-quotes a name that contains any
// byte `quote_c_style` escapes — which, under the default `core.quotepath`, means every
// non-ASCII byte, written as three octal digits.
extension DiffParser {

    struct DiffGitHeader {
        let oldPath: String
        let newPath: String
    }

    static func parseDiffGitHeader(_ line: String) -> DiffGitHeader? {
        if let match = line.wholeMatch(of: /^diff --git a\/(.*) b\/(.*)$/) {
            return DiffGitHeader(
                oldPath: unquoteIfNeeded(String(match.1)),
                newPath: unquoteIfNeeded(String(match.2))
            )
        }
        if let match = line.wholeMatch(of: /^diff --git "(.*)" "(.*)"$/) {
            var old = unquoteIfNeeded("\"\(match.1)\"")
            var new = unquoteIfNeeded("\"\(match.2)\"")
            if old.hasPrefix("a/") { old = String(old.dropFirst(2)) }
            if new.hasPrefix("b/") { new = String(new.dropFirst(2)) }
            return DiffGitHeader(oldPath: old, newPath: new)
        }
        return nil
    }

    /// The name on a `---`/`+++` line.
    ///
    /// git terminates the name with a TAB whenever the rendered name contains a space (and a
    /// traditional diff puts a timestamp after that TAB), so the name is not simply the rest
    /// of the line. A quoted name ends at its closing quote; an unquoted one cannot contain a
    /// TAB, because `quote_c_style` would have quoted it, so it ends at the first TAB.
    static func parseUnifiedPath(_ line: String, markerLength: Int, prefix: String) -> String? {
        var rest = String(line.dropFirst(markerLength))
        if !rest.hasPrefix("\""), let tab = rest.firstIndex(of: "\t") {
            rest = String(rest[..<tab])
        }
        if rest == "/dev/null" { return nil }
        var path = unquoteIfNeeded(rest)
        if path.hasPrefix(prefix) {
            path = String(path.dropFirst(prefix.count))
        }
        return path
    }

    /// Undoes git's `quote_c_style` when a name is quoted, and leaves it alone otherwise.
    /// Anything after the closing quote (git's separating TAB) is discarded.
    static func unquoteIfNeeded(_ string: String) -> String {
        guard string.hasPrefix("\"") else { return string }
        return unquoteCStyle(string) ?? string
    }

    /// git's `unquote_c_style`, byte for byte.
    ///
    /// Decoding has to happen on bytes, not characters: under the default `core.quotepath`
    /// git escapes every non-ASCII byte as three octal digits, so `é` arrives as `\303\251`
    /// and only reassembling those two bytes yields the real name. Returns nil for anything
    /// that is not a well-formed quoted string, so the caller can fall back to the raw text.
    static func unquoteCStyle(_ quoted: String) -> String? {
        let bytes = Array(quoted.utf8)
        guard bytes.first == UInt8(ascii: "\"") else { return nil }
        var out: [UInt8] = []
        var index = 1

        while index < bytes.count {
            let byte = bytes[index]
            index += 1
            if byte == UInt8(ascii: "\"") { return String(decoding: out, as: UTF8.self) }
            guard byte == UInt8(ascii: "\\") else {
                out.append(byte)
                continue
            }
            guard index < bytes.count else { return nil }
            let escape = bytes[index]
            index += 1
            switch escape {
            case UInt8(ascii: "a"): out.append(0x07)
            case UInt8(ascii: "b"): out.append(0x08)
            case UInt8(ascii: "t"): out.append(0x09)
            case UInt8(ascii: "n"): out.append(0x0A)
            case UInt8(ascii: "v"): out.append(0x0B)
            case UInt8(ascii: "f"): out.append(0x0C)
            case UInt8(ascii: "r"): out.append(0x0D)
            case UInt8(ascii: "\""), UInt8(ascii: "\\"): out.append(escape)
            case UInt8(ascii: "0")...UInt8(ascii: "7"):
                // Always exactly three digits, which is what `quote_c_style` emits.
                var value = Int(escape - UInt8(ascii: "0"))
                for _ in 0..<2 {
                    guard index < bytes.count,
                        (UInt8(ascii: "0")...UInt8(ascii: "7")).contains(bytes[index])
                    else { return nil }
                    value = value * 8 + Int(bytes[index] - UInt8(ascii: "0"))
                    index += 1
                }
                guard value <= 0xFF else { return nil }
                out.append(UInt8(value))
            default: return nil
            }
        }
        return nil  // No closing quote.
    }
}
