import Foundation
import Testing

@testable import GitCore

/// Repository shapes, remote-side state and process queries the remote-operation suites share.
///
/// Everything here works against **local bare repositories in temp directories**. No test in
/// this package ever touches a network host: the failure wordings that only a real server
/// produces are captured fixtures in `RemoteFailureParserTests`, measured once by hand and
/// written down, never re-measured by the suite.
extension TestRepo {
    /// A second clone of the same bare origin this repository was given by
    /// `addOriginWithFeatureBranch` — "the colleague", the other person pushing to the server.
    ///
    /// It is a `TestRepo` like any other, with its own identity config, so a test can commit
    /// and push from it and then watch this repository's `fetch` discover what it did. Its
    /// root is a sibling of this one's (never inside it, which would put a second working tree
    /// inside the worktree snapshot), so the caller cleans it up alongside the repository:
    /// `defer { colleague.cleanUp() }`, exactly as `addOriginWithFeatureBranch`'s URL is
    /// cleaned up.
    ///
    /// The origin URL is read back out of this repository's config rather than passed in, so a
    /// caller that already has the `URL` from `addOriginWithFeatureBranch` need not thread it
    /// through.
    func addColleague(named name: String = "colleague") async throws -> TestRepo {
        let url = try await configValue("remote.origin.url")
        let colleagueRoot = root.deletingLastPathComponent()
            .appendingPathComponent("\(root.lastPathComponent)-\(name)", isDirectory: true)
        let runner = ProcessRunner()
        _ = try await runner.run(
            "/usr/bin/git", ["clone", "-q", url, colleagueRoot.path],
            cwd: root.deletingLastPathComponent())

        let colleague = TestRepo(root: colleagueRoot)
        try await colleague.git(["config", "user.email", "colleague@example.invalid"])
        try await colleague.git(["config", "user.name", "Colleague"])
        try await colleague.git(["config", "commit.gpgsign", "false"])
        try await colleague.git(["config", "core.hooksPath", ".git/hooks"])
        return colleague
    }

    /// One config value, trimmed. `--get` exits 1 when the key is not set, which is a state a
    /// caller may legitimately ask about, so it reads back as "".
    func configValue(_ key: String) async throws -> String {
        let data = try await git(["config", "--get", key], allowedExitCodes: [1])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every `*.lock` file anywhere under `.git`, as paths relative to `.git`.
    ///
    /// What a killed git leaves behind if it is killed at the wrong moment: `index.lock`,
    /// `refs/remotes/origin/main.lock`, `FETCH_HEAD.lock`. Empty is the only acceptable answer
    /// after a cancelled fetch, and it is asked of the filesystem rather than of git, because
    /// git itself would happily *ignore* a stale lock it did not create.
    func lockFiles() -> [String] {
        let gitDirectory = root.appendingPathComponent(".git")
        guard let enumerator = FileManager.default.enumerator(atPath: gitDirectory.path) else {
            return []
        }
        var locks: [String] = []
        for case let relativePath as String in enumerator where relativePath.hasSuffix(".lock") {
            locks.append(relativePath)
        }
        return locks.sorted()
    }

    /// `git fsck --no-progress`'s complaints, or "" when the object store is sound.
    ///
    /// Only stderr is read and only a non-zero exit is a failure: `fsck` writes "dangling
    /// commit …" notices to stdout for perfectly healthy repositories, and a cancelled fetch
    /// that transferred nothing is exactly the shape that produces them.
    func fsckComplaints() async throws -> String {
        do {
            _ = try await git(["fsck", "--no-progress"])
            return ""
        } catch let GitError.commandFailed(_, stderr) {
            return stderr
        }
    }
}

/// Processes whose full command line contains `pattern`, as `pgrep -f` reports them.
///
/// `pgrep` exits 1 when nothing matches, which is the answer this asks for and not an error.
/// The pattern a caller passes must be unique to the test that asks — a bare `sleep 47` would
/// also match a developer's own shell — which is why the slow-transport script below sleeps
/// for a duration nothing else would.
func processesMatching(_ pattern: String) async throws -> [String] {
    let runner = ProcessRunner()
    let data = try await runner.run(
        "/usr/bin/pgrep", ["-f", pattern], cwd: URL(fileURLWithPath: "/"), allowedExitCodes: [1])
    return String(decoding: data, as: UTF8.self)
        .split(separator: "\n").map(String.init)
}

/// The refs a bare repository holds — the server's side of every remote operation.
///
/// Names *and* objects, because "the remote is untouched" is a claim about both: a ref that
/// still exists but points somewhere else is exactly the failure a lease is meant to catch.
/// `for-each-ref` covers branches, tags and anything else under `refs/`; `HEAD` is captured
/// separately because it is not under `refs/` and a `set-head` would move it without touching
/// a single ref.
struct RemoteState: Equatable {
    /// `git for-each-ref --format=%(refname)%00%(objectname)` in the bare repository.
    let refs: String
    /// `git symbolic-ref -q HEAD`, empty when the bare repository's HEAD is not symbolic.
    let head: String

