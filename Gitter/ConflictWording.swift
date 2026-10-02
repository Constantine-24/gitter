import Foundation
import GitCore

/// What the two sides of a conflict are called on screen. Never the marker labels: in a rebase
/// stage 2 ("ours") is the upstream and stage 3 ("theirs") the user's own commit (M 6), so the
/// words come from the operation, not from git's side names.
struct SideLabels: Hashable, Sendable {
    let ours: String
    let theirs: String

    func label(_ side: ConflictSide) -> String { side == .ours ? ours : theirs }
}

/// What the resolver can do to the conflicted file on screen (`ResolverOffer.actions`).
enum ResolverAction: Hashable, Sendable {
    case resolveFile, takeOurs, takeTheirs, delete, keep, openInEditor, markResolved
}

/// A resolving write waiting for the user to confirm that bytes git did not write may be
/// replaced (`BranchSheet.replaceHandEdited`): what was asked, ready to run again with
/// `recordIfEdited`.
enum PendingResolution: Hashable, Sendable {
    case blocks([BlockChoice])
    case take(ConflictSide)
    case delete
    case keep
}

/// Every sentence the resolver puts on screen: the side labels, the kind in words, the row badge,
/// why a file is whole-file only, the chooser, the buttons and their tooltips, the three sheets
/// (Replace, Mark Resolved, Reopen), every `ConflictError`, the notices, and Stage All's skip
/// notice.
///
/// Pure: nothing here reads the store, the disk or git. `ConflictWordingTests` pins each one.
enum ConflictWording {

    // MARK: - Helpers

    private static func name(_ path: String) -> String { StashWording.names([path]) }

    private static func short(_ sha: String) -> String { String(sha.prefix(7)) }

    /// A subject in a label: at most `subjectLimit` characters, then an ellipsis.
    private static let subjectLimit = 50
    private static func subject(_ text: String) -> String {
        text.count > subjectLimit ? String(text.prefix(subjectLimit)) + "\u{2026}" : text
    }

    /// `100755` → `755`.
    private static func mode(_ stage: ConflictStage?) -> String {
        String((stage?.mode ?? "").suffix(3))
    }

    // MARK: - Side labels

    /// The two sides' names for the operation in progress (spec, "App"): a merge is the current
    /// branch against the merged one (`MERGE_MSG`'s name, else `MERGE_HEAD <short>`); a rebase is
    /// the upstream it replays onto against the user's own commit; a pick is the branch against
    /// the picked commit; a revert the branch against the undoing of a commit; with no operation
    /// (a stash apply's conflict) HEAD against what came in.
    static func sides(operation: RepositoryOperation?, progress: OperationProgress?, branch: String?)
        -> SideLabels
    {
        let head = branch ?? "HEAD"
        let current = progress?.current
        switch operation {
        case nil:
            return SideLabels(ours: "HEAD", theirs: "incoming")
        case .merge:
            let theirs =
                progress?.mergedName
                ?? progress?.mergeHead.map { "MERGE_HEAD \(short($0.sha))" } ?? "MERGE_HEAD"
            return SideLabels(ours: head, theirs: theirs)
        case .rebase:
            return SideLabels(
                ours: progress?.onto.map { "upstream (\(short($0.sha)))" } ?? "upstream",
                theirs: current.map { "your commit \(short($0.sha)) \(subject($0.subject))" } ?? "your commit")
        case .cherryPick:
            return SideLabels(
                ours: head, theirs: current.map { "\(short($0.sha)) \(subject($0.subject))" } ?? "the picked commit")
        case .revert:
            return SideLabels(ours: head, theirs: current.map { "undoing \(short($0.sha))" } ?? "the revert")
        case .squash:
            return SideLabels(ours: head, theirs: "the squashed commits")
        case .applyingPatches:
            return SideLabels(ours: head, theirs: "the patch")
        }
    }

    /// "Ours — main": a side's heading in the chooser.
    static func side(_ side: ConflictSide, _ sides: SideLabels) -> String {
        "\(side == .ours ? "Ours" : "Theirs") \u{2014} \(sides.label(side))"
    }

