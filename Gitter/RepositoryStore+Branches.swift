import Foundation
import GitCore

/// Branch actions: everything that moves HEAD, creates a ref or merges.
///
/// All of them go through the same serialized `mutate` as staging and committing: one git write
/// at a time, a reload before the banner goes up, and never a prediction of git's answer. They
/// are not *queued* — `mutate` is a no-op while another one is running, which is also what
/// disables the buttons — so a second click during a merge is dropped, not deferred. Nothing
/// here passes a force flag; that is `GitBranchBackend`'s contract, and the refusals it throws
/// are turned into sentences in `RepositoryStore+Errors`.
///
/// Two gates sit in front of the five actions that move HEAD, and only in front of those:
///
/// - **An operation in progress.** git refuses a switch or a merge mid-merge anyway; this
///   refuses first, with a sentence that names the operation. Creating a branch without
///   switching, renaming and deleting stay available, since none of them touches the worktree.
/// - **A detached HEAD holding commits on no ref.** Asked of git every time, and never of the
///   snapshot: `unreferencedCommits` reports 0 on a branch by construction, so there is no need
///   to *decide* whether HEAD is detached before asking — and deciding from the snapshot would
///   mean a terminal that detached HEAD inside the watcher's 300 ms debounce could walk straight
///   past the guard. See `PendingBranchAction.canStrandCommits` for why a merge and a
///   `switch -c` from HEAD are exempt.
extension RepositoryStore {

    // MARK: - Actions that move HEAD

    func switchTo(branch: String) {
        perform(.switchTo(branch))
    }

    /// Check out `origin/x` as a local `x` tracking it. The backend turns an existing local `x`
    /// into a plain switch rather than re-pointing it.
    func track(remoteBranch: String) {
        perform(.track(remoteBranch))
    }

    /// Check out a commit or a tag without being on a branch.
    func detach(at revision: String) {
        perform(.detach(revision))
    }

    /// Merge `branch` into HEAD. The mode is remembered where the merge actually came back (see
    /// `rememberMergeMode`), not here and not before git runs: a merge this gate refuses — or
    /// one git refuses — never happened, and must not change what the next sheet comes up on.
    func merge(_ branch: String, mode: MergeMode) {
        perform(.merge(branch, mode))
    }

    /// Runs the action a `.leaveDetached` sheet was asked about. Nothing ran when the sheet went
    /// up, so this is the first and only attempt.
    ///
    /// What the sheet showed travels with it, and `perform` re-reads it from git before acting:
    /// the warning is about *those* commits at *that* HEAD, and a terminal can move HEAD while
    /// the sheet is up. Acting on a repository that has moved would strand commits nobody was
    /// warned about — the same hole the force delete had, closed the same way, by verifying
    /// inside the mutation that the state still matches and refusing if it does not.
    func confirmLeaveDetached() {
        guard case .leaveDetached(let count, let sha, let action) = activeSheet else { return }
        activeSheet = nil
        perform(action, confirming: UnreferencedCommits(headSha: sha, count: count))
    }

    /// A pull's integration step — the fast-forward straight after the fetch, or the sheet's
    /// "Merge" — through the same `perform` as every other HEAD-moving action, so every existing
    /// refusal (`wouldOverwrite`, `indexNotClean`, an operation in progress) and its wording is
    /// reused as it stands.
    ///
    /// `answer` is nil for the fast-forward (no question was asked) and `.merge` for the sheet's
    /// Merge; the sheet's Rebase is `rebase(_:onto:)`, never this.
    // internal (not private): used by +Remotes.swift and +RemoteSheets.swift
    func integratePull(upstream: String, answer: PullMode?) {
        assert(answer != .rebase, "a pull's Rebase runs on rebase(_:onto:)")
        perform(.pull(upstream: upstream, answer: answer))
    }

