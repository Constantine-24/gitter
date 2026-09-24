import Foundation

/// `rebase(onto:at:)` — the "Rebase" answer to a diverged pull. See `GitRemoteBackend.rebase`
/// for the contract; this file is about the checks made before git runs and how the outcome is
/// read back afterwards.
///
/// It lives beside, not inside, `CLIGitBackend+Remotes.swift` for length: nothing here talks to
/// a remote. The upstream is whatever the last fetch left in `refs/remotes/*`.
extension CLIGitBackend {
    public func rebase(onto upstream: String, at root: URL) async throws -> RebaseOutcome {
        // A ref name or a full object name, nothing else — the guard `commits(in:notIn:)` uses.
        // git reads its argument as a revision: `origin/main~1` is accepted (measured) and would
        // rebase onto a commit the sheet never named.
        try requireRevision(upstream)
        try requireRefNameOrObjectName(upstream)

        // Asked of the repository, not of a snapshot. git's own answer is worse than none:
        // during a conflicted merge it says "cannot rebase: You have unstaged changes." (and
        // "additionally, your index…"), which names the wrong problem, and during a resolved
        // one "Your index contains uncommitted changes." (both measured on git 2.54).
        if let operation = try await operationInProgress(at: root) {
            throw BranchOperationError.operationInProgress(Self.phrase(for: operation))
        }

        // git refuses over any uncommitted tracked change by itself — unless
        // `rebase.autoStash=true`, which it honours silently: measured, "Created autostash",
        // the rebase, "Applied autostash", exit 0. That is `--autostash`, forbidden in this
        // package, reached from the user's configuration the way `fetch.prune` reaches a prune,
        // and the vector cannot carry `--no-autostash` (it is pinned character for character by
        // the scanner's contract test). So the refusal is made here, before git runs, and it
        // is the same refusal git makes. What is left is a change made between this check and
        // the rebase, under that config: git then stashes and re-applies it, and a failed
        // re-apply leaves it in the stash ("Your changes are safe in the stash") — kept, not
        // lost.
        //
        // `git diff --quiet` and not `status`: it exits 1 on a difference and runs no external
        // diff driver (measured with `diff.external` set), and a file whose stat is stale but
        // whose content is not is correctly clean (measured with `touch`). An untracked file is
        // not asked about, because git does not refuse over one either.
        let unstaged = try await worktreeDiffersFromIndex(at: root)
        let staged = try await indexDiffersFromHead(at: root)
        if unstaged || staged { throw BranchOperationError.treeNotClean }

        let headBefore = try await headSHA(at: root)

        // ONE complete literal, pinned by `ForceFlagScannerTests`'
        // `allowsTheRemoteOperationsThisMilestoneNeeds`, character for character.
        // `--end-of-options` is accepted by `rebase` in this position (verified on git 2.54:
        // the rebase runs, and `-x` after it is answered "fatal: invalid upstream '-x'" rather
        // than read as an option).
        do {
            _ = try await run(["rebase", "--end-of-options", upstream], cwd: root)
        } catch let error as GitError {
            // A refusal first: git did nothing (an untracked file in the way, or a change made
            // since the check above). Then a stopped rebase, which is an outcome. Anything else
            // — a `pre-rebase` hook saying no, an upstream that resolves to nothing — is git's
            // own words.
            guard case .commandFailed(_, let stderr) = error else { throw error }
            if let refusal = BranchRefusalParser.parse(stderr: stderr) { throw refusal }
            guard try await operationInProgress(at: root) == .rebase else { throw error }
            return .conflicts
        }
        return try await outcome(onto: upstream, headBefore: headBefore, at: root)
    }

    /// Read back, in the order that cannot mislead: a rebase still in progress first (whatever
    /// git exited with), then whether HEAD moved at all, then whether it merely moved forward.
    private func outcome(
        onto upstream: String, headBefore: String, at root: URL
    ) async throws -> RebaseOutcome {
        if try await operationInProgress(at: root) == .rebase { return .conflicts }
        let headAfter = try await headSHA(at: root)
        if headAfter == headBefore { return .upToDate }
        // Landing on the upstream's tip is not enough on its own — a rebase that dropped every
        // local commit as already applied lands there too, with those commits off the branch.
        // The old tip being an ancestor of the new one is what makes it a fast-forward.
        if headAfter == (try await revision(upstream, at: root)),
            try await isAncestor(headBefore, of: headAfter, at: root) {
            return .fastForwarded
        }
        return .rebased
    }

    /// `git diff --quiet`: exit 0 when the worktree matches the index for every tracked file,
    /// exit 1 when it does not. The unstaged half of git's own "cannot rebase" check;
    /// `indexDiffersFromHead` is the staged half.
    private func worktreeDiffersFromIndex(at root: URL) async throws -> Bool {
        do {
            _ = try await run(["diff", "--quiet"], cwd: root)
            return false
        } catch GitError.commandFailed(exitCode: 1, stderr: _) {
            return true
        }
    }

    /// The phrase `BranchOperationError.operationInProgress` carries — it completes
    /// "while …" — for the operation git itself would have named, using the same words
    /// `BranchRefusalParser` reads out of git's own refusals. A pending squash has no git
    /// wording of its own; "squashing" completes the sentence the same way.
    private static func phrase(for operation: RepositoryOperation) -> String {
        switch operation {
        case .merge: return "merging"
        case .cherryPick: return "cherry-picking"
        case .revert: return "reverting"
        case .rebase: return "rebasing"
        case .applyingPatches: return "applying patches"
        case .squash: return "squashing"
        }
    }
}
