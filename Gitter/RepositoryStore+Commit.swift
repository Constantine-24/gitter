import Foundation
import GitCore

/// Committing: turning what's staged (or, absent that, every tracked change) into a commit.
extension RepositoryStore {

    func commit() {
        guard draft.canCommit else { return }
        let message = draft.message
        let amend = draft.amend
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
        let allTracked = stagedFiles.isEmpty && !amend && operationInProgress == nil

        mutate { backend, root in
            _ = try await backend.commit(
                message: message, amend: amend, allTracked: allTracked, at: root)
        } onSuccess: { [self] in
            // Only when git accepted the commit (a rejection — hook, signing, nothing to
            // commit — throws, leaving the draft as typed), and only while this is still the
            // repository it was committed to; see `mutate`.
            draft.reset()
            select(.workingCopy)
        }
    }

    /// Turns amending on or off, prefilling an untouched draft with HEAD's message.
    ///
    /// Not routed through `mutate`: it writes no git state, and the draft has to stay editable
    /// while a mutation is in flight. Turning amend back off takes the prefill away again,
    /// but only while it is still untouched — see `clearPrefillIfUntouched`.
    func setAmend(_ on: Bool) {
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
}