    // MARK: - The kind

    /// What each side did, in words, with the file's flags.
    static func kind(_ file: ConflictedFile, sides: SideLabels) -> String {
        let words: String
        switch file.kind {
        case .bothModified: words = "Changed on both sides"
        case .bothAdded:
            words =
                file.isModeOnly
                ? "Added on both sides with the same content but different modes "
                    + "(\(mode(file.ours)) and \(mode(file.theirs)))"
                : "Added on both sides"
        case .deletedByUs: words = "Deleted in \(sides.ours), changed in \(sides.theirs)"
        case .deletedByThem: words = "Changed in \(sides.ours), deleted in \(sides.theirs)"
        case .addedByUs: words = "Added only in \(sides.ours)"
        case .addedByThem: words = "Added only in \(sides.theirs)"
        case .bothDeleted: words = "Deleted on both sides"
        }
        if file.isSubmodule { return words + " (a submodule)" }
        if file.isSymlink { return words + " (a symbolic link)" }
        return words
    }

    /// The row's badge: git's own two letters (porcelain v2's XY).
    static func badge(_ kind: ConflictKind) -> String {
        switch kind {
        case .bothModified: "UU"
        case .bothAdded: "AA"
        case .deletedByUs: "DU"
        case .deletedByThem: "UD"
        case .addedByUs: "AU"
        case .addedByThem: "UA"
        case .bothDeleted: "DD"
        }
    }

    // MARK: - Why there are no blocks

    static func wholeFile(_ reason: WholeFileReason) -> String {
        switch reason {
        case .binary: "Git can't draw conflict blocks in a binary file. Keep one side's version whole."
        case .symlink: "One side is a symbolic link, which can only be kept whole."
        case .modeOnly: "Both sides added the same content; only the file mode differs."
        case .deletion: "One side deleted the file, so there are no blocks to choose between."
        case .oneSided: "Only one side has a file at this path, so there are no blocks to choose between."
        case .mergeAttribute(let value):
            "The file's merge attribute is \"\(value)\", so git did not merge it line by line. Keep one "
                + "side's version whole."
        case .unparsable:
            "Gitter couldn't split this conflict into blocks. Keep one side's version whole, or resolve it "
                + "in your editor."
        }
    }

    /// Submodule conflicts are shown and explained, never resolved here (backlog).
    static let submodule =
        "This is a submodule conflict, which Gitter can't resolve yet. In a terminal, check out the "
        + "commit you want inside the submodule, then stage the submodule here."

    /// The "changed since the conflict" state: the worktree is not what git wrote.
    static func changedSinceConflict(_ path: String) -> String {
        "\(name(path)) was changed since git wrote the conflict, so its blocks aren't shown. Take a side "
            + "\u{2014} Gitter keeps a copy of the file in the Stashes list first \u{2014} or finish it in "
            + "your editor and use Mark Resolved."
    }

    /// The heading over the current file in the "changed since" state.
    static let currentFile = "The file as it is now"

    // MARK: - The chooser

    /// `index` is 0-based.
    static func position(_ index: Int, of count: Int) -> String { "Conflict \(index + 1) of \(count)" }

    static func chosen(_ count: Int, of total: Int) -> String { "\(count) of \(total) chosen" }

    static func choice(_ choice: BlockChoice) -> String {
        switch choice {
        case .ours: "Ours"
        case .theirs: "Theirs"
        case .oursThenTheirs: "Both (ours first)"
        case .theirsThenOurs: "Both (theirs first)"
        }
    }

    static let base = "Base (before either side changed it)"
    static let noBase = "Git kept no base for this conflict."
    static let preview = "Result"
    static let previewEmpty = "Choose how to resolve this conflict to see the result."
    static let emptySide = "(nothing)"
    static let previous = "Previous Conflict"
    static let next = "Next Conflict"

    static func resolveHelp(remaining: Int) -> String {
        remaining == 0
            ? "Write the chosen blocks to the file and stage it"
            : "Choose a side for every conflict first (\(remaining) left)"
    }

