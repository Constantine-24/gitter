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

    // MARK: - Tag fields (13–15, B1 Task 2)

    /// Fields 13–15 are `%(taggername)`, `%(taggerdate:iso-strict)` and `%(contents:subject)`.
    /// The ref holds the tag object (`objectID`); `sha` is the commit it peels to.
    @Test func anAnnotatedTagReadsTaggerDateAndSubject() throws {
        let line = "refs/tags/v2\0aaaaaaa1\0\0\0tag\0bbbbbbb2\0\0\0\0\0\0\0"
            + "Tagger T\02023-11-16T06:00:00+04:00\0Release two\n"
        let v2 = try #require(RefParser.parse(Data(line.utf8)).tags.first)
        #expect(v2.name == "v2")
        #expect(v2.sha == "bbbbbbb2")
        #expect(v2.objectID == "aaaaaaa1")
        #expect(v2.isAnnotated)
        #expect(v2.tagger == "Tagger T")
        #expect(v2.date == Date(timeIntervalSince1970: 1_700_100_000))
        #expect(v2.subject == "Release two")
    }

    /// A lightweight tag has no tagger, no date and no message of its own: `%(contents:subject)`
    /// reports the **commit's** subject for it (B18), and that is not the tag's.
    @Test func aLightweightTagHasNoTaggerDateOrSubject() throws {
        let line = "refs/tags/v3\0ccccccc3\0\0\0commit\0\0\0\0\0\0\0\0\0\0The commit's subject\n"
        let v3 = try #require(RefParser.parse(Data(line.utf8)).tags.first)
        #expect(v3.sha == "ccccccc3")
        #expect(v3.objectID == "ccccccc3")
        #expect(!v3.isAnnotated)
        #expect(v3.tagger == nil)
        #expect(v3.date == nil)
        #expect(v3.subject == nil)
    }

    /// An annotated tag with an empty message has an empty subject, and one written without a
    /// tagger line has neither tagger nor date.
    @Test func anAnnotatedTagWithoutTaggerOrMessage() throws {
        let line = "refs/tags/bare\0ddddddd4\0\0\0tag\0eeeeeee5\0\0\0\0\0\0\0\0\0\n"
        let bare = try #require(RefParser.parse(Data(line.utf8)).tags.first)
        #expect(bare.objectID == "ddddddd4")
        #expect(bare.tagger == nil)
        #expect(bare.date == nil)
        #expect(bare.subject == "")
    }

    /// Fix round 1 (I2): a tag ref whose `%(symref)` (field 10) is set is a symbolic ref, and
    /// says so.
    @Test func aSymbolicTagRefIsMarked() throws {
        let line = "refs/tags/sym\0ccccccc3\0\0\0commit\0\0\0\0\0refs/heads/feature\0\0\0\0\0\n"
            + "refs/tags/plain\0ccccccc3\0\0\0commit\0\0\0\0\0\0\0\0\0\0\n"
        let tags = RefParser.parse(Data(line.utf8)).tags
        #expect(tags.map(\.name) == ["plain", "sym"])
        #expect(tags.map(\.isSymbolic) == [false, true])
    }

    /// Minor 2: the shared date style parses exactly what the per-call formatter did for every
    /// shape git prints, and an unreadable date is nil.
    @Test(arguments: [
        ("2023-11-16T02:00:00Z", 1_700_100_000.0), ("2023-11-16T06:00:00+04:00", 1_700_100_000.0),
        ("2023-11-16T01:30:00-00:30", 1_700_100_000.0),
    ])
    func taggerDatesParse(field: String, seconds: Double) throws {
        let line = "refs/tags/v\0aaaaaaa1\0\0\0tag\0bbbbbbb2\0\0\0\0\0\0\0T\0\(field)\0s\n"
        let tag = try #require(RefParser.parse(Data(line.utf8)).tags.first)
        #expect(tag.date == Date(timeIntervalSince1970: seconds))
    }

    @Test func anUnreadableTaggerDateIsNil() throws {
        let line = "refs/tags/v\0aaaaaaa1\0\0\0tag\0bbbbbbb2\0\0\0\0\0\0\0T\0yesterday\0s\n"
        #expect(try #require(RefParser.parse(Data(line.utf8)).tags.first).date == nil)
    }

    /// Output recorded before fields 13–15 existed still parses: the tag object is still the
    /// ref's own id, and what was not read is nil rather than empty.
    @Test func aSixFieldAnnotatedTagStillHasItsObjectID() throws {
        let line = "refs/tags/v2\0aaaaaaa1\0\0\0tag\0bbbbbbb2\n"
        let v2 = try #require(RefParser.parse(Data(line.utf8)).tags.first)
        #expect(v2.objectID == "aaaaaaa1")
        #expect(v2.tagger == nil)
        #expect(v2.subject == nil)
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

    // MARK: - Push target (fields 11–12)

    /// A twelve-field line: the nine above, then `%(symref)`, `%(push:remotename)` and
    /// `%(push:remoteref)`.
    private static func pushLine(upstream: String = "origin/main",
                                 upstreamRemote: String = "origin",
                                 upstreamRef: String = "refs/heads/main",
                                 pushRemote: String,
                                 pushRef: String = "") -> Data {
        Data(("refs/heads/main\0aaaa\0*\0\(upstream)\0commit\0\0\0\(upstreamRemote)\0"
              + "\(upstreamRef)\0\0\(pushRemote)\0\(pushRef)\n").utf8)
    }

    @Test func thePushRemoteIsParsed() throws {
        let main = try Self.parsedMain(Self.pushLine(pushRemote: "origin"))
        #expect(main.pushRemote == "origin")
        #expect(main.pushRef == nil)
    }

    /// `branch.<name>.pushRemote` / `remote.pushDefault`: push goes somewhere other than where
    /// the branch fetches from, and only the push fields say so.
    @Test func aPushRemoteDifferentFromTheUpstreamsIsKeptApart() throws {
        let main = try Self.parsedMain(Self.pushLine(pushRemote: "fork"))
        #expect(main.upstreamRemote == "origin")
        #expect(main.pushRemote == "fork")
    }

    @Test func anEmptyPushRemoteIsNil() throws {
        let main = try Self.parsedMain(
            Self.pushLine(upstream: "", upstreamRemote: "", upstreamRef: "", pushRemote: ""))
        #expect(main.pushRemote == nil)
        #expect(main.pushRef == nil)
    }

    /// "." is no more a remote for push than it is for fetch.
    @Test func aDotPushRemoteBecomesNoPushRemote() throws {
        let main = try Self.parsedMain(
            Self.pushLine(upstream: "dev", upstreamRemote: ".", upstreamRef: "refs/heads/dev",
                          pushRemote: "."))
        #expect(main.pushRemote == nil)
        #expect(main.upstreamRemote == nil)
    }

    /// The one configuration that fills `%(push:remoteref)`: an explicit `remote.<name>.push`
    /// refspec.
    @Test func anExplicitPushRefIsParsed() throws {
        let main = try Self.parsedMain(
            Self.pushLine(pushRemote: "origin", pushRef: "refs/heads/prefix-main"))
        #expect(main.pushRemote == "origin")
        #expect(main.pushRef == "refs/heads/prefix-main")
    }

    /// A line recorded before the push fields existed says nothing about the push target.
    @Test func theNineFieldShapeLeavesThePushFieldsUnset() throws {
        let main = try Self.parsedMain(
            Self.trackingLine(upstream: "origin/main", track: "[ahead 2]"))
        #expect(main.tracking == .counts(ahead: 2, behind: 0))
        #expect(main.pushRemote == nil)
        #expect(main.pushRef == nil)
    }

    // MARK: - Symbolic refs (field 10)

    /// A ten-field remote line: the nine above plus `%(symref)`.
    private static func remoteLine(_ refname: String, symref: String) -> String {
        "\(refname)\0aaaa\0 \0\0commit\0\0\0\0\0\(symref)\n"
    }

    /// The old rule looked for "HEAD" after the *first* slash, so the symbolic HEAD of a
    /// remote whose own name contains a slash survived and was listed as a branch. `%(symref)`
    /// answers the question git already knows the answer to.
    @Test func theSymbolicHeadOfASlashNamedRemoteIsSkipped() throws {
        let data = Data((Self.remoteLine("refs/remotes/up/stream/HEAD",
                                         symref: "refs/remotes/up/stream/main")
                         + Self.remoteLine("refs/remotes/up/stream/main", symref: "")).utf8)
        #expect(RefParser.parse(data).remoteBranches.map(\.name) == ["up/stream/main"])
    }

    /// A hand-made symbolic ref under `refs/remotes/` that is not named HEAD is still a
    /// symbolic ref, and still not a branch.
    @Test func aSymbolicRemoteRefNotNamedHeadIsSkipped() throws {
        let data = Data(Self.remoteLine("refs/remotes/origin/alias",
                                        symref: "refs/remotes/origin/main").utf8)
        #expect(RefParser.parse(data).remoteBranches.isEmpty)
    }

    /// The converse: a ref literally at `refs/remotes/origin/HEAD` that is *not* symbolic
    /// holds a commit of its own, and hiding it would hide those commits.
    @Test func aNonSymbolicRefNamedHeadIsKept() throws {
        let data = Data(Self.remoteLine("refs/remotes/origin/HEAD", symref: "").utf8)
        #expect(RefParser.parse(data).remoteBranches.map(\.name) == ["origin/HEAD"])
    }
}
