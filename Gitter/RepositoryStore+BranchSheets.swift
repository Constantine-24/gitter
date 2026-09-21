import Foundation
import GitCore

/// Opening the branch sheets, and the two actions that only exist behind one: force-deleting an
/// unmerged branch, and aborting an operation.
///
/// Both of those can lose work, so neither has an entry point that acts straight away. Delete is
/// two steps by construction — `requestDelete` runs a plain `git branch -d`, which git either
/// does or refuses *without changing anything*, and only the refusal opens the sheet — and abort
/// asks before running at all.
extension RepositoryStore {

    // MARK: - Opening a sheet

    /// `startPoint` nil means "from HEAD", which is what the sheet shows as the current branch
    /// or "detached at <sha>". A caller that has a revision (a commit row, a remote branch, a
    /// tag) passes both it and the label to show for it.
    func requestNewBranch(from startPoint: String? = nil, labelled label: String? = nil) {
        activeSheet = .newBranch(startPoint: startPoint, startLabel: label ?? startPoint ?? headLabel)
    }

    func requestRename(_ branch: String) {
        activeSheet = .rename(branch)
    }

    func requestMerge(_ branch: String) {
        activeSheet = .merge(branch)
    }

    /// Opens the confirmation for whatever the repository is really part-way through. Nothing to
    /// abort is not an error state worth a banner — the button that opens this is only visible
    /// while an operation is in progress — so it simply does nothing.
    func requestAbort() {
        guard let operation = operationInProgress else { return }
        activeSheet = .abort(operation)
    }

    // MARK: - Delete

    /// Runs `git branch -d`. The backend never forces here, so a branch git considers unmerged
    /// comes back as `.notFullyMerged` with the numbers to show — the branch is untouched — and
    /// that is what opens the second confirmation.
    func requestDelete(_ name: String) {
        mutate(result: { backend, root in
            try await Self.reporting(.delete, name) {
                try await backend.deleteBranch(name, at: root)
            }
        }, onSuccess: { [self] deletion in
            switch deletion {
            case .deleted:
                showNotice("Deleted branch \"\(name)\".")
            case .notFullyMerged(let uniqueCommits, let tip):
                activeSheet = .deleteUnmerged(name: name, uniqueCommits: uniqueCommits, tip: tip)
            }
        })
    }

    /// `git branch -D`, and **only** as the answer to the warning that named this branch, at the
    /// tip that warning showed.
    ///
    /// Two guards, and they answer different questions. This one is about *which warning*: with
    /// no matching `.deleteUnmerged` on screen there is nothing this could be the answer to, so
    /// a stale call, a mis-wired menu item or a debug hook reaching straight for the destructive
    /// half stops here. It is a UI-level check and it matches on the name alone, which is all
    /// the sheet's identity is.
    ///
    /// The second guard is about *which commits*, and it is not here — it is in the backend,
    /// next to the delete, because that is the only place where "what the sheet said" and "what
    /// the ref says now" can be compared with nothing in between. The tip is taken off the sheet
    /// and handed down, and `forceDeleteBranch` refuses unless `refs/heads/<name>` still resolves
    /// to exactly it. A name-only check here would not have been enough: the branch can gain a
    /// commit, or be renamed away and recreated under the same name, while the warning is on
    /// screen, and deleting *that* orphans commits nobody was warned about.
    ///
    /// The tip also lets the notice name it: git keeps the commit object (verified), so a user
    /// who changes their mind can recreate the branch.
    func confirmForceDelete(_ name: String) {
        guard case .deleteUnmerged(let warned, _, let tip) = activeSheet, warned == name else {
            return
        }
        // Closed before anything runs, which is also what a refusal needs: the numbers on it are
        // the ones being disputed, so it must not stay up looking authoritative.
        activeSheet = nil

        mutate({ backend, root in
            try await Self.reporting(.delete, name) {
                try await backend.forceDeleteBranch(name, expectedTip: tip, at: root)
            }
        }, onSuccess: { [self] in
            showNotice(
                "Deleted \"\(name)\". Recreate it with: git branch \(name) \(tip.prefix(7))")
        })
    }