    // MARK: - Actions

    static func title(_ action: ResolverAction, _ file: ConflictedFile) -> String {
        switch action {
        case .resolveFile: return "Resolve File"
        case .takeOurs:
            if file.isModeOnly { return "Keep Ours (mode \(mode(file.ours)))" }
            return file.kind == .addedByUs ? "Keep Our Version" : "Take Ours"
        case .takeTheirs:
            if file.isModeOnly { return "Keep Theirs (mode \(mode(file.theirs)))" }
            return file.kind == .addedByThem ? "Keep Their Version" : "Take Theirs"
        case .delete: return "Delete the File"
        case .keep: return file.kind == .deletedByUs ? "Keep Their Version" : "Keep Our Version"
        case .openInEditor: return "Open in Editor"
        case .markResolved: return "Mark Resolved"
        }
    }

    /// The button's tooltip.
    static func help(_ action: ResolverAction, _ file: ConflictedFile, _ sides: SideLabels) -> String {
        switch action {
        case .resolveFile: resolveHelp(remaining: 0)
        case .takeOurs: "Use the whole file as \(sides.ours) has it, and stage it"
        case .takeTheirs: "Use the whole file as \(sides.theirs) has it, and stage it"
        case .delete: "Resolve the conflict by deleting the file"
        case .keep:
            "Keep the file as \(file.kind == .deletedByUs ? sides.theirs : sides.ours) has it, and stage it"
        case .openInEditor: "Open the file in its default app"
        case .markResolved: "Stage the file as it is now"
        }
    }

    // MARK: - Replace a hand-edited file

    static func replaceTitle(_ path: String) -> String { "Replace the edited \(name(path))?" }

    static func replaceBody(_ path: String) -> String {
        "\(name(path)) was changed since git wrote the conflict. Gitter keeps a copy in the Stashes list "
            + "before replacing it."
    }

    static func replaceDestination(_ path: String) -> String {
        "The copy goes to the Stashes list as \"Replaced by Gitter: \(path)\"."
    }

    /// What happens after the copy is filed.
    static func replaceThen(_ pending: PendingResolution, _ file: ConflictedFile, _ sides: SideLabels) -> String {
        switch pending {
        case .blocks: "Then the chosen blocks are written to the file, and it is staged."
        case .take(let side): "Then the whole file is taken from \(sides.label(side)), and it is staged."
        case .delete: "Then the file is deleted, and the deletion is staged."
        case .keep:
            "Then the file is kept as \(file.kind == .deletedByUs ? sides.theirs : sides.ours) has it, and "
                + "it is staged."
        }
    }

    /// The sheet's destructive button: the action it confirms.
    static func replaceButton(_ pending: PendingResolution, _ file: ConflictedFile) -> String {
        switch pending {
        case .blocks: title(.resolveFile, file)
        case .take(let side): title(side == .ours ? .takeOurs : .takeTheirs, file)
        case .delete: title(.delete, file)
        case .keep: title(.keep, file)
        }
    }

    // MARK: - Mark Resolved with markers left

    /// No count: `leftoverMarkers` can over-count a content line that is exactly an opening or
    /// closing marker, so the sheet promises only that markers are there.
    static func markResolvedTitle(_ path: String) -> String {
        "Mark \(name(path)) resolved with conflict markers in it?"
    }

    static func markResolvedBody(_ path: String) -> String {
        "\(name(path)) still contains conflict markers. Marking it resolved stages the file with the "
            + "markers in it, and the next commit would contain them unless the file is edited first."
    }

    static let markResolvedButton = "Mark Resolved Anyway"

    // MARK: - Reopen

    static func reopenTitle(_ path: String) -> String { "Reopen the conflict in \(name(path))?" }

