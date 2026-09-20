import Foundation

/// `deleteBranch` and `commitsOnlyOn`. Split out of `CLIGitBackend+Branches.swift` for length,
/// not for any difference in the rules it follows — see that file's header comment (no force
/// flag outside `branch -D`, names are never pathspecs) and `GitBranchBackend`'s doc comments
/// on these two methods for exactly what each command does and why.
extension CLIGitBackend {
    public func deleteBranch(_ name: String, force: Bool, at root: URL) async throws -> BranchDeletion {
        try requireName(name)
        if try await currentBranchName(at: root) == name {
            throw BranchOperationError.cannotDeleteCurrent(name)
        }

        let arguments: [String]
        if force {
            arguments = ["branch", "-D", "--end-of-options", name]
        } else {
            arguments = ["branch", "-d", "--end-of-options", name]
        }

        do {
            try await runBranchCommand(arguments, at: root)
            return .deleted
        } catch GitError.commandFailed(_, let stderr) where !force && stderr.contains("is not fully merged") {
            // `-d` refused and changed nothing — the branch is exactly where it was, so reading
            // its tip and unique-commit count now is still "before any deletion".
            let tip = try await tipSHA(of: name, at: root)
            let uniqueCommits = try await commitsOnlyOn(branch: name, at: root)
            return .notFullyMerged(uniqueCommits: uniqueCommits, tip: tip)
        }
    }

    public func commitsOnlyOn(branch: String, at root: URL) async throws -> Int {
        try requireName(branch)
        // No `--end-of-options`: verified on git 2.54, it stops option parsing for the *rest*
        // of the argv, so placed anywhere here it would make `--not`, `--exclude=…` and `--all`
        // read as literal revisions instead of flags (`fatal: option '--not' must come before
        // non-option arguments`). It is not needed for safety either: the ref is always spelled
        // `refs/heads/<name>`, a string that cannot begin with `-` regardless of `name`, so it
        // can never be misread as an option.
        let ref = "refs/heads/" + branch
        let data = try await run(
            ["rev-list", "--count", ref, "--not", "--exclude=" + ref, "--all"], cwd: root)
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(text) else {
            throw GitError.commandFailed(exitCode: -1, stderr: "unexpected rev-list --count output: \(text)")
        }
        return count
    }

    public func unreferencedCommitCount(at root: URL) async throws -> Int {
        // `--branches --tags --remotes` rather than `--all`: `--all` pretends HEAD is listed
        // too (verified on git 2.54 — see `commitsOnlyOn`'s doc comment), which would make this
        // answer 0 in exactly the situation it exists to detect. No `--end-of-options` for the
        // same reason as `commitsOnlyOn`: it would stop option parsing for the rest of the argv
        // and turn `--not`/`--branches` into revisions. Nothing here is user input.
        do {
            let data = try await run(
                ["rev-list", "--count", "HEAD", "--not", "--branches", "--tags", "--remotes"],
                cwd: root)
            let text = String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard let count = Int(text) else {
                throw GitError.commandFailed(
                    exitCode: -1, stderr: "unexpected rev-list --count output: \(text)")
            }
            return count
        } catch GitError.commandFailed(exitCode: 128, let stderr)
            where stderr.contains("ambiguous argument 'HEAD'")
        {
            // An unborn HEAD, and only that: verified on git 2.54 under `LC_ALL=C` (which
            // `ProcessRunner` sets), "fatal: ambiguous argument 'HEAD': unknown revision or path
            // not in the working tree." No commits exist, so nothing can be stranded and the
            // honest answer is 0.
            //
            // Every other exit 128 is rethrown on purpose. "not a git repository" is one of
            // them, with different words. This number is the only input to the confirmation
            // standing between the user and losing commits, so a question that could not be
            // asked must fail **closed** — the caller declines to act and shows the error —
            // rather than answering 0 and skipping the confirmation silently.
            return 0
        }
    }

    // MARK: - Helpers

    /// The branch HEAD is on, or nil when HEAD is detached. `--short -q`: quiet so a detached
    /// HEAD is a silent exit 1 rather than an error, matching `TestRepo.currentBranch()`.
    private func currentBranchName(at root: URL) async throws -> String? {
        let data = try await run(
            ["symbolic-ref", "--short", "-q", "HEAD"], cwd: root, allowedExitCodes: [1])
        let name = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? nil : name
    }

    /// The full sha `refs/heads/<name>` currently points at. `--end-of-options` is harmless and
    /// included here (unlike in `commitsOnlyOn`) because nothing follows the ref in this argv.
    private func tipSHA(of name: String, at root: URL) async throws -> String {
        let data = try await run(
            ["rev-parse", "--verify", "--end-of-options", "refs/heads/" + name], cwd: root)
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
