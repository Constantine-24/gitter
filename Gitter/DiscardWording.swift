import Foundation
import GitCore

/// Every sentence a discard puts on screen: the sheet (its title, rows, destination, button and
/// stale line), the notice after a discard, the refusals and part-way failures, the undo's
/// outcomes, and why an entry point is off.
///
/// Pure: nothing here reads the store, the disk or git. `DiscardWordingTests` pins each one.
/// Names are quoted and capped at three the way the stash names them (`StashWording.names`).
enum DiscardWording {

    // MARK: - Helpers

    private static func names(_ paths: [String]) -> String { StashWording.names(paths) }

    /// "is"/"are", "it"/"they" and the like, by how many things a sentence names.
    private static func number(_ count: Int, _ one: String, _ many: String) -> String {
        count == 1 ? one : many
    }

    /// git's (or GitCore's) words in a sentence: one line, without a closing full stop — the
    /// caller puts its own punctuation after them.
    private static func clause(_ words: String) -> String {
        var flat = words.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        while let last = flat.last, ".;:".contains(last) { flat.removeLast() }
        return flat
    }

    private static func lines(_ count: Int) -> String {
        "\(count) \(number(count, "line", "lines"))"
    }

    // MARK: - Rows

    /// What one row of the sheet loses.
    enum Loss: Hashable, Sendable {
        /// The added and removed lines of the diffs shown for the file, both sides for a
        /// staged-side sheet.
        case counts(added: Int, removed: Int)
        case binary
        /// A diff with no lines: a mode change, a rename, an empty file added or removed.
        case noLineChanges
        /// The selected lines of a hunk.
        case lines(Int)
        case untrackedFile
        case untrackedFolder

        /// Counted from the diffs the sheet shows for one file.
        init(of diffs: [FileDiff]) {
            if diffs.contains(where: \.isBinary) {
                self = .binary
                return
            }
            let changed = diffs.flatMap(\.hunks).flatMap(\.lines)
            let added = changed.filter { $0.kind == .added }.count
            let removed = changed.filter { $0.kind == .removed }.count
            self = added + removed == 0 ? .noLineChanges : .counts(added: added, removed: removed)
        }
    }

    static func loss(_ loss: Loss) -> String {
        switch loss {
        case .counts(let added, let removed): "+\(added) \u{2212}\(removed)"
        case .binary: "binary file"
        case .noLineChanges: "no line changes"
        case .lines(let count): lines(count)
        case .untrackedFile: "untracked \u{2192} Trash"
        case .untrackedFolder: "untracked folder \u{2192} Trash"
        }
    }

    /// How many of a line discard's lines the sheet previews before `previewMore`.
    static let previewLimit = 12

    /// One previewed line: its marker and its text as the diff shows it.
    static func preview(_ line: DiffLine) -> String {
        let marker =
            switch line.kind {
            case .added: "+"
            case .removed: "\u{2212}"
            case .context, .noNewline: " "
            }
        return "\(marker) \(line.displayText)"
    }

    static func previewMore(_ count: Int) -> String {
        "\u{2026} and \(count) more \(number(count, "line", "lines"))"
    }

    // MARK: - The sheet

    /// What the sheet asks. `all` is Discard All…, whatever its requests hold.
    static func title(_ requests: [DiscardRequest], all: Bool) -> String {
        if all { return "Discard all unstaged changes?" }
        var tracked: [String] = []
        var untracked: [String] = []
        for request in requests {
            switch request {
            case .unstaged(let paths, _): tracked.append("the unstaged changes to \(names(paths))")
            case .stagedAndUnstaged(let paths, _):
                tracked.append("the staged and unstaged changes to \(names(paths))")
            case .lines(let path, _, let count, _): tracked.append("\(lines(count)) of \(names([path]))")
            case .untracked(let paths, _): untracked.append(names(paths))
            }
        }
        let move = untracked.isEmpty ? nil : "\(untracked.joined(separator: " and ")) to the Trash"
        switch (tracked.isEmpty, move) {
        case (false, nil): return "Discard \(tracked.joined(separator: " and "))?"
        case (true, let move?): return "Move \(move)?"
        case (false, let move?): return "Discard \(tracked.joined(separator: " and ")) and move \(move)?"
        case (true, nil): return "Discard?"
        }
    }

    /// The destructive button. It has no keyboard shortcut; Return is Cancel's.
    static func confirmButton(_ requests: [DiscardRequest], all: Bool) -> String {
        if all { return "Discard All" }
        if requests.count == 1, case .lines(_, _, let count, _) = requests[0] {
            return "Discard \(count) \(number(count, "Line", "Lines"))"
        }
        if requests.allSatisfy({ if case .untracked = $0 { true } else { false } }) {
            return "Move to Trash"
        }
        return "Discard"
    }

