import Foundation
import GitCore

/// What Stash and Continue would do for one refusal: stash every change under `message` —
/// untracked files too when the refusal named one — then run `action` again as it was asked.
struct StashAndContinueOffer: Equatable {
    /// Run again as it is (`RepositoryStore.retry`). A `.pull` is the exception: only its
    /// integrate step was refused (the merge step, or the diverged sheet's Rebase, both recorded
    /// here with the sheet's answer), so `retryPull` runs no fetch: it decides again on the
    /// stash's reload and keeps the answer while the branch is diverged from the same upstream.
    let action: PendingBranchAction
    /// The refusal named an untracked file: a stash without `-u` would leave it in the way, and
    /// the retry would be refused over it again.
    let includeUntracked: Bool
    /// `Gitter: before switching to b`, `… merging b`, `… pulling` (`StashWording`).
    let message: String
    /// What was refused. `.treeNotClean` (a pull's rebase) is the one refusal a change inside
    /// a submodule can cause, which a stash cannot hold; the nothing-stashed sentence says so
    /// only then.
    let refusal: BranchOperationError
}

/// Which refusals a stash answers. Pure.
enum StashAndContinue {

    /// The offer for `refusal`, or nil.
    ///
    /// Offered for the three refusals over local changes (M 12): `.wouldOverwrite` (switch,
    /// checkout, merge, a pull's merge step, and a rebase over an untracked file),
    /// `.indexNotClean` (a true merge or a squash over any staged change — a stash resets the
    /// index to HEAD, so the retry passes merge-ort's check and `requireACleanIndexForASquash`)
    /// and `.treeNotClean` (a pull's rebase). Never for anything else — a name, a branch, a
    /// moved tip, or an operation part-way through, where `stashAll` refuses anyway.
    static func offer(for refusal: BranchOperationError, action: PendingBranchAction)
        -> StashAndContinueOffer?
    {
        let untracked: Bool
        switch refusal {
        case .wouldOverwrite(_, let named):
            untracked = !named.isEmpty
        case .treeNotClean, .indexNotClean:
            // Neither is about an untracked file: a rebase refuses over one as
            // `.wouldOverwrite(untracked:)` instead (M 12), and merge-ort's index check
            // looks only at the index.
            untracked = false
        case .operationInProgress, .invalidName, .branchExists,
            .cannotDeleteCurrent, .branchMoved, .noSuchBranch, .noOperationInProgress,
            .operationMismatch:
            return nil
        }
        return StashAndContinueOffer(
            action: action, includeUntracked: untracked,
            message: StashWording.continueMessage(for: action), refusal: refusal)
    }

    /// The offer for a history action's refusal (`HistoryRefusal`), or nil: only
    /// `.trackedChanges` — GitCore refuses every tracked change, staged or not, before git runs,
    /// and never an untracked file — so it is offered as a pull's rebase is (`.treeNotClean`,
    /// no `-u`). `action` is a `.history` or `.rebaseOnto`, which `retry` plans again and puts
    /// back on screen as a sheet: a stash never runs the action without its confirmation.
    static func offer(forHistory refusal: HistoryRefusal, action: PendingBranchAction)
        -> StashAndContinueOffer?
    {
        guard case .trackedChanges = refusal else { return nil }
        return offer(for: .treeNotClean, action: action)
    }

    /// `error` as the action that met it throws it on: a `BranchActionFailure` a stash answers
    /// comes back carrying the offer, with its sentence unchanged; anything else — another
    /// refusal, git's own words — is returned as it is.
    static func offering(_ error: Error, for action: PendingBranchAction) -> Error {
        guard let failure = error as? BranchActionFailure,
            let offer = offer(for: failure.refusal, action: action)
        else { return error }
        return RefusalWithStashOffer(failure: failure, offer: offer)
    }
}

