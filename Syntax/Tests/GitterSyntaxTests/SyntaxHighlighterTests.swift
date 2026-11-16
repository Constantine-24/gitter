import Testing

@testable import GitterSyntax

/// The text in `range`, a range of UTF-16 offsets as `SyntaxToken` gives them.
func slice(_ text: String, _ range: Range<Int>) -> String {
    let utf16 = text.utf16
    let start = utf16.index(utf16.startIndex, offsetBy: range.lowerBound)
    let end = utf16.index(utf16.startIndex, offsetBy: range.upperBound)
    return String(utf16[start..<end])!
}

/// The UTF-16 range of the `occurrence`-th (0-based) appearance of `needle` in `text`.
func utf16Range(of needle: String, in text: String, occurrence: Int = 0) -> Range<Int>? {
    var searchStart = text.startIndex
    var found = 0
    while let range = text.range(of: needle, range: searchStart..<text.endIndex) {
        if found == occurrence {
            let lower = text.utf16.distance(from: text.utf16.startIndex, to: range.lowerBound)
            return lower..<(lower + needle.utf16.count)
        }
        found += 1
        searchStart = range.upperBound
    }
    return nil
}

/// A small text per language and the colours some of its pieces must get, each over exactly
/// that piece.
struct Sample: Sendable, CustomTestStringConvertible {
    let language: SyntaxLanguage
    let text: String
    let expected: [(SyntaxKind, String)]

    var testDescription: String { language.rawValue }
}

@Suite struct SyntaxHighlighterTests {

    static let samples: [Sample] = [
        Sample(language: .swift, text: "import Foundation\n// note\nlet s = \"hi\"\n",
               expected: [(.keyword, "import"), (.comment, "// note"), (.keyword, "let"), (.string, "\"hi\"")]),
        Sample(language: .python, text: "import os\n# note\nx = \"hi\"\n",
               expected: [(.keyword, "import"), (.comment, "# note"), (.string, "\"hi\"")]),
        Sample(language: .javascript, text: "const x = \"hi\"; // note\nfoo(1);\n",
               expected: [(.keyword, "const"), (.string, "\"hi\""), (.comment, "// note"),
                          (.function, "foo"), (.number, "1")]),
        Sample(language: .typescript, text: "let n: number = 1; // note\n",
               expected: [(.keyword, "let"), (.type, "number"), (.number, "1"), (.comment, "// note")]),
        Sample(language: .tsx, text: "const a = <div className=\"x\">hi</div>; // note\n",
               expected: [(.keyword, "const"), (.string, "\"x\""), (.comment, "// note")]),
        Sample(language: .json, text: "{\"a\": \"b\", \"n\": 1, \"t\": true}\n",
               expected: [(.string, "\"a\""), (.string, "\"b\""), (.number, "1"), (.keyword, "true")]),
        Sample(language: .html, text: "<!-- note -->\n<p class=\"x\">hi</p>\n",
               expected: [(.comment, "<!-- note -->"), (.keyword, "p"), (.attribute, "class")]),
        Sample(language: .css, text: "/* note */\n@media screen { a { width: 10px; content: \"x\"; } }\n",
               expected: [(.comment, "/* note */"), (.keyword, "@media"), (.string, "\"x\"")]),
        Sample(language: .scss, text: "// note\n@mixin m { color: red; content: \"x\"; }\n",
               expected: [(.comment, "// note"), (.keyword, "@mixin"), (.string, "\"x\"")]),
        Sample(language: .markdown, text: "# Title\n\n```\ncode\n```\n\n[ref]: https://example.com\n",
               expected: [(.keyword, "Title"), (.url, "https://example.com")]),
        Sample(language: .yaml, text: "# note\nkey: \"v\"\nn: 1\nb: true\n",
               expected: [(.comment, "# note"), (.string, "\"v\""), (.number, "1"), (.keyword, "true")]),
        Sample(language: .shell, text: "# note\nif true; then echo \"hi\"; fi\n",
               expected: [(.comment, "# note"), (.keyword, "if"), (.string, "\"hi\"")]),
        Sample(language: .c, text: "// note\nint main(void) { return 0; }\nchar *s = \"hi\";\n",
               expected: [(.comment, "// note"), (.keyword, "return"), (.type, "int"), (.number, "0"),
                          (.string, "\"hi\"")]),
        Sample(language: .cpp, text: "// note\nclass A { public: int x = 1; };\nauto s = \"hi\";\n",
               expected: [(.comment, "// note"), (.keyword, "class"), (.string, "\"hi\"")]),
        Sample(language: .go, text: "package main\n// note\nfunc f() string { return \"hi\" }\n",
               expected: [(.keyword, "package"), (.comment, "// note"), (.keyword, "func"),
                          (.keyword, "return"), (.string, "\"hi\"")]),
        Sample(language: .rust, text: "// note\nfn main() { let s = \"hi\"; }\n",
               expected: [(.comment, "// note"), (.keyword, "fn"), (.keyword, "let"), (.string, "\"hi\"")]),
        Sample(language: .ruby, text: "# note\ndef f\n  \"hi\"\nend\n",
               expected: [(.comment, "# note"), (.keyword, "def"), (.keyword, "end"), (.string, "\"hi\"")]),
        Sample(language: .java, text: "// note\nclass A { String s = \"hi\"; int n = 1; }\n",
               expected: [(.comment, "// note"), (.keyword, "class"), (.string, "\"hi\""), (.number, "1")]),
        Sample(language: .kotlin, text: "// note\nfun f(): String = \"hi\"\nval n = 1\n",
               expected: [(.comment, "// note"), (.keyword, "fun"), (.keyword, "val"), (.number, "1")]),
    ]

