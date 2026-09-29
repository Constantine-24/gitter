import Foundation
import GitCore

/// The stash: Stash Changes…, Apply, Pop and Drop Stash….
///
/// Stashing is not a loss — it moves work into an entry that can be seen and brought back — so
/// Stash Changes… asks only for a message. Dropping is: it has its confirmation, which carries
/// the entry's sha and position, and the confirm hands that very `Stash` to GitCore, whose
/// verified drop refuses if `stash@{index}` no longer names it. Pop drops only after a clean
/// apply, and only that entry (GitCore again); a pop whose entry stayed says so
/// (`.appliedButKept`).
///
/// Every write goes through `mutate`. The outcomes that must be read — nothing stashed, a push
/// that failed after filing, a conflict, a partial or refused apply — are sticky banners; a clean
/// stash, apply or pop is a notice. `StashWording` holds every sentence.
extension RepositoryStore {

    /// The stash list, newest first (`stash@{0}` first), from the snapshot.
    var stashes: [Stash] { snapshot?.stashes ?? [] }

    // MARK: - Why an action is off

    /// Why Stash Changes… is off right now, or nil when it is available: a sheet is up, an
    /// operation is in progress, another change is running, an intent-to-add entry exists (git
    /// refuses to push one, M 14), or there is nothing to stash. GitCore refuses the first,
    /// third and fourth itself too; this is the explanation before the click.
    var stashBlockedReason: String? {
        guard root != nil, let status = snapshot?.status else { return StashWording.nothingToStash }
        if activeSheet != nil { return StashWording.blockedBySheet }
        if let operation = operationInProgress {
            return StashWording.refusal(.operationInProgress(operation), verb: .stash, stash: nil)
        }
        if isMutating { return StashWording.busy }
        let intentToAdd = status.files.filter(\.isIntentToAdd).map(\.path)
        if !intentToAdd.isEmpty {
            return StashWording.refusal(.intentToAdd(intentToAdd), verb: .stash, stash: nil)
        }
        if status.files.isEmpty { return StashWording.nothingToStash }
        return nil
    }

    /// Why Apply, Pop and Drop Stash… are off right now, or nil: a sheet is up, an operation is
    /// in progress, or another change is running.
    var stashActionBlockedReason: String? {
        if activeSheet != nil { return StashWording.blockedBySheet }
        if let operation = operationInProgress { return StashWording.actionsBlocked(by: operation) }
        if isMutating { return StashWording.busy }
        return nil
    }

    /// What the sheet's "Selected files" stashes: the working copy's selected file, with a
    /// rename's original path (a rename is two index entries, and half of one must not stay
    /// staged). Empty when the pane shows no working-copy file.
    var selectedPathsForStash: [String] {
        guard selection == .workingCopy, let selectedPath,
            let file = snapshot?.status.files.first(where: { $0.path == selectedPath })
        else { return [] }
        return [file.path] + (file.originalPath.map { [$0] } ?? [])
    }

    // MARK: - Stash Changes…

    /// Opens the Stash Changes… sheet — the Repository menu's ⌥⌘S and the working copy's
    /// button. Does nothing while `stashBlockedReason` says why not.
    func requestStash() {
        guard stashBlockedReason == nil else { return }
        activeSheet = .stash(selectedPaths: selectedPathsForStash)
    }

    /// The sheet's Stash. `onlySelected` stashes the paths the sheet was opened with
    /// (`stashPaths`); otherwise every change (`stashAll`), untracked files only when asked. An
    /// empty message is git's own `WIP on …` for a full stash, and the files' names for a
    /// path-limited one.
    func confirmStash(message: String, includeUntracked: Bool, onlySelected: Bool) {
        guard case .stash(let selected) = activeSheet else { return }
        activeSheet = nil
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        mutate(result: { backend, root in
            try await Self.reportingStash(.stash, nil, root: root) {
                if onlySelected {
                    try await backend.stashPaths(
                        selected,
                        message: trimmed.isEmpty
                            ? StashWording.defaultMessage(forPaths: selected) : trimmed,
                        at: root)
                } else {
                    try await backend.stashAll(
                        message: trimmed.isEmpty ? nil : trimmed,
                        includeUntracked: includeUntracked, at: root)
                }
            }
        }, onSuccess: { [self] outcome in
            let text = StashWording.pushOutcome(
                outcome, includeUntracked: includeUntracked, onlySelected: onlySelected)
            switch outcome {
            case .saved(let stash):
                // Sticky, with the way back: the entry's own Pop.
                showStickyNotice(Notice(text: text, actions: [.popStash(stash)]))
            case .nothingToSave, .savedWithError:
                showStickyError(text)
            }
        })
    }

