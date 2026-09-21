import Foundation

/// Branch operations. See `GitBranchBackend` for the command each method runs and for the
/// two rules that shape all of them: no force flag, and names are never pathspecs.
///
/// `--end-of-options` (supported by `branch` and `switch` on git 2.54, verified; *not* by
/// `check-ref-format`, which rejects it outright) marks the end of flags, so a ref named
/// `--force` is read as a ref. It is deliberately not placed between `switch -c` and the new
/// branch name: verified on git 2.54, `git switch -c --end-of-options X Y` takes
/// `--end-of-options` itself as the branch name. Names therefore get the leading-`-` check
/// instead, which is what protects that position.
extension CLIGitBackend: GitBranchBackend {
    public func validateBranchName(_ name: String, at root: URL) async throws -> Bool {
        guard isPlausibleName(name), !meansSomethingElse(name) else { return false }
        do {
            _ = try await run(["check-ref-format", "--branch", name], cwd: root)
            return true
        } catch GitError.commandFailed(exitCode: 128, stderr: _) {
            return false
        }
    }

    public func createBranch(
        _ name: String, startPoint: String?, switchTo: Bool, at root: URL
    ) async throws {
        try requireName(name)
        if let startPoint { try requireRevision(startPoint) }

        var arguments: [String]
        if switchTo {
            arguments = ["switch", "-c", name]
            if let startPoint { arguments += ["--end-of-options", startPoint] }
        } else {
            arguments = ["branch", "--end-of-options", name]
            if let startPoint { arguments.append(startPoint) }
        }
        try await runBranchCommand(arguments, at: root)
    }

    public func switchTo(branch: String, at root: URL) async throws {
        try requireName(branch)
        try await runBranchCommand(["switch", "--no-guess", "--end-of-options", branch], at: root)
    }

    public func checkoutDetached(_ revision: String, at root: URL) async throws {
        try requireRevision(revision)
        try await runBranchCommand(["switch", "--detach", "--end-of-options", revision], at: root)
    }

    public func trackRemoteBranch(_ remoteBranch: String, at root: URL) async throws {
        try requireRevision(remoteBranch)
        // The remote is the first path component and the local name is all the rest, so
        // `origin/feat/x` becomes `feat/x`. Splitting on the *last* slash instead would make
        // it `x` and quietly put the branch somewhere the user did not ask for.
        let parts = remoteBranch.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2 else { throw BranchOperationError.invalidName(remoteBranch) }
        let local = String(parts[1])
        guard isPlausibleName(local) else { throw BranchOperationError.invalidName(remoteBranch) }

        if try await localBranchExists(local, at: root) {
            // Deliberately a plain switch: the existing branch keeps its tip and its upstream.
            // Re-pointing it at the remote would be a silent rewrite of the user's branch.
            try await switchTo(branch: local, at: root)
            return
        }
        try await runBranchCommand(
            ["switch", "-c", local, "--track", "--end-of-options", remoteBranch], at: root)
    }

    public func renameBranch(_ old: String, to new: String, at root: URL) async throws {
        try requireName(old)
        try requireName(new)
        try await runBranchCommand(["branch", "-m", "--end-of-options", old, new], at: root)
    }

    // MARK: - Helpers

    /// The one place a failed branch command becomes a typed error.
    ///
    /// `BranchRefusalParser` returns nil for anything it does not recognise, and then git's own
    /// `GitError.commandFailed` — exit code and stderr intact — is rethrown unchanged. Nothing
    /// is ever swallowed.
    ///
    /// Not `private`: `CLIGitBackend+BranchDelete.swift` shares this and `requireName` below,
    /// since Swift's `private` only reaches extensions in the *same file*.
    func runBranchCommand(_ arguments: [String], at root: URL) async throws {
        do {
            _ = try await run(arguments, cwd: root)
        } catch let error as GitError {
            guard case .commandFailed(_, let stderr) = error,
                let refusal = BranchRefusalParser.parse(stderr: stderr)
            else { throw error }
            throw refusal
        }
    }

    /// Whether `refs/heads/<name>` exists.
    ///
    /// `--quiet` is what makes the exit code meaningful: verified on git 2.54, `show-ref
    /// --verify` without it exits *128* ("not a valid ref") for a missing ref, while with it
    /// the missing case is a silent exit 1. Any other failure (not a repository at all, say)
    /// propagates rather than being read as "no".
    private func localBranchExists(_ name: String, at root: URL) async throws -> Bool {
        do {
            _ = try await run(
                ["show-ref", "--verify", "--quiet", "--end-of-options", "refs/heads/" + name],
                cwd: root)
            return true
        } catch GitError.commandFailed(exitCode: 1, stderr: _) {
            return false
        }
    }

    /// Names and revisions are arguments, not pathspecs, so `literalPathspec` must never be
    /// applied to them — it would make git look for a ref called `:(literal)main`.
    ///
    /// What protects them instead: an empty name is meaningless, and one starting with `-`
    /// would be parsed as an option in the one position (`switch -c <name>`) where
    /// `--end-of-options` cannot be used. Everything else is left to git, whose rules for what
    /// a ref may contain are the only ones that matter.
    private func isPlausibleName(_ name: String) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !name.hasPrefix("-")
    }

    /// Names `git check-ref-format --branch` accepts but that do not mean what the user typed.
    /// All four verified on git 2.54 (see `validateBranchName`'s doc comment): `refs/heads/x`
    /// becomes `refs/heads/refs/heads/x`, `heads/y` becomes `refs/heads/heads/y`, `@{-1}`
    /// expands to another branch's name, and `@` is a branch nobody can refer to clearly.
    ///
    /// Prefix matching only, so names that merely resemble these — `refsx`, `headsy`,
    /// `my-refs/heads`, `a@b` — stay valid.
    private func meansSomethingElse(_ name: String) -> Bool {
        name.hasPrefix("refs/") || name.hasPrefix("heads/") || name.contains("@{") || name == "@"
    }

    // Not `private` — see `runBranchCommand`'s doc comment.
    func requireName(_ name: String) throws {
        guard isPlausibleName(name) else { throw BranchOperationError.invalidName(name) }
    }

    // Not `private` — see `runBranchCommand`'s doc comment: `CLIGitBackend+BranchDelete.swift`
    // checks both sides of `commitCount(in:notIn:)`'s range with it.
    func requireRevision(_ revision: String) throws {
        guard isPlausibleName(revision) else { throw BranchOperationError.invalidName(revision) }
    }
}
