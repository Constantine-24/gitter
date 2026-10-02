import Foundation
import GitCore

/// Committing: turning what's staged (or, absent that, every tracked change) into a commit.
extension RepositoryStore {

    func commit() {
        guard draft.canCommit else { return }
        let message = draft.message
        let amend = draft.amend

        // A rebase, cherry-pick or revert stop is concluded by Continue, never by `commit -F`:
        // during a rebase it loses the original author, and after a single pick it breaks the
        // following `--continue` (M 15). The composer's button is Continue there; this refuses
        // what reaches it anyway (a debug hook, a stop that began a moment ago) before git runs.
        if let operation = operationInProgress, OperationBarState.isContinuable(operation) {
            mutate { _, _ in throw BranchActionBlocked(reason: ContinueWording.commitRefused(operation)) }
            return
        }
        // A merge's or squash's commit takes the draft as its message: one written for something
        // else is not sent before the user chooses (the composer's note, fix round 1).
        if let reason = composerCommitBlockedReason {
            mutate { _, _ in throw BranchActionBlocked(reason: reason) }
            return
        }

        // Amending part-way through an operation rewrites the commit that operation is standing
        // on, and in four of the six git goes through with it: the previous tip ends up on no
        // ref, and the merge/revert/squash it belonged to either vanishes or is left pointing at
        // nothing. `CLIGitBackend.commit` refuses all six outright; this refuses first so the
        // banner names the operation and the way out instead of repeating a backend error.
        //
        // Not redundant with the disabled toggle, either: ⌘↩ commits from either text field, and
        // `reconcileAmendWithOperation` only catches an operation the store has already seen. A
        // merge started in a terminal a moment ago has not reached the snapshot yet, and this is
        // the last gate on this side of the process.
        if amend, let operation = operationInProgress {
            // Through `mutate` rather than straight into `lastError`, like `perform`'s own
            // refusal: that is what makes the message sticky against the reload the watcher is
            // about to trigger. No git write runs.
            mutate { _, _ in throw BranchActionBlocked(reason: operation.amendBlockedHelp) }
            return
        }

        // With nothing staged, commit every tracked modification and deletion (`git commit
        // -a`), which never sweeps in untracked files. Amending keeps HEAD's tree instead.
        // When there is nothing to commit at all, git says so and that becomes the banner.
        //
        // Never mid-operation, though: `git commit -a` there concludes the merge *and* folds
        // in every unrelated dirty tracked file, which is not what "finish this merge" means
        // and cannot be undone by the user from here. Plain `git commit` is also the right
        // command when nothing is staged mid-merge, which is a real state — a conflict
        // resolved exactly to our side leaves the index matching HEAD, and git still writes
        // the two-parent commit.
        //
        // Same call during a pending squash: `commit -a` would restage every tracked file —
        // not only the squashed ones — under the "Commit Squash" label, which overstates what
        // the user asked for. And it is moot in the one case that would make it tempting
        // (nothing staged because the user unstaged everything): `blocksUnstaging` already
        // keeps that from happening through the app's own controls.
        let allTracked = stagedFiles.isEmpty && !amend && operationInProgress == nil

        mutate { backend, root in
            _ = try await backend.commit(
                message: message, amend: amend, allTracked: allTracked, at: root)
        } onSuccess: { [self] in
            // Only when git accepted the commit (a rejection — hook, signing, nothing to
            // commit — throws, leaving the draft as typed), and only while this is still the
            // repository it was committed to; see `mutate`.
            draft.reset()
            syncDraftWithOperation(restart: true)
            select(.workingCopy)
        }
    }

    /// Why the composer's Commit is off beyond an empty subject or a running change: during a
    /// merge or squash, a draft written before it began (`composerForeignDraft`).
    var composerCommitBlockedReason: String? {
        guard let operation = operationInProgress, let foreign = composerForeignDraft else { return nil }
        return ContinueWording.foreignReason(
            writtenFor: foreign.writtenFor, operation: operation, current: operationStop?.progress?.current)
    }

    /// Turns amending on or off, prefilling an untouched draft with HEAD's message.
    ///
    /// Not routed through `mutate`: it writes no git state, and the draft has to stay editable
    /// while a mutation is in flight. Turning amend back off takes the prefill away again,
    /// but only while it is still untouched — see `clearPrefillIfUntouched`.
    func setAmend(_ on: Bool) {
        // Ticking it while an operation is in progress is a no-op: the commit it describes
        // cannot be made (see `commit()` and `GitWorkingCopyBackend.commit`), and a box that
        // ticks and then refuses is worse than one that will not tick. Unticking always works —
        // that is the way out of the state `reconcileAmendWithOperation` cannot reach.
        if on, operationInProgress != nil { return }
        draft.amend = on
        if !on { draft.clearPrefillIfUntouched() }
        guard on, draft.subject.isEmpty, draft.body.isEmpty, let root else { return }
        let generation = self.generation
        Task {
            guard let message = try? await backend.headMessage(at: root) else { return }
            // Amending may have been switched off again, or another repository opened, while
            // `git log` ran: HEAD's message belongs to neither of those drafts.
            guard draft.amend, self.generation == generation else { return }
            draft.prefill(from: message)
        }
    }

    /// Takes Amend back off when the repository turns out to be part-way through an operation.
    ///
    /// The toggle is disabled while one is in progress, but the operation can begin *after*
    /// Amend was ticked — a merge from the sheet, a rebase started in a terminal — and a control
    /// that becomes disabled keeps whatever value it had. Left alone the draft would still say
    /// "Amend Commit" over a commit that cannot be amended, and HEAD's prefilled message would
    /// sit there as if it were the merge commit's.
    ///
    /// The draft is restored exactly the way unticking restores it, and by the same call:
    /// `clearPrefillIfUntouched` takes back the message Gitter offered and nothing else. Text
    /// the user typed over that offer is theirs and stays — an earlier milestone fixed "untick
    /// doesn't clear the amend message", and this must not undo either half of it.
    ///
    /// Called from `setSnapshot`, the one place the snapshot is written.
    // internal (not private): used by RepositoryStore.swift's `setSnapshot(_:)`
    func reconcileAmendWithOperation() {
        guard draft.amend, operationInProgress != nil else { return }
        draft.amend = false
        draft.clearPrefillIfUntouched()
    }
}
