import Foundation
import GitCore

/// Branch actions: everything that moves HEAD, creates a ref or merges.
///
/// All of them go through the same serialized `mutate` as staging and committing, so they queue
/// behind each other, reload before the banner goes up, and never predict git's answer. Nothing
/// here passes a force flag — that is `GitBranchBackend`'s contract, and the refusals it throws
/// are turned into sentences in `RepositoryStore+Errors`.
///
/// Two gates sit in front of the five actions that move HEAD, and only in front of those:
///
/// - **An operation in progress.** git refuses a switch or a merge mid-merge anyway; this
///   refuses first, with a sentence that names the operation. Creating a branch without
///   switching, renaming and deleting stay available, since none of them touches the worktree.
/// - **A detached HEAD holding commits on no ref.** Asked of git, not guessed
///   (`unreferencedCommitCount`), and when the answer is non-zero the action is parked in a
///   `.leaveDetached` sheet instead of run. See `PendingBranchAction.canStrandCommits` for why
///   a merge and a `switch -c` from HEAD are exempt.
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

    /// Merge `branch` into HEAD. `mode` becomes the remembered one only here, so a sheet the
    /// user cancelled never changes what the next sheet comes up on.
    func merge(_ branch: String, mode: MergeMode) {
        rememberMergeMode(mode)
        perform(.merge(branch, mode))
    }

    /// Runs the action a `.leaveDetached` sheet was asked about. Nothing ran when the sheet went
    /// up, so this is the first and only attempt.
    func confirmLeaveDetached() {
        guard case .leaveDetached(_, _, let action) = activeSheet else { return }
        activeSheet = nil
        perform(action, confirmed: true)
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

    // MARK: - Notices

    /// Shows a transient, non-error message and schedules its own removal.
    ///
    /// The timer is cancelled by the next notice and by `open()`, and it re-checks `generation`
    /// before clearing, so a notice raised for a repository opened since is not cleared by an
    /// older one's timer.
    // internal (not private): used by +BranchSheets.swift too
    func showNotice(_ message: String) {
        noticeTask?.cancel()
        setNotice(message)
        let generation = self.generation
        noticeTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, let self, self.generation == generation else { return }
            setNotice(nil)
        }
    }

    func dismissNotice() {
        noticeTask?.cancel()
        setNotice(nil)
    }

    // MARK: - Running one of the five

    /// The one path every HEAD-moving action takes: refuse while an operation is in progress,
    /// ask about a detached HEAD that would strand commits, otherwise run it and return to the
    /// working copy.
    ///
    /// The detached-HEAD count is asked *inside* `mutate`, not before it, so it cannot race a
    /// mutation already queued: by the time it runs, everything before it has finished and
    /// reloaded.
    private func perform(_ action: PendingBranchAction, confirmed: Bool = false) {
        if let reason = branchSwitchingBlockedReason {
            // Through `mutate` rather than straight into `lastError`: that is what makes the
            // message sticky against the reload the watcher is probably about to trigger, and
            // it keeps every refusal on one code path. No git *write* runs.
            mutate { _, _ in throw BranchActionBlocked(reason: reason) }
            return
        }

        let asksFirst = !confirmed && isDetached && action.canStrandCommits
        let detachedAt = headSha
        mutate(result: { backend, root -> BranchActionResult in
            if asksFirst, let detachedAt {
                let stranded = try await backend.unreferencedCommitCount(at: root)
                if stranded > 0 {
                    return .confirm(
                        .leaveDetached(
                            unreferencedCommits: stranded, headSha: detachedAt, then: action))
                }
            }
            return .acted(try await Self.run(action, backend: backend, at: root))
        }, onSuccess: { [self] result in
            switch result {
            case .confirm(let sheet):
                activeSheet = sheet
            case .acted(let message):
                // The detail pane may be showing a commit that the new HEAD's log no longer
                // lists, and after a merge the working copy is what the user needs to look at.
                select(.workingCopy)
                if let message { showNotice(message) }
            }
        })
    }

    private static func run(
        _ action: PendingBranchAction, backend: Backend, at root: URL
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
            return notice(for: outcome, branch: branch)
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

/// What `perform` found: either the action ran (with an optional notice), or it needs an answer
/// first and nothing has happened yet.
private enum BranchActionResult {
    case acted(String?)
    case confirm(BranchSheet)
}