    /// Where the copy goes: the record's name in the Stashes list, and/or the Trash.
    static func destination(record: String?, untracked: Bool) -> String {
        var sentences: [String] = []
        if let record { sentences.append("A copy goes to the Stashes list as \"\(record)\".") }
        if untracked { sentences.append("Untracked files go to the Trash.") }
        return sentences.joined(separator: " ")
    }

    /// The sheet's live stale line: what it shows is no longer what a confirm would find, and
    /// GitCore's stale check will refuse it.
    static let sheetStale =
        "This changed after it was shown. Discarding will be refused; close this and ask again."

    // MARK: - After a discard

    /// What a receipt discarded, completing "Discarded …". For untracked items only those the
    /// Trash took (a failure part-way names the ones that went).
    private static func what(_ receipt: DiscardReceipt) -> String {
        switch receipt.request {
        case .unstaged(let paths, _): "the unstaged changes to \(names(paths))"
        case .stagedAndUnstaged(let paths, _): "the staged and unstaged changes to \(names(paths))"
        case .lines(let path, _, let count, _): "\(lines(count)) of \(names([path]))"
        case .untracked(let paths, _):
            "\(names(paths.filter { receipt.trashed[$0] != nil })) (moved to the Trash)"
        }
    }

    /// The sticky notice after a discard, with Undo Discard. Discard All… names its tracked part,
    /// then after a semicolon what went to the Trash — each list is capped, and two "and"s in a
    /// row would run them together.
    static func done(_ receipts: [DiscardReceipt]) -> String {
        let tracked = receipts.filter { if case .untracked = $0.request { false } else { true } }
        let trashed = receipts.filter { if case .untracked = $0.request { true } else { false } }
            .flatMap { receipt in receipt.request.paths.filter { receipt.trashed[$0] != nil } }
        guard !tracked.isEmpty else { return "Discarded \(names(trashed)) (moved to the Trash)." }
        let discarded = "Discarded \(tracked.map(what).joined(separator: " and "))"
        return trashed.isEmpty ? discarded + "." : discarded + "; moved \(names(trashed)) to the Trash."
    }

    static let undoButton = "Undo Discard"

    // MARK: - Refusals

    /// A refusal as a clause, for a sentence that has its own subject.
    private static func reason(_ refusal: DiscardRefusal) -> String {
        switch refusal {
        case .operationInProgress(let operation): StashWording.inProgress(operation)
        case .unmerged(let paths):
            "\(names(paths)) \(number(paths.count, "has", "have")) unresolved conflicts"
        case .intentToAdd(let paths):
            "\(names(paths)) \(number(paths.count, "is", "are")) only marked to be added (git add -N)"
        case .submodules(let paths):
            "\(names(paths)) \(number(paths.count, "is a submodule", "are submodules"))"
        case .nestedRepositories(let paths):
            "\(names(paths)) \(number(paths.count, "belongs", "belong")) to another repository (a "
                + "submodule, or a repository inside this one)"
        case .needsWholeFile(let path): "only the whole of \(names([path])) can be discarded"
        case .changedSinceShown(let paths): "\(names(paths)) changed after this was shown"
        case .pathTypeChanged(let paths):
            "\(names(paths)) changed between a file and a folder"
        case .nothingSelected: "there was nothing left to discard"
        case .notTracked(let paths): "git no longer tracks \(names(paths))"
        }
    }

    /// GitCore's refusal as a banner: nothing was discarded.
    ///
    /// `.pathTypeChanged` without a disk reading takes the neutral phrase for each path; the
    /// store reads what each path is now and calls `typeChanged` instead.
    static func refusal(_ refusal: DiscardRefusal) -> String {
        switch refusal {
        case .operationInProgress(let operation):
            return "Can't discard while \(StashWording.inProgress(operation)). Commit or abort it first."
        case .unmerged(let paths):
            let it = number(paths.count, "it has", "they have")
            let file = number(paths.count, "the file", "the files")
            return "Can't discard \(names(paths)): \(it) unresolved conflicts. Resolve them and stage "
                + "\(file) first."
        case .intentToAdd(let paths):
            let it = number(paths.count, "it", "them")
            return "Can't discard \(names(paths)): \(number(paths.count, "it is", "they are")) only "
                + "marked to be added (git add -N), and no copy of \(it) can be kept. Stage \(it) "
                + "fully or unstage \(it) first."
        case .submodules(let paths):
            return "Can't discard \(names(paths)): "
                + "\(number(paths.count, "it is a submodule", "they are submodules")), and no copy of "
                + "the work inside one can be kept."
        case .nestedRepositories(let paths):
            return "Can't discard \(names(paths)): \(number(paths.count, "it belongs", "they belong")) "
                + "to another repository (a submodule, or a repository inside this one)."
        case .needsWholeFile(let path):
            // Ruling 4: GitCore can refuse lines the app offered (a file not in its checkout
            // form, say); the way on is the whole-file discard, which the row offers.
            return "Can't discard only some lines of \(names([path])): its changes can only be "
                + "discarded as a whole file. Nothing was discarded. \(discardChanges) on the file "
                + "discards all of its unstaged changes."
        case .changedSinceShown(let paths):
            return "The \(number(paths.count, "file", "files")) changed after this was shown; "
                + "nothing was discarded."
        case .pathTypeChanged(let paths):
            return typeChanged(paths.map { .changed($0) })
        case .nothingSelected:
            return "Nothing was discarded: there are no changes left to discard."
        case .notTracked(let paths):
            return "Can't discard \(names(paths)): git no longer tracks "
                + "\(number(paths.count, "it", "them")). Nothing was discarded."
        }
    }

