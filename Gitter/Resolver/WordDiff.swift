import Foundation

/// Word-level change marks within one changed line: the stretches of `new` that are not in `old`.
/// Pure. Offsets are UTF-16, as `NSTextView` counts.
///
/// A line is cut into tokens: runs of letters, digits and `_`, runs of whitespace, and every other
/// character on its own. Tokens are equal when their UTF-8 bytes are. The common prefix and suffix
/// of tokens are matched first, then the longest common subsequence of the middle, preferring the
/// later match, so inserted text gathers into one stretch. Marks separated only by whitespace are
/// one mark.
enum WordDiff {
    /// A middle stretch longer than this many token pairs is not searched for common words: it is
    /// marked whole, which bounds the work on a minified line.
    static let searchLimit = 250_000

    /// The stretches of `new` not in `old`; `[0..<new.utf16.count]` when less than half is shared
    /// — measured against the shorter line, in UTF-16 units of non-whitespace text, so a line that
    /// only grew keeps the mark on what it gained — and when `old` is empty. None for an empty
    /// `new`.
    static func marks(old: String, new: String) -> [Range<Int>] {
        let length = new.utf16.count
        guard length > 0 else { return [] }
        let whole = [0..<length]
        guard !old.isEmpty else { return whole }
        let oldTokens = tokens(of: old), newTokens = tokens(of: new)
        guard let matched = matches(oldTokens, newTokens) else { return whole }

        let shared = newTokens.indices.reduce(0) { sum, index in
            matched[index] && !newTokens[index].isSpace ? sum + newTokens[index].range.count : sum
        }
        let shorter = min(solidLength(oldTokens), solidLength(newTokens))
        guard shorter > 0, shared * 2 >= shorter else { return whole }

        // Unmatched tokens become marks; a gap of whitespace alone between two marks joins them.
        var marks: [Range<Int>] = []
        var index = 0
        while index < newTokens.count {
            guard !matched[index] else {
                index += 1
                continue
            }
            var end = index
            while end + 1 < newTokens.count, !matched[end + 1] { end += 1 }
            let range = newTokens[index].range.lowerBound..<newTokens[end].range.upperBound
            if let last = marks.last, isSpaceOnly(newTokens, from: last.upperBound, to: range.lowerBound) {
                marks[marks.count - 1] = last.lowerBound..<range.upperBound
            } else {
                marks.append(range)
            }
            index = end + 1
        }
        return marks
    }

    // MARK: - Tokens

    struct Token {
        let bytes: [UInt8]
        let range: Range<Int>
        let isSpace: Bool
    }

    private enum Kind: Equatable { case space, word, other }

    private static func kind(of character: Character) -> Kind {
        if character.isWhitespace { return .space }
        if character.isLetter || character.isNumber || character == "_" { return .word }
        return .other
    }

    static func tokens(of text: String) -> [Token] {
        var tokens: [Token] = []
        var current = "", currentKind: Kind?, start = 0, offset = 0
        func flush() {
            guard let kind = currentKind else { return }
            tokens.append(Token(bytes: Array(current.utf8), range: start..<offset, isSpace: kind == .space))
            current = ""
            currentKind = nil
        }
        for character in text {
            let kind = kind(of: character)
            if kind == .other || kind != currentKind { flush() }
            if currentKind == nil {
                currentKind = kind
                start = offset
            }
            current.append(character)
            offset += character.utf16.count
            if kind == .other { flush() }
        }
        flush()
        return tokens
    }

    private static func solidLength(_ tokens: [Token]) -> Int {
        tokens.reduce(0) { $0 + ($1.isSpace ? 0 : $1.range.count) }
    }

    private static func isSpaceOnly(_ tokens: [Token], from start: Int, to end: Int) -> Bool {
        tokens.allSatisfy { token in
            token.range.upperBound <= start || token.range.lowerBound >= end || token.isSpace
        }
    }

    // MARK: - Matching

    /// For each token of `new`, whether it is matched in `old`; nil when the middle is too large to
    /// search.
    private static func matches(_ old: [Token], _ new: [Token]) -> [Bool]? {
        var matched = [Bool](repeating: false, count: new.count)
        var prefix = 0
        while prefix < old.count, prefix < new.count, old[prefix].bytes == new[prefix].bytes {
            matched[prefix] = true
            prefix += 1
        }
        var suffix = 0
        while suffix < old.count - prefix, suffix < new.count - prefix,
            old[old.count - 1 - suffix].bytes == new[new.count - 1 - suffix].bytes
        {
            matched[new.count - 1 - suffix] = true
            suffix += 1
        }
        let oldMiddle = Array(old[prefix..<(old.count - suffix)])
        let newMiddle = Array(new[prefix..<(new.count - suffix)])
        guard !oldMiddle.isEmpty, !newMiddle.isEmpty else { return matched }
        guard oldMiddle.count * newMiddle.count <= searchLimit else { return nil }

        // lengths[i][j]: the longest common subsequence of oldMiddle[..<i] and newMiddle[..<j].
        let rows = oldMiddle.count + 1, columns = newMiddle.count + 1
        var lengths = [Int](repeating: 0, count: rows * columns)
        for i in 1..<rows {
            for j in 1..<columns {
                lengths[i * columns + j] =
                    oldMiddle[i - 1].bytes == newMiddle[j - 1].bytes
                    ? lengths[(i - 1) * columns + j - 1] + 1
                    : max(lengths[(i - 1) * columns + j], lengths[i * columns + j - 1])
            }
        }
        // Walk back from the end, matching as late as possible.
        var i = oldMiddle.count, j = newMiddle.count
        while i > 0, j > 0 {
            if oldMiddle[i - 1].bytes == newMiddle[j - 1].bytes {
                matched[prefix + j - 1] = true
                i -= 1
                j -= 1
            } else if lengths[i * columns + j - 1] >= lengths[(i - 1) * columns + j] {
                j -= 1
            } else {
                i -= 1
            }
        }
        return matched
    }
}