    @Test func everyLanguageHasASample() {
        #expect(Set(Self.samples.map(\.language)) == Set(SyntaxLanguage.allCases))
    }

    /// Each expected piece is one token of the expected kind, starting and ending exactly there.
    @Test(arguments: samples)
    func everyLanguageColoursASample(sample: Sample) {
        let tokens = SyntaxHighlighter.tokens(in: sample.text, language: sample.language)
        let found = tokens.map { ($0.kind, slice(sample.text, $0.range)) }
        for (kind, piece) in sample.expected {
            #expect(found.contains { $0 == (kind, piece) },
                    "\(sample.language): \(kind) over \(piece.debugDescription); got \(found)")
        }
    }

    /// Offsets count UTF-16 code units: "é" is two UTF-8 bytes and one unit, and "😀" is four
    /// bytes, two units and one scalar, so a keyword after them on the same line lands exactly
    /// only when the units are counted.
    @Test func nonASCIIOffsetsAreUTF16() throws {
        let text = "let e = \"é😀\"; let x = 1\n"
        let tokens = SyntaxHighlighter.tokens(in: text, language: .swift)
        let secondLet = try #require(utf16Range(of: "let", in: text, occurrence: 1))
        #expect(secondLet == 15..<18)
        #expect(tokens.contains(SyntaxToken(range: secondLet, kind: .keyword)))
        #expect(tokens.contains { $0.kind == .string && slice(text, $0.range).contains("é😀") })
    }

    /// Every capture name any language's compiled query can emit either gets a colour or is
    /// listed here on purpose, so a capture a pin raise brings in fails until someone decides.
    /// Spell-check markers and `_` helpers are ignored outright; the rest paint plain, so they
    /// clear an enclosing capture's colour.
    static let deliberatelyPlain: Set<String> = [
        "variable", "variable.member", "variable.parameter", "property", "operator", "delimiter",
        "punctuation.bracket", "punctuation.delimiter", "punctuation.special", "label",
        "namespace", "parameter", "embedded", "none", "spell", "_class", "_function",
    ]

    @Test(arguments: SyntaxLanguage.allCases)
    func everyEmittedCaptureIsMapped(language: SyntaxLanguage) throws {
        let names = try #require(SyntaxHighlighter.captureNames(for: language),
                                 "\(language)'s query did not load")
        #expect(!names.isEmpty)
        for name in names {
            let mapped = SyntaxKind(capture: name) != nil
            #expect(mapped || Self.deliberatelyPlain.contains(name),
                    "\(language) emits \(name.debugDescription), neither mapped nor deliberately plain")
            #expect(!(mapped && Self.deliberatelyPlain.contains(name)),
                    "\(name.debugDescription) is mapped but listed as deliberately plain")
        }
    }

    /// Nested captures (an interpolation inside a string, a doc comment) come out as sorted,
    /// non-empty, non-overlapping tokens, and the innermost capture wins: the interpolated
    /// expression isn't string-coloured.
    @Test func tokensAreSortedAndDisjoint() throws {
        let text = "/// Doc comment\nlet s = \"a \\(b + 1) c\"\n"
        let tokens = SyntaxHighlighter.tokens(in: text, language: .swift)
        #expect(!tokens.isEmpty)
        for token in tokens { #expect(!token.range.isEmpty) }
        for (a, b) in zip(tokens, tokens.dropFirst()) {
            #expect(a.range.upperBound <= b.range.lowerBound, "\(a) overlaps or precedes \(b)")
        }
        #expect(tokens.contains(SyntaxToken(range: 0..<15, kind: .comment)))
        let b = try #require(utf16Range(of: "b + 1", in: text)).lowerBound
        #expect(!tokens.contains { $0.range.contains(b) && $0.kind == .string })
        let one = try #require(utf16Range(of: "1", in: text))
        #expect(tokens.contains(SyntaxToken(range: one, kind: .number)))
        let a = try #require(utf16Range(of: "a ", in: text)).lowerBound
        #expect(tokens.contains { $0.range.contains(a) && $0.kind == .string })
    }

    /// Where two patterns capture the same node, the later pattern in the query wins, as the
    /// queries are written: Python's general `(identifier) @variable` comes first and its call
    /// patterns later. Tree-sitter returns the call pattern's match first (it starts higher in
    /// the tree), so going by the order matches arrive would leave both calls plain.
    @Test func laterPatternWinsAtTheSameRange() throws {
        let text = "print(len(x))\n"
        let tokens = SyntaxHighlighter.tokens(in: text, language: .python)
        #expect(tokens.contains(SyntaxToken(range: try #require(utf16Range(of: "print", in: text)),
                                             kind: .function)))
        #expect(tokens.contains(SyntaxToken(range: try #require(utf16Range(of: "len", in: text)),
                                             kind: .function)))
        let x = try #require(utf16Range(of: "x", in: text)).lowerBound
        #expect(!tokens.contains { $0.range.contains(x) })
    }

    /// A text over either limit isn't parsed at all; one exactly at the limit still is, so the
    /// empty answer comes from the limit and not from a sample that has nothing to colour.
    @Test func overLimitTextIsPlain() {
        let atBytes = "// " + String(repeating: "a", count: SyntaxHighlighter.maxBytes - 3)
        #expect(atBytes.utf8.count == 1_000_000)
        #expect(!SyntaxHighlighter.tokens(in: atBytes, language: .javascript).isEmpty)
        let overBytes = atBytes + "a"
        #expect(SyntaxHighlighter.tokens(in: overBytes, language: .javascript) == [])

        let atLines = String(repeating: "// c\n", count: SyntaxHighlighter.maxLines)
        #expect(!SyntaxHighlighter.tokens(in: atLines, language: .javascript).isEmpty)
        let overLines = atLines + "// c"
        #expect(SyntaxHighlighter.tokens(in: overLines, language: .javascript) == [])
    }

    /// Lines split on `\n`, with a `\r` before it belonging to the line, and no token reaching
    /// into a line terminator. A block comment over two lines becomes one token on each.
    @Test func lineTokensSplitsCRLFAndMultiLineTokens() throws {
        let text = "int a; /* x\r\ny */\r\nint b;"
        let lines = SyntaxHighlighter.lineTokens(
            SyntaxHighlighter.tokens(in: text, language: .c), in: text)
        try #require(lines.count == 3)
        let open = try #require(utf16Range(of: "/*", in: text)).lowerBound
        #expect(lines[0].contains(SyntaxToken(range: open..<(open + 4), kind: .comment)))
        #expect(lines[0].allSatisfy { $0.range.upperBound <= 11 })
        #expect(lines[1] == [SyntaxToken(range: 0..<4, kind: .comment)])
        // tree-sitter-c captures `int` as `(primitive_type) @type`.
        #expect(lines[2].first == SyntaxToken(range: 0..<3, kind: .type))
    }

    /// A line comment on a CRLF line can include the `\r` in its node; the line's token stops
    /// before it, so the token never runs past the line's text.
    @Test func lineTokensClipLineCommentsBeforeCR() {
        let text = "// a\r\nint b;\r\n"
        let lines = SyntaxHighlighter.lineTokens(
            SyntaxHighlighter.tokens(in: text, language: .c), in: text)
        #expect(lines.count == 3)
        #expect(lines[0] == [SyntaxToken(range: 0..<4, kind: .comment)])
        #expect(lines[2] == [])
    }

    /// The compiled query is cached, a failed one too: once every language has been used, there
    /// has been exactly one compile each, and no later call compiles. Every language is warmed
    /// first so that tests running in parallel can't move the count.
    @Test func queriesCompileOncePerLanguage() {
        for language in SyntaxLanguage.allCases {
            _ = SyntaxHighlighter.tokens(in: "x", language: language)
        }
        let before = SyntaxHighlighter.compiledCount
        #expect(before == SyntaxLanguage.allCases.count)
        _ = SyntaxHighlighter.tokens(in: "let x = 1", language: .swift)
        _ = SyntaxHighlighter.tokens(in: "x = 1", language: .python)
        #expect(SyntaxHighlighter.compiledCount == before)
    }
}