    static func capture(_ bareURL: URL) async throws -> RemoteState {
        RemoteState(
            refs: try await text(bareURL, ["for-each-ref", "--format=%(refname)%00%(objectname)"]),
            head: try await text(bareURL, ["symbolic-ref", "-q", "HEAD"], allowedExitCodes: [1])
        )
    }

    private static func text(
        _ bareURL: URL, _ arguments: [String], allowedExitCodes: Set<Int32> = []
    ) async throws -> String {
        let data = try await ProcessRunner().run(
            "/usr/bin/git", arguments, cwd: bareURL, allowedExitCodes: allowedExitCodes)
        return String(decoding: data, as: UTF8.self)
    }
}

/// Asserts the bare repository at `bareURL` holds exactly the refs `state` recorded.
///
/// Fails on an **empty baseline** for the same reason `assertWorktreeUnchanged` does: a
/// capture of a repository with no refs compares equal to a capture that failed to read any,
/// so every "the remote is untouched" claim built on one would be vacuous. A test that
/// genuinely starts from an empty server asserts that directly instead.
func assertRemoteUnchanged(
    _ bareURL: URL, since state: RemoteState,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    // Recorded and then *returned* from, unlike `assertWorktreeUnchanged`, which goes on to
    // compare anyway: an empty baseline is a bug in the test, not a fact about the server, and
    // the two mismatches that would follow it are noise in every run of the negative control
    // below.
    guard !state.refs.isEmpty else {
        Issue.record(
            "remote baseline holds no refs, so comparing against it would prove nothing",
            sourceLocation: sourceLocation)
        return
    }
    let now = try await RemoteState.capture(bareURL)
    #expect(now.refs == state.refs, "the remote's refs changed", sourceLocation: sourceLocation)
    #expect(now.head == state.head, "the remote's HEAD changed", sourceLocation: sourceLocation)
}

/// Runs `body` and returns the `RemoteOperationError` it threw, failing the test when it threw
/// something else or nothing at all. The mirror of `branchError`.
@discardableResult
func remoteError(
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () async throws -> Void
) async -> RemoteOperationError? {
    do {
        try await body()
        Issue.record("expected a RemoteOperationError, but nothing was thrown",
                     sourceLocation: sourceLocation)
        return nil
    } catch let error as RemoteOperationError {
        return error
    } catch {
        Issue.record("expected a RemoteOperationError, got \(error)", sourceLocation: sourceLocation)
        return nil
    }
}

/// Proves `assertRemoteUnchanged` can actually fail. Without these the helper could be
/// silently vacuous and every "the server is byte-for-byte what the colleague left" assertion
/// in this milestone would mean nothing.
///
/// These are the suite's known issues #5 and #6: `withKnownIssue` is the only way to assert
/// that an assertion *fails*, and it raises the reported "known issues" count by two.
@Suite struct RemoteAssertionsTests {
    @Test func noticesARefThatMovedOnTheServer() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        let before = try await RemoteState.capture(origin)
        #expect(!before.refs.isEmpty)

        try repo.write("later.txt", "later\n")
        try await repo.commitAll("later")
        try await repo.git(["push", "-q", "origin", "main"])

        await withKnownIssue("the server's refs really did move") {
            try await assertRemoteUnchanged(origin, since: before)
        }
    }

    @Test func failsOnAnEmptyBaseline() async throws {
        let repo = try await TestRepo.makeBranched()
        defer { repo.cleanUp() }
        let origin = try await repo.addOriginWithFeatureBranch()
        defer { try? FileManager.default.removeItem(at: origin) }

        await withKnownIssue("a baseline with no refs proves nothing") {
            try await assertRemoteUnchanged(origin, since: RemoteState(refs: "", head: ""))
        }
    }
}