    // MARK: - Apply and pop

    func applyStash(_ stash: Stash) {
        applyOrPop(stash, popping: false)
    }

    /// GitCore checks `stash@{index}` is still the entry first, and refuses otherwise.
    func popStash(_ stash: Stash) {
        applyOrPop(stash, popping: true)
    }

    /// The sticky notice's Pop Stash, which may be pressed long after the notice went up. The
    /// notice holds the entry as it was filed, `stash@{0}`, and any push since — a terminal, a
    /// discard's record — moves it down, so it is found again by sha in the list on screen and
    /// popped at the position it has now (GitCore still checks that position names the sha).
    /// No longer listed: the notice and its button give way to a sentence that says so, and
    /// nothing is attempted.
    func popOfferedStash(_ offered: Stash) {
        guard let current = StashList.resolve(sha: offered.sha, in: stashes) else {
            showStickyNotice(Notice(text: StashWording.offeredStashGone))
            return
        }
        popStash(current)
    }

    private func applyOrPop(_ stash: Stash, popping: Bool) {
        if let reason = stashActionBlockedReason {
            // The menu items are off already; a notice's button is not, and a click that does
            // nothing and says nothing reads as a broken button.
            showStickyError(reason)
            return
        }
        mutate(result: { backend, root in
            try await Self.reportingStash(popping ? .pop : .apply, stash, root: root) {
                popping
                    ? try await backend.pop(stash, at: root)
                    : try await backend.apply(stash, at: root)
            }
        }, onSuccess: { [self] outcome in
            let text = StashWording.applyOutcome(outcome, of: stash, popping: popping)
            if StashWording.isNotice(outcome) {
                showNotice(text)
            } else {
                showStickyError(text)
            }
            if outcome == .applied {
                switch Self.stickyNoticeChange(stickyNotice, afterRestoring: stash, popping: popping) {
                case .keep: break
                case .dismiss: dismissStickyNotice()
                case .replace(let notice): showStickyNotice(notice)
                }
            }
        })
    }

    /// What the sticky notice becomes after a clean apply or pop of `stash` (final review M1).
    /// A Pop Stash offering the popped entry goes. An Undo Discard whose record is that entry
    /// would contradict what just happened — refused, or the changes put back twice — so its
    /// receipt goes: the notice with it, or, when Discard All… also moved items to the Trash,
    /// the notice says and undoes only those. By sha, never by position.
    static func stickyNoticeChange(_ notice: Notice?, afterRestoring stash: Stash, popping: Bool) -> StickyNoticeChange {
        guard let notice else { return .keep }
        for action in notice.actions {
            switch action {
            case .popStash(let offered) where popping && offered.sha == stash.sha:
                return .dismiss
            case .undoDiscard(let receipts) where receipts.contains(where: { $0.record?.sha == stash.sha }):
                let rest = receipts.filter { $0.record?.sha != stash.sha && DiscardWording.isUndoable($0) }
                guard !rest.isEmpty else { return .dismiss }
                return .replace(Notice(text: DiscardWording.done(rest), actions: [.undoDiscard(rest)]))
            default:
                continue
            }
        }
        return .keep
    }

    enum StickyNoticeChange: Equatable {
        case keep, dismiss
        case replace(Notice)
    }

    // MARK: - Drop Stash…

    func requestDropStash(_ stash: Stash) {
        guard stashActionBlockedReason == nil else { return }
        activeSheet = .dropStash(stash)
    }

