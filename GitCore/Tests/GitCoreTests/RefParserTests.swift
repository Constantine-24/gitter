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

    /// `for-each-ref` says nothing about which remotes are configured — that comes from
    /// `git remote -v` — so the parser leaves the list empty and the remote branches
    /// unattached rather than inventing a remote by splitting their names on "/".
    @Test func theParserAloneKnowsOfNoRemotes() throws {
        let collection = RefParser.parse(try Self.fixtureData())
        #expect(collection.remotes == [])
        #expect(collection.remoteNames == [])
        #expect(collection.branchesWithoutRemote.count == collection.remoteBranches.count)
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

    @Test func annotatedTagUsesPeeledCommitSha() {
        // 6-field line: refname, objectname (the tag object), HEAD, upstream, objecttype,
        // *objectname (the commit the tag peels to).
        let line = "refs/tags/v2\0aaaaaaa1\0\0\0tag\0bbbbbbb2\n"
        let collection = RefParser.parse(Data(line.utf8))
        let v2 = collection.tags.first { $0.name == "v2" }
        #expect(v2?.sha == "bbbbbbb2")
        #expect(v2?.isAnnotated == true)
    }

    @Test func lightweightTagWithEmptyPeeledFieldKeepsObjectname() {
        let line = "refs/tags/v3\0ccccccc3\0\0\0commit\0\n"
        let collection = RefParser.parse(Data(line.utf8))
        let v3 = collection.tags.first { $0.name == "v3" }
        #expect(v3?.sha == "ccccccc3")
        #expect(v3?.isAnnotated == false)
    }

    @Test func branchWithEmptyPeeledFieldKeepsObjectname() {
        let line = "refs/heads/main\0ddddddd4\0*\0\0commit\0\n"
        let collection = RefParser.parse(Data(line.utf8))
        #expect(collection.localBranches.first?.sha == "ddddddd4")
    }

    // MARK: - Tracking (fields 7–9)

    /// A nine-field line: the six the parser has always read, then
    /// `%(upstream:track)`, `%(upstream:remotename)`, `%(upstream:remoteref)`.
    private static func trackingLine(upstream: String, track: String,
                                     remoteName: String = "origin",
                                     remoteRef: String = "refs/heads/main") -> Data {
        Data("refs/heads/main\0aaaa\0*\0\(upstream)\0commit\0\0\(track)\0\(remoteName)\0\(remoteRef)\n".utf8)
    }

    private static func parsedMain(_ data: Data) throws -> Branch {
        try #require(RefParser.parse(data).localBranches.first { $0.name == "main" })
    }

    @Test func aheadOnlyIsParsed() throws {
        let main = try Self.parsedMain(Self.trackingLine(upstream: "origin/main", track: "[ahead 2]"))
        #expect(main.tracking == .counts(ahead: 2, behind: 0))
    }

    @Test func behindOnlyIsParsed() throws {
        let main = try Self.parsedMain(Self.trackingLine(upstream: "origin/main", track: "[behind 3]"))
        #expect(main.tracking == .counts(ahead: 0, behind: 3))
    }

    @Test func aheadAndBehindAreParsed() throws {
        let main = try Self.parsedMain(
            Self.trackingLine(upstream: "origin/main", track: "[ahead 1, behind 1]"))
        #expect(main.tracking == .counts(ahead: 1, behind: 1))
    }

    @Test func goneIsParsed() throws {
        let main = try Self.parsedMain(Self.trackingLine(upstream: "origin/main", track: "[gone]"))
        #expect(main.tracking == .gone)
    }

    /// An empty track field means two different things, and the upstream field tells them
    /// apart: level when there is an upstream, nothing at all when there is not.
    @Test func anEmptyTrackFieldWithAnUpstreamIsLevel() throws {
        let main = try Self.parsedMain(Self.trackingLine(upstream: "origin/main", track: ""))
        #expect(main.tracking == .counts(ahead: 0, behind: 0))
    }

    @Test func anEmptyTrackFieldWithNoUpstreamIsNone() throws {
        let main = try Self.parsedMain(
            Self.trackingLine(upstream: "", track: "", remoteName: "", remoteRef: ""))
        #expect(main.tracking == .none)
        #expect(main.upstreamRemote == nil)
        #expect(main.upstreamRef == nil)
    }

    @Test func aDotRemoteNameBecomesNoRemote() throws {
        let main = try Self.parsedMain(
            Self.trackingLine(upstream: "dev", track: "[ahead 1]", remoteName: ".",
                              remoteRef: "refs/heads/dev"))
        #expect(main.upstreamRemote == nil)
        #expect(main.upstreamRef == "refs/heads/dev")
        #expect(main.tracksLocalBranch)
    }

    @Test func anUnrecognisedTrackFieldIsNotReportedAsLevel() throws {
        let main = try Self.parsedMain(
            Self.trackingLine(upstream: "origin/main", track: "[something new]"))
        #expect(main.tracking == .none, "a token we cannot read must not be claimed as level")
    }

    /// The old six-field shape — the recorded fixtures and any older call path — still parses,
    /// with no tracking rather than a refusal.
    @Test func theOldSixFieldShapeStillParses() throws {
        let line = "refs/heads/main\0aaaa\0*\0origin/main\0commit\0\n"
        let main = try Self.parsedMain(Data(line.utf8))
        #expect(main.upstream == "origin/main")
        #expect(main.tracking == .none)
        #expect(main.upstreamRemote == nil)
        #expect(main.upstreamRef == nil)
    }

    @Test func theFixtureStillParsesWithoutTrackingFields() throws {
        let collection = RefParser.parse(try Self.fixtureData())
        let main = try #require(collection.localBranches.first { $0.name == "main" })
        #expect(main.tracking == .none)
    }
}
