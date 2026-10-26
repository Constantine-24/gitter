import Foundation
import GitCore

/// What a stash action was, for the sentences that name it: "Can't **pop stash "x"** …".
enum StashVerb: Sendable {
    case stash, apply, pop, drop
}

/// Every sentence the stash puts on screen: the outcome of a push, an apply or a pop, the
/// refusals, the drop sheet and its notice, and why the actions are off.
///
/// Pure: nothing here reads the store, the disk or git. `StashWordingTests` pins each one.
enum StashWording {

    // MARK: - Names

    /// Quoted and capped: `"a"`, `"a" and "b"`, `"a", "b" and "c"`, then `"a", "b", "c" and N
    /// more`. A banner listing forty paths is not one anybody reads.
    static func names(_ paths: [String]) -> String {
        list(paths.map { "\"\($0)\"" })
    }

    /// What a stash is called, in the list, its header and every sentence: *named by what wrote
    /// it*. The user's message is shown as they wrote it; a subject git wrote (`WIP on main:
    /// 2153ff9 root`) or Gitter wrote (`Discarded by Gitter: a.txt`) is shown whole; an empty one
    /// is its position.
    static func title(_ stash: Stash) -> String {
        let text = stash.isGitDefault ? stash.reflogSubject : stash.message
        return text.isEmpty ? position(stash) : text
    }

    /// A stash in a sentence: its title in quotes, or its position when it has no title.
    static func name(_ stash: Stash) -> String {
        let title = title(stash)
        return title == position(stash) ? title : "\"\(title)\""
    }

    private static func position(_ stash: Stash) -> String { "stash@{\(stash.index)}" }

    /// The message a path-limited stash gets when the sheet's field was left empty: the files,
    /// unquoted, capped like `names`. (`stashPaths` files `On <branch>: <message>` and has no
    /// default of git's own to fall back on.)
    static func defaultMessage(forPaths paths: [String]) -> String {
        list(paths)
    }

