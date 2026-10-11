import Foundation
import GitCore

/// Tags (B1, Task 4): New Tag… on a commit, Delete Tag… with Restore Tag, and the remote half —
/// Push Tag to <remote> and Delete from <remote>….
///
/// | action | runs | holds |
/// |---|---|---|
/// | create, delete, restore | through `mutate` | the mutation slot — local ref writes |
/// | the remotes set to fetch no tags (before the Delete Tag sheet) | a task, no claim | nothing: a config read |
/// | push a tag, delete one on a remote | on the network lane (`.pushTag`, `.deleteRemoteTag`) | the lane and the slot: both write on the server |
/// | read a remote tag's id (before the remote delete's sheet) | on the lane, as a `.fetch` | the lane only: it writes nothing |
///
/// The same promise as every confirmation here: each `confirm…` acts only as the answer to its
/// own sheet, and hands GitCore what the sheet showed — the tag's `objectID` for the local
/// compare-and-delete, the remote's unpeeled id as the remote delete's lease — so a tag that
/// moved while the sheet was up is refused by git, not by a re-read here that could be overtaken
/// in turn. The New Tag sheet's name is checked live (`validateNewTagName`) and again by
/// `createTag` itself, holding the slot.
///
/// A symbolic ref under `refs/tags` (`Tag.isSymbolic`) is never deleted or pushed: GitCore
/// refuses the delete, but its push and remote reads go by name and would follow it to the
/// branch it names — so the store refuses all three for one, and the menu says why.
///
/// No sentence is written here: they are all in `TagWording`.
extension RepositoryStore {

    // MARK: - Reading

    /// The tag of that name in the list on screen, or nil.
    func tag(named name: String) -> Tag? {
        snapshot?.refs.tags.first { $0.name == name }
    }

    /// The subject of `sha` when the (capped) log shows it, for the sheets' "on 1a2b3c4 Add x".
    func commitSubject(_ sha: String) -> String? {
        snapshot?.commits.first { $0.sha == sha }?.summary
    }

    /// Why Delete Tag… is off for `tag`, or nil: a symbolic ref, or a change running.
    func deleteTagBlockedReason(_ tag: Tag) -> String? {
        tag.isSymbolic ? TagWording.symbolicReason(tag.name) : changeRunningBlockedReason
    }

    /// Why Push Tag to <remote> and Delete from <remote>… are off for `tag`, or nil: a symbolic
    /// ref, or the lane or the slot busy (what every remote sheet's button says).
    func remoteTagBlockedReason(_ tag: Tag) -> String? {
        if tag.isSymbolic { return TagWording.symbolicReason(tag.name) }
        guard remoteGate.hasRepository else { return RemoteWording.noRepository }
        return sheetBusyReason
    }

    // MARK: - New Tag

    /// Opens New Tag… on the commit `sha` (a full object id: it is what `createTag` is given).
    func requestNewTag(at sha: String) {
        guard snapshot != nil, requestMayProceed() else { return }
        activeSheet = .newTag(sha: sha)
    }

    /// What is wrong with `name` as a new tag, or nil when nothing is — GitCore's check
    /// (`tagNameProblem`: `check-ref-format`, the refs, root-ref names, case folded). Reads only,
    /// no slot, so the sheet's debounced field can ask it. A name nothing could judge (no
    /// repository, git failed) is `.invalid`: Create must not be enabled on a name nobody
    /// vouched for.
    func validateNewTagName(_ name: String) async -> TagNameProblem? {
        let trimmed = BranchNameValidator.trim(name)
        guard !trimmed.isEmpty else { return .empty }
        guard let root else { return .invalid }
        do {
            return try await backend.tagNameProblem(trimmed, at: root)
        } catch {
            return .invalid
        }
    }

    /// Creates the tag the New Tag sheet describes — only as the answer to that sheet, on its
    /// commit. `message` nil is a lightweight tag. `createTag` checks the name again itself,
    /// holding the slot (a tag or branch of that name may have been made since the field's
    /// check), and refuses before git runs.
    func confirmNewTag(name: String, message: String?, at sha: String) {
        guard case .newTag(let shown) = activeSheet, shown == sha else { return }
        // `mutate` drops a call silently while the slot is held; the answer to a question must
        // not vanish like that. The sheet stays up so it can be answered again.
        guard !isMutating else {
            showStickyError(RemoteWording.mutationBusy)
            return
        }
        activeSheet = nil
        mutate({ backend, root in
            do {
                try await backend.createTag(name, at: sha, message: message, at: root)
            } catch {
                throw TagActionFailed(sentence: TagWording.failure(error, .create(name)))
            }
        }, onSuccess: { [self] in
            showNotice(TagWording.created(name, at: sha, annotated: message != nil))
        })
    }

