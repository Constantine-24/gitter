import Foundation
import Testing

@testable import GitCore

/// Ruling 26's guard: no call through `CLIGitBackend` can hand `Process` more arguments than
/// it takes.
@Suite struct ArgumentGuardTests {

    // MARK: - The guard

    /// A shell script standing in for `/usr/bin/git`: one line in `log` per launch, then the
    /// real git.
    private struct LoggingGit {
        let directory: URL
        var wrapper: URL { directory.appendingPathComponent("git") }
        var log: URL { directory.appendingPathComponent("log") }

        init() throws {
            directory = FileManager.default.temporaryDirectory
                .appendingPathComponent("gitter-logging-git-\(UUID().uuidString)", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let script = """
                #!/bin/sh
                printf '%s\\n' "$1" >> '\(directory.path)/log'
                exec /usr/bin/git "$@"
                """
            try script.write(to: wrapper, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: wrapper.path)
        }

        var launches: Int {
            ((try? String(contentsOf: log, encoding: .utf8)) ?? "").split(separator: "\n").count
        }

        func cleanUp() { try? FileManager.default.removeItem(at: directory) }
    }

    /// `ls-files -z --` and `count - 3` pathspecs that match nothing: `count` arguments of a
    /// read that succeeds with no output.
    private static func lsFiles(arguments count: Int) -> [String] {
        ["ls-files", "-z", "--"] + (0..<(count - 3)).map { ":(literal)absent\($0)" }
    }

    /// Under `Process`'s own limit (4096, measured), with room for every vector Gitter builds:
    /// the largest is a `--cacheinfo` batch's 2 002 arguments.
    @Test func theLimitIsUnderProcesssOwn() {
        #expect(CLIGitBackend.argumentLimit < 4_096)
        #expect(CLIGitBackend.argumentLimit >= 2 + 2 * StashRecord.cacheinfoLimit)
    }

    /// 5 000 arguments through each of the three ways `CLIGitBackend` starts git: the typed
    /// error, and no process (the wrapper logs nothing). Exactly at the limit, git runs — the
    /// guard is not refusing everything.
    @Test func aCallOverTheLimitThrowsWithoutLaunchingGit() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let git = try LoggingGit()
        defer { git.cleanUp() }
        let backend = CLIGitBackend(gitPath: git.wrapper.path)
        let tooMany = GitError.tooManyArguments(count: 5_000, limit: CLIGitBackend.argumentLimit)

        await #expect(throws: tooMany) { try await backend.run(Self.lsFiles(arguments: 5_000), cwd: repo.root) }
        await #expect(throws: tooMany) {
            try await backend.runWithEnvironment(Self.lsFiles(arguments: 5_000), cwd: repo.root, extra: [:])
        }
        await #expect(throws: tooMany) {
            try await backend.runStreaming(Self.lsFiles(arguments: 5_000), cwd: repo.root, progress: { _ in })
        }
        #expect(git.launches == 0, "git was started")

        let atLimit = Self.lsFiles(arguments: CLIGitBackend.argumentLimit)
        #expect(try await backend.run(atLimit, cwd: repo.root).isEmpty)
        #expect(try await backend.runWithEnvironment(atLimit, cwd: repo.root, extra: [:]).stdout.isEmpty)
        #expect(try await backend.runStreaming(atLimit, cwd: repo.root, progress: { _ in }).stdout.isEmpty)
        #expect(git.launches == 3)
    }
}