    /// Stash and Continue's second half: `action` again, from scratch, with every gate it had
    /// the first time — an operation in progress, a detached HEAD holding commits (asked again,
    /// never taken as answered). A pull is the exception: its fetch had succeeded and only its
    /// integrate step was refused, so `retryPull` runs no fetch and needs no lane. It decides
    /// again on the tracking the stash's reload read, and keeps the sheet's Merge or Rebase
    /// answer while the branch is still diverged from the same upstream; another upstream asks.
    // internal (not private): used by +StashAndContinue.swift, and by `askAgain()`
    func retry(_ action: PendingBranchAction) {
        switch action {
        case .pull(let upstream, let answer):
            retryPull(upstream: upstream, answer: answer)
        // Planned again and put back on screen: a stash never runs a history action without
        // its confirmation (the plan may differ now — the stash itself changed nothing it
        // reads, but a terminal may have).
        case .history(let kind, let shas):
            requestHistoryAction(kind, shas: shas)
        case .rebaseOnto(let target):
            requestRebaseOnto(target)
        case .switchTo, .track, .detach, .merge, .createAndSwitch:
            perform(action)
        }
    }

    /// The banner's Ask Again, beside a history action refused because HEAD moved or its plan
    /// changed while the sheet was open: plans it again and puts its sheet back up (`retry`). The
    /// offer goes with the banner, so a second press finds nothing.
    func askAgain() {
        guard let action = offeredAskAgain else { return }
        dismissError()
        retry(action)
    }

    // MARK: - Actions that do not move HEAD

    /// Create `name`, optionally switching to it. Creating *without* switching writes one ref
    /// and touches nothing else, so it stays available mid-merge and needs no confirmation even
    /// from a detached HEAD — it is the cure for one.
    func createBranch(named name: String, startPoint: String?, switchTo shouldSwitch: Bool) {
        guard shouldSwitch else {
            mutate { backend, root in
                try await Self.reporting(.create, name) {
                    try await backend.createBranch(
                        name, startPoint: startPoint, switchTo: false, at: root)
                }
            } onSuccess: { [self] in
                showNotice("Created branch \"\(name)\".")
            }
            return
        }
        perform(.createAndSwitch(name: name, startPoint: startPoint))
    }

    /// Rename a branch, including the current one: HEAD follows it and the worktree is untouched.
    func rename(_ old: String, to new: String) {
        mutate { backend, root in
            try await Self.reporting(.rename, old) {
                try await backend.renameBranch(old, to: new, at: root)
            }
        } onSuccess: { [self] in
            showNotice("Renamed \"\(old)\" to \"\(new)\".")
        }
    }

    // MARK: - Running one of the five

