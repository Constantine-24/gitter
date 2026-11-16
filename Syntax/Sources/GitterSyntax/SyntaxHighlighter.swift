import Foundation
import SwiftTreeSitter
import Synchronization

/// A run of text that gets one syntax colour.
public struct SyntaxToken: Hashable, Sendable {
    /// UTF-16 offsets into the text the token came from (or, from `lineTokens`, into its line).
    public let range: Range<Int>
    public let kind: SyntaxKind

    public init(range: Range<Int>, kind: SyntaxKind) {
        self.range = range
        self.kind = kind
    }
}

/// Turns text into syntax-colour tokens with Tree-sitter.
///
/// Everything here is synchronous and safe to call from any thread; callers keep it off the
/// main actor, because a parse and its query take tens of milliseconds on a large file and a
/// query's first compile up to about 100 ms. Whatever can't be coloured correctly comes back as
/// no tokens, which the callers draw exactly as today: plain beats wrong.
public enum SyntaxHighlighter {
    /// Texts longer than this many UTF-8 bytes stay plain.
    public static let maxBytes = 1_000_000
    /// Texts with more lines than this stay plain. A final line break doesn't start a line.
    public static let maxLines = 20_000
    /// How long one parse may run before it gives up, and the text stays plain.
    static let parseTimeout: TimeInterval = 0.5

    /// The tokens for `text`, sorted and non-overlapping, where captures nest the innermost wins
    /// (a string's interpolated expression is not string-coloured), and among captures of the
    /// same range the one from the later query pattern wins, as the queries are written.
    ///
    /// Empty when the text is over a limit, the language's queries didn't load, or the parse
    /// failed or timed out.
    public static func tokens(in text: String, language: SyntaxLanguage) -> [SyntaxToken] {
        guard isWithinLimits(text), let highlights = highlights(for: language) else { return [] }
        let parser = Parser()
        guard (try? parser.setLanguage(language.grammar)) != nil else { return [] }
        parser.timeout = parseTimeout
        guard let tree = parser.parse(text) else { return [] }

        let length = text.utf16.count
        var captures: [Capture] = []
        let matches = highlights.query.execute(in: tree).resolve(with: .init(string: text))
        for match in matches where !highlights.unevaluable.contains(match.patternIndex) {
            for capture in match.captures {
                guard let paint = highlights.paint[capture.index] else { continue }
                let lower = max(0, capture.range.lowerBound)
                let upper = min(length, capture.range.upperBound)
                guard lower < upper else { continue }
                captures.append(Capture(range: lower..<upper, paint: paint,
                                        pattern: capture.patternIndex, order: captures.count))
            }
        }
        return flatten(captures, length: length)
    }

    /// `tokens` split into one array per line, with ranges relative to the line's start.
    ///
    /// Lines end at `\n`, and a `\r` just before it belongs to the line's terminator, not its
    /// text; the split works on UTF-16 code units, because `"\r\n"` is one `Character`. A token
    /// that spans lines becomes one token on each, and no token reaches into a terminator. The
    /// tokens must be sorted and disjoint, as `tokens` returns them.
    public static func lineTokens(_ tokens: [SyntaxToken], in text: String) -> [[SyntaxToken]] {
        var lines: [Range<Int>] = []
        var lineStart = 0
        var offset = 0
        var previous: UInt16 = 0
        for unit in text.utf16 {
            if unit == 0x0A {
                lines.append(lineStart..<(previous == 0x0D ? offset - 1 : offset))
                lineStart = offset + 1
            }
            previous = unit
            offset += 1
        }
        lines.append(lineStart..<offset)

        var result = [[SyntaxToken]](repeating: [], count: lines.count)
        var first = 0
        for token in tokens {
            while first + 1 < lines.count, lines[first + 1].lowerBound <= token.range.lowerBound {
                first += 1
            }
            var line = first
            while line < lines.count, lines[line].lowerBound < token.range.upperBound {
                let text = lines[line]
                let lower = max(token.range.lowerBound, text.lowerBound)
                let upper = min(token.range.upperBound, text.upperBound)
                if lower < upper {
                    let range = (lower - text.lowerBound)..<(upper - text.lowerBound)
                    result[line].append(SyntaxToken(range: range, kind: token.kind))
                }
                line += 1
            }
        }
        return result
    }

    // MARK: - Limits

    static func isWithinLimits(_ text: String) -> Bool {
        let utf8 = text.utf8
        guard utf8.count <= maxBytes else { return false }
        var breaks = 0
        for byte in utf8 where byte == 0x0A {
            breaks += 1
            if breaks > maxLines { return false }
        }
        let lines = breaks + (utf8.isEmpty || utf8.last == 0x0A ? 0 : 1)
        return lines <= maxLines
    }

    // MARK: - Flattening

    /// One capture of a match: its range, what it paints (0 for plain, else a kind's code), and
    /// its query pattern and position for ties.
    private struct Capture {
        let range: Range<Int>
        let paint: UInt8
        let pattern: Int
        let order: Int
    }