    // MARK: - Delete and Restore

    /// Opens Delete Tag… for the tag of `tag`'s name as the list shows it now, with the remotes
    /// this session saw holding that very object, less the ones set to fetch no tags — read
    /// first (`remotesFetchingNoTags`, a local config read), so the sheet opens a moment later.
    /// A read that fails names no remote either way: the sheet then says only the general line.
    func requestDeleteTag(_ tag: Tag) {
        guard let current = self.tag(named: tag.name) else {
            showStickyError(TagWording.noSuchTag(tag.name))
            return
        }
        if let reason = deleteTagBlockedReason(current) {
            showStickyError(reason)
            return
        }
        guard let root else { return }
        let seen = remoteTagsSeen.remotes(having: current.name, objectID: current.objectID)
        let configured = Set(snapshot?.refs.remotes.map(\.name) ?? [])
        let generation = self.generation
        let backend = self.backend
        Task { [self] in
            let read = try? await backend.remotesFetchingNoTags(at: root)
            // Another repository, or another sheet the user opened meanwhile: not over it.
            guard self.generation == generation, activeSheet == nil else { return }
            let noTags = (read ?? []).filter(configured.contains)
            activeSheet = .deleteTag(
                current, comesBackFrom: read == nil ? [] : seen.filter { !noTags.contains($0) },
                noTagsFrom: noTags)
        }
    }

    /// Deletes the tag the sheet shows, only if it still holds the sheet's `objectID` (GitCore's
    /// compare-and-delete), and keeps its receipt — the only way back — in `deletedTags`, with the
    /// notice naming every tag still deleted (`recordTagDeleted`).
    func confirmDeleteTag(_ tag: Tag) {
        guard case .deleteTag(let shown, _, _) = activeSheet, shown == tag else { return }
        guard !isMutating else {
            showStickyError(RemoteWording.mutationBusy)
            return
        }
        activeSheet = nil
        mutate(result: { backend, root in
            do {
                return try await backend.deleteTag(tag, at: root)
            } catch {
                throw TagActionFailed(sentence: TagWording.failure(error, .delete(tag.name)))
            }
        }, onSuccess: { [self] receipt in
            recordTagDeleted(receipt)
        })
    }

    /// Restore Tag(s), from the notice or a deleted tag's row: recreates each tag at its
    /// receipt's id — the identical tag object for an annotated tag (B19) — one after the other.
    /// Receipts no longer kept (restored meanwhile, or back as they were) are skipped. A refusal
    /// — a tag of that name exists again — keeps that receipt, so the tag can still come back
    /// once the other is out of the way.
    func restoreTags(_ receipts: [TagReceipt]) {
        let pending = receipts.filter(deletedTags.receipts.contains)
        guard !pending.isEmpty else { return }
        // The notice's button is not disabled; a click that says nothing reads as broken.
        guard !isMutating else {
            showStickyError(RemoteWording.mutationBusy)
            return
        }
        mutate(result: { backend, root in
            var results: [(TagReceipt, Result<Void, any Error>)] = []
            for receipt in pending {
                do {
                    try await backend.restoreTag(receipt, at: root)
                    results.append((receipt, .success(())))
                } catch {
                    results.append((receipt, .failure(error)))
                }
            }
            return results
        }, onSuccess: { [self] results in
            finishTagRestore(results)
        })
    }

    /// What the restores came to: the ones back end their receipts and say so; each refusal is
    /// said in the banner and keeps its receipt.
    func finishTagRestore(_ results: [(TagReceipt, Result<Void, any Error>)]) {
        var back: [TagReceipt] = []
        var failures: [String] = []
        for (receipt, result) in results {
            switch result {
            case .success: back.append(receipt)
            case .failure(let error): failures.append(TagWording.failure(error, .restore(receipt.name)))
            }
        }
        forgetDeletedTags(back)
        if !back.isEmpty { showNotice(TagWording.restored(back)) }
        if !failures.isEmpty { showStickyError(failures.joined(separator: " ")) }
    }

    // MARK: - Push

