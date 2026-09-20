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
                try await backend.deleteBranch(name, force: false, at: root)
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

    /// `git branch -D`, from the sheet `requestDelete` opened. The tip sha is read back off that
    /// sheet before it closes so the notice can name it: git keeps the commit object, so a user
    /// who changes their mind can still recreate the branch from it.
    func confirmForceDelete(_ name: String) {
        var tip: String?
        if case .deleteUnmerged(let sheetName, _, let sheetTip) = activeSheet, sheetName == name {
            tip = sheetTip
        }
        activeSheet = nil

        mutate({ backend, root in
            _ = try await Self.reporting(.delete, name) {
                try await backend.deleteBranch(name, force: true, at: root)
            }
        }, onSuccess: { [self] in
            guard let tip else {
                showNotice("Deleted branch \"\(name)\".")
                return
            }
            let short = String(tip.prefix(7))
            showNotice("Deleted \"\(name)\". Recreate it with: git branch \(name) \(short)")
        })
    }

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
