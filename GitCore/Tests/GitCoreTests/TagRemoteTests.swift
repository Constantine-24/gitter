import Foundation
import Testing

@testable import GitCore

/// `GitTagBackend`'s remote half against a local bare remote: `remoteTagID`, `pushTag` and the
/// leased `deleteRemoteTag` (B20, B21, RF1, RF3) — plus the two VERIFY items of Task 2 (B21's
/// `receive.denyDeletes`, B22's "would clobber existing tag" through Gitter's fetch).
@Suite struct TagRemoteTests {
    /// `makeBranched()` with `origin` (a bare repository holding `main` and `feat/x`, no tags),
    /// a second commit on `main` that the remote does not have, an annotated `ann` on it and a
    /// lightweight `light` on the root.
    static func makeRepo() async throws -> (repo: TestRepo, origin: URL) {
        let repo = try await TestRepo.makeBranched()
        let origin = try await repo.addOriginWithFeatureBranch()
        _ = try await repo.commit("b.txt", "two", "second")
        try await repo.git(["tag", "-a", "ann", "-m", "Annotated"])
        try await repo.git(["tag", "light", "refs/tags/v1"])
        return (repo, origin)
    }

    static func cleanUp(_ repo: TestRepo, _ origin: URL) {
        repo.cleanUp()
        try? FileManager.default.removeItem(at: origin)
    }

    // MARK: - Push

    @Test(arguments: ["ann", "light"])
    func aNewTagIsPushedAndNothingElse(name: String) async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        let before = try await RemoteState.capture(origin)

        #expect(try await CLIGitBackend().pushTag(name, to: "origin", at: repo.root) == .pushed)

