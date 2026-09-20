import Foundation

/// `merge(_:mode:at:)`. See `GitBranchBackend.merge` for the contract; this file is about how
/// the three modes are spelled and how the outcome is worked out afterwards.
extension CLIGitBackend {
    public func merge(_ branch: String, mode: MergeMode, at root: URL) async throws -> MergeOutcome {
        try requireName(branch)
        let headBefore = try await headSHA(at: root)

        // Each vector is a COMPLETE literal chosen by this switch — no flag is ever picked with
        // a ternary inside an element, so `ForceFlagScannerTests` can read exactly what runs.
        //
        // `--ff` and `--no-ff` are on the command line deliberately: verified on git 2.54, they
        // override a repository's `merge.ff` config, so the mode the user picked in the sheet
        // wins. `.squash` carries `--ff` for the same reason and it is NOT cosmetic — a bare
        // `merge --squash` is *fatal* under `merge.ff=false` ("options '--squash' and
        // '--no-ff.' cannot be used together") and under `merge.ff=only` on a diverged branch
        // ("Not possible to fast-forward, aborting."). It changes nothing else: `--squash`
        // still never moves HEAD, fast-forwardable or not.
        //
        // `--no-edit` is belt and braces — `ProcessRunner` already sets `GIT_EDITOR=true`, so a
        // merge commit gets git's default message either way — and is left off `--squash`,
        // which implies `--no-commit` and has no message to edit.
        //
        // `--end-of-options` is accepted by `merge` in this position (verified), so a ref named
        // like a flag would still be read as a ref.
        let arguments: [String]
        switch mode {
        case .fastForwardIfPossible:
            arguments = ["merge", "--ff", "--no-edit", "--end-of-options", branch]
        case .alwaysMergeCommit:
            arguments = ["merge", "--no-ff", "--no-edit", "--end-of-options", branch]
        case .squash:
            arguments = ["merge", "--ff", "--squash", "--end-of-options", branch]
        }

        do {
            _ = try await run(arguments, cwd: root)
        } catch let error as GitError {
            // Refusal first, conflict second. Both can exit non-zero with codes that overlap
            // (a refused fast-forward and a conflicting merge both exit 1), and a merge
            // attempted while conflicts are already unresolved would otherwise be reported as
            // "this merge conflicted" when in fact it never started.
            guard case .commandFailed(_, let stderr) = error else { throw error }
            if let refusal = BranchRefusalParser.parse(stderr: stderr) { throw refusal }
            guard try await hasUnmergedEntries(at: root) else { throw error }
            return .conflicts
        }
        return try await outcome(of: branch, mode: mode, headBefore: headBefore, at: root)
    }

    // MARK: - Reading the outcome out of the repository

    /// What a *successful* merge did, asked of the repository rather than of git's output.
    ///
    /// A squash never moves HEAD, so "did anything happen" cannot be asked of HEAD there; it is
    /// asked of the branch instead. After a real squash `branch` is still not an ancestor of
    /// HEAD (only the index changed), while a no-op squash leaves it one — which is precisely
    /// the condition git itself reported as "Already up to date. (nothing to squash)", verified
    /// on git 2.54 to write no `SQUASH_MSG` and stage nothing.
    ///
    /// For the other two modes: HEAD standing still means there was nothing to merge, HEAD
    /// landing exactly on the branch's tip is a fast-forward, and anything else is a new merge
    /// commit. Comparing against the tip rather than counting parents matters — fast-forwarding
    /// *onto a merge commit* would otherwise look like a merge, because that commit has two
    /// parents of its own and its first parent is where HEAD was.
    private func outcome(
        of branch: String, mode: MergeMode, headBefore: String, at root: URL
    ) async throws -> MergeOutcome {
        if mode == .squash {
            return try await isAncestor(branch, of: "HEAD", at: root) ? .alreadyUpToDate : .squashed
        }
        let headAfter = try await headSHA(at: root)
        if headAfter == headBefore { return .alreadyUpToDate }
        if headAfter == (try await revision(branch, at: root)) { return .fastForwarded }
        return .merged
    }

    /// `git ls-files -u`: index entries at a merge stage other than 0. Git's own definition of
    /// "this worktree has unresolved conflicts", and the only signal that covers both shapes —
    /// a normal merge leaves `MERGE_HEAD`, a conflicting `--squash` leaves none (verified).
    private func hasUnmergedEntries(at root: URL) async throws -> Bool {
        let data = try await run(["ls-files", "-u"], cwd: root)
        return !data.isEmpty
    }

    /// `git merge-base --is-ancestor <rev> <other>`: exit 0 yes, exit 1 no. Any other failure
    /// propagates rather than being read as "no".
    private func isAncestor(_ revision: String, of other: String, at root: URL) async throws -> Bool {
        do {
            _ = try await run(
                ["merge-base", "--is-ancestor", "--end-of-options", revision, other], cwd: root)
            return true
        } catch GitError.commandFailed(exitCode: 1, stderr: _) {
            return false
        }
    }

    /// The commit `revision` resolves to, or "" in a repository with no commits — which is what
    /// `rev-parse --verify HEAD` reports there (exit 128, "Needed a single revision"), and a
    /// state a merge can legitimately be attempted from.
    private func revision(_ revision: String, at root: URL) async throws -> String {
        do {
            let data = try await run(
                ["rev-parse", "--verify", "--end-of-options", revision], cwd: root)
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch GitError.commandFailed(exitCode: 128, stderr: _) {
            return ""
        }
    }

    private func headSHA(at root: URL) async throws -> String {
        try await revision("HEAD", at: root)
    }
}