    /// The drop sheet's Drop Stash, **only** as the answer to the sheet that named this entry.
    /// The `Stash` goes to GitCore as the sheet had it — sha *and* position — and GitCore's
    /// verified drop refuses (`.stashListChanged`) when `stash@{index}` no longer names that
    /// sha, so an entry that moved or went while the sheet was up is never dropped in its
    /// place.
    func confirmDropStash(_ stash: Stash) {
        guard case .dropStash(let shown) = activeSheet, shown == stash else { return }
        activeSheet = nil
        mutate({ backend, root in
            try await Self.reportingStash(.drop, stash, root: root) {
                try await backend.drop(stash, at: root)
            }
        }, onSuccess: { [self] in
            dismissStickyNotice(offeringToPop: stash)
            // Sticky: it holds the only copy of the sha once the entry is gone.
            showStickyNotice(Notice(text: StashWording.dropped(stash)))
        })
    }

    /// What the drop sheet lists: the entry's files, read when it opens. Nil when it cannot be
    /// read (the sheet then says so through its stale line or shows no list). Writes nothing
    /// and takes no mutation lock.
    func loadStashContents(_ stash: Stash) async -> StashContents? {
        guard let root else { return nil }
        return try? await backend.stashContents(stash, at: root)
    }

    // MARK: - Helpers

    /// A sticky notice whose Pop Stash names `stash` is out of date once the entry is gone.
    private func dismissStickyNotice(offeringToPop stash: Stash) {
        if stickyNotice?.actions.contains(where: {
            if case .popStash(let offered) = $0 { offered.sha == stash.sha } else { false }
        }) == true {
            dismissStickyNotice()
        }
    }

    /// Runs `work`, turning GitCore's `StashRefusal` into its sentence. Anything else — git's
    /// own words, such as the exit 128 for a path inside a file/folder swap — goes to the banner
    /// as it is (`describe`).
    static func reportingStash<T>(
        _ verb: StashVerb, _ stash: Stash?, root: URL, _ work: () async throws -> T
    ) async throws -> T {
        do {
            return try await work()
        } catch let refusal as StashRefusal {
            if case .pathTypeChanged(let paths) = refusal {
                throw StashMessage(
                    text: StashWording.typeChanged(
                        paths.map { typeChange(of: $0, under: root) }, verb: verb, stash: stash))
            }
            throw StashMessage(text: StashWording.refusal(refusal, verb: verb, stash: stash))
        }
    }

    /// Which shape of file/folder swap `path` is on disk now, read with `lstat` semantics: a
    /// leading component that is no longer a folder, or the path itself now a folder. Neither
    /// (it changed again since GitCore looked) is `.changed`.
    nonisolated static func typeChange(of path: String, under root: URL) -> StashWording.TypeChange {
        let components = path.split(separator: "/").map(String.init)
        var url = root
        for (offset, component) in components.dropLast().enumerated() {
            url = url.appending(path: component)
            guard let type = fileType(url) else { return .changed(path) }
            if type != .typeDirectory {
                return .folderBecameFile(
                    path: path, file: components[...offset].joined(separator: "/"))
            }
        }
        if fileType(root.appending(path: components.joined(separator: "/"))) == .typeDirectory {
            return .fileBecameFolder(components.joined(separator: "/"))
        }
        return .changed(path)
    }

    private nonisolated static func fileType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    #if DEBUG
        /// The harness's `stashpaths:` step: the sheet as if these files had been selected.
        func debugRequestStash(paths: [String]) {
            guard stashBlockedReason == nil else { return }
            activeSheet = .stash(selectedPaths: paths)
        }
    #endif
}

/// Finding an entry again in the stash list.
enum StashList {
    /// The entry whose sha is `sha`, at the position it has in `stashes` now; nil when it is no
    /// longer listed. By sha only: a position is whatever entry is there now, and an entry
    /// pushed since moves every other one down.
    static func resolve(sha: String, in stashes: [Stash]) -> Stash? {
        stashes.first { $0.sha == sha }
    }
}

/// A stash refusal, in `StashWording`'s sentence, for the banner.
struct StashMessage: LocalizedError {
    let text: String
    var errorDescription: String? { text }
}