    private static func list(_ items: [String], separator: String = ", ") -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        case 2, 3: return items.dropLast().joined(separator: separator) + " and " + items.last!
        default: return items.prefix(3).joined(separator: separator) + " and \(items.count - 3) more"
        }
    }

    /// git's words in a sentence: one line, and the full stop the sentence needs.
    private static func sentence(_ words: String) -> String {
        let flat = words.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard let last = flat.last, !".!?".contains(last) else { return flat }
        return flat + "."
    }

    private static func words(_ words: String) -> String {
        words.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    /// "is"/"are", "it"/"them" and the like, by how many things a sentence names.
    private static func number(_ count: Int, _ one: String, _ many: String) -> String {
        count == 1 ? one : many
    }

    // MARK: - Push outcomes

    /// What a Stash Changes… did. `.saved` is the notice; `.nothingToSave` and
    /// `.savedWithError` are banners (see `RepositoryStore.confirmStash`).
    static func pushOutcome(
        _ outcome: StashPushOutcome, includeUntracked: Bool, onlySelected: Bool
    ) -> String {
        switch outcome {
        case .saved(let stash):
            return "Your changes are in stash \(name(stash))."
        case .nothingToSave:
            if onlySelected { return "Nothing was stashed: the selected files have no changes." }
            if includeUntracked { return "Nothing was stashed: there are no changes a stash can hold." }
            return "Nothing was stashed: there are no changes to tracked files. Untracked files "
                + "are stashed only with \"Include untracked files\"."
        case .savedWithError(let stash, let gitsWords, let trashed):
            var text =
                "Your changes are in stash \(name(stash)); git also said: \(words(gitsWords)); "
                + "some may still be in your files."
            if !trashed.isEmpty {
                text += " Already moved to the Trash: \(names(trashed.keys.sorted()))."
            }
            return text
        }
    }

    // MARK: - Apply and pop outcomes

    /// Whether this outcome is a success notice. Everything else is a banner that stays until it
    /// is read: a conflict, a partial apply, a refusal, a failure — and an apply whose entry was
    /// kept, which must not be mistaken for a pop.
    static func isNotice(_ outcome: StashApplyOutcome) -> Bool {
        outcome == .applied
    }

    static func applyOutcome(_ outcome: StashApplyOutcome, of stash: Stash, popping: Bool) -> String {
        let name = name(stash)
        let kept = popping ? "The stash is kept, not dropped." : "The stash is kept."
        switch outcome {
        case .applied:
            return popping
                ? "Popped stash \(name): applied and dropped."
                : "Applied stash \(name). It stays in the list."
        case .appliedButKept(let reason):
            return "Applied stash \(name), but it was not dropped: \(sentence(reason)) It is "
                + "still in the list."
        case .conflicts(let paths):
            return "Stash \(name) applied with conflicts in \(names(paths)). Resolve them, then "
                + "stage the files. \(kept)"
        case .partiallyApplied(let files):
            let clause =
                files.count == 1
                ? "a file of that name already exists and was left as it is"
                : "files of those names already exist and were left as they are"
            return "Stash \(name) applied, except its untracked \(names(files)): \(clause). \(kept)"
        case .refused(let files):
            let advice =
                isLinesRecord(stash)
                ? "Stage or commit \(number(files.count, "its", "their")) other changes first."
                : "Commit, stash or move \(number(files.count, "it", "them")) first."
            return "Can't \(popping ? "pop" : "apply") stash \(name): it would overwrite "
                + "\(names(files)). \(advice) Nothing changed."
        case .failed(let gitsWords):
            return "Couldn't \(popping ? "pop" : "apply") stash \(name): \(sentence(gitsWords)) "
                + kept
        }
    }

    /// Whether `stash` is the record of a line discard (`Discarded by Gitter: <n> line(s) in
    /// <name>`, `DiscardRequest.recordMessage`). It holds the whole file as it was, so git
    /// refuses to apply it while the file's other changes are unstaged, and applies it once they
    /// are staged (measured, final review M2).
    static func isLinesRecord(_ stash: Stash) -> Bool {
        guard stash.kind == .discarded else { return false }
        let rest = stash.reflogSubject.dropFirst(Stash.discardPrefix.count)
        let count = rest.prefix { $0.isASCII && $0.isNumber }
        guard !count.isEmpty else { return false }
        let after = rest.dropFirst(count.count)
        return after.hasPrefix(" line in ") || after.hasPrefix(" lines in ")
    }

    // MARK: - Refusals

    /// "Can't <attempt>" — `stash`, or the verb with the stash it was about.
    private static func attempt(_ verb: StashVerb, _ stash: Stash?) -> String {
        let named = stash.map { " stash \(name($0))" } ?? " a stash"
        switch verb {
        case .stash: return "stash"
        case .apply: return "apply" + named
        case .pop: return "pop" + named
        case .drop: return "drop" + named
        }
    }

    /// Completes "while …".
    static func inProgress(_ operation: RepositoryOperation) -> String {
        switch operation {
        case .merge: "a merge is in progress"
        case .cherryPick: "a cherry-pick is in progress"
        case .revert: "a revert is in progress"
        case .rebase: "a rebase is in progress"
        case .applyingPatches: "git am is applying patches"
        case .squash: "a squash is pending"
        }
    }

    /// GitCore's refusal as a banner: nothing was written.
    ///
    /// `.pathTypeChanged` without a disk reading takes the neutral phrase for each path; the
    /// store reads what each path is now and calls `typeChanged` instead.
    static func refusal(_ refusal: StashRefusal, verb: StashVerb, stash: Stash?) -> String {
        let attempt = attempt(verb, stash)
        switch refusal {
        case .operationInProgress(let operation):
            return "Can't \(attempt) while \(inProgress(operation)). Commit or abort it first."
        case .unmergedPaths(let paths):
            return "Can't \(attempt): \(names(paths)) \(number(paths.count, "has", "have")) "
                + "unresolved conflicts. Resolve them and stage the files first."
        case .intentToAdd(let paths):
            let it = number(paths.count, "it", "them")
            return "Can't \(attempt): \(names(paths)) \(number(paths.count, "is", "are")) only "
                + "marked to be added (git add -N). Stage \(it) fully or unstage \(it) first."
        case .submodules(let paths):
            return "Can't \(attempt): \(names(paths)) "
                + "\(number(paths.count, "is a submodule", "are submodules")), and a stash can't "
                + "hold the work inside one."
        case .nestedRepositories(let paths):
            // Also a path inside a submodule: "another repository" is true of both.
            return "Can't \(attempt): \(names(paths)) \(number(paths.count, "belongs", "belong")) "
                + "to another repository (a submodule, or a repository inside this one), and a "
                + "stash can't hold \(number(paths.count, "its", "their")) files."
        case .pathTypeChanged(let paths):
            return typeChanged(paths.map { .changed($0) }, verb: verb, stash: stash)
        case .stashListChanged:
            let nothing =
                switch verb {
                case .drop: "Nothing was dropped."
                case .pop: "Nothing was applied or dropped."
                case .apply, .stash: "Nothing was applied."
                }
            guard let stash else { return "The stash list changed since it was read. \(nothing)" }
            return "The stash list changed since it was read: \(name(stash)) is no longer "
                + "stash@{\(stash.index)}. \(nothing)"
        case .nothingSelected:
            return "Select the files to stash first."
        }
    }

    /// A file and a folder that swapped places, as the disk shows it now.
    enum TypeChange: Hashable, Sendable {
        /// A tracked file (or link) whose path is now a real folder: `p` → `p/x`.
        case fileBecameFolder(String)
        /// `path` is tracked under `file`, which was a folder and is now a file or a link.
        case folderBecameFile(path: String, file: String)
        /// Neither shape is on disk any more (it changed again); said without a direction.
        case changed(String)

        var phrase: String {
            switch self {
            case .fileBecameFolder(let path): "\"\(path)\" was a file and is now a folder"
            case .folderBecameFile(let path, let file):
                "\"\(file)\" was a folder (holding \"\(path)\") and is now a file"
            case .changed(let path): "\"\(path)\" changed between a file and a folder"
            }
        }
    }

    static func typeChanged(_ changes: [TypeChange], verb: StashVerb, stash: Stash? = nil) -> String {
        let phrases = changes.map(\.phrase)
        let shown =
            phrases.count > 3
            ? phrases.prefix(3).joined(separator: "; ") + "; and \(phrases.count - 3) more"
            : phrases.joined(separator: "; ")
        return "Can't \(attempt(verb, stash)): \(shown). A stash would lose what is there now. "
            + "Put it back, or commit the change first."
    }

    // MARK: - Drop

    /// The notice after a drop: the only place the sha is still written down once the entry is
    /// gone, and what brings it back (the commit lives until git's garbage collection).
    static func dropped(_ stash: Stash) -> String {
        let short = String(stash.sha.prefix(7))
        return "Dropped \(name(stash)) (\(short)). \"git stash apply \(short)\" brings it "
            + "back until git's cleanup removes it."
    }

    static func dropTitle(_ stash: Stash) -> String {
        "Drop stash \(name(stash))?"
    }

    static let dropBody =
        "It is removed from the Stashes list, and the changes it holds go with it — unless they "
        + "are in your files too."

    static let dropFilesLabel = "Files"
    static let dropShaLabel = "Stash commit"
    static let dropReading = "Reading its files…"
    static let dropUnreadable = "Its files could not be read."
    static let dropButton = "Drop Stash"

    /// The tracked files, then `+ untracked` and the untracked ones.
    static func dropFiles(tracked: [String], untracked: [String]) -> String {
        switch (tracked.isEmpty, untracked.isEmpty) {
        case (true, true): "No files."
        case (false, true): names(tracked)
        case (true, false): "untracked \(names(untracked))"
        case (false, false): "\(names(tracked)) + untracked \(names(untracked))"
        }
    }

    /// The sheet's live stale line: the entry went away (`movedTo` nil) or moved. Either way the
    /// confirm hands GitCore the position the sheet was opened with, which refuses.
    static func dropSheetStale(movedTo index: Int?) -> String {
        guard let index else { return "This stash is no longer in the list. Drop Stash will be refused." }
        return "The stash list changed: this stash is now stash@{\(index)}. Drop Stash will be "
            + "refused; close this and ask again."
    }

    // MARK: - The notice's Pop Stash

    /// What replaces a "stashed" notice whose Pop Stash is pressed after its entry was popped or
    /// dropped elsewhere: nothing was attempted, and the button is gone with the notice.
    static let offeredStashGone = "That stash is no longer in the list."

    // MARK: - Stash and Continue

    /// The error banner's button beside a switch, merge or pull refused over local changes.
    static let continueButton = "Stash and Continue"

    /// The message the stash is filed under (git adds `On <branch>: `): what was about to
    /// happen, so the entry says why it is there when it turns up in the list weeks later.
    /// Unquoted, as the spec writes it: a branch name holds no space, and every sentence that
    /// names a stash quotes its message already (`stash "Gitter: before merging b"`).
    static func continueMessage(for action: PendingBranchAction) -> String {
        switch action {
        case .switchTo(let branch): "Gitter: before switching to \(branch)"
        case .createAndSwitch(let name, _): "Gitter: before switching to \(name)"
        case .track(let remoteBranch): "Gitter: before checking out \(remoteBranch)"
        case .detach(let revision): "Gitter: before checking out \(revision)"
        case .merge(let branch, _): "Gitter: before merging \(branch)"
        case .pull: "Gitter: before pulling"
        case .history(.cherryPick, let shas):
            "Gitter: before cherry-picking \(HistoryWording.count(shas.count))"
        case .history(.revert, let shas): "Gitter: before reverting \(HistoryWording.count(shas.count))"
        case .rebaseOnto(let target): "Gitter: before rebasing onto \(HistoryWording.bareTarget(target))"
        }
    }

    /// The sticky notice, with Pop Stash, put up once the stash is filed and before the retry
    /// runs — so it stays whatever the retry ends in: done, a conflict, a new refusal, the
    /// pull's question. Stash Changes…'s own sentence for a filed entry, so the two cannot
    /// drift apart.
    static func continued(stash: Stash) -> String {
        pushOutcome(.saved(stash), includeUntracked: false, onlySelected: false)
    }

    /// `stashAll` filed nothing, so nothing was run: the changes git named may be gone (then the
    /// retry would work). Only for a pull's rebase (`.treeNotClean`) can the cause also be a
    /// change a stash cannot hold — a submodule with changes inside it, which Gitter's own
    /// clean-tree check refuses over and a stash leaves where it is — so only that sentence
    /// says so. A switch or merge is refused by git over files, never over a submodule's
    /// content.
    static func continueNothingStashed(_ offer: StashAndContinueOffer) -> String {
        let text =
            "Nothing was stashed: there are no changes a stash can hold, so Gitter did not try "
            + "to \(offer.action.summary) again. If the changes are gone, try again"
        guard offer.refusal == .treeNotClean else { return text + "." }
        return text + "; a change inside a submodule has to be committed in the submodule."
    }

    /// The entry was filed and something after it failed: the changes are in the stash and may
    /// still be in the files, so nothing was run on top of them.
    static func continueSavedWithError(
        _ stash: Stash, gitsWords: String, trashed: [String: URL], action: PendingBranchAction
    ) -> String {
        pushOutcome(
            .savedWithError(stash, gitsWords: gitsWords, trashed: trashed),
            includeUntracked: false, onlySelected: false)
            + " Gitter did not try to \(action.summary) again."
    }

    // MARK: - The Stash Changes… sheet

    static let sheetTitle = "Stash Changes"
    static let messagePlaceholder = "Message (optional)"
    static let includeUntracked = "Include untracked files"
    static let allChanges = "All changes"
    static func selectedFiles(_ count: Int) -> String { "Selected files (\(count))" }
    static let stashButton = "Stash"
    static let selectedUntrackedNote =
        "Selected untracked files go into the stash too, and are then moved to the Trash."
    static let includeUntrackedNote =
        "An empty folder is not kept: git deletes it and a pop does not bring it back."

    // MARK: - Blocked reasons

    static let blockedBySheet = "Answer the open sheet first."
    static let nothingToStash = "There are no changes to stash."
    /// The same sentence the other actions use while a change runs.
    static let busy = RemoteWording.mutationBusy

    /// Apply, Pop and Drop Stash… while an operation is in progress.
    static func actionsBlocked(by operation: RepositoryOperation) -> String {
        "Stashes can't be applied, popped or dropped while \(inProgress(operation)). Commit or "
            + "abort it first."
    }

    /// Why the stash actions are off while any path is unmerged — with or without an operation
    /// (a stash apply or an Undo Discard leaves `u` records and no MERGE_HEAD): git refuses to
    /// stash or apply over them, and GitCore says so after the click; this says it before. Drop
    /// goes with Apply and Pop, as it does during an operation. Nil when nothing is unmerged.
    static func blockedByConflicts(_ paths: [String], actions: Bool) -> String? {
        guard !paths.isEmpty else { return nil }
        guard actions else { return refusal(.unmergedPaths(paths), verb: .stash, stash: nil) }
        return "Stashes can't be applied, popped or dropped while \(names(paths)) "
            + "\(number(paths.count, "has", "have")) unresolved conflicts. Resolve them first."
    }

    // MARK: - Rows

    /// The tooltip of a record Gitter filed before a discard.
    static let discardedRowHelp = "Recorded by Gitter before a discard. Apply it to bring the changes back."
}
