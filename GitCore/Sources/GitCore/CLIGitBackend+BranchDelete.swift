import Foundation

/// `deleteBranch`, `forceDeleteBranch` and the three `rev-list --count` readers the
/// confirmations are built on
/// (`commitsOnlyOn`, `commitCount(in:notIn:)`, `unreferencedCommits`). Split out of
/// `CLIGitBackend+Branches.swift` for length, not for any difference in the rules it follows —
/// see that file's header comment (no force flag outside `branch -D`, names are never
/// pathspecs) and `GitBranchBackend`'s doc comments on each method for exactly what each
/// command does and why.
extension CLIGitBackend {
    public func deleteBranch(_ name: String, at root: URL) async throws -> BranchDeletion {
        try requireName(name)
        if try await currentBranchName(at: root) == name {
            throw BranchOperationError.cannotDeleteCurrent(name)
        }

        do {
            try await runBranchCommand(["branch", "-d", "--end-of-options", name], at: root)
            return .deleted
        } catch GitError.commandFailed(_, let stderr) where stderr.contains("is not fully merged") {
            // `-d` refused and changed nothing — the branch is exactly where it was, so reading
            // its tip and unique-commit count now is still "before any deletion".
            let tip = try await tipSHA(of: name, at: root)
            let uniqueCommits = try await commitsOnlyOn(branch: name, at: root)
            return .notFullyMerged(uniqueCommits: uniqueCommits, tip: tip)
        }
    }

    public func forceDeleteBranch(_ name: String, expectedTip: String, at root: URL) async throws {
        try requireName(name)
        // Before the tip is read: the current branch is refused whatever it points at, and
        // "the branch moved" would be the wrong thing to tell the user about it.
        if try await currentBranchName(at: root) == name {
            throw BranchOperationError.cannotDeleteCurrent(name)
        }

        // The whole safety of this method. `refs/heads/<name>` is live, and the warning the user
        // is answering was drawn from a read that has already happened; see
        // `GitBranchBackend.forceDeleteBranch` for why this is a verify-then-delete rather than
        // `update-ref -d <ref> <oldvalue>`, and for how wide the remaining window is.
        let actual: String
        do {
            actual = try await tipSHA(of: name, at: root)
        } catch GitError.commandFailed(exitCode: 128, stderr: _) {
            // `rev-parse --verify` on a ref that is not there: exit 128, "fatal: Needed a single
            // revision" (verified on git 2.54). Nothing else about this call can fail that way,
            // and `branch -D` would have said "branch '<name>' not found" for the same state.
            throw BranchOperationError.noSuchBranch(name)
        }
        guard actual == expectedTip else {
            throw BranchOperationError.branchMoved(
                name: name, expected: expectedTip, actual: actual)
        }

        try await runBranchCommand(["branch", "-D", "--end-of-options", name], at: root)
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
        return try await revListCount(
            ["rev-list", "--count", ref, "--not", "--exclude=" + ref, "--all"], at: root)
    }

    public func commitCount(in branch: String, notIn base: String, at root: URL) async throws -> Int {
        try requireRevision(branch)
        try requireRevision(base)
        // `--end-of-options` *is* usable here, unlike in the two counts around it: the range is
        // the last argument, so stopping option parsing costs nothing (verified on git 2.54 —
        // accepted, and not echoed the way `rev-parse` echoes it without `--verify`).
        //
        // The trailing `--` says "no pathspecs follow", which is what keeps a revision git
        // cannot resolve from being tried as a file name: with it the failure is a clean
        // "fatal: bad revision 'HEAD..nope'", without it the longer "ambiguous argument …
        // unknown revision or path not in the working tree". Both exit 128 and both throw; the
        // first is the honest description of what went wrong.
        return try await revListCount(
            ["rev-list", "--count", "--end-of-options", base + ".." + branch, "--"], at: root)
    }

    public func unreferencedCommits(at root: URL) async throws -> UnreferencedCommits {
        // An unborn HEAD is `--quiet`'s exit 1 with no output (verified on git 2.54), which is
        // the one failure that is not a failure: no commits exist, so nothing can be stranded.
        // Every other way this can go wrong — "not a git repository" is exit 128, with words —
        // propagates, because this pair is the only input to the confirmation standing between
        // the user and losing commits and a question that could not be asked must fail **closed**
        // rather than answer 0 and skip the confirmation silently.
        let data = try await run(
            ["rev-parse", "--verify", "--quiet", "--end-of-options", "HEAD"], cwd: root,
            allowedExitCodes: [1])
        let sha = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !sha.isEmpty else { return UnreferencedCommits(headSha: nil, count: 0) }

        // Counted from the sha, not from `HEAD` a second time: the two commands are a process
        // spawn apart, and a HEAD that moved in between would pair this count with a commit it
        // is not about. The sha is git's own 40-character output, so it cannot be read as an
        // option however the repository got into this state.
        //
        // `--branches --tags --remotes` rather than `--all`: `--all` pretends HEAD is listed
        // too (verified on git 2.54 — see `commitsOnlyOn`'s doc comment), which would make this
        // answer 0 in exactly the situation it exists to detect. No `--end-of-options` for the
        // same reason as `commitsOnlyOn`: it would stop option parsing for the rest of the argv
        // and turn `--not`/`--branches` into revisions.
        let count = try await revListCount(
            ["rev-list", "--count", sha, "--not", "--branches", "--tags", "--remotes"], at: root)
        return UnreferencedCommits(headSha: sha, count: count)
    }

    // MARK: - Helpers

    /// Runs a `rev-list --count …` and returns the number it printed.
    ///
    /// Output that is not a number is never rounded down to 0: every one of these counts feeds
    /// a confirmation or a warning, so an answer that cannot be read has to be an error the
    /// caller sees, not a reassuring zero.
    ///
    /// Internal rather than private because `CLIGitBackend+Remotes.swift`'s
    /// `commitsOnlyOnRemoteBranch` is the fourth count of this kind and reads its answer under
    /// the same rule. A second copy would be a second place for "unreadable means zero" to
    /// creep back in.
    func revListCount(_ arguments: [String], at root: URL) async throws -> Int {
        let data = try await run(arguments, cwd: root)
        let text = String(decoding: data, as: UTF8.self)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let count = Int(text) else {
            throw GitError.commandFailed(
                exitCode: -1, stderr: "unexpected rev-list --count output: \(text)")
        }
        return count
    }

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
