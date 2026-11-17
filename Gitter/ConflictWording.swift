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
    /// Focus mode's Result, as the worktree-form bytes `resolve(_:text:…)` writes.
    case text(Data)
    case take(ConflictSide)
    case delete
    case keep
}

/// Every sentence the resolver puts on screen: the side labels, the kind in words, the row badge,
/// why a file is whole-file only, the card and focus mode (toolbar, sidebar, headers, bars,
/// bottom bar), the buttons and their tooltips, the sheets (Replace, Mark Resolved, Reopen, Take
/// for N Files), every `ConflictError`, the notices, and Stage All's skip notice.
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

    /// Submodule conflicts are shown and explained, never resolved here.
    static let submodule =
        "This is a submodule conflict, which Gitter can't resolve yet. In a terminal, check out the "
        + "commit you want inside the submodule, then stage the submodule here."

    // MARK: - Where focus mode is

    /// "Conflict 2 of 5" in the toolbar; `index` is 0-based.
    static func position(_ index: Int, of count: Int) -> String { "Conflict \(index + 1) of \(count)" }

    static let previous = "Previous Conflict"
    static let next = "Next Conflict"

    // MARK: - A conflict that cannot be read

    /// The resolver's failed state (B4 item 4): `message` is git's own words, and the two
    /// buttons under it are the ones that need no read. git's words often end in a period of
    /// their own: one is dropped before the sentence's, so the banner never reads "..".
    static func loadFailed(_ message: String) -> String {
        let message = message.hasSuffix(".") ? String(message.dropLast()) : message
        return "Gitter couldn't read this conflict: \(message). You can still open the file in its editor, "
            + "or mark it resolved as it is."
    }

    static let tryAgain = "Try Again"

    static func resolveHelp(remaining: Int) -> String {
        remaining == 0
            ? "Write the Result to the file and stage it"
            : "Choose a side for every conflict first (\(remaining) left)"
    }

    /// Resolve File's tooltip on a Result that can't be written: why, and what is left to do —
    /// also after Keep Editing has hidden the bar that said so.
    static func notWritableHelp(_ detachment: DraftDetachment) -> String {
        switch detachment {
        case .changedOutside:
            "This file changed outside Gitter, so this Result can't be written over it. Reload it, or copy the Result, from the \u{22EF} menu."
        case .resolvedOutside: bar(.resolvedOutside)
        case .operationEnded: bar(.operationEnded)
        }
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
        case .text: "Then the Result is written to the file, and it is staged."
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
        case .blocks, .text: title(.resolveFile, file)
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
    /// A binary file — or one whose merge attribute tells git not to merge it, said as such —
    /// gets the ours side's bytes, a mode-only add the ours side's mode — named with the
    /// operation's side names, so a rebase says the upstream.
    static func reopenBody(_ path: String, _ comesBack: ReopenedFile, _ sides: SideLabels) -> String {
        let back = "Git's conflict comes back in place of the resolution"
        let unmerged = "is unmerged until it is resolved again."
        switch comesBack {
        case .markers:
            return "\(back): \(name(path)) gets its conflict markers again and \(unmerged)"
        case .oursVersion:
            return "\(back), without conflict markers: git can't merge \(name(path)) line by line, so the "
                + "file goes back to the version from \(sides.ours) and \(unmerged)"
        case .oursByAttribute(let value):
            // Not "can't merge": git is told not to (final review L170) — text included.
            let attribute =
                value == "unset"
                ? "the merge attribute of \(name(path)) is unset (-merge, or the binary attribute)"
                : "the merge attribute of \(name(path)) is \"\(value)\""
            return "\(back), without conflict markers: \(attribute), which tells git not to merge it, so the "
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
        case .blocks, .text: text = "Resolved \(path)."
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

    // MARK: - Focus mode

    /// The kept notice when the operation ends while focus mode is up, outside Gitter (a
    /// terminal, another window).
    static func operationEndedOutside(_ operation: RepositoryOperation) -> String {
        "The \(operation.noun.lowercased()) ended outside Gitter."
    }

    /// The kept bar's text in the normal window: every file whose Result with changes is kept
    /// while Resolve Conflicts is closed and no operation bar shows.
    static func keptChanges(_ paths: [String]) -> String {
        "Your changes to \(StashWording.names(paths)) in Resolve Conflicts are kept."
    }

    /// The card where a conflicted file's diff would be: the kind, and how many conflicts when
    /// the file has blocks ("Changed on both sides · 3 conflicts").
    static func card(kind: String, count: Int?) -> String {
        guard let count else { return kind }
        return "\(kind) \u{00B7} \(count == 1 ? "1 conflict" : "\(count) conflicts")"
    }

    /// The card's and the operation bar's button.
    static let resolveConflictsButton = "Resolve Conflicts\u{2026}"
    static let keptChangesHelp = "Open Resolve Conflicts on the files whose changes are kept"
    static let resolveConflictsHelp = "Resolve the conflicts with both sides and the result side by side"

    static let focusTitle = "Resolve Conflicts"

    /// The line under the title: the operation's own words without their period, or, with no
    /// operation, where such conflicts come from (Ruling 20).
    static func focusSubtitle(_ operation: RepositoryOperation?, _ progress: OperationProgress?, branch: String?)
        -> String
    {
        guard let operation else { return "Conflicts from applying a stash or undoing a discard" }
        guard let sentence = ContinueWording.progress(operation, progress, branch: branch) else {
            return "\(operation.noun) in progress"
        }
        return sentence.hasSuffix(".") ? String(sentence.dropLast()) : sentence
    }

    static let showBase = "Show Base"
    static let showBaseHelp = "Show what each conflict looked like before either side changed it"
    static let done = "Done"
    static let doneHelp =
        "Back to the repository. Your changes are kept until you resolve or discard them, except in a "
        + "file that was resolved or whose operation ended, whose changes are dropped."

    // The sidebar.

    static let conflictedFiles = "Conflicted Files"

    static func filesResolved(_ resolved: Int, of total: Int) -> String {
        "\(resolved) of \(total) \(total == 1 ? "file" : "files") resolved"
    }

    /// The footer once every file is resolved.
    static func allResolved(withOperation: Bool) -> String {
        withOperation ? "All files resolved \u{2014} press Done, then Continue" : "All files resolved \u{2014} press Done"
    }

    /// The footer until then (Ruling 21): `title` is the operation's Continue or Commit.
    static func comesBack(_ title: String) -> String { "\(title) comes back once every file is resolved." }

    /// A row's trailing text; nothing while its read is still to land.
    static func sidebarStatus(_ status: ResolverRowStatus) -> String? {
        switch status {
        case .pending: nil
        case .left(let count): "\(count) left"
        case .wholeFile: "Whole file"
        case .resolved: "Resolved"
        case .readOnly: "Read only"
        }
    }

    /// A row's folder line for a file at the repository's top.
    static let noFolder = "\u{2014}"

    /// A row for VoiceOver: the path and its state.
    static func sidebarRowLabel(_ path: String, _ status: ResolverRowStatus) -> String {
        sidebarStatus(status).map { "\(path), \($0)" } ?? path
    }

    // The column headers.

    static func sideTitle(_ side: ConflictSide) -> String { sideName(side) }

    static func useRest(_ side: ConflictSide) -> String { "Use \(sideName(side)) for the rest" }

    static func useRestHelp(_ side: ConflictSide, _ sides: SideLabels) -> String {
        "Take \(sides.label(side)) for every conflict still waiting in this file"
    }

    static let resultTitle = "Result"

    /// After the path in the Result's header.
    static func resultState(editable: Bool) -> String { editable ? "\u{2014} editable" : "\u{2014} read-only" }

    static func resolvedCount(_ resolved: Int, of total: Int) -> String { "\(resolved) of \(total) resolved" }

    /// The Result header's overflow menu, for VoiceOver and its tooltip.
    static let moreActions = "More Actions"
    static let copyResult = "Copy Result"
    static let discardChanges = "Discard Changes"
    static let reload = "Reload"
    /// The Result menu's Reload, which asks first when there are changes (Ruling 26).
    static let reloadMenuItem = "Reload\u{2026}"
    /// Its question: the changed-outside bar's own sentence.
    static let reloadQuestion = bar(.changedOutside)
    static let cancel = "Cancel"
    static let keepEditing = "Keep Editing"

    // Never losing a draft: the questions before one is dropped (Task 7).

    /// Before Gitter's own action writes over or removes a file with a draft that has changes.
    static func discardQuestion(_ file: String) -> String { "Discard your changes to \(name(file))?" }

    /// The same question about several drafts at once (Take for N Files, Skip, an open in this
    /// window): one question, listing them.
    static func discardQuestion(files: [String]) -> String {
        files.count == 1 ? discardQuestion(files[0]) : "Discard your changes to \(StashWording.names(files))?"
    }

    /// Closing a window, quitting, or Done over several read-only drafts. The spec gives the
    /// plural; one file reads in the singular.
    static func closeQuestion(_ count: Int) -> String {
        count == 1
            ? "You have changes in 1 conflicted file that isn't saved. Close anyway?"
            : "You have changes in \(count) conflicted files that aren't saved. Close anyway?"
    }

    static let discardAndClose = "Discard and Close"
    static let discardAndQuit = "Discard and Quit"

    /// The in-window question's sentence (`BranchSheet.discardDrafts`): Done over several
    /// read-only drafts asks the close question (Ruling 36); everything else the discard question.
    static func draftQuestionTitle(_ question: DraftQuestion) -> String {
        question.closes ? closeQuestion(question.paths.count) : discardQuestion(files: question.paths)
    }

    /// Its destructive button.
    static func draftQuestionButton(_ question: DraftQuestion) -> String {
        question.closes ? discardAndClose : discardChanges
    }

    /// The Abort sheet's line naming the files with drafts, which the abort discards too.
    static func abortDrafts(_ paths: [String]) -> String {
        "Your changes to \(StashWording.names(paths)) in Resolve Conflicts are discarded too."
    }

    // The bars above the columns.

    static func bar(_ bar: ResolverBar) -> String {
        switch bar {
        case .editedAfterConflict:
            "This file was edited after the conflict; resolving here replaces those edits. A copy will be kept."
        case .changedOutside:
            "This file changed outside Gitter. Reload it to see the new version; your changes will be discarded."
        // Not "outside": Gitter's own Stage and Abort can end a draft this way too.
        case .resolvedOutside:
            "This file is no longer in conflict, so this Result can't be written. Copy it if you need it."
        case .operationEnded:
            "The operation this file was part of has ended, so this Result can't be written. Copy it if you need it."
        case .notEditable(.tooLarge): "This file is too large to edit here"
        case .notEditable(.notUTF8): "This file isn't UTF-8 text"
        }
    }

    // The bottom bar.

    /// "1 conflict left in this file"; nothing once none is.
    static func conflictsLeft(_ count: Int) -> String? {
        switch count {
        case 0: nil
        case 1: "1 conflict left in this file"
        default: "\(count) conflicts left in this file"
        }
    }

    /// The five key hints, as in the mockup: the keys, then what they do.
    static let keyHints: [(keys: String, action: String)] = [
        ("\u{2303}\u{2318}\u{2190}", "Take Ours"), ("\u{2303}\u{2318}\u{2192}", "Take Theirs"),
        ("\u{2303}\u{2318}\u{2193}", "Both"), ("\u{2318}]", "Next conflict"), ("\u{2318}[", "Previous"),
    ]

    // The centre.

    /// A side's column for a file with no blocks: what that side has.
    static func wholeFileSide(_ file: ConflictedFile, _ side: ConflictSide, _ reason: WholeFileReason) -> String {
        guard let stage = side == .ours ? file.ours : file.theirs else {
            return reason == .oneSided ? "Not on this side" : "Deleted on this side"
        }
        switch stage.mode {
        case "160000": return "Submodule"
        case "120000": return "Symbolic link"
        default: break
        }
        switch reason {
        case .binary: return "Binary file"
        case .modeOnly: return "Mode \(String(stage.mode.suffix(3)))"
        default: return "Whole file"
        }
    }

    static let allResolvedTitle = "All files resolved"

    /// A whole-file side's column: the side's text when it is text, else what it is — "Binary
    /// file, 2.8 MB", "Symlink to …", "Deleted on this side" (Ruling 23). `content` is the stage
    /// as read (nil when the read failed or the side has none); without it, the short description.
    static func wholeFileSideContent(
        _ file: ConflictedFile, _ side: ConflictSide, _ reason: WholeFileReason, content: Data?
    ) -> WholeFileSideContent {
        guard let stage = side == .ours ? file.ours : file.theirs, stage.mode != "160000", let content else {
            return .description(wholeFileSide(file, side, reason))
        }
        if stage.mode == "120000" {
            let target = String(decoding: content, as: UTF8.self)
            return .description("Symlink to \(target)")
        }
        if reason != .binary, !content.contains(0), let text = String(validating: content, as: UTF8.self) {
            return .text(text)
        }
        let size = ByteCountFormatter.string(fromByteCount: Int64(content.count), countStyle: .file)
        return .description("Binary file, \(size)")
    }

    // The columns.

    /// The Show Base row of a conflict whose base is empty.
    static let noBaseStrip = "No base: both sides added this"
    /// A column's text view for VoiceOver.
    static func columnLabel(_ column: ResolverColumn) -> String {
        switch column {
        case .ours: "Ours"
        case .result: "Result"
        case .theirs: "Theirs"
        }
    }

    /// The waiting slot's words.
    static let slotPrompt = "Choose a side, or type here"
    static let slotOurs = "\u{2190} Ours"
    static let slotBoth = "Both"
    static let slotTheirs = "Theirs \u{2192}"
    static let bothOursFirst = "Both, Ours First"
    static let bothTheirsFirst = "Both, Theirs First"

    /// A take button, chip or menu item for VoiceOver: the conflict and the side.
    static func takeLabel(_ choice: BlockChoice, conflict index: Int, of count: Int) -> String {
        let what: String
        switch choice {
        case .ours: what = "Take Ours"
        case .theirs: what = "Take Theirs"
        case .oursThenTheirs: what = "Take Both, Ours First"
        case .theirsThenOurs: what = "Take Both, Theirs First"
        }
        return "\(what) for \(position(index, of: count).lowercasedFirst)"
    }

    /// A take button's tooltip: the side's label.
    static func takeHelp(_ side: ConflictSide, _ sides: SideLabels) -> String {
        "Take \(sides.label(side)) for this conflict"
    }

    /// A badge's words.
    static func badge(_ badge: ResultBadge) -> String {
        switch badge {
        case .ours: "Ours"
        case .theirs: "Theirs"
        case .oursThenTheirs: "Ours + Theirs"
        case .theirsThenOurs: "Theirs + Ours"
        case .editedByYou: "Edited by you"
        case .fromOurs: "From Ours"
        case .fromTheirs: "From Theirs"
        }
    }

    /// A badge for VoiceOver, with the conflict it marks when it marks one.
    static func badgeLabel(_ badge: ResultBadge, conflict index: Int?, of count: Int) -> String {
        guard let index else { return self.badge(badge) }
        return "\(position(index, of: count)): \(self.badge(badge))"
    }

    /// The slot for VoiceOver.
    static func slotLabel(conflict index: Int, of count: Int) -> String {
        "\(position(index, of: count)), waiting: \(slotPrompt)"
    }

    /// The Repository menu's Resolve items.
    static let resolveMenu = "Resolve"
    static let takeOursMenuItem = "Take Ours"
    static let takeTheirsMenuItem = "Take Theirs"
    static let takeBothMenuItem = "Take Both, Ours First"
    static let takeBothTheirsFirstMenuItem = "Take Both, Theirs First"


    private static func sideName(_ side: ConflictSide) -> String { side == .ours ? "Ours" : "Theirs" }

    private static func files(_ count: Int) -> String { count == 1 ? "1 File" : "\(count) Files" }

    /// The sidebar's menu item and footer button for a selection of `count` files.
    static func takeForFilesMenuItem(_ side: ConflictSide, count: Int) -> String {
        "Take \(sideName(side)) for \(files(count))\u{2026}"
    }

    static func takeForFilesTitle(_ plan: TakeForFilesPlan) -> String {
        "Take \(sideName(plan.side)) for \(files(plan.files.count))?"
    }

    /// The sheet's lines: what is taken from where, which files get a copy first (edited since
    /// git wrote the conflict), and each file skipped with why.
    static func takeForFiles(_ plan: TakeForFilesPlan, _ sides: SideLabels) -> [String] {
        let from = sides.label(plan.side)
        var lines: [String] = []
        let taken = plan.files.map(\.file.path)
        if !taken.isEmpty {
            lines.append(
                taken.count == 1
                    ? "\(name(taken[0])) is replaced by the whole file from \(from), and staged."
                    : "\(StashWording.names(taken)) are each replaced by the whole file from \(from), and staged.")
        }
        if plan.copies.count == 1 {
            lines.append(
                "\(name(plan.copies[0])) was changed since git wrote the conflict. Gitter keeps a copy in the "
                    + "Stashes list first, as \"Replaced by Gitter: \(plan.copies[0])\".")
        } else if plan.copies.count > 1 {
            lines.append(
                "\(StashWording.names(plan.copies)) were changed since git wrote the conflict. Gitter keeps a copy "
                    + "of each in the Stashes list first, as \"Replaced by Gitter: <file>\".")
        }
        for skipped in plan.skipped {
            switch skipped.reason {
            case .noSide: lines.append("Skipped: \(name(skipped.path)), which \(from) deleted.")
            case .submodule: lines.append("Skipped: \(name(skipped.path)), a submodule, which Gitter can't resolve.")
            }
        }
        return lines
    }

    static func takeForFilesButton(_ plan: TakeForFilesPlan) -> String {
        "Take \(sideName(plan.side)) for \(files(plan.files.count))"
    }

    /// The notice after the files were taken: those resolved, the copy filed (or how many), and
    /// the files skipped.
    static func tookForFiles(_ plan: TakeForFilesPlan, _ receipts: [ConflictReceipt], _ sides: SideLabels) -> String {
        var text =
            "Resolved \(StashWording.names(receipts.map(\.path))) with the whole file from \(sides.label(plan.side))."
        let recorded = receipts.compactMap(\.recorded)
        if recorded.count == 1 {
            text += " The edited file is in the Stashes list as \"\(recorded[0].message)\"."
        } else if recorded.count > 1 {
            text += " The \(recorded.count) edited files are in the Stashes list."
        }
        if !plan.skipped.isEmpty { text += " Skipped \(StashWording.names(plan.skipped.map(\.path)))." }
        return text
    }

    // MARK: - Stage All

    /// Stage All never stages an unmerged path (M 22); this says how many it left.
    static func stageAllSkipped(_ count: Int) -> String {
        count == 1
            ? "1 conflicted file was left out — resolve it first"
            : "\(count) conflicted files were left out — resolve them first"
    }
}

/// A whole-file side's column (`ConflictWording.wholeFileSideContent`).
enum WholeFileSideContent: Hashable, Sendable {
    case text(String)
    case description(String)
}

extension String {
    /// The first character lowercased: "Conflict 2 of 3" inside a sentence.
    fileprivate var lowercasedFirst: String { prefix(1).lowercased() + dropFirst() }
}
