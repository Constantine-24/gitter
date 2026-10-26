import Foundation
import Testing

@testable import GitCore

/// `LogParser`'s author date (H1): one shared `Date.ISO8601FormatStyle` in place of an
/// `ISO8601DateFormatter` made per commit, which was most of a deep read's cost (11.9 s for
/// 100,001 commits, measured). The dates must not move: each offset `%aI` can print is read as
/// the old formatter read it.
@Suite struct LogParserDateTests {

    /// One record of `CLIGitBackend.logFormat`'s seven NUL-terminated fields, with `date`.
    static func record(date: String) -> Data {
        let fields = [String(repeating: "a", count: 40), "", "Tester", "t@t", date, "subject", ""]
        return Data(fields.map { $0 + "\u{0}" }.joined().utf8)
    }

    static func parsedDate(_ date: String) throws -> Date {
        try #require(LogParser.parse(record(date: date)).first).authorDate
    }

    @Test(arguments: [
        "2026-10-26T10:00:00Z", "2026-10-26T10:00:00+02:00", "2026-10-26T10:00:00-07:30",
        "2026-10-26T10:00:00+00:00",
    ])
    func parsesOffsetsLikeTheOldFormatter(_ date: String) throws {
        let old = ISO8601DateFormatter()
        old.formatOptions = [.withInternetDateTime]
        let expected = try #require(old.date(from: date))

        #expect(try Self.parsedDate(date) == expected)
        // The offsets really are read, not dropped: the four instants are not all the same.
        #expect(expected.timeIntervalSince1970 != 0)
    }

    /// The offsets give different instants, so the equality above can tell a dropped offset.
    @Test func theOffsetsAreDifferentInstants() throws {
        let instants = try ["2026-10-26T10:00:00Z", "2026-10-26T10:00:00+02:00", "2026-10-26T10:00:00-07:30"]
            .map(Self.parsedDate)
        #expect(Set(instants).count == 3)
        #expect(instants[0].timeIntervalSince(instants[1]) == 7_200)
        #expect(instants[2].timeIntervalSince(instants[0]) == 27_000)
    }

    @Test func unparsableDateIsTheEpoch() throws {
        #expect(try Self.parsedDate("garbage") == Date(timeIntervalSince1970: 0))
        #expect(try Self.parsedDate("") == Date(timeIntervalSince1970: 0))
    }
}
