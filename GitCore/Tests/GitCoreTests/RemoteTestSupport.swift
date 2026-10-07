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
        _ = try await isolatedRunner().run(
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

    /// Whether `ref` resolves to anything. `rev-parse --verify -q` exits 1 and says nothing
    /// when it does not, which is the answer being asked for rather than an error — and unlike
    /// `revParse`, a missing ref is a `false` here instead of a thrown `GitError`, so a test can
    /// assert a ref's *absence* as easily as its presence.
    func gitRefExists(_ ref: String) async throws -> Bool {
        let data = try await git(["rev-parse", "--verify", "-q", ref], allowedExitCodes: [1])
        return !String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

/// One git command run **in a bare repository**, as trimmed text.
///
/// `RemoteState` says what the server's refs are, and this says everything else about it: that
/// a commit a force push took off a branch is still an object in the object store, that a
/// commit is no longer reachable from a branch, what the bare repository's HEAD is. A working
/// `TestRepo` cannot answer any of those about the server, because the server has no worktree
/// and is nobody's `TestRepo`.
///
/// The runner is `isolatedRunner()`, so the developer's own configuration reaches this git as
/// little as it reaches every other one in this suite.
@discardableResult
func bareGit(
    _ bareURL: URL, _ arguments: [String], allowedExitCodes: Set<Int32> = []
) async throws -> String {
    let data = try await isolatedRunner().run(
        "/usr/bin/git", arguments, cwd: bareURL, allowedExitCodes: allowedExitCodes)
    return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Writes an executable hook into a **bare** repository's `hooks` directory.
///
/// `TestRepo.writeExecutable` works on a working repository; the server has no worktree, so
/// its hooks are written by path. Shared by every suite that needs a server with an opinion —
/// a `pre-receive` that declines, a `post-receive` that prints a pull-request URL.
func writeBareHook(_ bareURL: URL, _ name: String, _ contents: String) throws {
    let url = bareURL.appendingPathComponent("hooks/\(name)")
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try contents.write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

// MARK: - The test's own processes

/// A process query that could not answer: `pgrep` would not start, or failed (exit 2 or 3), or
/// was asked with an empty marker, which matches every process the user has.
struct OwnProcessQueryFailed: Error, CustomStringConvertible {
    let description: String
}

/// The pids of **this user's** live processes whose full command line contains `marker`:
/// `pgrep -U <uid> -f <marker>`, and nothing else. Every leak check and every cleanup in the
/// suite looks through this, never through the whole process table (E1 promise 5).
///
/// The marker must be unique to the test that asks — a UUID, or a `sleep` duration with six
/// random digits — so that another test's process, or another run's, is never counted
/// (`OwnProcessTests.aDecoyUnderAnotherMarkerIsNeitherCountedNorKilled`). `-U` keeps other
/// users' processes out even of a marker that collided. `pgrep` never lists itself, and exits
/// 1 when nothing matches, which is the answer asked for and not an error.
///
/// Synchronous on purpose: the probe is launched and waited for on one thread with no `await`
/// in between — the one way `waitUntilExit` on a `Process` without a `terminationHandler`
/// cannot hang (see `StreamingRunnerTests`' stress marker).
func ownProcesses(matching marker: String) throws -> [pid_t] {
    guard !marker.isEmpty else {
        throw OwnProcessQueryFailed(description: "an empty marker matches every process")
    }
    let probe = Process()
    probe.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
    probe.arguments = ["-U", String(getuid()), "-f", marker]
    let out = Pipe()
    probe.standardOutput = out
    probe.standardError = FileHandle.nullDevice
    try probe.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    probe.waitUntilExit()
    guard probe.terminationReason == .exit, [0, 1].contains(probe.terminationStatus) else {
        throw OwnProcessQueryFailed(
            description: "the process query for \(marker) failed: \(probe.terminationStatus)")
    }
    return String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { pid_t($0) }
}

/// Whether `killOwnGroup` may signal `pgid`: never 0, 1 or below — `kill(-1, …)` is every
/// process the user owns and `kill(0, …)` is the caller's own group — and never this process's
/// own group, which holds the test runner and whatever started it.
func isKillableOwnGroup(_ pgid: pid_t) -> Bool {
    pgid > 1 && pgid != getpgid(0)
}

/// SIGKILLs process group `pgid`, a group the test made: a child the runner launched leads its
/// own, as does a `Process` the test started, and a fixture's `set -m` job. Refuses what
/// `isKillableOwnGroup` refuses. True when the signal was delivered.
@discardableResult
func killOwnGroup(_ pgid: pid_t) -> Bool {
    guard isKillableOwnGroup(pgid) else { return false }
    return kill(-pgid, SIGKILL) == 0
}

/// The cleanup on a failure path: SIGKILLs the group of every process `ownProcesses` finds for
/// `marker` — a fixture's `sleep` and whatever shares its group — and returns the groups it
/// killed. The group is read from a process that matched, so it is a live group and the test's
/// own, never one the number may name after a reap. A matched process in this process's own
/// group (which `killOwnGroup` refuses) is killed by its own pid.
@discardableResult
func killOwnGroups(matching marker: String) throws -> Set<pid_t> {
    var killed: Set<pid_t> = []
    for pid in try ownProcesses(matching: marker) {
        let group = getpgid(pid)
        if killOwnGroup(group) {
            killed.insert(group)
        } else if group != -1 {
            kill(pid, SIGKILL)
        }
    }
    return killed
}

/// The failure-path cleanup every suite shares: SIGKILLs, by group, every process of the
/// test's own that carries one of `markers` (`killOwnGroups`), and returns the groups it
/// killed. A query that fails is recorded, never swallowed — a cleanup that could not look
/// leaves a fixture running past the test, and the run should say so.
@discardableResult
func killLeftovers(
    _ markers: [String], sourceLocation: SourceLocation = #_sourceLocation
) -> Set<pid_t> {
    var killed: Set<pid_t> = []
    for marker in markers {
        do {
            killed.formUnion(try killOwnGroups(matching: marker))
        } catch {
            Issue.record("could not look for the leftovers under \(marker): \(error)", sourceLocation: sourceLocation)
        }
    }
    return killed
}

/// Whether every process of ours under `marker` is gone, polled for up to two seconds: a
/// killed fixture's `sleep` is reaped by launchd after its parent shell died, which is prompt
/// rather than instant.
func waitForNoOwnProcess(matching marker: String) async throws -> Bool {
    for _ in 0..<200 {
        if try ownProcesses(matching: marker).isEmpty { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// The controls for the helpers above, which every leak check and cleanup now goes through
/// (E1 RF4: a process that is not the test's own must never be counted or killed).
@Suite struct OwnProcessTests {
    /// `/bin/sh -c "true; sleep 660" <marker>`, started directly: Foundation puts it in a group
    /// of its own. The `true;` keeps the shell, and the marker on its command line, from being
    /// replaced by the `sleep`; the `sleep` carries no marker and is reached through the group.
    private static func startMarked(_ marker: String) throws -> (pid: pid_t, group: pid_t) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", "true; sleep 660", marker]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        return (process.processIdentifier, getpgid(process.processIdentifier))
    }

    private static func groupIsGone(_ group: pid_t) async -> Bool {
        for _ in 0..<200 {
            errno = 0
            if kill(-group, 0) == -1, errno == ESRCH { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }

    /// **The decoy proof.** A second process of the very same shape, under another marker —
    /// another test's, or another run's — is not counted by this test's leak check and survives
    /// this test's cleanup. It is then killed by its own pid.
    @Test(.timeLimit(.minutes(10))) func aDecoyUnderAnotherMarkerIsNeitherCountedNorKilled() async throws {
        let marker = "gitter-own-\(UUID().uuidString)"
        let decoyMarker = "gitter-decoy-\(UUID().uuidString)"
        // Each is killed by its group on any way out — a `try` that throws included — but only
        // while that group is surely still the test's: a defer that ran after the group was
        // seen gone could reach a group someone has since made with the number.
        let ours = try Self.startMarked(marker)
        var oursLeft = true
        defer { if oursLeft { killOwnGroup(ours.group) } }
        let decoy = try Self.startMarked(decoyMarker)
        var decoyLeft = true
        defer { if decoyLeft { killOwnGroup(decoy.group) } }
        try #require(isKillableOwnGroup(ours.group) && isKillableOwnGroup(decoy.group))
        #expect(ours.group != decoy.group)

        // Baselines that can fail: each is found under its own marker, and a query loose enough
        // to span both (the command they share) finds the decoy — so it really is a candidate.
        #expect(try ownProcesses(matching: marker) == [ours.pid])
        #expect(try ownProcesses(matching: decoyMarker) == [decoy.pid])
        #expect(try ownProcesses(matching: "true; sleep 660").contains(decoy.pid))

        // The leak check does not count it, and the cleanup does not kill it.
        #expect(try !ownProcesses(matching: marker).contains(decoy.pid))
        #expect(try killOwnGroups(matching: marker) == [ours.group])
        let oursGone = await Self.groupIsGone(ours.group)
        oursLeft = !oursGone
        #expect(oursGone, "the test's own process survived its cleanup")
        #expect(try await waitForNoOwnProcess(matching: marker))
        #expect(kill(decoy.pid, 0) == 0, "the cleanup killed a process that was not the test's")
        #expect(kill(-decoy.group, 0) == 0)
        #expect(try ownProcesses(matching: decoyMarker) == [decoy.pid])

        // The decoy, by its own pid; then its `sleep`, which carries no marker, by the group
        // it made.
        #expect(kill(decoy.pid, SIGKILL) == 0)
        killOwnGroup(decoy.group)
        let decoyGone = await Self.groupIsGone(decoy.group)
        decoyLeft = !decoyGone
        #expect(decoyGone)
    }

    /// Control: a leak check finds a process that really is running under its marker, so the
    /// "nothing is left" it is used for can fail.
    @Test(.timeLimit(.minutes(10))) func aLeakCheckFailsOnAProcessThatIsStillRunning() async throws {
        let marker = "gitter-leak-\(UUID().uuidString)"
        let leaked = try Self.startMarked(marker)
        // As in the decoy proof: killed on any way out while its group is surely the test's.
        var leakedLeft = true
        defer { if leakedLeft { killOwnGroup(leaked.group) } }
        let found = try ownProcesses(matching: marker)
        withKnownIssue("the marked process really is running") {
            #expect(found.isEmpty, "left running: \(found)")
        }
        #expect(killOwnGroup(leaked.group))
        let gone = await Self.groupIsGone(leaked.group)
        leakedLeft = !gone
        #expect(gone)
    }

    /// Control: the refusals that make `killOwnGroup` safe to call on a failure path. Asked of
    /// the predicate it applies, never of `kill` itself — a refusal that failed would signal
    /// every process the user owns, or the test runner's own group.
    @Test func killOwnGroupRefusesEveryGroupThatIsNotATestsOwn() {
        #expect(!isKillableOwnGroup(-1))
        #expect(!isKillableOwnGroup(0))
        #expect(!isKillableOwnGroup(1))
        #expect(!isKillableOwnGroup(getpgid(0)))
        #expect(isKillableOwnGroup(getpgid(0) + 1))
    }

    /// An empty marker would match every process the user has; it is refused, not asked.
    @Test func anEmptyMarkerIsRefused() {
        #expect(throws: OwnProcessQueryFailed.self) { try ownProcesses(matching: "") }
    }

    /// Control: the shared cleanup records a query that failed — here the refused empty
    /// marker — rather than returning as if nothing were left.
    @Test func aCleanupWhoseQueryFailsIsRecorded() {
        withKnownIssue("the query for an empty marker is refused") {
            #expect(killLeftovers([""]).isEmpty)
        } matching: { $0.comments.contains { $0.rawValue.contains("could not look for the leftovers") } }
    }
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
        let data = try await isolatedRunner().run(
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

/// Asserts that the only ref the server gained, lost or moved since `state` is `ref`.
///
/// What "a push publishes the branch and nothing else" is actually made of. `push.followTags`
/// and friends can add refs to a push Gitter never named — a tag, most of all — and those land
/// as extra refs on the server while the branch's own result line looks perfectly ordinary. So
/// the claim is made over the whole ref list rather than over the one ref the test cares about.
///
/// Two ways for it to be vacuous are closed: an **empty baseline** (`assertRemoteUnchanged`'s
/// reason — a capture that read nothing compares equal to anything) and an **empty diff**,
/// which would mean the operation under test did nothing at all and the assertion passed by
/// saying nothing.
func assertOnlyRefChanged(
    _ bareURL: URL, since state: RemoteState, isThe ref: String,
    sourceLocation: SourceLocation = #_sourceLocation
) async throws {
    guard !state.refs.isEmpty else {
        Issue.record(
            "remote baseline holds no refs, so comparing against it would prove nothing",
            sourceLocation: sourceLocation)
        return
    }
    let now = try await RemoteState.capture(bareURL)
    let lines: (String) -> Set<String> = { Set($0.split(separator: "\n").map(String.init)) }
    let changed = lines(state.refs).symmetricDifference(lines(now.refs))
    #expect(!changed.isEmpty, "nothing on the server changed, so this proves nothing",
            sourceLocation: sourceLocation)
    // Each captured line is `<refname>\0<objectname>`; a ref name cannot contain a NUL.
    let names = Set(changed.compactMap {
        $0.split(separator: "\u{0}", maxSplits: 1).first.map(String.init)
    })
    #expect(names == [ref], "the server's refs changed beyond \(ref): \(names.sorted())",
            sourceLocation: sourceLocation)
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
