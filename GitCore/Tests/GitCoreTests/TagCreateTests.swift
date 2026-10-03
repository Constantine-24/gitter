import Foundation
import Testing

@testable import GitCore

/// `GitTagBackend.tagNameProblem` and `createTag` (B17, RF2, RF3), and the tag list's new
/// fields (B18).
@Suite struct TagCreateTests {
    /// `makeBranched()` (root commit tagged `v1`, `main`, `feature`) plus a second commit on
    /// `main`, so the root is a commit other than HEAD.
    static func makeRepo() async throws -> (repo: TestRepo, root: String, head: String) {
        let repo = try await TestRepo.makeBranched()
        let root = try await repo.revParse("main")
        let head = try await repo.commit("b.txt", "two", "second")
        return (repo, root, head)
    }

    // MARK: - Create

    @Test func aLightweightTagIsCreatedAtACommitThatIsNotHead() async throws {
        let (repo, root, head) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let before = try await HistorySnapshot.capture(repo)

        try await CLIGitBackend().createTag("light", at: root, message: nil, at: repo.root)

        #expect(try await repo.tagObject("light") == root)
        #expect(try await repo.objectType("refs/tags/light") == "commit")
        #expect(try await repo.headSha() == head)
        let now = try await RepoState.capture(repo)
        #expect(now.index == before.state.index)
        #expect(Set(now.refs.split(separator: "\n")).subtracting(before.state.refs.split(separator: "\n"))
            == ["\(root) commit\trefs/tags/light"])
    }

    @Test func anAnnotatedTagIsCreatedAtACommitThatIsNotHead() async throws {
        let (repo, root, head) = try await Self.makeRepo()
        defer { repo.cleanUp() }

        try await CLIGitBackend().createTag("ann", at: root, message: "Release two\n", at: repo.root)

        let object = try #require(try await repo.tagObject("ann"))
        #expect(object != root)
        #expect(try await repo.objectType("refs/tags/ann") == "tag")
        #expect(try await repo.revParse("refs/tags/ann^{commit}") == root)
        #expect(try await repo.headSha() == head)
        let body = String(decoding: try await repo.git(["cat-file", "tag", "ann"]), as: UTF8.self)
        #expect(body.hasSuffix("\n\nRelease two\n"), "\(body)")
        #expect(!body.contains("-----BEGIN"))
    }

    /// `-F` strips `#` lines unless `--cleanup=verbatim` (B17): the message is stored exactly as
    /// written, comment-looking lines and blank lines included.
    @Test func aMultiLineMessageIsStoredAsWrittenHashLinesIncluded() async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let message = "Title line\n\nBody 1\n# hash line\n\n  indented\n"

        try await CLIGitBackend().createTag("v3", at: root, message: message, at: repo.root)

        let body = String(decoding: try await repo.git(["cat-file", "tag", "v3"]), as: UTF8.self)
        #expect(body.hasSuffix("\n\n" + message), "\(body)")
    }

    /// A message without a final newline gets one, as every message git writes itself has.
    @Test func aMessageWithoutAFinalNewlineGetsOne() async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }

        try await CLIGitBackend().createTag("v4", at: root, message: "# only a hash line", at: repo.root)

        let body = String(decoding: try await repo.git(["cat-file", "tag", "v4"]), as: UTF8.self)
        #expect(body.hasSuffix("\n\n# only a hash line\n"), "\(body)")
    }

    /// The message file is Gitter's own, under the temporary directory, and gone afterwards.
    @Test func theMessageFileIsRemoved() async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let marker = "marker-\(UUID().uuidString)"
        let temporary = URL(fileURLWithPath: NSTemporaryDirectory())

        try await CLIGitBackend().createTag("v5", at: root, message: marker, at: repo.root)

        let leftovers = try FileManager.default.contentsOfDirectory(at: temporary, includingPropertiesForKeys: nil)
            .filter { (try? String(contentsOf: $0, encoding: .utf8))?.contains(marker) == true }
        #expect(leftovers.isEmpty, "\(leftovers)")
        #expect(try await repo.tagObject("v5") != nil)
    }

    /// RF3: `tag.gpgSign=true` turns a plain `git tag` into a signed annotated create and
    /// `tag.forceSignAnnotated=true` signs `-m` without `-a` (B17). With a gpg that always
    /// fails, both kinds are still created — unsigned, and gpg never called.
    @Test(arguments: ["tag.gpgSign", "tag.forceSignAnnotated"])
    func signingConfigNeverSignsATag(key: String) async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let gpgLog = try await repo.failTagSigning(key)
        // A baseline that can fail: git itself would sign here, and the fake gpg refuses.
        let direct = try await repo.git(["tag", "-m", "m", "direct", root], allowedExitCodes: [128])
        #expect(try await repo.tagObject("direct") == nil, "\(direct)")
        #expect(FileManager.default.fileExists(atPath: gpgLog.path))
        try FileManager.default.removeItem(at: gpgLog)

        try await CLIGitBackend().createTag("light", at: root, message: nil, at: repo.root)
        try await CLIGitBackend().createTag("ann", at: root, message: "Annotated\n", at: repo.root)

        #expect(try await repo.objectType("refs/tags/light") == "commit")
        #expect(try await repo.objectType("refs/tags/ann") == "tag")
        let body = String(decoding: try await repo.git(["cat-file", "tag", "ann"]), as: UTF8.self)
        #expect(!body.contains("-----BEGIN"), "\(body)")
        #expect(!FileManager.default.fileExists(atPath: gpgLog.path), "gpg was called")
    }

    @Test func anExistingNameIsRefusedAndNothingChanges() async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let before = try await HistorySnapshot.capture(repo)

        await #expect(throws: TagOperationError.nameProblem(.exists)) {
            try await CLIGitBackend().createTag("v1", at: root, message: "again\n", at: repo.root)
        }
        try await before.assertUnchanged(repo)
    }

    /// Full object ids only (RF2): a short id, a name, upper case, zeros or nothing is refused
    /// before git runs.
    @Test(arguments: ["", "HEAD", "main", "0000000000000000000000000000000000000000"])
    func aTargetThatIsNotAFullObjectIDIsRefused(target: String) async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        let before = try await HistorySnapshot.capture(repo)

        for value in [target, String(root.prefix(7)), root.uppercased()] {
            await #expect(throws: TagOperationError.invalidObjectID(value)) {
                try await git.backend.createTag("t", at: value, message: nil, at: repo.root)
            }
        }
        git.assertNothingRan()
        try await before.assertUnchanged(repo)
    }

    // MARK: - Name problems (RF2)

    static let problems: [(String, TagNameProblem?)] = [
        ("", .empty),
        ("HEAD", .reserved), ("-x", .reserved), ("@", .reserved),
        // Fix round 1 (I1): git's root-ref syntax — `[A-Z_-]` ending in `HEAD`, and the
        // irregular five — compared folded, as APFS compares them.
        ("MERGE_HEAD", .reserved), ("ORIG_HEAD", .reserved), ("FETCH_HEAD", .reserved),
        ("CHERRY_PICK_HEAD", .reserved), ("REBASE_HEAD", .reserved), ("merge_head", .reserved),
        ("head", .reserved), ("MY-HEAD", .reserved), ("AUTO_MERGE", .reserved), ("Auto_Merge", .reserved),
        ("BISECT_EXPECTED_REV", .reserved), ("NOTES_MERGE_PARTIAL", .reserved),
        ("NOTES_MERGE_REF", .reserved), ("MERGE_AUTOSTASH", .reserved),
        // Final fix wave I2: `stash` — `git stash drop stash@{N}` reads `stash` as the tag
        // (`aStashTagIsRefusedBecauseItBreaksEveryStashDrop`). Folded, as APFS compares names.
        ("stash", .reserved), ("Stash", .reserved), ("STASH", .reserved),
        (String(repeating: "z", count: 251), .tooLong),
        ("a..b", .invalid), ("x.lock", .invalid), ("a b", .invalid), ("a~1", .invalid),
        ("v1.0^{}", .invalid), ("x/", .invalid), (".x", .invalid), ("a//b", .invalid), ("a@{b", .invalid),
        ("deadbeef", .looksLikeObjectID), ("DEADBEE", .looksLikeObjectID),
        (String(repeating: "c", count: 40), .looksLikeObjectID),
        ("v1", .exists), ("V1", .exists), ("v1/sub", .exists),
        ("feature", .isBranchName), ("Main", .isBranchName), ("origin/feat/x", .isBranchName),
        ("origin/main", .isBranchName),
        ("release/1.0", nil), ("abcdef", nil), ("ünï", nil),
        // Minor 1: a remote's name — `origin` alone resolves to `refs/remotes/origin/HEAD`, and
        // a tag of that name wins.
        ("origin", .isBranchName), ("ORIGIN", .isBranchName),
        // Read as files through `--git-path`, never as refs: a tag of that name changes
        // nothing Gitter reads (`aTagNamedLikeAStateFileIsHarmless`).
        ("SQUASH_MSG", nil), ("MERGE_MSG", nil), ("HEADS", nil), ("V1_HEAD", nil),
        ("stashes", nil), ("stash/x", nil), ("my-stash", nil),
        (String(repeating: "z", count: 250), nil),
    ]

    @Test(arguments: Self.problems)
    func eachNameProblemIsReported(name: String, problem: TagNameProblem?) async throws {
        let (repo, _, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let before = try await HistorySnapshot.capture(repo)

        #expect(try await CLIGitBackend().tagNameProblem(name, at: repo.root) == problem)
        try await before.assertUnchanged(repo)
    }

    /// Every problem is also a refusal of the create itself, before git runs: the confirm cannot
    /// make what the sheet's check would have refused.
    @Test(arguments: Self.problems.filter { $0.1 != nil })
    func createRefusesEachNameProblem(name: String, problem: TagNameProblem?) async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }
        let before = try await HistorySnapshot.capture(repo)

        for message in [nil, "m\n"] as [String?] {
            await #expect(throws: TagOperationError.nameProblem(try #require(problem))) {
                try await CLIGitBackend().createTag(name, at: root, message: message, at: repo.root)
            }
        }
        try await before.assertUnchanged(repo)
    }

    /// I1: the reason for the root-ref refusal. A tag named `MERGE_HEAD` (made in a terminal)
    /// is what `rev-parse MERGE_HEAD` resolves to, and Gitter would then report a merge in a
    /// clean repository. Through Gitter the name is refused, and the snapshot is unaffected.
    @Test func aPseudoRefNameIsRefusedAndTheSnapshotStaysClean() async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }

        await #expect(throws: TagOperationError.nameProblem(.reserved)) {
            try await CLIGitBackend().createTag("MERGE_HEAD", at: root, message: nil, at: repo.root)
        }
        #expect(try await CLIGitBackend().snapshot(at: repo.root).status.operationInProgress == nil)

        // The baseline that can fail: the same tag made by git itself.
        try await repo.git(["tag", "MERGE_HEAD", root])
        #expect(try await CLIGitBackend().snapshot(at: repo.root).status.operationInProgress == .merge)
    }

    /// Final fix wave I2: the reason `stash` is reserved. A tag of that name (made in a terminal,
    /// either case: APFS folds it) is what `git stash drop -q stash@{N}` resolves `stash` to —
    /// "error: 'stash@{0}' is not a stash reference", exit 1 — so A1's Drop, Pop's drop and the
    /// empty-stash cleanup fail for every entry of the repository. Through Gitter the name is
    /// refused, and a drop works; the baseline that can fail is the same tag made by git itself.
    @Test(arguments: ["stash", "Stash"])
    func aStashTagIsRefusedBecauseItBreaksEveryStashDrop(name: String) async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let backend = CLIGitBackend()

        await #expect(throws: TagOperationError.nameProblem(.reserved)) {
            try await backend.createTag(name, at: root, message: nil, at: repo.root)
        }
        try repo.write("b.txt", "one\n")
        try await repo.git(["stash", "-q"])
        try await backend.drop(try #require(try await backend.stashes(at: repo.root).first), at: repo.root)
        #expect(try await backend.stashes(at: repo.root).isEmpty)

        try await repo.git(["tag", name, root])
        try repo.write("b.txt", "three\n")
        try await repo.git(["stash", "-q"])
        let entry = try #require(try await backend.stashes(at: repo.root).first)
        await #expect(throws: (any Error).self) { try await backend.drop(entry, at: repo.root) }
        #expect(try await backend.stashes(at: repo.root).count == 1)
    }

    /// `SQUASH_MSG` and `MERGE_MSG` are files Gitter reads through `--git-path`: a tag of either
    /// name is allowed and changes no operation state (measured for fix round 1).
    @Test(arguments: ["SQUASH_MSG", "MERGE_MSG"])
    func aTagNamedLikeAStateFileIsHarmless(name: String) async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }

        try await CLIGitBackend().createTag(name, at: root, message: nil, at: repo.root)

        #expect(try await repo.tagObject(name) == root)
        #expect(try await CLIGitBackend().snapshot(at: repo.root).status.operationInProgress == nil)
    }

    /// Minor 1: a configured remote nothing has been fetched from is a remote's name all the
    /// same — `git push upstream` would read the tag's name as the remote.
    @Test func aConfiguredRemotesNameIsRefusedBeforeAnyFetch() async throws {
        let (repo, _, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        let upstream = try await repo.addEmptyRemote(named: "upstream")
        defer { try? FileManager.default.removeItem(at: upstream) }

        #expect(try await CLIGitBackend().tagNameProblem("upstream", at: repo.root) == .isBranchName)
        #expect(try await CLIGitBackend().tagNameProblem("Upstream", at: repo.root) == .isBranchName)
    }

    /// I2: a dangling symbolic ref under `refs/tags/` is invisible to `for-each-ref`, and `git
    /// tag <name>` writes **through** it, creating the branch it names (measured). The name is
    /// taken: refused, and no branch appears.
    @Test func aDanglingSymbolicTagIsAnExistingName() async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        try await repo.git(["symbolic-ref", "refs/tags/dang", "refs/heads/gone"])
        let before = try await HistorySnapshot.capture(repo)

        #expect(try await CLIGitBackend().tagNameProblem("dang", at: repo.root) == .exists)
        await #expect(throws: TagOperationError.nameProblem(.exists)) {
            try await CLIGitBackend().createTag("dang", at: root, message: nil, at: repo.root)
        }
        try await before.assertUnchanged(repo)
        #expect(!(try await repo.gitRefExists("refs/heads/gone")))
    }

    /// RF2's reason: a tag named like a branch is what a short name then resolves to.
    @Test func aTagNamedLikeABranchWouldShadowIt() async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        try await repo.git(["tag", "feature", root])
        let resolved = try await repo.revParse("feature")
        #expect(resolved == root)
        #expect(resolved != (try await repo.revParse("refs/heads/feature")))
    }

    /// A reference-transaction hook refusing the create: git's words, no tag.
    @Test func aRefusingReferenceTransactionHookIsGitsWords() async throws {
        let (repo, root, _) = try await Self.makeRepo()
        defer { repo.cleanUp() }
        try repo.writeExecutable(
            ".git/hooks/reference-transaction",
            "#!/bin/sh\nif [ \"$1\" = prepared ]; then echo RT-NO >&2; exit 1; fi\nexit 0\n")
        let before = try await HistorySnapshot.capture(repo)

        do {
            try await CLIGitBackend().createTag("hooked", at: root, message: "m\n", at: repo.root)
            Issue.record("the create went through")
        } catch GitError.commandFailed(_, let stderr) {
            #expect(stderr.contains("RT-NO"), "\(stderr)")
            #expect(stderr.contains("reference-transaction hook"), "\(stderr)")
        }
        try await before.assertUnchanged(repo)
    }
}

