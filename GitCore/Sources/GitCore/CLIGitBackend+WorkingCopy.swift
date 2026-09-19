import Foundation

/// File-level stage/unstage operations. See `GitWorkingCopyBackend` for the command each
/// method runs.
extension CLIGitBackend: GitWorkingCopyBackend {
    public func stage(paths: [String], at root: URL) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["add", "--"] + paths, cwd: root)
    }

    public func unstage(paths: [String], at root: URL) async throws {
        guard !paths.isEmpty else { return }
        if try await hasCommits(at: root) {
            _ = try await run(["restore", "--staged", "--"] + paths, cwd: root)
        } else {
            _ = try await run(["rm", "--cached", "-q", "--"] + paths, cwd: root)
        }
    }

    public func stageAll(at root: URL) async throws {
        _ = try await run(["add", "-A"], cwd: root)
    }

    public func unstageAll(at root: URL) async throws {
        if try await hasCommits(at: root) {
            _ = try await run(["reset", "-q"], cwd: root)
            return
        }

        do {
            _ = try await run(["rm", "--cached", "-r", "-q", "--", "."], cwd: root)
        } catch let GitError.commandFailed(_, stderr) where stderr.contains("did not match any files") {
            // Nothing is staged yet in a repository with no commits: there is nothing to
            // unstage, so treat this the same as `git reset -q` on an empty index — a no-op.
        }
    }

    /// Whether `root` has at least one commit reachable from HEAD.
    ///
    /// `rev-parse --verify -q HEAD` exits 1 with empty stdout when there are none; exit 0
    /// with the resolved sha on stdout otherwise.
    private func hasCommits(at root: URL) async throws -> Bool {
        let data = try await run(["rev-parse", "--verify", "-q", "HEAD"], cwd: root, allowedExitCodes: [1])
        return !data.isEmpty
    }
}
