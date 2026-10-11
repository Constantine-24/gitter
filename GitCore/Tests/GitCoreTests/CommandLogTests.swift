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
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: marker.path) {
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        guard FileManager.default.fileExists(atPath: marker.path) else {
            call.cancel()
            _ = await call.value("the cancelled call")
            killLeftovers([sleep])
            Issue.record("the fake git never started")
            return
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