    /// The one path every HEAD-moving action takes: refuse while an operation is in progress,
    /// ask about a detached HEAD that would strand commits, otherwise run it and return to the
    /// working copy.
    ///
    /// Everything the guard decides on is read *inside* `mutate` — the count and the sha HEAD is
    /// really at — so neither can be stale. The snapshot is up to 300 ms behind the repository
    /// (the watcher debounces), and "is HEAD detached?" answered from it would be a gate a
    /// terminal could step around by detaching within that window. Asking git costs one
    /// `rev-list` on a branch, where the answer is 0 by construction.
    ///
    /// If that question cannot be answered, the action does **not** run: the error propagates
    /// out of `mutate` into the banner, and nothing has moved. A guard whose input failed must
    /// fail closed.
    private func perform(
        _ action: PendingBranchAction, confirming warned: UnreferencedCommits? = nil
    ) {
        // A branch another worktree holds (B3 final review, T3 m1): its menu item is off with this
        // reason, but a double-click on its row has no disabled state, and a retry or a confirmed
        // leave-detached arrive here too. Refused first, with the same sentence, before the
        // detached-HEAD question — never a warning about commits for a switch git would refuse.
        if case .switchTo(let branch) = action, let reason = worktreeHeldReason(branch) {
            showStickyError(reason)
            return
        }
        if let reason = branchSwitchingBlockedReason {
            // Through `mutate` rather than straight into `lastError`: that is what makes the
            // message sticky against the reload the watcher is probably about to trigger, and
            // it keeps every refusal on one code path. No git *write* runs.
            mutate { _, _ in throw BranchActionBlocked(reason: reason) }
            return
        }

        // Where a merge or a pull's merge records its mode (`rememberMergeMode`).
        let defaults = defaults
        mutate(result: { backend, root -> BranchActionResult in
            if let warned {
                // Answering a warning: it named a sha and a count, and both must still hold.
                // Read here, inside the mutation, immediately before the action — the closest
                // this side of the app can get to the ref itself. What remains is one process
                // spawn's worth of window against another process, the same residual the force
                // delete documents.
                let now = try await backend.unreferencedCommits(at: root)
                guard now == warned else { throw DetachedHeadMovedOn(now: now) }
            } else if action.canStrandCommits() {
                let now = try await backend.unreferencedCommits(at: root)
                // `headSha` is non-nil whenever the count is: the count was taken *of* that sha.
                if now.count > 0, let sha = now.headSha,
                    action.canStrandCommits(leavingHeadAt: sha)
                {
                    return .confirm(sha: sha, stranded: now.count)
                }
            }
            do {
                return .acted(try await Self.run(action, backend: backend, at: root, defaults: defaults))
            } catch {
                // A refusal over local changes goes up with Stash and Continue beside it.
                throw StashAndContinue.offering(error, for: action)
            }
        }, onSuccess: { [self] result in
            switch result {
            case .confirm(let sha, let stranded):
                // Both halves come from one read of git, taken together (see
                // `UnreferencedCommits`) — not from the snapshot, which the watcher leaves up to
                // 300 ms behind, and not from two reads that could describe two moments.
                activeSheet = .leaveDetached(
                    unreferencedCommits: stranded, headSha: sha, then: action)
            case .acted(let message):
                // The detail pane may be showing a commit that the new HEAD's log no longer
                // lists, and after a merge the working copy is what the user needs to look at.
                select(.workingCopy)
                let leftBehind = warned.flatMap(Self.leftBehindNotice)
                let notice = [message, leftBehind].compactMap { $0 }.joined(separator: " ")
                // With commits left behind it is the only copy of their sha: kept.
                if !notice.isEmpty { show(Notice(text: notice, keep: leftBehind != nil)) }
            }
        })
    }

    /// What to say once the user has answered "Leave It/Them Behind" and the action has run.
    ///
    /// Nothing else on screen holds the sha any more: the warning is gone, the toolbar names the
    /// branch just switched to, and the commits are on no ref, so the sidebar and the graph
    /// cannot show them either. Without this line the one string that brings them back leaves
    /// with the sheet.
    ///
    /// Shaped like the force delete's notice ("Deleted "x". Recreate it with: git branch x
    /// 1a2b3c4") because it is the same promise: the objects are still in the repository, and
    /// this is the command that gives them a name again. True for every action that can be
    /// parked here — switch, track, detach and a `switch -c` from somewhere other than HEAD all
    /// leave HEAD's old commit exactly where it was, which is why the sha is the warned one and
    /// not one read afterwards. `<name>` is a placeholder the user fills in: these commits were
    /// on no branch, so there is no name to suggest.
    ///
    /// The *command* carries the whole object name, not the seven characters the sentence reads
    /// with. This notice is the only copy of that sha once it has been shown — the warning is
    /// gone, and nothing on screen refers to commits that are on no ref — so it has to be a
    /// command that still works when it is pasted somewhere else weeks later, into a repository
    /// that has grown enough objects to make seven characters ambiguous. Git resolves an
    /// ambiguous abbreviation by refusing, not by guessing, which would make the one recovery
    /// route fail exactly when the user has most to lose.
    private static func leftBehindNotice(_ warned: UnreferencedCommits) -> String? {
        guard warned.count > 0, let sha = warned.headSha else { return nil }
        let what =
            warned.count == 1
            ? "Left 1 commit behind at \(sha.prefix(7)). Recover it with:"
            : "Left \(warned.count) commits behind at \(sha.prefix(7)). Recover them with:"
        return "\(what) git branch <name> \(sha)"
    }