    /// What comes back, as `GitConflictBackend.reopenedFile` read it: markers only for text.
    /// A binary (or `merge=binary`) file gets the ours side's bytes, a mode-only add the ours
    /// side's mode — named with the operation's side names, so a rebase says the upstream.
    static func reopenBody(_ path: String, _ comesBack: ReopenedFile, _ sides: SideLabels) -> String {
        let back = "Git's conflict comes back in place of the resolution"
        let unmerged = "is unmerged until it is resolved again."
        switch comesBack {
        case .markers:
            return "\(back): \(name(path)) gets its conflict markers again and \(unmerged)"
        case .oursVersion:
            return "\(back), without conflict markers: git can't merge \(name(path)) line by line, so the "
                + "file goes back to the version from \(sides.ours) and \(unmerged)"
        case .oursMode:
            return "\(back): the content of \(name(path)) stays as it is, its mode goes back to the one in "
                + "\(sides.ours), and it \(unmerged)"
        case .driver(let driver):
            return "\(back): the \"\(driver)\" merge driver writes \(name(path)) again, and it \(unmerged)"
        }
    }

    static func reopenDestination(_ path: String) -> String {
        "The resolution as it is now \u{2014} the staged file and the file on disk \u{2014} goes to the "
            + "Stashes list first as \"Reopened by Gitter: \(path)\"."
    }

    static let reopenButton = "Reopen Conflict"
    static let reopenMenuItem = "Reopen Conflict\u{2026}"

    /// Above the diff of a resolved file that can be reopened.
    static func reopenOffer(_ path: String) -> String {
        "The conflict in \(name(path)) was resolved. It can be reopened while the operation is in progress."
    }

    // MARK: - Refusals

    static func error(_ error: ConflictError) -> String {
        switch error {
        case .changedSinceShown(let path):
            "\(name(path)) changed after it was shown, so nothing was written. Look at it again, then choose."
        case .wouldReplaceEdits(let path):
            "\(name(path)) was changed since git wrote the conflict, so nothing was written."
        case .stageMissing(let path, let side):
            "\(name(path)) has no \(side == .ours ? "ours" : "theirs") version: that side deleted it. "
                + "Nothing was written."
        case .notAvailable(let path):
            "That can't be done to \(name(path)) now, so nothing was written."
        case .choicesDoNotMatch(let path):
            "The conflict in \(name(path)) changed after it was shown, so nothing was written. Look at it "
                + "again, then choose."
        case .leftoverMarkers:
            "The file still contains conflict markers, so nothing was staged."
        case .pathTypeChanged(let path):
            "\(name(path)) is no longer a file \u{2014} a folder stands there, or a folder on its path is "
                + "now a file \u{2014} so nothing was written: git would delete what is there."
        }
    }

    // MARK: - Notices

    private static func copy(_ receipt: ConflictReceipt, _ what: String) -> String {
        receipt.recorded.map { " \(what) is in the Stashes list as \"\($0.message)\"." } ?? ""
    }

    static func done(_ pending: PendingResolution, _ receipt: ConflictReceipt, _ sides: SideLabels) -> String {
        let path = name(receipt.path)
        let text: String
        switch pending {
        case .blocks: text = "Resolved \(path)."
        case .take(let side): text = "Resolved \(path) with the whole file from \(sides.label(side))."
        case .delete: text = "Resolved \(path) by deleting it."
        case .keep: text = "Resolved \(path) by keeping the file."
        }
        return text + copy(receipt, "The edited file")
    }

    static func marked(_ path: String) -> String { "Marked \(name(path)) resolved." }

    static func reopened(_ receipt: ConflictReceipt) -> String {
        "Reopened the conflict in \(name(receipt.path))." + copy(receipt, "The resolution")
    }

    /// The notice's button that shows the entry a resolution or a reopen filed.
    static let showCopy = "Show Copy"

    /// Why the resolver's buttons are off while a sheet or another change is up.
    static let blockedBySheet = StashWording.blockedBySheet
    static let busy = StashWording.busy

    // MARK: - Stage All

    /// Stage All never stages an unmerged path (M 22); this says how many it left.
    static func stageAllSkipped(_ count: Int) -> String {
        count == 1
            ? "1 conflicted file was left out — resolve it first"
            : "\(count) conflicted files were left out — resolve them first"
    }
}