    /// A file and a folder that swapped places, as the disk shows it now.
    static func typeChanged(_ changes: [StashWording.TypeChange]) -> String {
        let phrases = changes.map(\.phrase)
        let shown =
            phrases.count > 3
            ? phrases.prefix(3).joined(separator: "; ") + "; and \(phrases.count - 3) more"
            : phrases.joined(separator: "; ")
        return "Can't discard: \(shown). Discarding would lose what is there now. Put it back, or "
            + "commit the change first."
    }

    /// Discard All's second request refused after the first one discarded (ruling 1): only the
    /// untracked part stayed, so the sentence must not say that nothing was discarded.
    static func untrackedPartRefused(_ refusal: DiscardRefusal) -> String {
        "The untracked files were not moved to the Trash: \(reason(refusal))."
    }

    /// Any other error of a discard: thrown before anything was written, or after a change
    /// that provably changed nothing (GitCore drops its record again then).
    static func discardError(_ words: String) -> String {
        "Couldn't discard: \(clause(words)). Nothing was discarded."
    }

    /// The same for Discard All's second request, after the first one discarded.
    static func untrackedPartFailed(_ words: String) -> String {
        "The untracked files were not moved to the Trash: \(clause(words))."
    }

    // MARK: - Failures part-way

    /// A discard that stopped after something was written (`DiscardFailure`).
    ///
    /// Tracked kinds: where the copy is, and that the file may be partly restored. Never
    /// "apply it from the Stashes list": over a part-way restore git refuses that apply too
    /// (ruling 3). Untracked: what already went to the Trash.
    static func failure(_ failure: DiscardFailure) -> String {
        let receipt = failure.receipt
        let words = clause(failure.gitsWords)
        if case .untracked(let paths, _) = receipt.request {
            let went = paths.filter { receipt.trashed[$0] != nil }
            let already = went.isEmpty ? "Nothing was moved." : "Already in the Trash: \(names(went))."
            return "Moving \(names(paths)) to the Trash did not finish: \(words). \(already)"
        }
        let paths = receipt.request.paths
        let copy =
            receipt.record.map {
                "a copy of the changes as they were is in the Stashes list as \"\($0.message)\"."
            } ?? "no copy of the changes was kept."
        return "Discarding \(what(receipt)) did not finish: \(words). \(names(paths)) may be partly "
            + "restored; \(copy)"
    }

    // MARK: - Undo

    /// Whether an undo outcome is a notice. Everything else is a banner that stays until read.
    static func isNotice(_ outcome: UndoDiscardOutcome) -> Bool {
        switch outcome {
        case .restored, .restoredUnstaged: true
        case .restoredUnverified, .refused, .conflicted, .partiallyRestored: false
        }
    }

    /// What came back, completing "Restored …".
    private static func restored(_ receipt: DiscardReceipt) -> String {
        switch receipt.request {
        case .unstaged(let paths, _), .stagedAndUnstaged(let paths, _): names(paths)
        case .lines(let path, _, let count, _): "\(lines(count)) of \(names([path]))"
        case .untracked(let paths, _):
            "\(names(paths.filter { receipt.trashed[$0] != nil })) from the Trash"
        }
    }

    private static func copyLeft(_ kept: Stash?) -> String {
        kept == nil ? "the copy is no longer in the Stashes list" : "the copy is still in the Stashes list"
    }

