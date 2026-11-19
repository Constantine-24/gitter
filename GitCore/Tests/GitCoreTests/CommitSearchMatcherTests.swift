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
}
