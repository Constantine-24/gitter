import Foundation
import GitCoreTestSupport
import Synchronization
import Testing

@testable import GitCore

/// A sink that keeps what it is given, for the tests below.
final class RecordingLog: CommandLog {
    let entries = Mutex<[CommandLogEntry]>([])
    func record(_ entry: CommandLogEntry) { entries.withLock { $0.append(entry) } }
    var all: [CommandLogEntry] { entries.withLock { $0 } }
}

/// P1 Task 1: `CLIGitBackend` reports each git call it ran, once, to its `CommandLog` — from
/// `run`, `runStreaming` and `runWithEnvironment` — redacted and cut to size.
@Suite(.timeLimit(.minutes(10))) struct CommandLogTests {
    /// A `#!/bin/sh` fake git with `body`, written into `directory`.
    private static func fakeGit(_ body: String, in directory: URL) throws -> String {
        let script = directory.appendingPathComponent("fake-git-\(UUID().uuidString)")
        try "#!/bin/sh\n\(body)\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return script.path
    }

    private static func scratch() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-commandlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func backend(_ log: RecordingLog, git gitPath: String = "/usr/bin/git") -> CLIGitBackend {
        CLIGitBackend(gitPath: gitPath, runner: isolatedRunner(), commandLog: log)
    }

    // MARK: - Real git

    @Test func aSuccessfulRunIsOneSucceededEntry() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let log = RecordingLog()
        _ = try await backend(log).run(["rev-parse", "--git-dir"], cwd: repo.root)
        let entries = log.all
        #expect(entries.count == 1)
        #expect(entries.first?.outcome == .succeeded)
        #expect(entries.first?.arguments == ["rev-parse", "--git-dir"])
        #expect(entries.first?.directory == repo.root.path)
        #expect(entries.first?.stderr == nil)
    }

    @Test func aFailedRunIsOneExitCodeEntryWithGitsStderr() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let log = RecordingLog()
        _ = await thrownError { _ = try await backend(log).run(["rev-parse", "--verify", "nope"], cwd: repo.root) }
        let entries = log.all
        #expect(entries.count == 1)
        #expect(entries.first?.outcome == .exitCode(128))
        #expect(entries.first?.stderr?.contains("fatal") == true)
    }

    @Test func aStreamingCallIsItsExitCode() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let log = RecordingLog()
        _ = try await backend(log).runStreaming(["status"], cwd: repo.root, progress: { _ in })
        #expect(log.all.count == 1)
        #expect(log.all.first?.outcome == .exitCode(0))
        #expect(log.all.first?.stderr == nil)
    }

    @Test func anAllowedExitCodeIsLoggedAsTheCodeGitReturned() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a.txt", "one\n")
        try repo.write("b.txt", "two\n")
        let log = RecordingLog()
        let a = repo.root.appendingPathComponent("a.txt").path
        let b = repo.root.appendingPathComponent("b.txt").path
        _ = try await backend(log).runWithEnvironment(
            ["diff", "--quiet", "--no-index", a, b], cwd: repo.root, extra: [:], allowedExitCodes: [1])
        #expect(log.all.count == 1)
        #expect(log.all.first?.outcome == .exitCode(1))
    }

    // MARK: - Fake git

    @Test func aGitKilledBySignalIsKilled() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RecordingLog()
        let git = try Self.fakeGit("kill -KILL $$", in: directory)
        // Through the two streaming seams: `ProcessRunner.run` does not tell a signal from an exit
        // code (it throws `commandFailed(9, …)`), so `run` cannot report `.killed` (docs/BACKLOG.md).
        let backend = self.backend(log, git: git)
        _ = await thrownError { _ = try await backend.runStreaming(["status"], cwd: directory, progress: { _ in }) }
        _ = await thrownError { _ = try await backend.runWithEnvironment(["status"], cwd: directory, extra: [:]) }
        #expect(log.all.count == 2)
        #expect(log.all.map(\.outcome) == [.killed, .killed])
    }

    /// The pin for the BACKLOG entry "The diagnostics log cannot tell a git killed by a signal ...":
    /// `ProcessRunner.run` throws `commandFailed(9)` for a killed git, so through `run` the entry is
    /// an exit code, not `.killed`. When the runner is fixed this fails; change it to `.killed`
    /// (as the streaming seams' test above) and close the entry. A plain expectation rather than
    /// `withKnownIssue`, so the test states what happens today and fails on the fix, naming the entry.
    @Test func aKilledGitThroughRunIsAnExitCodeForNow() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RecordingLog()
        let git = try Self.fakeGit("kill -KILL $$", in: directory)
        _ = await thrownError { _ = try await backend(log, git: git).run(["status"], cwd: directory) }
        #expect(log.all.map(\.outcome) == [.exitCode(9)], "if this is .killed, ProcessRunner.run was fixed: close the BACKLOG entry")
    }

    @Test func aCredentialInAnOutcomesPayloadIsRedacted() {
        let url = "https://u:secret@h.invalid/x"
        for outcome in [CommandLogEntry.Outcome.launchFailed("cannot run \(url)"), .refusedBeforeLaunch("refused \(url)")] {
            #expect(!String(describing: entry(outcome: outcome)).contains("secret"))
        }
    }

    @Test func aCredentialAmongTheShownOfACutListIsRedacted() {
        var arguments = (0..<45).map { "a\($0)" }
        arguments[3] = "https://u:secret@h.invalid/x"
        let cut = entry(arguments: arguments).arguments
        #expect(cut.count == 21)
        #expect(!cut.joined().contains("secret"))
    }

    @Test func aGitThatCannotBeLaunchedIsLaunchFailed() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let log = RecordingLog()
        let missing = directory.appendingPathComponent("no-such-git").path
        _ = await thrownError { _ = try await backend(log, git: missing).run(["status"], cwd: directory) }
        #expect(log.all.count == 1)
        guard case .launchFailed? = log.all.first?.outcome else {
            Issue.record("expected launchFailed, got \(String(describing: log.all.first?.outcome))")
            return
        }
    }

    @Test func aCallOverTheArgumentLimitIsRefusedBeforeLaunchAndNothingLaunches() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("launched")
        let git = try Self.fakeGit("touch '\(marker.path)'", in: directory)
        let log = RecordingLog()
        let arguments = (0..<5_000).map { "arg\($0)" }
        _ = await thrownError { _ = try await backend(log, git: git).run(arguments, cwd: directory) }
        #expect(log.all.count == 1)
        guard case .refusedBeforeLaunch? = log.all.first?.outcome else {
            Issue.record("expected refusedBeforeLaunch, got \(String(describing: log.all.first?.outcome))")
            return
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func aCancelledCallIsCancelled() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let marker = directory.appendingPathComponent("started")
        let sleep = "sleep 48.\(Int.random(in: 100_000...999_999))"
        let git = try Self.fakeGit("touch '\(marker.path)'\nexec \(sleep)", in: directory)
        let log = RecordingLog()
        let backend = self.backend(log, git: git)
        let call = CallUnderTest {
            await thrownError { _ = try await backend.runStreaming(["status"], cwd: directory, progress: { _ in }) }
        }
        // No bound of our own: a fake git that never starts is ended by the suite's time limit,
        // which cancels this sleep.
        do {
            while !FileManager.default.fileExists(atPath: marker.path) {
                try await Task.sleep(for: .milliseconds(10))
            }
        } catch {
            call.cancel()
            killLeftovers([sleep])
            throw error
        }
        call.cancel()
        guard await call.value("the cancelled call") != nil else {
            killLeftovers([sleep])
            return
        }
        #expect(log.all.count == 1)
        #expect(log.all.first?.outcome == .cancelled)
        #expect(try await waitForNoOwnProcess(matching: sleep))
        killLeftovers([sleep])
    }

    // MARK: - Redaction

    // MARK: - A URL's userinfo, by structure (P1 Task 2 fix round 1, I1, Ruling 6)

    /// The prose redactor ends a run of address at `'"<>`()]` and a blank, so a password holding one
    /// of them came back whole (measured in Task 2's review). An argument is one token: a URL's
    /// userinfo goes by its structure, whatever it holds — a username alone too, as a token is often
    /// the whole of it.
    @Test(arguments: [
        ("https://me:p'ss@example.invalid/x.git", "p'ss"),
        ("https://me:p(ss)@example.invalid/x.git", "p(ss)"),
        ("https://me:p)ss@example.invalid/x.git", "p)ss"),
        ("https://me:p(@ss@example.invalid/x.git", "p(@ss"),
        ("https://me:p:(ss@example.invalid/x.git", "p:(ss"),
        ("https://me:p%28ss%29@example.invalid/x.git", "p%28ss%29"),
        ("https://me:p ss)@example.invalid/x.git", "p ss)"),
        ("https://ghp_only'token@example.invalid/x.git", "ghp_only'token"),
        ("https://ghp_onlytoken@example.invalid/x.git", "ghp_onlytoken"),
        ("ssh://me:p(ss)@[::1]:22/x.git", "p(ss)"),
        ("--url=https://me:p(ss)@example.invalid/x.git", "p(ss)"),
        ("--push-option=https://me:p(ss)@example.invalid/x", "p(ss)"),
        ("remote.origin.url=me:p(ss)@example.invalid:x.git", "p(ss)"),
        ("https://me:p(ss)@[::1]:8443/x.git", "p(ss)"),
    ])
    func aURLsUserinfoIsStrippedWhateverItHolds(url: String, secret: String) {
        let arguments = entry(arguments: ["remote", "add", "--end-of-options", "origin", url]).arguments
        #expect(!arguments.joined(separator: " ").contains(secret), "\(arguments)")
        #expect(!arguments.joined(separator: " ").contains("me:"), "\(arguments)")
        #expect(arguments.last?.contains("example.invalid") == true || arguments.last?.contains("[::1]") == true)
    }

    @Test func theStrippedURLKeepsItsSchemeHostAndPath() {
        #expect(CommandLogEntry.strippingUserinfo("https://me:p(ss)@example.invalid/x.git") == "https://example.invalid/x.git")
        #expect(CommandLogEntry.strippingUserinfo("https://tok@example.invalid:8443/x?y=1") == "https://example.invalid:8443/x?y=1")
        #expect(CommandLogEntry.strippingUserinfo("--url=https://me:p@example.invalid/x") == "--url=https://example.invalid/x")
        #expect(CommandLogEntry.strippingUserinfo("--push-option=https://me:p@example.invalid/x") == "--push-option=https://example.invalid/x")
        #expect(CommandLogEntry.strippingUserinfo("remote.o.url=me:p(ss)@example.invalid:x") == "remote.o.url=example.invalid:x")
        #expect(CommandLogEntry.strippingUserinfo("--url=me:p@example.invalid:x") == "--url=example.invalid:x")
        // A `=` inside a password is not a value's start: the first `:` comes before it.
        #expect(CommandLogEntry.strippingUserinfo("https://me:p=ss@example.invalid/x") == "https://example.invalid/x")
        #expect(CommandLogEntry.strippingUserinfo("me:p=ss@example.invalid:x") == "example.invalid:x")
        // IPv6 hosts keep their brackets.
        #expect(CommandLogEntry.strippingUserinfo("https://me:p@[::1]:8443/x") == "https://[::1]:8443/x")
        #expect(CommandLogEntry.strippingUserinfo("ssh://me:p(ss)@[fe80::1%25en0]/x") == "ssh://[fe80::1%25en0]/x")
        // scp-style, only where userinfo is there.
        #expect(CommandLogEntry.strippingUserinfo("me:p(ss)@example.invalid:x.git") == "example.invalid:x.git")
        #expect(CommandLogEntry.strippingUserinfo("git@example.invalid:team@2024/x.git") == "example.invalid:team@2024/x.git")
        #expect(CommandLogEntry.strippingUserinfo("example.invalid:x.git") == "example.invalid:x.git")
    }

    /// What is not a URL with userinfo is kept as it is: a path, a refspec, a revision, an `@` in a
    /// path, a reflog selector.
    @Test(arguments: [
        "/tmp/gitter-test/a:b@origin.git", "./a:b@c", "~/a:b@c", "refs/heads/main:refs/heads/main",
        "HEAD:refs/heads/x", "stash@{0}:a.txt", "main@{upstream}", "https://example.invalid/team@2024/x.git",
        "file:///tmp/x@y.git", "--message", "Discarded by Gitter: a@b.c", "user@example.invalid",
        "HEAD@{1}", "HEAD@{1}:a.txt", "--format=%H@%s", "--push-option=ci.skip", "refs/stash@{0}",
        "--git-dir=/tmp/a:b@c/.git", "https://[::1]:8443/team@2024/x",
    ])
    func whatIsNoURLWithUserinfoIsKept(argument: String) {
        #expect(CommandLogEntry.strippingUserinfo(argument) == argument)
    }

    /// The control: the prose redactor alone — the only one before this fix — hands the password
    /// with a parenthesis back.
    @Test func theProseRedactorAloneLeaksAPasswordWithAParenthesis() {
        withKnownIssue("the prose redactor ends its run at `(`, so the userinfo is never seen") {
            #expect(!RemoteFailureParser.redactingCredentials("https://me:p(ss)@example.invalid/x.git").contains("p(ss)"))
        }
    }

    @Test func aCredentialInTheArgumentsIsInNoField() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = try Self.fakeGit("exit 0", in: directory)
        let log = RecordingLog()
        _ = try await backend(log, git: git).run(
            ["remote", "add", "o", "https://u:secret@example.invalid/r.git"], cwd: directory)
        let entry = try #require(log.all.first)
        #expect(!String(describing: entry).contains("secret"))
        #expect(entry.arguments.count == 4)
    }

    @Test func aCredentialInStderrIsRedacted() async throws {
        let directory = try Self.scratch()
        defer { try? FileManager.default.removeItem(at: directory) }
        let git = try Self.fakeGit("echo 'fatal: https://u:secret@h.invalid/x' >&2\nexit 1", in: directory)
        let log = RecordingLog()
        _ = await thrownError { _ = try await backend(log, git: git).run(["fetch"], cwd: directory) }
        let entry = try #require(log.all.first)
        #expect(entry.outcome == .exitCode(1))
        let stderr = try #require(entry.stderr)
        #expect(stderr.contains("fatal"))
        #expect(!stderr.contains("secret"))
    }

    // MARK: - Cuts

    private func entry(arguments: [String] = [], outcome: CommandLogEntry.Outcome = .exitCode(1),
                       stderr: String = "") -> CommandLogEntry {
        CommandLogEntry(started: Date(), duration: .zero, directory: URL(fileURLWithPath: "/tmp"),
                        rawArguments: arguments, outcome: outcome, rawStderr: stderr)
    }

    @Test func moreThanFortyArgumentsAreCutToTheFirstTwentyAndACount() {
        let arguments = (0..<45).map { "a\($0)" }
        let cut = entry(arguments: arguments).arguments
        #expect(cut.count == 21)
        #expect(Array(cut.prefix(20)) == Array(arguments.prefix(20)))
        #expect(cut.last == "… and 25 more")
    }

    @Test func fortyArgumentsAreKeptWhole() {
        let arguments = (0..<40).map { "a\($0)" }
        #expect(entry(arguments: arguments).arguments == arguments)
    }

    @Test func stderrIsCutOnACharacterBoundaryWithAnEllipsis() throws {
        let stderr = try #require(entry(stderr: String(repeating: "é", count: 1_500)).stderr)
        #expect(stderr.hasSuffix("…"))
        let body = stderr.dropLast()
        #expect(body.utf8.count <= CommandLogEntry.stderrLimit)
        #expect(body.allSatisfy { $0 == "é" })
        #expect(String(validating: Array(stderr.utf8), as: UTF8.self) == stderr)
    }

    @Test func stderrWithinTheLimitIsKeptAndEmptyIsNil() {
        #expect(entry(stderr: "fatal: x").stderr == "fatal: x")
        #expect(entry(stderr: "").stderr == nil)
    }

    @Test func stderrIsKeptOnlyForAFailure() {
        #expect(entry(outcome: .succeeded, stderr: "warning").stderr == nil)
        #expect(entry(outcome: .exitCode(0), stderr: "warning").stderr == nil)
        #expect(entry(outcome: .exitCode(1), stderr: "warning").stderr == "warning")
    }

    // MARK: - Raw kept

    @Test func anArgumentWithANewlineStaysAsItIs() {
        #expect(entry(arguments: ["commit", "-m", "a\nb"]).arguments == ["commit", "-m", "a\nb"])
    }

    // MARK: - Control

    @Test func aBackendWithoutALogRecordsNothingAnywhere() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let log = RecordingLog()
        _ = try await CLIGitBackend(runner: isolatedRunner()).run(["rev-parse", "--git-dir"], cwd: repo.root)
        #expect(log.all.isEmpty)
        withKnownIssue("the control: a log that was not passed in has no entry") {
            #expect(log.all.count == 1)
        }
    }
}
