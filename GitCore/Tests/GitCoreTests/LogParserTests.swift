import Foundation
import Testing

@testable import GitCore

@Suite struct LogParserTests {
    static func fixtureData() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "log", withExtension: "bin", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    static let expectedDate = Date(timeIntervalSince1970: 1_789_711_200) // 2026-09-18T06:00:00Z

    @Test func parsesSixCommitsInFixtureOrder() throws {
        let commits = LogParser.parse(try Self.fixtureData())
        #expect(commits.count == 6)
    }

    @Test func firstCommitIsTopicWithRefs() throws {
        let commits = LogParser.parse(try Self.fixtureData())
        let first = try #require(commits.first)
        #expect(first.sha == "e9dfaf1d58a71618528d9a9ac40d1ed6ed2777c7")
        #expect(first.parents == ["66e749e9705f08ca6bc833aab6a587f59736bcc8"])
        #expect(first.authorName == "Tester")
        #expect(first.authorEmail == "t@t")
        #expect(first.summary == "Topic commit")
        #expect(first.refs == ["origin/topic", "topic"])
    }

    @Test func secondCommitIsMergeWithTwoParentsAndTagRefs() throws {
        let commits = LogParser.parse(try Self.fixtureData())
        #expect(commits.count > 1)
        let merge = commits[1]
        #expect(merge.sha == "66e749e9705f08ca6bc833aab6a587f59736bcc8")
        #expect(merge.parents == [
            "42c1d8daca181dfb4b8f03161f78ac3540e81007",
            "79aff822dbf884fd25cc84560bb4bdd36022a8e5",
        ])
        #expect(merge.isMerge == true)
        #expect(merge.refs.first == "HEAD -> main")
        #expect(merge.refs.contains("tag: v1.0"))
    }

    @Test func lastCommitHasNoParents() throws {
        let commits = LogParser.parse(try Self.fixtureData())
        let last = try #require(commits.last)
        #expect(last.sha == "a7fa885726e7a41a7df45a41485247b21c664d00")
        #expect(last.parents.isEmpty)
        #expect(last.refs.isEmpty)
    }

    @Test func allDatesParseToExpectedUTCInstant() throws {
        let commits = LogParser.parse(try Self.fixtureData())
        for commit in commits {
            #expect(commit.authorDate == Self.expectedDate)
        }
    }

    @Test func truncatedStreamDropsPartialRecord() {
        let text = "abc123\u{0}\u{0}Tester\u{0}t@t\u{0}2026-09-18T10:00:00+04:00\u{0}Only six fields\u{0}"
        let commits = LogParser.parse(Data(text.utf8))
        #expect(commits.isEmpty)
    }

    @Test func emptyDataProducesEmptyArray() {
        let commits = LogParser.parse(Data())
        #expect(commits.isEmpty)
    }

    @Test func unparsableDateFallsBackToEpoch() throws {
        let text = "abc123\u{0}\u{0}Tester\u{0}t@t\u{0}not-a-date\u{0}Summary\u{0}\u{0}"
        let commits = LogParser.parse(Data(text.utf8))
        let commit = try #require(commits.first)
        #expect(commit.authorDate == Date(timeIntervalSince1970: 0))
    }
}
