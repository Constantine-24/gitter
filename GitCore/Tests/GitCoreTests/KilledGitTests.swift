import Foundation
import Testing

@testable import GitCore

/// A stand-in for `/usr/bin/git` that hangs up on itself — SIGHUP, whose status is **1**, the
/// code of an ordinary refusal — for every command whose arguments contain `match`: after
/// running that command when `runFirst`, before anything otherwise. Every other command is the
/// real git, so the reads around the one under test are git's own. Written into `dir`; the path
/// is for `CLIGitBackend(gitPath:)`.
///
/// `match` is compared with the arguments joined by spaces (`"remote add"`, `"--unset-all"`).
/// `meanwhile` is a shell command run just before the signal — another writer's change landing
/// while git runs (`/usr/bin/git update-ref …`, which does not go through the wrapper).
func hangingUpGitPath(on match: String, runFirst: Bool, meanwhile: String = ":", in dir: URL) throws -> String {
    precondition(!match.contains("'"), "a match with a quote would break the wrapper's quoting")
    let wrapper = dir.appendingPathComponent("git-hangup-\(UUID().uuidString)")
    let script = """
        #!/bin/bash
        if [[ " $* " == *'\(match)'* ]]; then
            \(runFirst ? "/usr/bin/git \"$@\"" : ":")
            \(meanwhile)
            kill -HUP $$
        fi
        exec /usr/bin/git "$@"

        """
    try script.write(to: wrapper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
    return wrapper.path
}

/// Whether `error` is the refusal of a git killed by a signal: `commandFailed` with no exit
/// code (-1) and words that open with "git was killed by signal <n>.".
func isKilledGit(_ error: Error?, signal: Int32 = SIGHUP) -> Bool {
    guard case GitError.commandFailed(let code, let stderr)? = error else { return false }
    return code == -1 && stderr.hasPrefix("git was killed by signal \(signal).")
}

/// E1 promise 4, "a killed git is never read as an exit code", at every place a status reaches
/// GitCore (fix round 1, Ruling 5): the runner's own failure, the two backend seams every git
/// command goes through, and each caller that allows every exit code.
///
/// Where a caller already treats a git stopped part-way as an outcome it cannot know — its
/// `CancellationError` branch — a killed git takes that branch too: the outcome is just as
/// unknown, and the read-back that a plain failure would skip is what those callers exist to
/// keep. Everywhere else the killed git is thrown as a failure in the runner's words.
@Suite struct KilledGitTests {
    // MARK: - The wrapper

    /// The control for `hangingUpGitPath`: a matching command dies of SIGHUP with status 1 —
    /// after the real command when `runFirst` (its output is there), before anything otherwise
    /// — and every other command is git's, exiting as git does.
    @Test(arguments: [true, false])
    func theHangingUpGitDiesOfItsSignalOnlyOnAMatch(runFirst: Bool) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let gitPath = try hangingUpGitPath(on: "rev-parse --verify", runFirst: runFirst, in: repo.root.appendingPathComponent(".git"))

        let matched = try await isolatedRunner().runStreaming(
            gitPath, ["rev-parse", "--verify", "HEAD"], cwd: repo.root,
            allowedExitCodes: CLIGitBackend.anyExitCode, onStderr: { _ in })
        #expect(matched.terminationReason == .uncaughtSignal)
        #expect(matched.exitCode == 1)
        #expect(!matched.stdout.isEmpty == runFirst)

        let other = try await isolatedRunner().runStreaming(
            gitPath, ["rev-parse", "-q", "--sq", "refs/tags/nosuch"], cwd: repo.root,
            allowedExitCodes: CLIGitBackend.anyExitCode, onStderr: { _ in })
        #expect(other.terminationReason == .exit)
    }

    // MARK: - The runner, and the two seams

    /// The runner's own failure for a signal that is not an allowed code: no exit code, and the
    /// signal named — never `commandFailed(exitCode: 15)`, which the app worded "git exited with
    /// code 15".
    @Test func theRunnersFailureForASignalNamesTheSignalAndCarriesNoExitCode() async {
        let error = await thrownError {
            _ = try await ProcessRunner().runStreaming(
                "/bin/sh", ["-c", "echo nope >&2; kill -TERM $$"], cwd: URL(fileURLWithPath: "/"),
                onStderr: { _ in })
        }
        #expect(error as? GitError == .commandFailed(exitCode: -1, stderr: "git was killed by signal 15.\nnope"))
    }

    /// The control: an exit is still its code, so the -1 above is the signal's doing.
    @Test func theRunnersFailureForAnExitKeepsItsCode() async {
        let error = await thrownError {
            _ = try await ProcessRunner().runStreaming(
                "/bin/sh", ["-c", "echo nope >&2; exit 15"], cwd: URL(fileURLWithPath: "/"), onStderr: { _ in })
        }
        #expect(error as? GitError == .commandFailed(exitCode: 15, stderr: "nope"))
    }

    /// `runWithEnvironment` and `runStreaming` refuse a killed git before any caller sees its
    /// status — even with every code allowed, where SIGHUP's 1 used to come back as git's answer.
    @Test(arguments: [true, false])
    func bothSeamsRefuseAKilledGitWhateverCodesTheCallerAllows(environment: Bool) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let gitPath = try hangingUpGitPath(on: "check-ref-format", runFirst: true, in: repo.root.appendingPathComponent(".git"))
        let backend = CLIGitBackend(gitPath: gitPath)
        let arguments = ["check-ref-format", "refs/remotes/x/test"]

        let error = await thrownError {
            let result =
                environment
                ? try await backend.runWithEnvironment(arguments, cwd: repo.root, extra: [:], allowedExitCodes: CLIGitBackend.anyExitCode)
                : try await backend.runStreaming(arguments, cwd: repo.root, allowedExitCodes: CLIGitBackend.anyExitCode, progress: { _ in })
            Issue.record("a killed git came back as status \(result.exitCode)")
        }
        #expect(isKilledGit(error), "\(String(describing: error))")
    }

    // MARK: - Callers that throw it

    /// A name check whose git was killed is not an answer: thrown, never `.invalid`.
    @Test func aKilledNameCheckIsThrownNotAnInvalidName() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let gitPath = try hangingUpGitPath(on: "check-ref-format", runFirst: true, in: repo.root.appendingPathComponent(".git"))

        let error = await thrownError {
            let problem = try await CLIGitBackend(gitPath: gitPath).remoteNameProblem("fine", at: repo.root)
            Issue.record("read as \(String(describing: problem))")
        }
        #expect(isKilledGit(error), "\(String(describing: error))")
    }

    /// A local tag delete whose git was killed is read back, as a refused one always was (fix
    /// round 2): the tag gone is the delete — its receipt, so Restore is offered and an
    /// annotated tag's object is not lost; the tag as it was is nothing deleted — the killed git,
    /// thrown; and the tag holding something else is `.tagMoved`.
    @Test(arguments: ["deleted", "untouched", "moved"])
    func aKilledTagDeleteIsReadBack(when: String) async throws {
        let repo = try await TagDeleteTests.makeRepo()
        defer { repo.cleanUp() }
        let tag = try await repo.listedTag("v1")
        let commit = try await repo.revParse("refs/tags/v1")
        let head = try await repo.revParse("HEAD")
        #expect(head != commit)
        let gitPath = try hangingUpGitPath(
            on: "update-ref --no-deref -d", runFirst: when == "deleted",
            meanwhile: when == "moved" ? "/usr/bin/git update-ref refs/tags/v1 \(head)" : ":",
            in: repo.root.appendingPathComponent(".git"))

        do {
            let receipt = try await CLIGitBackend(gitPath: gitPath).deleteTag(tag, at: repo.root)
            #expect(when == "deleted", "read as deleted: \(receipt)")
            #expect(receipt == TagReceipt(name: "v1", objectID: commit, target: commit))
        } catch {
            switch when {
            case "untouched": #expect(isKilledGit(error), "\(error)")
            case "moved": #expect(error as? TagOperationError == .tagMoved(name: "v1"), "\(error)")
            default: Issue.record("git deleted the tag, yet the delete threw \(error)")
            }
        }
        // The premise of each case, read from the repository.
        let now = try await repo.tagObject("v1")
        switch when {
        case "deleted": #expect(now == nil)
        case "untouched": #expect(now == commit)
        default: #expect(now == head)
        }
    }

    /// A stash push whose git was killed is read back, as one that exited with a refusal always
    /// was (fix round 2): an entry filed is `.savedWithError` — saved, git not having finished,
    /// in the signal's words — so the entry and its Pop are reported; nothing filed is the
    /// killed git, thrown.
    @Test(arguments: [true, false])
    func aKilledStashPushIsReadBack(runFirst: Bool) async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "changed\n")
        let gitPath = try hangingUpGitPath(on: "stash push", runFirst: runFirst, in: repo.root.appendingPathComponent(".git"))

        do {
            let outcome = try await CLIGitBackend(gitPath: gitPath).stashAll(message: "kept", includeUntracked: false, at: repo.root)
            #expect(runFirst, "nothing was filed, yet the push was read as \(outcome)")
            guard case .savedWithError(let stash, let words, _) = outcome else {
                Issue.record("the filed entry was read as \(outcome)")
                return
            }
            #expect(stash.index == 0)
            #expect(words.hasPrefix("git was killed by signal 1."), "\(words)")
        } catch {
            #expect(!runFirst, "an entry was filed, yet the push threw \(error)")
            #expect(isKilledGit(error), "\(error)")
        }
        let listed = try await repo.git(["stash", "list"])
        #expect(listed.isEmpty != runFirst, "the premise: an entry was filed exactly when git ran")
    }

    /// A continue whose git was killed is a failure in the runner's words, not git's answer.
    @Test func aKilledContinueIsThrown() async throws {
        let repo = try await SequenceFixtures.stopped(.cherryPick, commits: 1)
        defer { repo.cleanUp() }
        try await SequenceFixtures.resolve(repo)
        let gitPath = try hangingUpGitPath(on: "cherry-pick --continue", runFirst: false, in: repo.root.appendingPathComponent(".git"))

        let error = await thrownError {
            let outcome = try await CLIGitBackend(gitPath: gitPath).continueOperation(.cherryPick, message: nil, at: repo.root)
            Issue.record("read as \(outcome)")
        }
        #expect(isKilledGit(error), "\(String(describing: error))")
    }

    /// A single revert whose git was killed before it did anything: HEAD and the index are where
    /// they were and the status is 1 — which read as git's own "already reverted".
    @Test func aKilledRevertIsThrownNotAlreadyReverted() async throws {
        let (repo, _, _, _) = try await HistoryRunTests.makeSide()
        defer { repo.cleanUp() }
        let head = try await repo.revParse("HEAD")
        let plan = try await CLIGitBackend().historyPlan(.revert, shas: [head], at: repo.root)
        let gitPath = try hangingUpGitPath(on: "revert --no-edit", runFirst: false, in: repo.root.appendingPathComponent(".git"))

        let error = await thrownError {
            let outcome = try await CLIGitBackend(gitPath: gitPath).run(plan, at: repo.root)
            Issue.record("read as \(outcome)")
        }
        #expect(isKilledGit(error), "\(String(describing: error))")
        #expect(try await repo.revParse("HEAD") == head)
    }

    // MARK: - Callers that cannot know the outcome

    /// Adding a remote, and the three URL writes: a killed git may have written or not, so it is
    /// the outcome nobody knows — as for a cancel — never git's refusal with the signal as code.
    @Test(arguments: ["remote add", "set-url --end-of-options", "set-url --push", "--unset-all"])
    func aKilledURLWriteIsOfUnknownOutcome(match: String) async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let gitPath = try hangingUpGitPath(on: match, runFirst: false, in: repo.root.appendingPathComponent(".git"))
        let backend = CLIGitBackend(gitPath: gitPath)
        if match == "--unset-all" { try await repo.git(["config", "remote.origin.pushurl", "/srv/p.git"]) }

        let error = await thrownError {
            switch match {
            case "remote add": try await backend.addRemote("second", url: "/srv/second.git", at: repo.root)
            case "set-url --end-of-options": try await backend.setURLs(of: "origin", fetch: "/srv/moved.git", push: .unchanged, at: repo.root)
            case "set-url --push": try await backend.setURLs(of: "origin", fetch: fixture.origin.path, push: .set("/srv/p.git"), at: repo.root)
            default: try await backend.setURLs(of: "origin", fetch: fixture.origin.path, push: .clear, at: repo.root)
            }
        }
        let remote = match == "remote add" ? "second" : "origin"
        #expect(error as? RemoteAdminPartial == .urlsOutcomeUnknown(remote: remote), "\(String(describing: error))")
    }

    @Test func aKilledRenameIsOfUnknownOutcome() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let gitPath = try hangingUpGitPath(on: "remote rename", runFirst: true, in: fixture.repo.root.appendingPathComponent(".git"))

        let error = await thrownError { try await CLIGitBackend(gitPath: gitPath).renameRemote("origin", to: "up", at: fixture.repo.root) }

        #expect(error as? RemoteAdminPartial == .renameOutcomeUnknown(old: "origin", new: "up"), "\(String(describing: error))")
    }

    @Test func aKilledRemoteRemovalIsOfUnknownOutcome() async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let impact = try await CLIGitBackend().removalImpact(of: "origin", at: repo.root)
        let gitPath = try hangingUpGitPath(on: "remote remove", runFirst: true, in: repo.root.appendingPathComponent(".git"))

        let error = await thrownError { try await CLIGitBackend(gitPath: gitPath).removeRemote(impact, keeping: [:], at: repo.root) }

        #expect(
            error as? RemoteAdminPartial == .removeOutcomeUnknown(remote: "origin", keptBranches: []),
            "\(String(describing: error))")
    }

    @Test func aKilledFastForwardIsOfUnknownOutcome() async throws {
        let fixture = try await FastForwardFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let gitPath = try hangingUpGitPath(on: "update-ref --no-deref -m", runFirst: true, in: repo.root.appendingPathComponent(".git"))

        let error = await thrownError {
            _ = try await CLIGitBackend(gitPath: gitPath).fastForward("keep", expecting: fixture.old, at: repo.root)
        }

        #expect(
            error as? RemoteAdminPartial == .fastForwardOutcomeUnknown(branch: "keep", from: fixture.old, to: fixture.new),
            "\(String(describing: error))")
    }

    @Test(arguments: ["--set-upstream-to", "--unset-upstream"])
    func aKilledUpstreamWriteIsOfUnknownOutcome(match: String) async throws {
        let fixture = try await UpstreamFixture.make()
        defer { fixture.cleanUp() }
        let repo = fixture.repo
        let gitPath = try hangingUpGitPath(on: match, runFirst: false, in: repo.root.appendingPathComponent(".git"))
        let backend = CLIGitBackend(gitPath: gitPath)

        let error = await thrownError {
            if match == "--set-upstream-to" {
                _ = try await backend.setUpstream(of: "b1", to: "refs/remotes/origin/keep", at: repo.root)
            } else {
                try await backend.unsetUpstream(of: "b1", at: repo.root)
            }
        }

        #expect(error as? RemoteAdminPartial == .upstreamOutcomeUnknown(branch: "b1"), "\(String(describing: error))")
    }

    /// A killed `worktree add` is read back like a cancelled one: a worktree that is there is
    /// reported as added with git not having finished (its words the signal's), and one that is
    /// not is the killed git, thrown — never "git refused" with the signal as its code.
    @Test(arguments: [true, false])
    func aKilledWorktreeAddIsReadBack(runFirst: Bool) async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.repo.git(["branch", "feat"])
        let gitPath = try hangingUpGitPath(on: "worktree add", runFirst: runFirst, in: fixture.repo.root.appendingPathComponent(".git"))

        do {
            let result = try await CLIGitBackend(gitPath: gitPath).addWorktree(path: fixture.path("wt"), branch: "feat", at: fixture.repo.root)
            #expect(runFirst, "nothing was added, yet the add was read as \(result)")
            guard case .addedWithError(let wt, let words) = result else {
                Issue.record("the added worktree was read as \(result)")
                return
            }
            #expect(wt.path == fixture.listedPath("wt"))
            #expect(words.hasPrefix("git was killed by signal 1."), "\(words)")
        } catch {
            #expect(!runFirst, "the worktree is there, yet the add threw \(error)")
            #expect(isKilledGit(error), "\(error)")
        }
    }

    @Test func aKilledWorktreeRemovalIsOfUnknownOutcome() async throws {
        let fixture = try await WorktreeFixture.make()
        defer { fixture.cleanUp() }
        try await fixture.addOnNewBranch("wt", "w")
        let removal = try await fixture.backend.removalCheck(try await fixture.listed("wt"), at: fixture.repo.root, walkLimit: .standard)
        let gitPath = try hangingUpGitPath(on: "worktree remove", runFirst: true, in: fixture.repo.root.appendingPathComponent(".git"))

        let error = await thrownError { _ = try await CLIGitBackend(gitPath: gitPath).removeWorktree(removal, keeping: [:], at: fixture.repo.root) }

        #expect(error as? WorktreeRemovalPartial == .outcomeUnknown(keptBranches: []), "\(String(describing: error))")
    }

    /// A prune's compare-and-delete killed after it deleted: not "it moved" and not "git refused".
    @Test func aKilledPruneDeleteIsOfUnknownOutcome() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let plan = try await CLIGitBackend().prunePlan("origin", at: fixture.repo.root)
        let gitPath = try hangingUpGitPath(on: "update-ref --no-deref -d", runFirst: true, in: fixture.repo.root.appendingPathComponent(".git"))

        let result = try await CLIGitBackend(gitPath: gitPath).prune(plan, keeping: [:], at: fixture.repo.root)

        #expect(result.outcomeUnknown == plan.refs)
        #expect(result.skippedMoved.isEmpty)
        #expect(result.failed.isEmpty)
    }

    /// A kept branch whose `branch` was killed may or may not exist: the cancelled case's
    /// wording, never "nothing was created".
    @Test func aKilledKeptBranchIsOfUnknownOutcome() async throws {
        let fixture = try await PruneFixture.make()
        defer { fixture.cleanUp() }
        let plan = try await CLIGitBackend().prunePlan("origin", at: fixture.repo.root)
        let gitPath = try hangingUpGitPath(on: "branch --no-track", runFirst: true, in: fixture.repo.root.appendingPathComponent(".git"))

        let error = await thrownError {
            _ = try await CLIGitBackend(gitPath: gitPath).prune(plan, keeping: [PruneFixture.gone1Ref: "saved"], at: fixture.repo.root)
        }

        #expect(error as? RemoteAdminPartial == .keptBranchesCancelled(kept: [], unknown: "saved"), "\(String(describing: error))")
    }
}
