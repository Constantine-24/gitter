import GitCore
import Testing

@testable import Gitter

/// B2 Task 5, fix round 2 (Ruling 14): what Copy URL / Copy Push URL put on the general
/// pasteboard (`RemoteWording.copyableURL`, `RemoteMenu.copyItems`) — the remote's address with
/// its credential taken out by the URL's structure, as the sheets show it (I4): a password may
/// hold RFC 3986's sub-delims (`'`, `(`, `)`), which the prose redactor stops at. An ssh login
/// stays — without it a pasted `git clone` logs in as another account. Pure.
@Suite struct CopyURLTests {
    static let cases: [(url: String, copied: String)] = [
        // Sub-delims, a space, a quote and `@` in a password: never on the pasteboard.
        ("https://u:p(ss)@example.invalid/x.git", "https://example.invalid/x.git"),
        ("https://u:p)ss@example.invalid/x.git", "https://example.invalid/x.git"),
        ("https://u:p'ss@example.invalid/x.git", "https://example.invalid/x.git"),
        ("https://u:p ss@example.invalid/x.git", "https://example.invalid/x.git"),
        ("https://u:p\"ss@example.invalid/x.git", "https://example.invalid/x.git"),
        ("https://u:p@ss@example.invalid/x.git", "https://example.invalid/x.git"),
        ("ssh://u:p(ss)@example.invalid:22/x.git", "ssh://example.invalid:22/x.git"),
        ("u:p(ss)@example.invalid:o/x.git", "example.invalid:o/x.git"),
        // The cases the copy promised before (its doc comment), unchanged.
        ("https://alice:s3cret@example.invalid/o/r.git", "https://example.invalid/o/r.git"),
        ("https://ghp_tok@example.invalid/o/r.git", "https://example.invalid/o/r.git"),
        ("https://u:p%40ss@example.invalid/x.git", "https://example.invalid/x.git"),
        ("ssh://git@example.invalid:2222/o/r.git", "ssh://git@example.invalid:2222/o/r.git"),
        ("git+ssh://git@example.invalid/o/r.git", "git+ssh://git@example.invalid/o/r.git"),
        ("git@example.invalid:o/r.git", "git@example.invalid:o/r.git"),
        ("git@example.invalid:team@2024/x.git", "git@example.invalid:team@2024/x.git"),
        // A second `@` in an scp-style user is no lone login: it goes.
        ("a@b@example.invalid:o/r.git", "example.invalid:o/r.git"),
        ("https://example.invalid/r.git?ref=a@b", "https://example.invalid/r.git?ref=a@b"),
        ("https://example.invalid/o/r.git", "https://example.invalid/o/r.git"),
        ("file:///srv/repos/o.git", "file:///srv/repos/o.git"),
        ("/tmp/gitter-test/a:b@origin.git", "/tmp/gitter-test/a:b@origin.git"),
    ]

    @Test(arguments: cases)
    func aCopiedURLHasNoCredential(url: String, copied: String) {
        #expect(RemoteWording.copyableURL(url) == copied)
    }

    /// The menu's items carry the same text, for the fetch URL and a different push URL alike.
    @MainActor @Test func theMenuCopiesTheRedactedAddresses() {
        let remote = Remote(
            name: "paren", fetchURL: "https://u:p(ss)@example.invalid/x.git",
            pushURL: "https://v:q'x@example.invalid/p.git")
        let items = RemoteMenu.copyItems(for: remote)
        #expect(items.map(\.title) == [RemoteWording.copyURLTitle, RemoteWording.copyPushURLTitle])
        #expect(items.map(\.text) == ["https://example.invalid/x.git", "https://example.invalid/p.git"])
    }
}
