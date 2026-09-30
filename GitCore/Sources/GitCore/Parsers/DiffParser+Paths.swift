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

    /// The two names of a `diff --git a/<old> b/<new>` header, read the way git's own
    /// `git_header_name` (apply.c) reads them.
    ///
    /// git quotes each side on its own, so a header is both sides quoted, neither, or — for a
    /// rename or copy between a name it quotes and one it does not — just one of them. With
    /// neither quoted nothing marks where the first name ends, and a name containing ` b/` has
    /// more than one place to split: `a/plan b/blob.bin b/plan b/blob.bin`. Like git, the split
    /// is where the two halves are the same name. Different halves are a rename or a copy, whose
    /// `rename from`/`rename to` (`copy …`) lines name both sides again unambiguously, as do a
    /// diff's `---`/`+++` lines; the header's own reading of those is only a placeholder.
    static func parseDiffGitHeader(_ line: String) -> DiffGitHeader? {
        guard line.utf8.starts(with: gitHeaderLead) else { return nil }
        let rest = Array(line.utf8.dropFirst(gitHeaderLead.count))
        if rest.first != quote, let header = unquotedThenQuoted(rest) ?? sameNameOnBothSides(rest) {
            return header
        }
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
        return quotedThenUnquoted(rest)
    }

    private static let gitHeaderLead = Array("diff --git ".utf8)
    private static let quote = UInt8(ascii: "\"")

    /// `a/P b/P`: split where both halves are the same name — the middle, which is the only
    /// place that can be. Bytes, not characters: a name's bytes are what git compared.
    private static func sameNameOnBothSides(_ rest: [UInt8]) -> DiffGitHeader? {
        guard rest.count >= 5, (rest.count - 5) % 2 == 0 else { return nil }
        let length = (rest.count - 5) / 2
        let first = rest[2..<(2 + length)]
        let separator = rest[(2 + length)..<(5 + length)]
        let second = rest[(5 + length)...]
        guard rest.starts(with: Array("a/".utf8)), separator.elementsEqual(" b/".utf8), first.elementsEqual(second)
        else { return nil }
        let name = String(decoding: first, as: UTF8.self)
        return DiffGitHeader(oldPath: name, newPath: name)
    }

    /// `a/<old> "b/<new>"`. An unquoted name cannot contain a `"` (`quote_c_style` would have
    /// quoted it), so the first one is where the quoted second name begins.
    private static func unquotedThenQuoted(_ rest: [UInt8]) -> DiffGitHeader? {
        guard let start = rest.firstIndex(of: quote), start >= 3, rest[start - 1] == UInt8(ascii: " "),
            quotedEnd(rest, from: start) == rest.count,
            let new = unquoteCStyle(String(decoding: rest[start...], as: UTF8.self)), new.hasPrefix("b/")
        else { return nil }
        return DiffGitHeader(
            oldPath: String(decoding: rest[2..<(start - 1)], as: UTF8.self), newPath: String(new.dropFirst(2)))
    }

    /// `"a/<old>" b/<new>`: the second name is everything after the first one's closing quote
    /// and a space.
    private static func quotedThenUnquoted(_ rest: [UInt8]) -> DiffGitHeader? {
        guard rest.first == quote, let end = quotedEnd(rest, from: 0),
            let old = unquoteCStyle(String(decoding: rest[..<end], as: UTF8.self)), old.hasPrefix("a/")
        else { return nil }
        let second = rest[end...]
        guard second.starts(with: Array(" b/".utf8)), !second.contains(quote) else { return nil }
        return DiffGitHeader(
            oldPath: String(old.dropFirst(2)), newPath: String(decoding: second.dropFirst(3), as: UTF8.self))
    }

    /// The index just past the closing quote of the quoted string that starts at `start`, or
    /// nil when it is not closed. A backslash escapes the byte after it.
    private static func quotedEnd(_ bytes: [UInt8], from start: Int) -> Int? {
        var index = start + 1
        while index < bytes.count {
            if bytes[index] == UInt8(ascii: "\\") {
                index += 2
                continue
            }
            if bytes[index] == quote { return index + 1 }
            index += 1
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
