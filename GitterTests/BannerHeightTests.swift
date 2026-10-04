import Testing

@testable import Gitter

/// B2 Task 5, fix round 3: a banner's strip grows with its text up to a cap and scrolls past it.
/// The cap is `Banner.lineLimit(for:)` lines of the message font — three for a sentence, two
/// more per line the message was built with, at most twenty-four; the strip itself is sized to
/// the text (a one-line notice is one line tall), which the harness snapshots show.
@MainActor @Suite struct BannerHeightTests {
    @Test func theCapIsTheLineLimitInLinesOfTheMessageFont() {
        #expect(Banner.lineHeight > 10 && Banner.lineHeight < 30)
        let line = Banner.lineHeight
        let nine = (1...9).map { "line \($0)" }.joined(separator: "\n")
        let thirty = (1...30).map { "line \($0)" }.joined(separator: "\n")
        // In lines, so a rounding of the font's metrics cannot make two equal heights differ.
        #expect((Banner.capHeight(for: "Fetched from every remote.") / line).rounded() == 3)
        #expect((Banner.capHeight(for: nine) / line).rounded() == 19)
        #expect((Banner.capHeight(for: thirty) / line).rounded() == 24)
    }
}