    /// Pushes exactly `refs/tags/<name>` to `remote`, never forced, on the lane. A remote with
    /// a different tag of that name keeps it (`.rejectedExists`, a banner).
    func pushTag(_ name: String, to remote: String) {
        guard let local = tag(named: name) else {
            showStickyError(TagWording.noSuchTag(name))
            return
        }
        if let reason = remoteTagBlockedReason(local) {
            showStickyError(reason)
            return
        }
        let attempt = TagWording.Attempt.push(name, remote: remote)
        let objectID = local.objectID
        runOnLane(.pushTag, remote: remote, holdingMutation: true) { [self] backend, root, lane, _ in
            let outcome: TagPushOutcome
            do {
                outcome = try await backend.pushTag(name, to: remote, at: root)
            } catch where Self.isCancellation(error) {
                return LaneEnding(failure: TagWording.stopped(attempt))
            } catch {
                return LaneEnding(failure: TagWording.failure(error, attempt))
            }
            switch outcome {
            // This tag is there now.
            case .pushed, .alreadyThere: note(name, on: remote, id: objectID, lane: lane)
            // Another tag of that name is: not this one, so never claimed for it (I2).
            case .rejectedExists: note(name, on: remote, id: nil, lane: lane)
            case .failed: break
            }
            if let failure = TagWording.pushFailure(outcome, name, remote: remote) {
                return LaneEnding(failure: failure)
            }
            return LaneEnding(notice: TagWording.pushNotice(outcome, name, remote: remote))
        }
    }

    // MARK: - Delete on a remote

    /// Opens Delete from <remote>…: reads the tag's **unpeeled** id on `remote` on the lane
    /// (`remoteTagID`, one `ls-remote`), then the sheet — leased on that id, or saying the
    /// remote has no such tag. Holds only the lane: it writes nothing.
    func requestDeleteRemoteTag(_ name: String, on remote: String) {
        if let local = tag(named: name), let reason = remoteTagBlockedReason(local) {
            showStickyError(reason)
            return
        }
        let attempt = TagWording.Attempt.readRemote(name, remote: remote)
        runOnLane(.fetch, remote: remote, holdingMutation: false) { [self] backend, root, lane, _ in
            let id: String?
            do {
                id = try await backend.remoteTagID(name, on: remote, at: root)
                try Task.checkCancellation()
            } catch where Self.isCancellation(error) {
                return LaneEnding(notice: TagWording.stopped(attempt))
            } catch {
                return LaneEnding(failure: TagWording.failure(error, attempt))
            }
            note(name, on: remote, id: id, lane: lane)
            return LaneEnding(sheet: .deleteRemoteTag(name: name, remote: remote, id: id))
        }
    }

    /// Deletes the tag on `remote`, leased on the id the sheet showed: a tag that moved there
    /// — or went — since is refused by the server and worded (`.remoteTagMoved`). Only as the
    /// answer to that sheet.
    func confirmDeleteRemoteTag(_ name: String, on remote: String, expecting id: String) {
        guard case .deleteRemoteTag(let shownName, let shownRemote, let shownID?) = activeSheet,
            shownName == name, shownRemote == remote, shownID == id
        else { return }
        // Asked before the sheet closes, as Confirm on New Tag and Delete Tag asks: a lane or
        // slot already taken (or a quit under way) is said with the sheet still up to answer
        // again, never after it went (final fix wave, Minor 3).
        if let refusal = laneClaimRefusal(.deleteRemoteTag, holdingMutation: true) {
            showStickyError(refusal)
            return
        }
        activeSheet = nil
        let attempt = TagWording.Attempt.deleteRemote(name, remote: remote)
        // Whether the hint's `git push <id>:…` has an object here to send (Minor 4).
        let objectIsHere = snapshot?.refs.tags.contains { $0.objectID == id || $0.sha == id } ?? false
        runOnLane(.deleteRemoteTag, remote: remote, holdingMutation: true) { [self] backend, root, lane, _ in
            do {
                try await backend.deleteRemoteTag(name, on: remote, expecting: id, at: root)
            } catch where Self.isCancellation(error) {
                return LaneEnding(failure: TagWording.stopped(attempt))
            } catch {
                // Moved or gone there: what it holds now is not known, so it is not claimed.
                if case TagOperationError.remoteTagMoved = error {
                    note(name, on: remote, id: nil, lane: lane)
                }
                return LaneEnding(failure: TagWording.failure(error, attempt))
            }
            note(name, on: remote, id: nil, lane: lane)
            return LaneEnding(
                notice: TagWording.deletedOnRemote(name, remote: remote, id: id, objectIsHere: objectIsHere))
        }
    }

    /// What a remote answered about a tag, kept only for the repository the lane belongs to.
    private func note(_ name: String, on remote: String, id: String?, lane: RemoteLane) {
        guard generation == lane.generation else { return }
        noteRemoteTag(name, on: remote, id: id)
    }
}