    #if DEBUG
        /// Puts the unmerged-delete warning on screen **without deleting anything** — the count
        /// is asked of git (`commitsOnlyOn`) and the tip comes from the **snapshot**, not from
        /// `rev-parse`, which is the difference from the real flow and matters now that the tip
        /// is load-bearing.
        ///
        /// The snapshot is up to 300 ms behind the repository (the watcher debounces), so a
        /// branch moved in the last instant gives this sheet a stale tip. That is safe but
        /// visible: `confirmForceDelete` hands the tip to `forceDeleteBranch`, which refuses on
        /// any mismatch, so the worst a stale preview can do is refuse a delete — never make one
        /// against numbers the sheet did not show. A debug step whose tip came from the snapshot
        /// can therefore fail where `delete:<b>` succeeds, and that is the honest behaviour, not
        /// a bug to paper over. Reading the tip from git would need a tip-reading method on
        /// `GitBranchBackend` that nothing else wants.
        ///
        /// Only the debug hook wants this at all. The real flow has to be the other one: `-d` is
        /// the authority on whether a branch is merged, it changes nothing when it refuses, and
        /// its refusal is what the warning answers. This exists so `sheet:delete:<b>` can
        /// honestly mean "open the sheet", where routing it through `requestDelete` would
        /// *delete* a merged branch under a step documented as showing a sheet.
        func previewDeleteWarning(_ name: String) {
            guard let root, let branch = localBranches.first(where: { $0.name == name }) else {
                return
            }
            let generation = self.generation
            Task { [self] in
                guard let count = try? await backend.commitsOnlyOn(branch: name, at: root),
                    self.generation == generation
                else { return }
                activeSheet = .deleteUnmerged(name: name, uniqueCommits: count, tip: branch.sha)
            }
        }
    #endif

    // MARK: - Abort

    /// Ends the operation the sheet asked about.
    ///
    /// The backend re-reads what is really in progress before running anything, because the one
    /// command that would not catch a stale request (`git reset --merge`, the undo for a pending
    /// squash) exits 0 during a real merge and aborts *that* instead. Both of its refusals mean
    /// the UI was a refresh behind, which is worth saying plainly rather than in git's words.
    ///
    /// Any other failure keeps git's own message: `git am --abort` in particular can fail
    /// half-way, leaving the conflict destroyed and the operation still in progress, so a failed
    /// abort must never be reported as "nothing happened".
    func confirmAbort(_ operation: RepositoryOperation) {
        activeSheet = nil
        mutate({ backend, root in
            do {
                try await backend.abort(operation, at: root)
            } catch BranchOperationError.noOperationInProgress {
                throw RepositoryMovedOn()
            } catch BranchOperationError.operationMismatch {
                throw RepositoryMovedOn()
            }
        }, onSuccess: { [self] in
            showNotice(
                operation == .squash ? "Squash undone." : "\(operation.noun) aborted.")
        })
    }

    // MARK: - What a merge would bring in

    /// How many commits `branch` has that HEAD does not — the merge sheet's "N commits in
    /// <branch> are not in <current>" line.
    ///
    /// **nil means the question could not be answered**, and the sheet then shows no number at
    /// all: a made-up count is worse than none, and this one is only ever informational, so
    /// unlike `unreferencedCommitCount` (which gates a confirmation and must fail closed) a
    /// failure here simply removes the line.
    ///
    /// Asked of git against `HEAD` rather than worked out from the snapshot, for the same
    /// reason as everywhere else in this milestone: the snapshot is up to 300 ms behind, and
    /// `HEAD` is also the only spelling that works while HEAD is detached — which is a legal
    /// merge target. Like `validateNewBranchName` this takes no mutation lock and writes
    /// nothing, so it cannot deadlock behind one.
    ///
    func incomingCommitCount(for branch: String) async -> Int? {
        guard let root else { return nil }
        return try? await backend.commitCount(in: branch, notIn: "HEAD", at: root)
    }

    // MARK: - Live name validation

    /// What is wrong with `name` as a new branch name, or nil when nothing is.
    ///
    /// Cheap enough to call from a debounced `.task` on the field: one `git check-ref-format`
    /// and a lookup in the snapshot's refs. It writes nothing and takes no mutation lock, so it
    /// cannot deadlock behind one either.
    ///
    /// Validity is asked before existence because "already exists" about a name git would never
    /// accept is the less useful of the two answers. A name git cannot judge (no repository
    /// open, the command failed) counts as invalid: the sheet must not enable a Create button on
    /// a name nothing has vouched for.
    func validateNewBranchName(_ name: String) async -> BranchNameProblem? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return .empty }
        guard let root else { return .invalid }
        guard (try? await backend.validateBranchName(trimmed, at: root)) == true else {
            return .invalid
        }
        guard !localBranches.contains(where: { $0.name == trimmed }) else { return .exists }
        return nil
    }
}
