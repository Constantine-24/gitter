import Foundation

/// `merge(_:mode:at:)`. See `GitBranchBackend.merge` for the contract; this file is about how
/// the three modes are spelled and how the outcome is worked out afterwards.
extension CLIGitBackend {
    public func merge(_ branch: String, mode: MergeMode, at root: URL) async throws -> MergeOutcome {
        try requireName(branch)
        // A squash is the one mode git will start with a dirty index, and the one mode whose
        // only exit resets that index wholesale. See `requireACleanIndexForASquash`.
        if mode == .squash { try await requireACleanIndexForASquash(at: root) }
        let target = try await unambiguousSpelling(of: branch, at: root)
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
            arguments = ["merge", "--ff", "--no-edit", "--end-of-options", target]
        case .alwaysMergeCommit:
            arguments = ["merge", "--no-ff", "--no-edit", "--end-of-options", target]
        case .squash:
            arguments = ["merge", "--ff", "--squash", "--end-of-options", target]
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
            // `try?`, not `try`: if asking about unmerged entries fails for its own reason,
            // that error must not replace the one git actually reported about the merge. An
            // unanswerable question falls back to "no conflicts", which rethrows git's words.
            guard (try? await hasUnmergedEntries(at: root)) == true else { throw error }
            return .conflicts
        }
        return try await outcome(of: target, mode: mode, headBefore: headBefore, at: root)
    }

    // MARK: - Which ref the name actually means

    /// How to spell `name` so git merges what the user pointed at.
    ///
    /// A tag and a local branch may share a name, and git's lookup order puts `refs/tags/<name>`
    /// **ahead** of `refs/heads/<name>`. Verified on git 2.54: with both present, `git merge dup`
    /// fast-forwarded onto the *tag's* commit and said nothing about it beyond a "refname 'dup'
    /// is ambiguous" warning on stderr — exit 0, so no banner, no refusal, and a branch the user
    /// clicked in the sidebar quietly not merged. `git rev-list HEAD..dup` picks the tag for the
    /// same reason, which is why the merge sheet's count asks for `refs/heads/<name>` outright.
    ///
    /// The full refname is **not** used unconditionally, because git builds the merge commit's
    /// subject out of the string it was given: `git merge refs/heads/feature` writes
    /// "Merge branch 'refs/heads/feature'" (verified), where the bare name writes
    /// "Merge branch 'feature'" and, on any branch but `main`/`master`, " into <branch>" after
    /// it. Gitter is not in the business of rewriting git's commit messages, so the bare name is
    /// kept wherever it is unambiguous — which is every repository that does not have a tag and
    /// a branch of the same name pointing at different commits.
    ///
    /// Compared by **object**, not by name and not by the commit each side peels to: the bare
    /// name is kept only when it resolves to the very object `refs/heads/<name>` does.
    ///
    /// That distinction is the whole difference an *annotated* tag makes. An annotated tag on the
    /// branch's own commit is a separate object, so `git merge dup` merges the right commit but
    /// writes "Merge tag 'dup'" and copies the tag's message into the body (verified on git
    /// 2.54) — a history entry about a tag the user never clicked. Peeling both sides with
    /// `^{commit}` would call that unambiguous; comparing the unpeeled names does not, and the
    /// merge is spelled `refs/heads/dup`.
    ///
    /// A **lightweight** tag on the same commit *is* the same object, so the bare name is kept —
    /// and git then writes "Merge tag 'dup'" of its own accord, because it names whichever ref it
    /// found and only the full refname changes that (verified on git 2.54; pinned by
    /// `MergeAmbiguousNameTests`). Recorded rather than fixed: the commit merged is the branch's,
    /// the tag really does point at it, and the alternative is spelling every merge in a
    /// repository that has a same-named tag `refs/heads/…`.
    ///
    /// Ambiguity is re-read here rather than taken from the snapshot, but this is still a check
    /// followed by an act: a tag created in between is merged as before. That is a
    /// wrong-thing-merged, not a loss — a merge commit is a commit, and nothing uncommitted is
    /// touched — so it does not fail closed the way `unreferencedCommits` does.
    private func unambiguousSpelling(of name: String, at root: URL) async throws -> String {
        let branchRef = "refs/heads/" + name
        let tip = try await objectName(branchRef, at: root)
        // Not a local branch at all (a remote-tracking branch, a tag, a raw sha): `name` is the
        // only spelling there is, and git's own lookup is the right answer.
        guard !tip.isEmpty else { return name }
        return (try await objectName(name, at: root)) == tip ? name : branchRef
    }

    // MARK: - The one refusal Gitter makes that git does not

    /// Refuses a squash while anything is staged, because the *undo* cannot tell the user's
    /// staged work from the squash's.
    ///
    /// git refuses this by itself for a **true** merge (`.indexNotClean`, see that case), but a
    /// squash of a fast-forwardable branch never goes through the merge strategy: verified on
    /// git 2.54, `git merge --ff --squash feature` with `keep.txt` staged exits 0, writes
    /// `SQUASH_MSG`, and leaves `keep.txt` staged alongside the squashed changes. The only way
    /// out of a pending squash is `git reset --merge`, which resets the whole index to HEAD —
    /// so that pre-existing staged work is destroyed by "Undo Squash", with nothing in the
    /// confirmation able to warn about it, since by then the two are indistinguishable.
    ///
    /// Gitter therefore will not create the state. It is still *reachable* — a terminal can do
    /// it — and `UndoSquashTests.undoingASquashStartedOutsideGitterDestroysWorkStagedBeforeIt`
    /// pins what happens then, so the sheet's wording stays honest about it.
    ///
    /// Unmerged entries are deliberately not caught here: they make the index differ from HEAD
    /// too, but the useful refusal for "you are half-way through a conflict" is git's own
    /// (`.operationInProgress("resolving conflicts")`), so that case is left to git, exactly as
    /// it is for the other two modes.
    private func requireACleanIndexForASquash(at root: URL) async throws {
        guard try await indexDiffersFromHead(at: root) else { return }
        guard try await hasUnmergedEntries(at: root) == false else { return }
        throw BranchOperationError.indexNotClean
    }

    /// `git diff --cached --quiet`: exit 0 when the index matches HEAD, exit 1 when it does
    /// not. Verified on git 2.54 across the cases that matter here: an unstaged edit alone and
    /// an untracked file alone both exit 0 (neither is in the index), unmerged entries exit 1,
    /// and an **unborn HEAD** is handled without a special case — exit 0 with an empty index,
    /// exit 1 once something is staged, never the 128 a bare `rev-parse HEAD` would give.
    func indexDiffersFromHead(at root: URL) async throws -> Bool {
        do {
            _ = try await run(["diff", "--cached", "--quiet"], cwd: root)
            return false
        } catch GitError.commandFailed(exitCode: 1, stderr: _) {
            return true
        }
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
    ///
    /// Not `private`, like `revision`, `headSHA` and `indexDiffersFromHead`: `rebase`
    /// (`CLIGitBackend+Rebase.swift`) reads its outcome back with the same questions.
    func isAncestor(_ revision: String, of other: String, at root: URL) async throws -> Bool {
        do {
            _ = try await run(
                ["merge-base", "--is-ancestor", "--end-of-options", revision, other], cwd: root)
            return true
        } catch GitError.commandFailed(exitCode: 1, stderr: _) {
            return false
        }
    }

    /// The **commit** `revision` resolves to, or "" in a repository with no commits — which is
    /// what `rev-parse --verify HEAD^{commit}` reports there (exit 128, "Needed a single
    /// revision"), and a state a merge can legitimately be attempted from.
    ///
    /// `^{commit}` is not decoration. An *annotated* tag resolves to the tag object's sha,
    /// which is never what HEAD points at after a merge, so comparing an unpeeled `v2` against
    /// HEAD would report a plain single-parent fast-forward as `.merged`. Verified on git 2.54:
    /// the peel is applied after `--end-of-options` (the suffix is part of the revision, not an
    /// option), and it is a no-op for a branch, a lightweight tag or a raw sha.
    func revision(_ revision: String, at root: URL) async throws -> String {
        try await revParse(revision + "^{commit}", at: root)
    }

    /// The object `name` resolves to **unpeeled**, or "" when it resolves to nothing: the tag
    /// object for an annotated tag, the commit for a branch, a lightweight tag or a raw sha.
    /// What `unambiguousSpelling` compares, and the one read here that must *not* peel.
    private func objectName(_ name: String, at root: URL) async throws -> String {
        try await revParse(name, at: root)
    }

    private func revParse(_ revision: String, at root: URL) async throws -> String {
        do {
            let data = try await run(
                ["rev-parse", "--verify", "--end-of-options", revision], cwd: root)
            return String(decoding: data, as: UTF8.self)
                .trimmingCharacters(in: .whitespacesAndNewlines)
        } catch GitError.commandFailed(exitCode: 128, stderr: _) {
            return ""
        }
    }

    func headSHA(at root: URL) async throws -> String {
        try await revision("HEAD", at: root)
    }
}
