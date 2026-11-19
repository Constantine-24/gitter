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

    /// Ordinary words of hex letters ("added", "feed") and a revert's id in a message are id
    /// queries too, but a commit whose id does not start with them is still found by its text.
    @Test func aHexLookingWordIsStillText() {
        #expect(matches("added", message: "Added a row"))
        #expect(matches("feed", name: "Feed Bot"))
        #expect(matches("1234abcd", message: "This reverts commit 1234abcd."))
        #expect(!matches("added", message: "a row"), "control: text that does not hold it")
    }

    /// A field longer than the session's first buffer (4,096 keys) grows it, and the same session
    /// then still reads short and long fields right.
    @Test func aLongFieldGrowsTheBuffer() {
        let session = CommitSearchMatcher.Session(query: "the needle")
        func field(_ text: String) -> Bool {
            let bytes = Array(text.utf8), none = [UInt8]()
            return bytes.withUnsafeBufferPointer { message in
                none.withUnsafeBufferPointer { none in
                    session.matches(sha: none, authorName: none, authorEmail: none, message: message)
                }
            }
        }
        let filler = String(repeating: "lorem ipsum dolor sit ", count: 1_200)
        #expect(filler.utf8.count > 25_000)
        #expect(field(filler + "the\nneedle"))
        #expect(field("a short the needle"))
        #expect(!field(String(filler.prefix(10_000))))
        #expect(field("the needle " + filler))
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
        // Canonical singletons and their targets, and grapheme extenders that are not marks.
        ";", "\u{37E}", "\u{B7}", "\u{387}", "`", "\u{1FEF}", "\u{B4}", "\u{1FFD}", "\u{3008}", "\u{2329}",
        "\u{8C48}", "\u{F900}", "\u{3AC}", "\u{1F71}", "\u{2126}", "\u{3A9}", "\u{212B}", "Å", "ก", "ท",
        "\u{E33}", "\u{EB3}", "\u{D4E}", "\u{FF76}", "\u{FF9E}", "\u{FF9F}",
    ]

    /// Seeded cases over `alphabet`: the cases where `agree(query, haystack)` is false, and how
    /// many were hits for the reference.
    private static func differential(
        cases: Int, seed: UInt64, agree: (String, String) -> Bool
    ) -> (disagreements: [String], hits: Int) {
        // A fixed linear congruential sequence keeps a failure reproducible.
        var state = seed
        func next(_ bound: Int) -> Int {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return Int((state >> 33) % UInt64(bound))
        }
        var disagreements: [String] = []
        var hits = 0
        for _ in 0..<cases {
            let haystack = (0..<(1 + next(9))).map { _ in alphabet[next(alphabet.count)] }.joined()
            // Half the needles are a piece of the haystack (a likely hit), half are made up.
            var query: String
            if next(2) == 0 {
                let scalars = Array(haystack.unicodeScalars)
                let start = next(scalars.count)
                let end = start + 1 + next(scalars.count - start)
                query = String(String.UnicodeScalarView(scalars[start..<end]))
            } else {
                query = (0..<(1 + next(3))).map { _ in alphabet[next(alphabet.count)] }.joined()
            }
            if reference(query, haystack) { hits += 1 }
            if !agree(query, haystack) {
                disagreements.append("query \(query.debugDescription) in \(haystack.debugDescription)")
            }
        }
        return (disagreements, hits)
    }

    @Test func sessionAgreesWithTheUnicodeWay() {
        let result = Self.differential(cases: 20_000, seed: 0x9E37_79B9_7F4A_7C15) { query, haystack in
            Self.reference(query, haystack) == Self.session(query, in: Array(haystack.utf8))
        }
        #expect(result.disagreements.isEmpty, "\(result.disagreements.count) of 20000, first: \(result.disagreements.prefix(5))")
        #expect(result.hits > 2_000, "the comparison must include many hits, or it proves little: \(result.hits)")
    }

    /// The classes of scalar the table once trusted wrongly, by hand: canonical singletons
    /// (equal to their target under canonical equivalence), and grapheme extenders that are not
    /// marks (so the letter before them is not a match of its own).
    @Test func sessionAgreesOnSingletonsAndExtenders() {
        let singletons: [(String, String)] = [
            (";", "\u{37E}"), ("\u{B7}", "\u{387}"), ("`", "\u{1FEF}"), ("\u{B4}", "\u{1FFD}"),
            ("\u{3008}", "\u{2329}"), ("\u{3009}", "\u{232A}"), ("\u{8C48}", "\u{F900}"),
            ("\u{3AC}", "\u{1F71}"), ("\u{3A9}", "\u{2126}"), ("K", "\u{212A}"), ("\u{C5}", "\u{212B}"),
        ]
        for (a, b) in singletons {
            for (q, h) in [(a, b), (b, a), ("x" + a + "y", "x" + b + "y"), ("x" + b + "y", "x" + a + "y")] {
                #expect(Self.session(q, in: Array(h.utf8)) == Self.reference(q, h), "\(q.debugDescription) in \(h.debugDescription)")
            }
        }
        let extenders: [(String, String)] = [
            ("ก", "ก\u{E33}"), ("ท", "ท\u{E33}"), ("\u{E81}", "\u{E81}\u{EB3}"), ("\u{D12}", "\u{D12}\u{D4E}"),
            ("\u{FF76}", "\u{FF76}\u{FF9E}"), ("\u{FF8A}", "\u{FF8A}\u{FF9F}"),
        ]
        for (q, h) in extenders {
            #expect(Self.session(q, in: Array(h.utf8)) == Self.reference(q, h), "\(q.debugDescription) in \(h.debugDescription)")
        }
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

    /// Control: the differential loop collects disagreements. Against a comparator that is wrong
    /// for one scalar class (it says a Greek final sigma never matches), the loop reports them.
    @Test func theComparisonCanFail() {
        withKnownIssue("a deliberately wrong comparator disagrees with the reference") {
            let result = Self.differential(cases: 20_000, seed: 0x9E37_79B9_7F4A_7C15) { query, haystack in
                let wrong = Self.session(query, in: Array(haystack.utf8)) && !query.contains("ς")
                return Self.reference(query, haystack) == wrong
            }
            #expect(result.disagreements.isEmpty, "\(result.disagreements.count) disagreements")
        }
    }
}