/// The tag list's fields, read from `for-each-ref` (B18) — never from the log's `%D`, which user
/// config rewrites or hides.
@Suite struct TagListTests {
    @Test func annotatedAndLightweightFields() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let base = try await repo.commit("a.txt", "one", "commit subject")
        try await repo.git(["tag", "light"])
        _ = try await CLIGitBackend().runWithEnvironment(
            ["tag", "-a", "ann", "-m", "Annotated subject\n\nbody"], cwd: repo.root,
            extra: ["GIT_COMMITTER_DATE": "2023-11-16T02:00:00Z", "GIT_COMMITTER_NAME": "Tagger T"])

        let light = try await repo.listedTag("light")
        #expect(light.sha == base)
        #expect(light.objectID == base)
        #expect(!light.isAnnotated)
        #expect(light.tagger == nil)
        #expect(light.date == nil)
        #expect(light.subject == nil)

        let ann = try await repo.listedTag("ann")
        let object = try #require(try await repo.tagObject("ann"))
        #expect(object != base)
        #expect(ann.sha == base)
        #expect(ann.objectID == object)
        #expect(ann.isAnnotated)
        #expect(ann.tagger == "Tagger T")
        #expect(ann.date == Date(timeIntervalSince1970: 1_700_100_000))
        #expect(ann.subject == "Annotated subject")
    }

    /// `%(*objectname)` peels a tag of a tag all the way to the commit; the ref still holds the
    /// outer tag object.
    @Test func aTagOfATagPeelsToTheCommit() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let base = try await repo.commit("a.txt", "one", "base")
        try await repo.git(["tag", "-a", "inner", "-m", "inner"])
        try await repo.git(["tag", "-a", "outer", "-m", "outer", "inner"])

        let outer = try await repo.listedTag("outer")
        #expect(outer.sha == base)
        #expect(outer.objectID == (try await repo.tagObject("outer")))
        #expect(outer.objectID != (try await repo.tagObject("inner")))
        #expect(outer.subject == "outer")
    }

    /// RF3: `log.decorate=full` and `log.excludeDecoration=refs/tags/*` change the log's `%D` and
    /// leave the tag list exactly as it was.
    @Test func decorationConfigLeavesTheTagListAlone() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        _ = try await repo.commit("a.txt", "one", "base")
        try await repo.git(["tag", "light"])
        try await repo.git(["tag", "-a", "ann", "-m", "ann"])
        let before = try await CLIGitBackend().snapshot(at: repo.root).refs.tags
        #expect(before.map(\.name) == ["ann", "light"])

        try await repo.git(["config", "log.decorate", "full"])
        try await repo.git(["config", "log.excludeDecoration", "refs/tags/*"])

        #expect(try await CLIGitBackend().snapshot(at: repo.root).refs.tags == before)
    }
}
