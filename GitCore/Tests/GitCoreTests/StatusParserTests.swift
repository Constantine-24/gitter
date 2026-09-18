import Foundation
import Testing

@testable import GitCore

@Suite struct StatusParserTests {
    static func fixtureData() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "status-v2", withExtension: "bin", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    @Test func parsesBranchHeader() throws {
        let status = StatusParser.parse(try Self.fixtureData())
        #expect(status.headSha == "66e749e9705f08ca6bc833aab6a587f59736bcc8")
        #expect(status.branch == "main")
        #expect(status.upstream == "origin/main")
        #expect(status.ahead == 0)
        #expect(status.behind == 0)
    }

    @Test func parsesFiveFiles() throws {
        let status = StatusParser.parse(try Self.fixtureData())
        #expect(status.files.count == 5)
    }

    @Test func filesAreSortedByPath() throws {
        let status = StatusParser.parse(try Self.fixtureData())
        #expect(status.files.map(\.path) == [
            "a.txt", "renamed.txt", "src/one.txt", "staged.txt", "untracked.txt",
        ])
    }

    @Test func ordinaryModifiedFile() throws {
        let status = StatusParser.parse(try Self.fixtureData())
        let file = try #require(status.files.first { $0.path == "a.txt" })
        #expect(file.staged == nil)
        #expect(file.unstaged == .modified)
        #expect(file.originalPath == nil)
    }

    @Test func renamedFileHasOriginalPath() throws {
        let status = StatusParser.parse(try Self.fixtureData())
        let file = try #require(status.files.first { $0.path == "renamed.txt" })
        #expect(file.staged == .renamed)
        #expect(file.unstaged == nil)
        #expect(file.originalPath == "keep.txt")
    }

    @Test func deletedFile() throws {
        let status = StatusParser.parse(try Self.fixtureData())
        let file = try #require(status.files.first { $0.path == "src/one.txt" })
        #expect(file.staged == .deleted)
        #expect(file.unstaged == nil)
    }

    @Test func stagedAddedAndUnstagedModifiedFile() throws {
        let status = StatusParser.parse(try Self.fixtureData())
        let file = try #require(status.files.first { $0.path == "staged.txt" })
        #expect(file.staged == .added)
        #expect(file.unstaged == .modified)
    }

    @Test func untrackedFile() throws {
        let status = StatusParser.parse(try Self.fixtureData())
        let file = try #require(status.files.first { $0.path == "untracked.txt" })
        #expect(file.isUntracked == true)
        #expect(file.staged == nil)
    }

    @Test func detachedHeadHasNilBranch() {
        let text = "# branch.oid deadbeef\0# branch.head (detached)\0"
        let status = StatusParser.parse(Data(text.utf8))
        #expect(status.headSha == "deadbeef")
        #expect(status.branch == nil)
    }

    @Test func initialCommitHasNilHeadSha() {
        let text = "# branch.oid (initial)\0# branch.head main\0"
        let status = StatusParser.parse(Data(text.utf8))
        #expect(status.headSha == nil)
        #expect(status.branch == "main")
    }

    @Test func branchAheadBehindParsed() {
        let text = "# branch.oid deadbeef\0# branch.head main\0# branch.ab +3 -1\0"
        let status = StatusParser.parse(Data(text.utf8))
        #expect(status.ahead == 3)
        #expect(status.behind == 1)
    }

    @Test func unmergedRecordSetsBothStagedAndUnstaged() throws {
        let text =
            "u UU N... 100644 100644 100644 100644 "
            + "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa "
            + "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb "
            + "cccccccccccccccccccccccccccccccccccccccc conflict.txt\0"
        let status = StatusParser.parse(Data(text.utf8))
        let file = try #require(status.files.first { $0.path == "conflict.txt" })
        #expect(file.staged == .unmerged)
        #expect(file.unstaged == .unmerged)
    }

    @Test func emptyInputProducesEmptyStatus() {
        let status = StatusParser.parse(Data())
        #expect(status == WorkingCopyStatus.empty)
    }
}
