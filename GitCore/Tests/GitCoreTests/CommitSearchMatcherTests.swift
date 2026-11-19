import Testing

@testable import GitCore

/// F1 Task 1: the Message, Author or ID matcher, which runs in the app over what one `log` read
/// returned (git's `--grep` and `--author` combine by AND, so it cannot do the OR).
@Suite struct CommitSearchMatcherTests {
    private static let sha = "2153ff9c0a1b2c3d4e5f60718293a4b5c6d7e8f9"

    private func matches(
        _ query: String, sha: String = CommitSearchMatcherTests.sha, name: String = "Nobody",
        email: String = "n@n.test", message: String = ""
    ) -> Bool {
        CommitSearchMatcher.matches(query: query, sha: sha, authorName: name, authorEmail: email, message: message)
    }

    @Test func wrappedBodyMatchesAPhrase() {
        #expect(matches("Stash Caption", message: "Fix\n\nthe stash\n  caption of a row\n"))
    }

    @Test func phraseIsNotWords() {
        #expect(!matches("stash caption", message: "caption of the stash"))
    }

    @Test func unicodeFolds() {
        #expect(matches("ёлка", message: "Ёлка"))
    }

    @Test func authorNameOrEmail() {
        #expect(matches("ali", name: "Alice"))
        #expect(matches("x.org", email: "a@x.org"))
        #expect(!matches("bob", name: "Alice", email: "a@x.org"))
    }

    @Test func idPrefix() {
        #expect(matches("2153ff9"))
        #expect(matches("2153FF9"))
        #expect(!matches("153ff9"), "an id is matched from its start")
        #expect(!CommitSearchMatcher.isIDQuery("215"))
        #expect(CommitSearchMatcher.isIDQuery("2153"))
        #expect(!CommitSearchMatcher.isIDQuery("2153ff9z"))
        #expect(!matches("215"), "three characters are text only")
        #expect(!matches("2153ff9z"))
        #expect(matches("2153ff9z", message: "ref 2153ff9z here"), "a non-id query is still text")
        #expect(CommitSearchMatcher.isIDQuery(String(repeating: "a", count: 40)))
        #expect(!CommitSearchMatcher.isIDQuery(String(repeating: "a", count: 41)))
    }

    @Test func literalCharacters() {
        #expect(matches("[regex] (x)", message: "use [regex] (x) here"))
        #expect(!matches("[regex] (x)", message: "use r (x) here"))
        #expect(!matches("a.c", message: "abc"))
    }

    @Test func normalizedCollapsesWhitespaceAndTrims() {
        #expect(CommitSearchMatcher.normalized("  a \t b\n\n c  ") == "a b c")
        #expect(CommitSearchMatcher.normalized(" \n ") == "")
    }

    @Test func anEmptyQueryMatchesNothing() {
        #expect(!matches("   ", message: "anything"))
    }

    /// Control: the helper can fail (a query the message does not hold).
    @Test func theHelperCanFail() {
        withKnownIssue("`zzz` is not in the message") {
            #expect(matches("zzz", message: "stash caption"))
        }
    }

    // MARK: - The byte-level Session against the Unicode way

    /// The matcher as it was before `Session`: components, join, `range(of:)`.
    private static func reference(_ query: String, _ haystack: String) -> Bool {
        func collapse(_ s: String) -> String {
            s.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
        }
        let needle = collapse(query)
        return !needle.isEmpty && collapse(haystack).range(of: needle, options: .caseInsensitive) != nil
    }

    private static func session(_ query: String, in haystack: [UInt8]) -> Bool {
        let session = CommitSearchMatcher.Session(query: query)
        return haystack.withUnsafeBufferPointer { bytes in
            session.matches(sha: UnsafeBufferPointer(start: nil, count: 0), authorName: UnsafeBufferPointer(start: nil, count: 0),
                            authorEmail: UnsafeBufferPointer(start: nil, count: 0), message: bytes)
        }
    }

