import Foundation
import GitCoreTestSupport

/// A real repository in a temporary directory of its own, for the store-flow tests (E2 Task 1).
///
/// `directory` is a fresh `mktemp`-style folder; the repository is `directory/<name>` and the bare
/// remotes `makeBareRemote` makes are its siblings, so `remove()` takes everything the test made
/// and nothing else. Every git runs under `TestGitEnvironment.isolated` (a `precondition` in
/// `init`), as `/usr/bin/git -C <url>`, with a fixed identity, no signing, no automatic gc or
/// maintenance, and no editor.
struct ScratchRepo {
    let directory: URL
    let url: URL

    init(_ name: String = "repo") throws {
        precondition(TestGitEnvironment.isolated)
        directory = FileManager.default.temporaryDirectory
            .appending(path: "gitter-scratch-\(UUID().uuidString)").standardizedFileURL
        url = directory.appending(path: name)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try git("init", "-b", "main")
        try git("config", "gc.auto", "0")
        try git("config", "maintenance.auto", "false")
        try git("config", "user.name", "Tester")
        try git("config", "user.email", "tester@example.com")
        try git("config", "commit.gpgsign", "false")
    }

    struct Failure: Error, CustomStringConvertible {
        let arguments: [String]
        let status: Int32
        let output: String
        let errors: String
        var description: String { "git \(arguments.joined(separator: " ")) exited \(status): \(errors)" }
    }

    private func run(_ arguments: [String], in directory: URL? = nil) throws -> (status: Int32, output: String, errors: String) {
        precondition(TestGitEnvironment.isolated)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", (directory ?? url).path] + arguments
        var environment = ProcessInfo.processInfo.environment
        environment["GIT_TERMINAL_PROMPT"] = "0"
        environment["LC_ALL"] = "C"
        environment["GIT_EDITOR"] = "true"
        process.environment = environment
        // Output goes to files, not pipes: nothing to drain, nothing to deadlock on.
        let out = self.directory.appending(path: ".git-out-\(UUID().uuidString)")
        let err = self.directory.appending(path: ".git-err-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil)
        FileManager.default.createFile(atPath: err.path, contents: nil)
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: err)
        }
        let outHandle = try FileHandle(forWritingTo: out)
        let errHandle = try FileHandle(forWritingTo: err)
        process.standardOutput = outHandle
        process.standardError = errHandle
        process.standardInput = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        try? outHandle.close()
        try? errHandle.close()
        return (
            process.terminationStatus,
            String(decoding: try Data(contentsOf: out), as: UTF8.self),
            String(decoding: try Data(contentsOf: err), as: UTF8.self)
        )
    }

    /// Runs `git` in the repository and returns its standard output; throws `Failure` when git
    /// exits non-zero.
    @discardableResult
    func git(_ args: String...) throws -> String {
        let result = try run(args)
        guard result.status == 0 else {
            throw Failure(arguments: args, status: result.status, output: result.output, errors: result.errors)
        }
        return result.output
    }

    /// Runs `git` and requires it to exit non-zero (a cherry-pick or rebase that stops on a
    /// conflict); throws when git succeeds.
    func gitExpectingFailure(_ args: String...) throws {
        let result = try run(args)
        guard result.status != 0 else {
            throw Failure(arguments: args, status: 0, output: result.output, errors: "expected a failure")
        }
    }

    func write(_ path: String, _ contents: String) throws {
        let file = url.appending(path: path)
        try FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.write(to: file, atomically: true, encoding: .utf8)
    }

    /// Writes `path`, stages it and commits it.
    func commit(_ path: String, _ contents: String, _ message: String) throws {
        try write(path, contents)
        try git("add", "--", path)
        try git("commit", "-m", message)
    }

    /// A bare repository beside this one, inside the same temporary directory.
    func makeBareRemote(named name: String = "origin") throws -> URL {
        let bare = directory.appending(path: "\(name).git")
        try FileManager.default.createDirectory(at: bare, withIntermediateDirectories: true)
        let result = try run(["init", "--bare", "-b", "main"], in: bare)
        guard result.status == 0 else {
            throw Failure(arguments: ["init", "--bare"], status: result.status, output: result.output, errors: result.errors)
        }
        return bare
    }

    /// Removes the temporary directory this repository and its remotes live in. Nothing else.
    func remove() {
        try? FileManager.default.removeItem(at: directory)
    }
}
