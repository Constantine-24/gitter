import Foundation
import Testing

@testable import GitCore

@Suite struct RefParserTests {
    static func fixtureData() throws -> Data {
        let url = try #require(
            Bundle.module.url(forResource: "for-each-ref", withExtension: "txt", subdirectory: "Fixtures")
        )
        return try Data(contentsOf: url)
    }

    @Test func parsesLocalBranchNames() throws {
        let collection = RefParser.parse(try Self.fixtureData())
        #expect(collection.localBranches.map(\.name) == ["feature", "main", "topic"])
    }

    @Test func mainIsHeadWithUpstream() throws {
        let collection = RefParser.parse(try Self.fixtureData())
        let main = try #require(collection.localBranches.first { $0.name == "main" })
        #expect(main.isHead == true)
        #expect(main.upstream == "origin/main")
    }

    @Test func featureIsNotHeadWithNoUpstream() throws {
        let collection = RefParser.parse(try Self.fixtureData())
        let feature = try #require(collection.localBranches.first { $0.name == "feature" })
        #expect(feature.isHead == false)
        #expect(feature.upstream == nil)
    }

    @Test func remoteBranchesExcludeOriginHead() throws {
        let collection = RefParser.parse(try Self.fixtureData())
        #expect(collection.remoteBranches.count == 3)
        #expect(!collection.remoteBranches.contains { $0.name == "origin/HEAD" })
    }

    @Test func remoteNamesContainsOrigin() throws {
        let collection = RefParser.parse(try Self.fixtureData())
        #expect(collection.remoteNames == ["origin"])
    }

    @Test func tagsParsedWithAnnotationFlag() throws {
        let collection = RefParser.parse(try Self.fixtureData())
        let v1_0 = try #require(collection.tags.first(where: { $0.name == "v1.0" }))
        let v1_1 = try #require(collection.tags.first(where: { $0.name == "v1.1" }))
        #expect(v1_0.isAnnotated == false)
        #expect(v1_1.isAnnotated == true)
    }

    @Test func emptyDataProducesEmptyCollection() {
        let collection = RefParser.parse(Data())
        #expect(collection == RefCollection.empty)
    }

    @Test func garbageLineIsSkipped() {
        let garbage = "not-enough-fields\0only-two\n"
        let data = Data(garbage.utf8)
        let collection = RefParser.parse(data)
        #expect(collection == RefCollection.empty)
    }

    @Test func garbageLineSkippedAmongValidLines() throws {
        var data = try Self.fixtureData()
        data.append(Data("garbage\0line\n".utf8))
        let collection = RefParser.parse(data)
        #expect(collection.localBranches.map(\.name) == ["feature", "main", "topic"])
    }

    @Test func nestedRemoteBranchNamedHeadIsKeptButSymbolicRemoteHeadIsSkipped() {
        let line = "refs/remotes/origin/release/HEAD\0deadbeef\0\0\0commit\n"
            + "refs/remotes/origin/HEAD\0cafebabe\0\0\0commit\n"
        let data = Data(line.utf8)
        let collection = RefParser.parse(data)
        #expect(collection.remoteBranches.map(\.name) == ["origin/release/HEAD"])
        #expect(!collection.remoteBranches.contains { $0.name == "origin/HEAD" })
    }
}