    /// Scalars where folding, whitespace or composition is not plain: the tricky part of the
    /// alphabet the paths are compared over.
    private static let alphabet: [String] = [
        "a", "B", "k", "S", "s", "e", "i", "I", "f", "x", " ", "  ", "\t", "\n", "\r\n", "\u{0B}", "\u{1C}",
        "ё", "Ё", "е", "й", "é", "É", "e\u{301}", "\u{301}", "ß", "ẞ", "\u{212A}", "ſ", "ﬁ", "İ", "ı", "Σ", "σ", "ς",
        "\u{A0}", "\u{2028}", "\u{85}", "\u{3000}", "\u{200D}", "漢", "😀", "한", "\u{1112}\u{1161}", "ǅ", "Ǆ", "ǆ",
    ]

    @Test func sessionAgreesWithTheUnicodeWay() {
        // A fixed linear congruential sequence keeps a failure reproducible.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        var disagreements: [String] = []
        var matched = 0
        for _ in 0..<20_000 {
            let haystack = (0..<(1 + next(9))).map { _ in Self.alphabet[next(Self.alphabet.count)] }.joined()
            // Half the needles are a piece of the haystack (a likely hit), half are made up.
            var query: String
            if next(2) == 0 {
                let scalars = Array(haystack.unicodeScalars)
                let start = next(scalars.count)
                let end = start + 1 + next(scalars.count - start)
                query = String(String.UnicodeScalarView(scalars[start..<end]))
            } else {
                query = (0..<(1 + next(3))).map { _ in Self.alphabet[next(Self.alphabet.count)] }.joined()
            }
            let expected = Self.reference(query, haystack)
            let got = Self.session(query, in: Array(haystack.utf8))
            if expected { matched += 1 }
            if expected != got { disagreements.append("query \(query.debugDescription) in \(haystack.debugDescription): reference \(expected), session \(got)") }
        }
        #expect(disagreements.isEmpty, "\(disagreements.count) of 20000, first: \(disagreements.prefix(5))")
        #expect(matched > 2_000, "the comparison must include many hits, or it proves little: \(matched)")
    }

    @Test func sessionReadsInvalidUTF8LikeTheStringWay() {
        let bytes: [UInt8] = Array("stash ".utf8) + [0xFF, 0xC3] + Array(" caption".utf8)
        let text = String(decoding: bytes, as: UTF8.self)
        for query in ["stash", "caption", "stash caption", "\u{FFFD}"] {
            #expect(Self.session(query, in: bytes) == Self.reference(query, text), "\(query)")
        }
    }

    @Test func sessionFoldsWhitespaceRunsAndCaseInAscii() {
        let message = Array("Fix the\tstash \r\n  CAPTION of a row\n".utf8)
        #expect(Self.session("stash caption", in: message))
        #expect(Self.session("  The STASH  ", in: message))
        #expect(!Self.session("caption of the", in: message))
        #expect(Self.session("row", in: message))
    }

    @Test func sessionFindsAuthorAndIDFields() {
        let session = CommitSearchMatcher.Session(query: "2153FF9")
        let sha = Array("2153ff9c0a1b".utf8), none = Array("".utf8)
        let found = sha.withUnsafeBufferPointer { sha in
            none.withUnsafeBufferPointer { none in
                session.matches(sha: sha, authorName: none, authorEmail: none, message: none)
            }
        }
        #expect(found)
        let byEmail = CommitSearchMatcher.Session(query: "X.ORG")
        let email = Array("a@x.org".utf8)
        let foundEmail = sha.withUnsafeBufferPointer { sha in
            email.withUnsafeBufferPointer { email in
                none.withUnsafeBufferPointer { none in byEmail.matches(sha: sha, authorName: none, authorEmail: email, message: none) }
            }
        }
        #expect(foundEmail)
    }

    @Test func normalizedAgreesWithComponentsAndJoin() {
        for text in Self.alphabet + ["  a \t b\n\n c  ", "\u{A0}x\u{2028}\u{2028}y\u{85}", " ", ""] {
            let old = text.components(separatedBy: .whitespacesAndNewlines).filter { !$0.isEmpty }.joined(separator: " ")
            #expect(CommitSearchMatcher.normalized(text) == old, "\(text.debugDescription)")
        }
    }

    /// Control: the comparison can fail (a path that answered wrongly would be reported).
    @Test func theComparisonCanFail() {
        withKnownIssue("the session says no to a phrase the reference finds, when the haystack is another one") {
            #expect(Self.session("zzz", in: Array("stash".utf8)) == Self.reference("stash", "stash"))
        }
    }
}
