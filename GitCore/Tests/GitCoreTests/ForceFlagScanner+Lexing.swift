import Foundation

/// `ForceFlagScanner`'s lexer: the part that turns Swift source text into argument vectors.
///
/// Split from the rules in `ForceFlagScanner.swift` purely for length. Nothing here knows
/// what a dangerous flag is; it only answers "which string literals appear where". The
/// members are internal rather than private only because they now live in a second file.
extension ForceFlagScanner {
    /// `code` with every comment and every string literal's *contents* replaced by spaces, so
    /// brackets, commas and quotes inside them cannot shift the parse. Offsets line up with
    /// `source` byte for byte (UTF-8 scalar for scalar), so a literal's position in `code`
    /// indexes straight back into `source`.
    static func strippingCommentsAndStringContents(_ source: String) -> [Character] {
        var out: [Character] = []
        out.reserveCapacity(source.count)
        var characters = Array(source)
        var index = 0
        var blockDepth = 0

        while index < characters.count {
            let c = characters[index]
            let next = index + 1 < characters.count ? characters[index + 1] : "\0"

            if blockDepth > 0 {
                if c == "*", next == "/" { blockDepth -= 1; out.append(contentsOf: "  "); index += 2; continue }
                if c == "/", next == "*" { blockDepth += 1; out.append(contentsOf: "  "); index += 2; continue }
                out.append(c == "\n" ? "\n" : " ")
                index += 1
                continue
            }
            if c == "/", next == "*" { blockDepth = 1; out.append(contentsOf: "  "); index += 2; continue }
            if c == "/", next == "/" {
                while index < characters.count, characters[index] != "\n" { out.append(" "); index += 1 }
                continue
            }
            if c == "\"" {
                // Keep the quotes (so literals stay findable) and blank the contents.
                out.append("\"")
                index += 1
                while index < characters.count {
                    let s = characters[index]
                    if s == "\\", index + 1 < characters.count {
                        out.append(contentsOf: "  ")
                        index += 2
                        continue
                    }
                    if s == "\"" { out.append("\""); index += 1; break }
                    out.append(s == "\n" ? "\n" : " ")
                    index += 1
                }
                continue
            }
            out.append(c)
            index += 1
        }
        characters = []
        return out
    }

    /// The string literal passed to each `.append("…")`, which is how a flag gets added to an
    /// argument vector without ever appearing inside an array literal. A non-literal argument
    /// (`arguments.append(file.path)`) yields nothing.
    static func appendedLiterals(in source: String, code: [Character]) -> [String] {
        let raw = Array(source)
        let marker = Array(".append(")
        var result: [String] = []
        var index = 0

        while index + marker.count < code.count {
            guard Array(code[index..<(index + marker.count)]) == marker else { index += 1; continue }
            var start = index + marker.count
            while start < code.count, code[start] == " " || code[start] == "\n" { start += 1 }
            guard start < code.count, code[start] == "\"" else { index += marker.count; continue }
            var end = start + 1
            while end < code.count, code[end] != "\"" { end += 1 }
            guard end < code.count else { break }
            result.append(String(raw[(start + 1)..<end]))
            index = end + 1
        }
        return result
    }

    /// Every string literal in the file as (offset in `source`, value).
    static func literals(in source: String, code: [Character]) -> [(Int, String)] {
        let raw = Array(source)
        var result: [(Int, String)] = []
        var index = 0
        while index < code.count {
            guard code[index] == "\"" else { index += 1; continue }
            var end = index + 1
            while end < code.count, code[end] != "\"" { end += 1 }
            guard end < code.count else { break }
            result.append((index, String(raw[(index + 1)..<end])))
            index = end + 1
        }
        return result
    }

    /// Each `[...]` array literal's top-level elements: the literal's value, or nil for an
    /// element that is not a plain string literal.
    static func argumentArrays(in source: String, code: [Character]) -> [[String?]] {
        let raw = Array(source)
        var result: [[String?]] = []

        for open in code.indices where code[open] == "[" {
            var depth = 0
            var close = open
            var found = false
            while close < code.count {
                if "[({".contains(code[close]) { depth += 1 }
                if "])}".contains(code[close]) {
                    depth -= 1
                    if depth == 0 { found = true; break }
                }
                close += 1
            }
            guard found, close > open + 1 else { continue }
            result.append(elements(raw: raw, code: code, from: open + 1, to: close))
        }
        return result
    }

    static func elements(
        raw: [Character], code: [Character], from start: Int, to end: Int
    ) -> [String?] {
        var elements: [String?] = []
        var current: [Character] = []
        var currentLiteral: String?
        var literalCount = 0
        var depth = 0
        var index = start

        func flush() {
            let trimmed = String(current).trimmingCharacters(in: .whitespacesAndNewlines)
            elements.append(literalCount == 1 && trimmed.hasPrefix("\"") && trimmed.hasSuffix("\"")
                ? currentLiteral : nil)
            current = []
            currentLiteral = nil
            literalCount = 0
        }

        while index < end {
            let c = code[index]
            if "[({".contains(c) { depth += 1 }
            if "])}".contains(c) { depth -= 1 }
            if c == "," && depth == 0 { flush(); index += 1; continue }
            if c == "\"" {
                var stop = index + 1
                while stop < end, code[stop] != "\"" { stop += 1 }
                guard stop < end else { break }
                currentLiteral = String(raw[(index + 1)..<stop])
                literalCount += 1
                current += ["\"", "\""]
                index = stop + 1
                continue
            }
            current.append(c)
            index += 1
        }
        flush()
        return elements
    }
}