        #expect(try await TestRepo.remoteTag(origin, name) == (try await repo.tagObject(name)))
        try await assertOnlyRefChanged(origin, since: before, isThe: "refs/tags/\(name)")
    }

    @Test func aTagTheRemoteAlreadyHasIsAlreadyThere() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        #expect(try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root) == .pushed)
        let before = try await RemoteState.capture(origin)

        #expect(try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root) == .alreadyThere)
        try await assertRemoteUnchanged(origin, since: before)
    }

    /// The remote has another tag of that name — even one a fast-forward away: rejected, never
    /// forced (B20).
    @Test(arguments: ["ann", "light"])
    func aDifferentTagOnTheRemoteIsRejectedAndKept(name: String) async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        // The remote's tag points at the root, an ancestor of what ours points at.
        try await repo.git(["push", "-q", "origin", "refs/tags/v1:refs/tags/\(name)"])
        if name == "light" { try await repo.git(["tag", "-f", "light", "main"]) }
        let before = try await RemoteState.capture(origin)

        #expect(try await CLIGitBackend().pushTag(name, to: "origin", at: repo.root) == .rejectedExists)
        try await assertRemoteUnchanged(origin, since: before)
    }

    /// RF3: `push.followTags=true` would push every annotated tag on the pushed commits too
    /// (B20). Only the one named tag reaches the server.
    @Test func pushFollowTagsPushesOnlyTheOneTag() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        try await repo.git(["tag", "-a", "extra", "-m", "nobody named me"])
        try await repo.git(["config", "push.followTags", "true"])
        let before = try await RemoteState.capture(origin)

        #expect(try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root) == .pushed)

        try await assertOnlyRefChanged(origin, since: before, isThe: "refs/tags/ann")
        #expect(try await TestRepo.remoteTag(origin, "extra") == nil)
    }

    /// `remote.<r>.mirror=true`: git refuses any refspec with a mirror (B20) — its words, and
    /// nothing pushed.
    @Test func aMirrorRemoteIsGitsRefusal() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        try await repo.git(["config", "remote.origin.mirror", "true"])
        let before = try await RemoteState.capture(origin)

        let outcome = try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root)

        guard case .failed(let words) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(words.contains("--mirror can't be combined with refspecs"), "\(words)")
        try await assertRemoteUnchanged(origin, since: before)
    }

    @Test func aRefusingPrePushHookIsFailedInItsWords() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        try repo.writeExecutable(".git/hooks/pre-push", "#!/bin/sh\necho PRE-PUSH-NO >&2\nexit 1\n")
        let before = try await RemoteState.capture(origin)

        let outcome = try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root)

        guard case .failed(let words) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(words.contains("PRE-PUSH-NO"), "\(words)")
        try await assertRemoteUnchanged(origin, since: before)
    }

    @Test func aDecliningServerHookIsFailedInItsWords() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        try writeBareHook(origin, "update", "#!/bin/sh\necho UPDATE-HOOK-NO\nexit 1\n")
        let before = try await RemoteState.capture(origin)

        let outcome = try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root)

        guard case .failed(let words) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(words.contains("hook declined"), "\(words)")
        #expect(words.contains("UPDATE-HOOK-NO"), "\(words)")
        try await assertRemoteUnchanged(origin, since: before)
    }

    @Test func aTagThatDoesNotExistLocallyIsFailed() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        let before = try await RemoteState.capture(origin)

        let outcome = try await CLIGitBackend().pushTag("nosuch", to: "origin", at: repo.root)

        guard case .failed(let words) = outcome else {
            Issue.record("\(outcome)")
            return
        }
        #expect(words.contains("does not match any"), "\(words)")
        try await assertRemoteUnchanged(origin, since: before)
    }

    /// A name that would make the refspec something else — a glob, a second `:` — or a remote
    /// read as an option: refused before git runs. (git forbids each of these characters in a
    /// ref name, so no tag that exists is refused.)
    @Test func namesThatChangeTheRefspecAreRefusedBeforeGit() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        let before = try await RemoteState.capture(origin)

        for name in ["*", "v*", "a:b", "", "a b", "x?", "a..b"] {
            await #expect(throws: TagOperationError.nameProblem(name.isEmpty ? .empty : .invalid)) {
                _ = try await git.backend.pushTag(name, to: "origin", at: repo.root)
            }
            await #expect(throws: TagOperationError.self) {
                _ = try await git.backend.remoteTagID(name, on: "origin", at: repo.root)
            }
            await #expect(throws: TagOperationError.self) {
                try await git.backend.deleteRemoteTag(
                    name, on: "origin", expecting: String(repeating: "a", count: 40), at: repo.root)
            }
        }
        await #expect(throws: RemoteOperationError.noRemote) {
            _ = try await git.backend.pushTag("ann", to: "--mirror", at: repo.root)
        }
        git.assertNothingRan()
        try await assertRemoteUnchanged(origin, since: before)
    }

    // MARK: - Remote id

    /// Unpeeled: an annotated tag's id on the remote is its tag object — what a lease must name
    /// (B21).
    @Test func theRemoteIDIsTheUnpeeledTagObject() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        _ = try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root)
        _ = try await CLIGitBackend().pushTag("light", to: "origin", at: repo.root)
        let object = try #require(try await repo.tagObject("ann"))
        #expect(object != (try await repo.revParse("ann^{commit}")))

        #expect(try await CLIGitBackend().remoteTagID("ann", on: "origin", at: repo.root) == object)
        #expect(try await CLIGitBackend().remoteTagID("light", on: "origin", at: repo.root)
            == (try await repo.revParse("refs/tags/v1")))
    }

    /// No such tag → nil. Also when another ref on the remote merely ends in the same path:
    /// `ls-remote` matches patterns from the tail.
    @Test func aTagTheRemoteDoesNotHaveIsNil() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        try await repo.git(["push", "-q", "origin", "refs/tags/v1:refs/heads/refs/tags/ann"])

        #expect(try await CLIGitBackend().remoteTagID("ann", on: "origin", at: repo.root) == nil)
        #expect(try await CLIGitBackend().remoteTagID("nosuch", on: "origin", at: repo.root) == nil)
    }

    @Test func anUnreachableRemoteIsThrown() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        try await repo.git(["remote", "add", "gone", origin.path + "-missing"])

        await #expect(throws: RemoteOperationError.repositoryNotFound) {
            _ = try await CLIGitBackend().remoteTagID("ann", on: "gone", at: repo.root)
        }
    }

    // MARK: - Leased remote delete

    @Test(arguments: ["ann", "light"])
    func aRemoteTagIsDeletedOnTheIDTheSheetShowed(name: String) async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        _ = try await CLIGitBackend().pushTag(name, to: "origin", at: repo.root)
        let id = try #require(try await CLIGitBackend().remoteTagID(name, on: "origin", at: repo.root))
        let before = try await RemoteState.capture(origin)

        try await CLIGitBackend().deleteRemoteTag(name, on: "origin", expecting: id, at: repo.root)

        #expect(try await TestRepo.remoteTag(origin, name) == nil)
        try await assertOnlyRefChanged(origin, since: before, isThe: "refs/tags/\(name)")
        #expect(try await repo.tagObject(name) != nil, "the local tag is not touched")
    }

    /// RF1: the remote tag moved — or was deleted — after the sheet read it: the lease is
    /// stale, and the remote keeps what it has now.
    @Test(arguments: ["move", "delete"])
    func aRemoteTagThatChangedIsRefusedAndKept(change: String) async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        _ = try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root)
        let id = try #require(try await CLIGitBackend().remoteTagID("ann", on: "origin", at: repo.root))
        if change == "move" {
            try await bareGit(origin, ["update-ref", "refs/tags/ann", "refs/heads/feat/x"])
        } else {
            try await bareGit(origin, ["update-ref", "-d", "refs/tags/ann"])
        }
        let before = try await RemoteState.capture(origin)

        await #expect(throws: TagOperationError.remoteTagMoved(name: "ann", remote: "origin")) {
            try await CLIGitBackend().deleteRemoteTag("ann", on: "origin", expecting: id, at: repo.root)
        }
        try await assertRemoteUnchanged(origin, since: before)
    }

    /// The lease names the unpeeled id: the commit an annotated tag peels to is stale (B21).
    @Test func aLeaseOnThePeeledCommitIsStale() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        _ = try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root)
        let commit = try await repo.revParse("ann^{commit}")
        let before = try await RemoteState.capture(origin)

        await #expect(throws: TagOperationError.remoteTagMoved(name: "ann", remote: "origin")) {
            try await CLIGitBackend().deleteRemoteTag("ann", on: "origin", expecting: commit, at: repo.root)
        }
        try await assertRemoteUnchanged(origin, since: before)
    }

    @Test(arguments: ["", "0000000000000000000000000000000000000000", "abc1234"])
    func aLeaseThatIsNotAFullObjectNameIsRefusedBeforeGit(id: String) async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        _ = try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root)
        let git = try GitLaunchLog()
        defer { git.cleanUp() }
        let before = try await RemoteState.capture(origin)

        await #expect(throws: RemoteOperationError.invalidLease(id)) {
            try await git.backend.deleteRemoteTag("ann", on: "origin", expecting: id, at: repo.root)
        }
        git.assertNothingRan()
        try await assertRemoteUnchanged(origin, since: before)
    }

    @Test func aDecliningServerHookOnTheDeleteIsGitsWords() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        _ = try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root)
        let id = try #require(try await CLIGitBackend().remoteTagID("ann", on: "origin", at: repo.root))
        try writeBareHook(origin, "update", "#!/bin/sh\necho UPDATE-HOOK-NO\nexit 1\n")
        let before = try await RemoteState.capture(origin)

        do {
            try await CLIGitBackend().deleteRemoteTag("ann", on: "origin", expecting: id, at: repo.root)
            Issue.record("the delete went through")
        } catch GitError.commandFailed(_, let stderr) {
            #expect(stderr.contains("UPDATE-HOOK-NO"), "\(stderr)")
            #expect(stderr.contains("hook declined"), "\(stderr)")
        }
        try await assertRemoteUnchanged(origin, since: before)
    }

    // MARK: - A git killed by a signal (E1 S5)

    /// A tag push whose git was killed is a failure, never an outcome read from what git got as
    /// far as printing: not `.pushed` from a `[new tag]` line it printed before the signal, and
    /// not `.failed` with a status that is really the signal's number. It is thrown, with no
    /// exit code (-1) and words that name the signal — a write, so the banner says the remote
    /// may or may not have been updated.
    @Test(arguments: [true, false])
    func aTagPushWhoseGitIsKilledIsAFailure(pushFirst: Bool) async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        let gitPath = try hangingUpGitPath(on: "push --porcelain", runFirst: pushFirst, in: repo.root.appendingPathComponent(".git"))

        do {
            let outcome = try await CLIGitBackend(gitPath: gitPath).pushTag("ann", to: "origin", at: repo.root)
            Issue.record("a killed git was read as an outcome: \(outcome)")
        } catch GitError.commandFailed(let code, let stderr) {
            #expect(code == -1, "the signal was read as exit code \(code)")
            #expect(stderr.contains("git was killed by signal 1"), "\(stderr)")
        }
        // The premise: the push itself happened, or did not.
        #expect((try await TestRepo.remoteTag(origin, "ann") != nil) == pushFirst)
    }

    /// The same for the leased delete, which used to report the signal as git's exit code 1 —
    /// or, killed after the delete went through, a success.
    @Test(arguments: [true, false])
    func aLeasedDeleteWhoseGitIsKilledIsAFailure(pushFirst: Bool) async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        _ = try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root)
        let id = try #require(try await CLIGitBackend().remoteTagID("ann", on: "origin", at: repo.root))
        let gitPath = try hangingUpGitPath(on: "push --porcelain", runFirst: pushFirst, in: repo.root.appendingPathComponent(".git"))

        do {
            try await CLIGitBackend(gitPath: gitPath).deleteRemoteTag("ann", on: "origin", expecting: id, at: repo.root)
            Issue.record("a killed git was read as a delete")
        } catch GitError.commandFailed(let code, let stderr) {
            #expect(code == -1, "the signal was read as exit code \(code)")
            #expect(stderr.contains("git was killed by signal 1"), "\(stderr)")
        }
        #expect((try await TestRepo.remoteTag(origin, "ann") == nil) == pushFirst)
    }

    // MARK: - VERIFY (Task 2)

    /// B21 left it unexplained; measured for Task 2: `receive.denyDeletes=true` is enforced on a
    /// local bare remote, but only for `refs/heads/` — receive-pack lets a tag (or any other
    /// ref) be deleted under it. A server cannot protect its tags this way; the lease and the
    /// confirmation are what stand between a click and a deleted remote tag.
    @Test func receiveDenyDeletesProtectsBranchesButNotTags() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        _ = try await CLIGitBackend().pushTag("ann", to: "origin", at: repo.root)
        try await bareGit(origin, ["config", "receive.denyDeletes", "true"])
        // The baseline that can fail: the setting is in force for a branch.
        let branch = try await repo.git(["push", "--porcelain", "origin", ":refs/heads/feat/x"], allowedExitCodes: [1])
        #expect(String(decoding: branch, as: UTF8.self).contains("[remote rejected] (deletion prohibited)"))
        let id = try #require(try await CLIGitBackend().remoteTagID("ann", on: "origin", at: repo.root))

        try await CLIGitBackend().deleteRemoteTag("ann", on: "origin", expecting: id, at: repo.root)

        #expect(try await TestRepo.remoteTag(origin, "ann") == nil)
    }

    /// B22: under `remote.<r>.tagOpt=--tags`, a tag the remote moved fails Gitter's fetch
    /// ("would clobber existing tag", exit 1). `RemoteFailureParser` has no wording for it, so
    /// it reaches the user as git's own words; the local tag is kept, and the rest of the fetch
    /// is applied.
    @Test func aMovedRemoteTagUnderTagOptTagsFailsTheFetchInGitsWords() async throws {
        let (repo, origin) = try await Self.makeRepo()
        defer { Self.cleanUp(repo, origin) }
        _ = try await CLIGitBackend().pushTag("light", to: "origin", at: repo.root)
        let local = try await repo.tagObject("light")
        try await bareGit(origin, ["update-ref", "refs/tags/light", "refs/heads/feat/x"])
        try await bareGit(origin, ["update-ref", "refs/heads/feat/x", "refs/heads/main"])
        try await repo.git(["config", "remote.origin.tagOpt", "--tags"])
        #expect(RemoteFailureParser.parse(stderr: " ! [rejected]        light      -> light  (would clobber existing tag)") == nil)

        do {
            try await CLIGitBackend().fetch(remote: "origin", at: repo.root, progress: { _ in })
            Issue.record("the fetch succeeded")
        } catch GitError.commandFailed(let code, let stderr) {
            #expect(code == 1)
            #expect(stderr.contains("(would clobber existing tag)"), "\(stderr)")
        }
        #expect(try await repo.tagObject("light") == local)
        #expect(try await repo.revParse("refs/remotes/origin/feat/x") == (try await bareGit(origin, ["rev-parse", "main"])))
    }
}