    private static func run(
        _ action: PendingBranchAction, backend: Backend, at root: URL, defaults: UserDefaults
    ) async throws -> String? {
        switch action {
        case .switchTo(let branch):
            try await reporting(.switchTo, branch) {
                try await backend.switchTo(branch: branch, at: root)
            }
            // No notice: the toolbar already says which branch this is.
            return nil
        case .track(let remoteBranch):
            try await reporting(.checkOut, remoteBranch) {
                try await backend.trackRemoteBranch(remoteBranch, at: root)
            }
            return "Checked out \"\(remoteBranch)\" as a local branch."
        case .detach(let revision):
            try await reporting(.checkOut, revision) {
                try await backend.checkoutDetached(revision, at: root)
            }
            return nil
        case .createAndSwitch(let name, let startPoint):
            try await reporting(.create, name) {
                try await backend.createBranch(
                    name, startPoint: startPoint, switchTo: true, at: root)
            }
            return "Created \"\(name)\" and switched to it."
        case .merge(let branch, let mode):
            let outcome = try await reporting(.merge, branch) {
                try await backend.merge(branch, mode: mode, at: root)
            }
            // Here and nowhere earlier — not before `merge`, which was where this used to sit.
            // Every refusal leaves by way of a throw, and a merge git refused did not happen:
            // it must not rewrite what the next sheet comes up on. Reaching this line means git
            // ran the merge the user asked for and did not refuse it, which is true of all five
            // outcomes including `.conflicts` (a half-done merge is in the worktree) and
            // `.alreadyUpToDate` (nothing to do, but the mode was accepted and the user's choice
            // was a real one — silently declining to remember it would be its own small lie).
            rememberMergeMode(mode, in: defaults)
            return notice(for: outcome, branch: branch)
        case .pull(let upstream, .rebase):
            // Never performed here: the sheet's Rebase, first time or retried, is
            // `rebase(_:onto:)` (`+RemoteSheets`).
            assertionFailure("a pull's rebase onto \(upstream) reached perform")
            return nil
        case .pull(let upstream, let answer):
            let mode: MergeMode = answer == .merge ? .alwaysMergeCommit : .fastForwardIfPossible
            let outcome = try await reporting(.merge, upstream) {
                try await backend.merge(upstream, mode: mode, at: root)
            }
            // The pull mode, never the merge mode, and only for the sheet's explicit Merge: a
            // pull that fast-forwarded asked the user nothing. Here for the reason
            // `rememberMergeMode` is above — every refusal is a throw, so reaching this line
            // means the merge ran.
            if answer == .merge { rememberPullMode(.merge, in: defaults) }
            return notice(for: outcome, branch: upstream)
        case .history, .rebaseOnto:
            // Never performed here: `retry` sends both to their own request (`+History`), which
            // plans and asks before anything runs.
            assertionFailure("\(action) reached perform")
            return nil
        }
    }

    /// What a successful merge says in the notice strip.
    ///
    /// `.conflicts` and `.squashed` say nothing here on purpose: both leave an operation in
    /// progress, and the note above the file list already explains that state and offers the way
    /// out. A second message would compete with it — and neither is an error, so the banner is
    /// certainly wrong for them.
    private static func notice(for outcome: MergeOutcome, branch: String) -> String? {
        switch outcome {
        case .alreadyUpToDate: "Already up to date with \"\(branch)\"."
        case .fastForwarded: "Fast-forwarded to \"\(branch)\"."
        case .merged: "Merged \"\(branch)\"."
        case .squashed, .conflicts: nil
        }
    }

    /// Tags a `BranchOperationError` with the action that provoked it, so the banner can say
    /// "Can't switch to …" instead of describing a refusal in the abstract.
    ///
    /// Only `BranchOperationError` is wrapped. A `GitError.commandFailed` is git's own words for
    /// something Gitter does not recognise — and, from `merge` or `abort`, may describe a
    /// repository that *did* change — so it passes through untouched rather than being dressed
    /// up as a refusal.
    // internal (not private): used by +BranchSheets.swift
    static func reporting<T>(
        _ verb: BranchVerb, _ target: String, _ body: () async throws -> T
    ) async throws -> T {
        do {
            return try await body()
        } catch let refusal as BranchOperationError {
            throw BranchActionFailure(verb: verb, target: target, refusal: refusal)
        }
    }
}

/// What `perform` found: either the action ran (with an optional notice), or HEAD is at `sha`
/// holding `stranded` commits on no ref and nothing has happened yet.
private enum BranchActionResult {
    case acted(String?)
    case confirm(sha: String, stranded: Int)
}
