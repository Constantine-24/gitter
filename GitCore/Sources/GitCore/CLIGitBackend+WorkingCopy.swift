import Foundation

/// File-level stage/unstage operations. See `GitWorkingCopyBackend` for the command each
/// method runs.
extension CLIGitBackend: GitWorkingCopyBackend {
    public func stage(paths: [String], at root: URL) async throws {
        guard !paths.isEmpty else { return }
        _ = try await run(["add", "--"] + paths.map(literalPathspec), cwd: root)
    }

    public func unstage(paths: [String], at root: URL) async throws {
        guard !paths.isEmpty else { return }
        if try await hasCommits(at: root) {
            // `--no-recurse-submodules` changes nothing here (`--staged` never touches the
            // worktree; measured with `submodule.recurse=true`: the submodule's checkout and
            // an untracked file inside it were kept), and the scanner requires it of every
            // `restore` vector, because on `--worktree` it is what keeps a submodule's work.
            _ = try await run(
                ["restore", "--no-recurse-submodules", "--staged", "--"] + paths.map(literalPathspec),
                cwd: root)
        } else {
            // `--ignore-unmatch`: without commits, a caller may pass a mix of paths that are
            // and aren't in the index (e.g. after another change already removed one). Without
            // this flag `git rm` fails outright on the first unmatched path and leaves every
            // path — matched or not — still staged. `unstageAll`'s `rm --cached -r -- .` fallback
            // doesn't need it: `.` either matches something or the empty-index case is handled
            // separately below.
            _ = try await run(
                ["rm", "--cached", "-q", "--ignore-unmatch", "--"] + paths.map(literalPathspec),
                cwd: root)
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
            // The `.` is a real pathspec — "everything below the repository root" — not a file
            // name, so it deliberately stays unprefixed: `:(literal).` would mean a file
            // called `.` instead.
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

        // Never with `--unidiff-zero`, even for a hunk with no context line (the only kind
        // `patch.hasContextFreeHunk` marks). Without it git anchors such a hunk to the start
        // and end of the file, so it applies only to an index that is exactly its preimage;
        // with it, an index that changed after the diff was loaded took the hunk at an offset
        // and gained lines the user never selected (measured in A1 Task 3, Step 5, and pinned
        // by `PartialStagingStaleTests`). Refused, the caller shows "the file changed".
        var arguments = ["apply", "--cached", "--whitespace=nowarn"]
        if reverse { arguments.append("--reverse") }
        // No `--` before the file: it is the patch `git apply` reads, not a pathspec, and
        // `--` would make git treat the rest as paths to restrict the patch to.
        arguments.append(file.path)
        _ = try await run(arguments, cwd: root)
    }

    public func commit(message: String, amend: Bool, allTracked: Bool, at root: URL) async throws -> String {
        guard !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw GitError.emptyCommitMessage
        }

        // Amending while an operation is in progress rewrites the commit that operation is
        // standing on, and git only refuses two of the six (see the protocol's table). The
        // other four leave the previous tip on no ref at all — the one thing this milestone
        // promises never to happen without a confirmation naming it. Asked of git here, at the
        // moment of the write, rather than taken from a caller's snapshot: a terminal can start
        // a merge between a refresh and this call, and a guard fed stale state is not a guard.
        // If the question cannot be answered the error propagates and nothing is committed.
        if amend, let operation = try await operationInProgress(at: root) {
            throw GitError.amendDuringOperation(operation)
        }

        // Outside the repository on purpose, same as `applyToIndex`'s patch file: a message
        // file inside the worktree would itself show up as an untracked change while it exists.
        let file = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-commit-message-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: file) }
        try message.write(to: file, atomically: true, encoding: .utf8)

        var arguments = ["commit", "-q"]
        if allTracked { arguments.append("-a") }
        if amend { arguments.append("--amend") }
        arguments += ["-F", file.path]
        _ = try await run(arguments, cwd: root)

        let sha = try await run(["rev-parse", "HEAD"], cwd: root)
        return String(decoding: sha, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public func headMessage(at root: URL) async throws -> String {
        guard try await hasCommits(at: root) else { return "" }
        let data = try await run(["log", "-1", "--format=%B"], cwd: root)
        return trimmingTrailingWhitespaceAndNewlines(String(decoding: data, as: UTF8.self))
    }

    /// Trims only trailing whitespace and newline characters, leaving the rest of `string`
    /// (including any leading whitespace) untouched.
    private func trimmingTrailingWhitespaceAndNewlines(_ string: String) -> String {
        var result = Substring(string)
        while let last = result.last, last.isWhitespace {
            result.removeLast()
        }
        return String(result)
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