    /// Paints the captures over the text, outer ones first, so an inner capture overwrites the
    /// part of an outer one it covers; at equal ranges the later pattern paints last. Tree-sitter
    /// captures are nodes, so two ranges are always nested or disjoint. Then each run of one
    /// kind becomes a token.
    private static func flatten(_ captures: [Capture], length: Int) -> [SyntaxToken] {
        guard !captures.isEmpty else { return [] }
        let ordered = captures.sorted { a, b in
            if a.range.count != b.range.count { return a.range.count > b.range.count }
            if a.pattern != b.pattern { return a.pattern < b.pattern }
            return a.order < b.order
        }
        var paint = [UInt8](repeating: 0, count: length)
        paint.withUnsafeMutableBufferPointer { buffer in
            for capture in ordered {
                UnsafeMutableBufferPointer(rebasing: buffer[capture.range]).update(repeating: capture.paint)
            }
        }

        let kinds = SyntaxKind.allCases
        var tokens: [SyntaxToken] = []
        var start = 0
        while start < length {
            let value = paint[start]
            var end = start + 1
            while end < length, paint[end] == value { end += 1 }
            if value != 0 {
                tokens.append(SyntaxToken(range: start..<end, kind: kinds[Int(value) - 1]))
            }
            start = end
        }
        return tokens
    }

    // MARK: - Queries

    /// A language's compiled highlight query, and for each of its capture ids what that capture
    /// paints: nil when it is ignored, 0 for plain, else the kind's index in `allCases` plus 1.
    ///
    /// Plain captures still paint: a `variable` inside a string's interpolation must clear the
    /// string's colour. Ignored ones are spell-check markers (`spell`, on the same node as
    /// `comment`) and private helper captures (`_name`), which would otherwise clear real colours.
    ///
    /// `unevaluable` holds the patterns guarded by `#is?` or `#is-not?`, which ask about scopes
    /// (`local`) the binding doesn't track. It would answer "not local" for everything, so Ruby's
    /// `((identifier) @function.method (#is-not? local))` would colour every local variable as a
    /// method; those patterns never match instead (ledger Ruling 2).
    struct Highlights: Sendable {
        let query: Query
        let paint: [UInt8?]
        let unevaluable: Set<Int>
    }

    private struct Cache {
        /// nil for a language whose queries failed to load or compile, so it isn't tried again.
        var highlights: [SyntaxLanguage: Highlights?] = [:]
        var compiles = 0
    }

    private static let cache = Mutex(Cache())

    /// How many times a language's queries have been loaded and compiled, for the tests.
    static var compiledCount: Int { cache.withLock { $0.compiles } }

    /// Every capture name the language's compiled query can emit, or nil when it didn't load.
    static func captureNames(for language: SyntaxLanguage) -> [String]? {
        guard let query = highlights(for: language)?.query else { return nil }
        return (0..<query.captureCount).compactMap { query.captureName(for: $0) }
    }

    /// The language's highlights, compiled once. The compile runs inside the lock, so two
    /// threads asking for the same language at once still compile it once.
    static func highlights(for language: SyntaxLanguage) -> Highlights? {
        cache.withLock { cache in
            if let cached = cache.highlights[language] { return cached }
            cache.compiles += 1
            let compiled = compile(language)
            cache.highlights[language] = .some(compiled)
            return compiled
        }
    }

    private static func compile(_ language: SyntaxLanguage) -> Highlights? {
        var source = Data()
        for (bundle, file) in language.queryFiles {
            guard let directory = queriesDirectory(bundle),
                  let data = try? Data(contentsOf: directory.appendingPathComponent("\(file).scm"))
            else { return nil }
            source.append(data)
            source.append(0x0A)
        }
        guard let query = try? Query(language: language.grammar, data: source) else { return nil }
        let kinds = SyntaxKind.allCases
        let paint = (0..<query.captureCount).map { id -> UInt8? in
            guard let name = query.captureName(for: id), name != "spell", !name.hasPrefix("_") else {
                return nil
            }
            guard let kind = SyntaxKind(capture: name), let index = kinds.firstIndex(of: kind) else {
                return 0
            }
            return UInt8(index + 1)
        }
        let unevaluable = Set((0..<query.patternCount).filter { pattern in
            query.predicates(for: pattern).contains { predicate in
                switch predicate {
                case .isNot: true
                case .generic(let name, _, _): name == "is?" || name == "is-not?"
                default: false
                }
            }
        })
        return Highlights(query: query, paint: paint, unevaluable: unevaluable)
    }

    /// The `queries` folder of a grammar's SwiftPM resource bundle. In the app the bundles are in
    /// its Resources; in the package tests they sit next to the test bundle. The binding's own
    /// lookup finds neither, so this checks the main bundle's resources, then each loaded
    /// bundle's resources and the folder that holds it.
    private static func queriesDirectory(_ bundleName: String) -> URL? {
        var folders: [URL] = []
        if let resources = Bundle.main.resourceURL { folders.append(resources) }
        for bundle in Bundle.allBundles + Bundle.allFrameworks {
            if let resources = bundle.resourceURL { folders.append(resources) }
            folders.append(bundle.bundleURL.deletingLastPathComponent())
        }
        for folder in folders {
            let queries = folder.appendingPathComponent("\(bundleName).bundle/Contents/Resources/queries")
            if FileManager.default.fileExists(atPath: queries.path) { return queries }
        }
        return nil
    }
}
