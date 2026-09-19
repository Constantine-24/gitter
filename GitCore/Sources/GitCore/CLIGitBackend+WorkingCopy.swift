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
            // `--ignore-unmatch`: without commits, a caller may pass a mix of paths that are
            // and aren't in the index (e.g. after another change already removed one). Without
            // this flag `git rm` fails outright on the first unmatched path and leaves every
            // path — matched or not — still staged. `unstageAll`'s `rm --cached -r -- .` fallback
            // doesn't need it: `.` either matches something or the empty-index case is handled
            // separately below.
            _ = try await run(["rm", "--cached", "-q", "--ignore-unmatch", "--"] + paths, cwd: root)
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

    public func applyToIndex(patch: Patch, reverse: Bool, at root: URL) async throws {
        // Outside the repository on purpose: a patch file inside the worktree would itself
        // show up as an untracked change while it exists.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-patch-\(UUID().uuidString).diff")
        defer { try? FileManager.default.removeItem(at: file) }
        try patch.text.write(to: file, atomically: true, encoding: .utf8)

        var arguments = ["apply", "--cached", "--whitespace=nowarn"]
        if patch.needsUnidiffZero { arguments.append("--unidiff-zero") }
        if reverse { arguments.append("--reverse") }
        // No `--` before the file: it is the patch `git apply` reads, not a pathspec, and
        // `--` would make git treat the rest as paths to restrict the patch to.
        arguments.append(file.path)
        _ = try await run(arguments, cwd: root)
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