    /// The outcome of Undo Discard for one receipt. `headMoved` says why a staged part came back
    /// unstaged: a commit since the discard, or else something staged since.
    static func undone(_ outcome: UndoDiscardOutcome, of receipt: DiscardReceipt, headMoved: Bool) -> String {
        switch outcome {
        case .restored:
            return "Restored \(restored(receipt))."
        case .restoredUnstaged:
            let why = headMoved ? "a commit was made since" : "something was staged since"
            return "Restored \(restored(receipt)); its staged part came back unstaged because \(why)."
        case .restoredUnverified(let kept):
            let copy = kept == nil ? "" : ", so the copy stays in the Stashes list"
            return "Restored \(restored(receipt)), but the file could not be checked against the "
                + "copy\(copy)."
        case .refused(let words, let kept):
            // `apply` refused over files changed since: GitCore passes only their names.
            let lines = words.split(whereSeparator: \.isNewline).map(String.init)
            let why =
                !lines.isEmpty && lines.allSatisfy(receipt.request.paths.contains)
                ? "\(names(lines)) changed since the discard" : clause(words)
            return "Couldn't undo: \(why); \(copyLeft(kept))."
        case .conflicted(let paths, let kept):
            return "Undo brought the changes back with conflicts in \(names(paths)). Resolve them, "
                + "then stage the files; \(copyLeft(kept))."
        case .partiallyRestored(let notRestored):
            let back = receipt.request.paths.filter {
                receipt.trashed[$0] != nil && !notRestored.contains($0)
            }
            let restoredPart = back.isEmpty ? "" : "Restored \(names(back)) from the Trash. "
            let count = notRestored.count
            return restoredPart + "Couldn't put \(names(notRestored)) back: something of "
                + "\(number(count, "that name", "those names")) is there again. "
                + "\(number(count, "It is", "They are")) still in the Trash."
        }
    }

    /// An undo GitCore refused before it ran (`DiscardRefusal`, an operation in progress).
    static func undoRefused(_ refusal: DiscardRefusal) -> String {
        "Couldn't undo: \(reason(refusal)); the copy is still in the Stashes list."
    }

    /// A staged-side undo whose content came back but whose staged part could not be restored.
    static func undoFailed(_ failure: DiscardFailure) -> String {
        "Restored \(restored(failure.receipt)), but not its staged part: \(clause(failure.gitsWords)). "
            + "The copy, which holds it, is still in the Stashes list."
    }

    /// Any other error an undo threw, in its own words.
    static func undoError(_ words: String) -> String {
        "Couldn't undo: \(clause(words)); the copy is still in the Stashes list."
    }

    // MARK: - Why an entry point is off

    /// Why one file cannot be discarded (`DiscardGate`).
    enum FileBlock: Hashable, Sendable {
        case unmerged(String)
        case intentToAdd(String)
        case submodule(String)
        case anotherRepository(String)
        case typeChanged(StashWording.TypeChange)
        /// A tracked file in a repository with no commit: the record is a stash commit on HEAD.
        case noCommitYet
    }

    static func blocked(_ block: FileBlock) -> String {
        switch block {
        case .unmerged(let path):
            "\(names([path])) has unresolved conflicts. Resolve them and stage the file first."
        case .intentToAdd(let path):
            "\(names([path])) is only marked to be added (git add -N), and no copy of it can be "
                + "kept. Stage it fully or unstage it first."
        case .submodule(let path):
            "\(names([path])) is a submodule, and no copy of the work inside one can be kept."
        case .anotherRepository(let path):
            "\(names([path])) belongs to another repository (a submodule, or a repository inside "
                + "this one)."
        case .typeChanged(let change):
            "\(change.phrase); discarding would lose what is there now. Put it back, or commit the "
                + "change first."
        case .noCommitYet:
            "Tracked changes can't be discarded before the first commit: there is no commit to keep "
                + "a copy of them on. Untracked files can still be moved to the Trash."
        }
    }

    static func blockedDuringOperation(_ operation: RepositoryOperation) -> String {
        "Changes can't be discarded while \(StashWording.inProgress(operation)). Commit or abort it "
            + "first."
    }

    static let nothingToDiscard = "There are no unstaged changes to discard."

    // MARK: - Entry points

    static let discardChanges = "Discard Changes\u{2026}"
    static let moveToTrash = "Move to Trash\u{2026}"
    static let discardStaged = "Discard Staged and Unstaged Changes\u{2026}"
    static let discardAll = "Discard All\u{2026}"
    static let discardHunk = "Discard Hunk\u{2026}"
    static let discardFile = "Discard File\u{2026}"
    static func discardLines(_ count: Int) -> String {
        "Discard \(count) \(number(count, "Line", "Lines"))\u{2026}"
    }
    /// The Discard All… button's tooltip while it is available.
    static let discardAllHelp =
        "Discard every unstaged change: tracked files are restored, untracked ones go to the Trash"
}
