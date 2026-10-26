import Foundation

/// `rebase(onto:at:)` — the "Rebase" answer to a diverged pull — and, since B1, the rebase onto
/// a chosen target: `rebasePlan(onto:at:)` and `rebase(_:at:)`. See `GitRemoteBackend.rebase`
/// and `GitHistoryBackend` for the contracts; this file is about the checks made before git
/// runs, the one vector both share, and how the outcome is read back afterwards.
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
        // package, reached from the user's configuration the way `fetch.prune` reaches a prune.
        // The vector below carries `--no-autostash`, which defeats the setting, so **git's own
        // check is the authoritative one**: it is made by the process that rebases, so a change
        // made after the check below is refused by git and parsed back into `.treeNotClean`
        // (tested with a wrapper that dirties the tree as git starts). It is not atomic with
        // the rebase — git checks, then checks out, two steps inside one process — but that
        // gap is git's own, and far narrower than the one between this check and git's start.
        // This check stays as defence in depth, and because it answers without starting a
        // rebase at all.
        //
        // `git diff --quiet` and not `status`: it exits 1 on a difference and runs no external
        // diff driver (measured with `diff.external` set), and a file whose stat is stale but
        // whose content is not is correctly clean (measured with `touch`). An untracked file is
        // not asked about, because git does not refuse over one either. It is **stricter than
        // git's check in one place**, deliberately: a submodule with uncommitted content makes
        // `git diff --quiet` exit 1, while git's own check ignores submodules and rebases (and
        // leaves the submodule alone, with or without `submodule.recurse` — measured). No
        // `--ignore-submodules`: submodules are outside this milestone, and refusing is the
        // answer that cannot lose work.
        let unstaged = try await worktreeDiffersFromIndex(at: root)
        let staged = try await indexDiffersFromHead(at: root)
        if unstaged || staged { throw BranchOperationError.treeNotClean }

        let headBefore = try await headSHA(at: root)
        return try await runRebase(onto: upstream, headBefore: headBefore, at: root)
    }

    /// The one rebase vector, for both callers, and the outcome read back.
    ///
    /// ONE complete literal, pinned whole by `ForceFlagScannerTests`' shape for `rebase`.
    /// `--no-autostash` defeats `rebase.autoStash=true` (see `rebase(onto:at:)`).
    /// `--no-update-refs` defeats `rebase.updateRefs=true`, which would otherwise move every other
    /// local branch that points into the rewritten commits ("Updated the following refs with
    /// --update-refs", measured) — branches the sheet never named. `--no-rebase-merges` (B1) defeats
    /// `rebase.rebaseMerges=true`, which recreates the merges a plain rebase flattens, so the
    /// commits replayed are no longer the list the sheet showed (B13). All three are accepted on
    /// git 2.54, also under `rebase.backend=apply`. `--end-of-options` is accepted in this
    /// position (the rebase runs, and `-x` after it is answered "fatal: invalid upstream '-x'"
    /// rather than read as an option).
    private func runRebase(onto target: String, headBefore: String, at root: URL) async throws -> RebaseOutcome {
        do {
            _ = try await run(["rebase", "--no-autostash", "--no-update-refs", "--no-rebase-merges", "--end-of-options", target], cwd: root)
        } catch let error as GitError {
            // A stopped rebase FIRST, then a refusal. Both callers' guards proved no operation
            // was in progress before git ran, so a rebase in progress now is this one — and a
            // rebase that stopped part-way can print text shaped exactly like a refusal: replaying a
            // commit that adds a file an untracked one is sitting on says "untracked working
            // tree files would be overwritten", and git echoes the stopped commit's subject
            // ("Could not apply 1a2b3c… <subject>"), which can read like anything. Parsing
            // first would report "refused, nothing changed" with `rebase-merge/` in place and
            // HEAD detached (both measured). Only with no rebase in progress is a parsed
            // refusal what it claims to be: git did nothing (an untracked file in the way of
            // the first checkout). Anything else — a `pre-rebase` hook saying no, an upstream
            // that resolves to nothing — is git's own words.
            //
            // A hook's refusal is never parsed at all. Its stderr is the hook's own text, which
            // can be shaped like anything — a hook that prints "cannot rebase: You have
            // unstaged changes." would read as `.treeNotClean` over a clean tree. git names the
            // hook on a line of its own, and prints it only when the hook said no: its
            // dirty-tree check runs first, and when that refuses the hook is never run
            // (measured on git 2.54).
            guard case .commandFailed(_, let stderr) = error else { throw error }
            if try await operationInProgress(at: root) == .rebase { return .conflicts }
            if stderr.contains(Self.preRebaseHookRefused) { throw error }
            if let refusal = BranchRefusalParser.parse(stderr: stderr) { throw refusal }
            throw error
        }
        return try await outcome(onto: target, headBefore: headBefore, at: root)
    }

    // MARK: - Rebase onto a chosen target (B1)

    public func rebasePlan(onto target: String, at root: URL) async throws -> RebasePlan {
        // A ref name or a full object id, as for the pull flow: `main~1` would be read as a
        // revision and rebase onto a commit the sheet never named.
        try requireRevision(target)
        try requireRefNameOrObjectName(target)
        try await refuseHistoryOperationInProgress(at: root)
        let head = try await headSHA(at: root)
        guard !head.isEmpty else { throw HistoryRefusal.unbornHead }
        let commit = try await targetCommit(target, at: root)
        let plan = try await replayPlan(
            head: head, headRef: try await symbolicHead(at: root), target: commit, named: target, at: root)
        let changed = try await trackedChanges(at: root)
        if !changed.isEmpty { throw HistoryRefusal.trackedChanges(changed) }
        return plan
    }

    public func rebase(_ plan: RebasePlan, at root: URL) async throws -> RebaseOutcome {
        // By commit AND by name: the same commit on another branch, or detached, is not the branch
        // the sheet said it would rewrite (fix round 1).
        guard try await headSHA(at: root) == plan.head, try await symbolicHead(at: root) == plan.headRef else {
            throw HistoryRefusal.headMoved
        }
        let now = try await rebasePlan(onto: plan.targetName, at: root)
        guard now.runsAs(plan) else { throw HistoryRefusal.planChanged }
        // The full object id, never the name: a tag spelled like a branch takes the short name
        // over in git (B17).
        return try await runRebase(onto: plan.target, headBefore: plan.head, at: root)
    }

    /// The commit `name` means as the user picked it: a full object id itself; a local branch
    /// before anything spelled the same (git's own lookup prefers a tag, B17 — RF2); then a
    /// remote-tracking branch; then git's lookup (a full ref name, a tag, `HEAD`).
    private func targetCommit(_ name: String, at root: URL) async throws -> String {
        let candidates =
            Self.isFullObjectID(name) || name.hasPrefix("refs/")
            ? [name] : ["refs/heads/" + name, "refs/remotes/" + name, name]
        for candidate in candidates {
            let commit = try await revision(candidate, at: root)
            if !commit.isEmpty { return commit }
        }
        throw BranchOperationError.noSuchBranch(name)
    }

    /// B11–B15, asked of git with both ends as full object ids.
    ///
    /// git says "up to date" and replays nothing when the target is an ancestor of HEAD and the
    /// history between is a straight line (`can_fast_forward` with `is_linear_history`;
    /// measured: with a merge between, it flattens instead). Otherwise it replays
    /// `log --reverse --topo-order --cherry-pick --right-only --no-merges <t>...HEAD` — read
    /// here with `--cherry-mark`, whose `=` marks the patch-identical commits it skips.
    private func replayPlan(
        head: String, headRef: String, target: String, named name: String, at root: URL
    ) async throws -> RebasePlan {
        let range = "\(target)..\(head)"
        let merges = Self.count(try await run(["rev-list", "--count", "--min-parents=2", "--end-of-options", range], cwd: root))
        if merges == 0, try await isAncestor(target, of: head, at: root) {
            return RebasePlan(
                head: head, target: target, replayed: [], flattenedMerges: 0, skippedAsApplied: 0, alreadyPushed: 0,
                targetName: name, headRef: headRef)
        }
        let data = try await run(["log", "--reverse", "--topo-order", "--cherry-mark", "--right-only", "--no-merges", "--no-show-signature", "--format=%m%x00%H%x00%s", "--end-of-options", "\(target)...\(head)"], cwd: root)
        var replayed: [CommitRef] = []
        var skipped = 0
        for line in GitLines.split(data) {
            let fields = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            if fields[0] == "=" { skipped += 1 } else { replayed.append(CommitRef(sha: fields[1], subject: fields[2])) }
        }
        // B15: on some remote-tracking branch — `--remotes` — whichever remote it is.
        let all = try await commitCount(range, at: root)
        let unpushed = Self.count(try await run(["rev-list", "--count", "--not", "--remotes", "--not", "--end-of-options", range], cwd: root))
        return RebasePlan(
            head: head, target: target, replayed: replayed, flattenedMerges: merges, skippedAsApplied: skipped,
            alreadyPushed: all - unpushed, targetName: name, headRef: headRef)
    }

    /// The line git prints when a `pre-rebase` hook exits non-zero (git 2.54, `LC_ALL=C`).
    private static let preRebaseHookRefused = "The pre-rebase hook refused to rebase."

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