/// A refusal Stash and Continue answers: the refusal's own sentence, carrying the offer to
/// `finishMutation`, which puts both up together — and only for the generation the refusal
/// belongs to. `failure` is a `BranchActionFailure`, or a history action's refusal
/// (`HistoryActionRefused`, `HistoryWording.error(_:for:)`).
struct RefusalWithStashOffer: LocalizedError {
    let failure: any LocalizedError
    let offer: StashAndContinueOffer

    var errorDescription: String? { failure.errorDescription }
}

/// Stash and Continue: the error banner's answer to a switch, merge or pull refused over local
/// changes.
///
/// 1. `stashAll(message:includeUntracked:)`, through `beginMutation`/`finishMutation` like any
///    other write, its refusals in `StashWording`'s sentences.
/// 2. Filed (`.saved`): the sticky notice `Your changes are in stash "…".` with Pop Stash goes
///    up **first**, then the action runs again (`retry`; a pull without its fetch, `retryPull`).
///    Whatever the retry ends in — done, a conflict, another refusal, the pull's Merge-or-Rebase
///    sheet when its upstream changed — the notice is already there, and a notice the retry
///    shows after it does not replace one with a button (`NoticeSlot.choose`).
/// 3. Anything else runs nothing more: nothing filed (the refusal may or may not still apply),
///    a stash git refused, or one filed with an error (the changes may be in both places). The
///    banner says which.
///
/// The stash is never popped here; the notice offers it.
extension RepositoryStore {

    /// Why Stash and Continue is off right now, or nil (also nil when nothing is offered): a
    /// sheet is up, another change is running, or the action it would run again is itself
    /// blocked — checked **before** stashing, so a stash is never filed for a retry that could
    /// not start. A pull offer is checked on everything `pullBlocked` asks except the lane and
    /// the fetch URL (`RemoteWording.pullRetryBlocked`): its retry runs no fetch (`retryPull`),
    /// so a Fetch on the lane does not turn the button off, but a detached HEAD or an upstream
    /// gone since the refusal does.
    var stashAndContinueBlockedReason: String? {
        guard let offer = offeredStashAndContinue else { return nil }
        if activeSheet != nil { return StashWording.blockedBySheet }
        if isMutating { return StashWording.busy }
        if case .pull = offer.action { return RemoteWording.pullRetryBlocked(remoteGate) }
        return branchSwitchingBlockedReason
    }

    /// The banner's Stash and Continue. Does nothing unless the banner on screen is the refusal
    /// the offer was made for (`offeredStashAndContinue`).
    func stashAndContinue() {
        guard let offer = offeredStashAndContinue else { return }
        if let reason = stashAndContinueBlockedReason {
            // The button is off already; a stale call still says why rather than nothing.
            showStickyError(reason)
            return
        }
        // Not `mutate`: its `onSuccess` runs while the slot is still held, and the retry must
        // claim the slot itself. Here the release and the retry happen in one synchronous run
        // on the main actor, so nothing can take the slot between them.
        guard let root, let generation = beginMutation() else { return }
        Task { @MainActor [self] in
            var failure: Error?
            var outcome: StashPushOutcome?
            do {
                outcome = try await Self.reportingStash(.stash, nil, root: root) {
                    try await backend.stashAll(
                        message: offer.message, includeUntracked: offer.includeUntracked,
                        at: root)
                }
            } catch {
                failure = error
            }
            await refresh()
            finishMutation(generation: generation, failure: failure)
            guard self.generation == generation, failure == nil, let outcome else { return }
            continueAfterStash(outcome, offer: offer)
        }
    }

    private func continueAfterStash(_ outcome: StashPushOutcome, offer: StashAndContinueOffer) {
        switch outcome {
        case .saved(let stash):
            showStickyNotice(
                Notice(text: StashWording.continued(stash: stash), actions: [.popStash(stash)]))
            retry(offer.action)
        case .nothingToSave:
            showStickyError(StashWording.continueNothingStashed(offer))
        case .savedWithError(let stash, let gitsWords, let trashed):
            showStickyError(
                StashWording.continueSavedWithError(
                    stash, gitsWords: gitsWords, trashed: trashed, action: offer.action))
        }
    }
}
