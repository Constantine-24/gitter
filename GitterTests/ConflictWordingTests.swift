import Foundation
import GitCore
import Testing

@testable import Gitter

/// Every sentence the resolver puts on screen, pinned: the side labels, the kind in words, the
/// row badge, why a file is whole-file only, the buttons, each sheet, every `ConflictError`, the
/// notices, Stage All's skip notice, and the discard sentences A2 changed. Pure — no store, no
/// repository, no `UserDefaults`.
@Suite struct ConflictWordingTests {

    static let sha = "fedcba9876543210fedcba9876543210fedcba98"
    static let onto = CommitRef(sha: "1234567890abcdef1234567890abcdef12345678", subject: "Upstream tip")
    static let current = CommitRef(sha: sha, subject: "Fix the parser")
    static let sides = SideLabels(ours: "main", theirs: "feature")

    static func stage(_ mode: String = "100644", _ blob: String = "a") -> ConflictStage {
        ConflictStage(mode: mode, blob: blob)
    }

    static func file(
        _ kind: ConflictKind, base: ConflictStage? = stage(), ours: ConflictStage? = stage(),
        theirs: ConflictStage? = stage()
    ) -> ConflictedFile {
        ConflictedFile(path: "f.txt", kind: kind, base: base, ours: ours, theirs: theirs)
    }

    static let record = Stash(
        sha: sha, index: 0, reflogSubject: "On main: Replaced by Gitter: f.txt", parents: ["p1", "p2"],
        date: Date(timeIntervalSince1970: 1_800_000_000))

    // MARK: - A conflict that cannot be read (B4 item 4)

    @Test func theFailedReadSaysWhatCanStillBeDone() {
        #expect(ConflictWording.loadFailed("git went away")
            == "Gitter couldn't read this conflict: git went away. You can still open the file in its editor, "
            + "or mark it resolved as it is.")
        #expect(ConflictWording.tryAgain == "Try Again")
    }

    /// git's words, trimmed, often end in their own period: one is dropped before the sentence's,
    /// so the banner never reads "..". Only one: an ellipsis keeps two of its dots.
    @Test func gitsOwnFinalPeriodIsNotDoubled() {
        #expect(ConflictWording.loadFailed("fatal: bad object.")
            == "Gitter couldn't read this conflict: fatal: bad object. You can still open the file in its "
            + "editor, or mark it resolved as it is.")
        #expect(ConflictWording.loadFailed("timed out...").hasPrefix("Gitter couldn't read this conflict: timed out... "))
    }

    // MARK: - Side labels

    @Test func withNoOperationTheSidesAreHeadAndIncoming() {
        #expect(ConflictWording.sides(operation: nil, progress: nil, branch: "main")
            == SideLabels(ours: "HEAD", theirs: "incoming"))
    }

    @Test func aMergeNamesTheCurrentBranchAndTheMergedOne() {
        let named = OperationProgress(operation: .merge, mergeHead: Self.current, mergedName: "feature")
        #expect(ConflictWording.sides(operation: .merge, progress: named, branch: "main")
            == SideLabels(ours: "main", theirs: "feature"))
        let unnamed = OperationProgress(operation: .merge, mergeHead: Self.current)
        #expect(ConflictWording.sides(operation: .merge, progress: unnamed, branch: "main")
            == SideLabels(ours: "main", theirs: "MERGE_HEAD fedcba9"))
        #expect(ConflictWording.sides(operation: .merge, progress: nil, branch: nil)
            == SideLabels(ours: "HEAD", theirs: "MERGE_HEAD"))
    }

    /// In a rebase stage 2 is the upstream and stage 3 the user's own commit (M 6).
    @Test func aRebaseNamesTheUpstreamAndTheUsersOwnCommit() {
        let progress = OperationProgress(operation: .rebase, step: 1, total: 2, current: Self.current, onto: Self.onto)
        #expect(ConflictWording.sides(operation: .rebase, progress: progress, branch: nil)
            == SideLabels(ours: "upstream (1234567)", theirs: "your commit fedcba9 Fix the parser"))
        #expect(ConflictWording.sides(operation: .rebase, progress: nil, branch: nil)
            == SideLabels(ours: "upstream", theirs: "your commit"))
    }

    @Test func aPickAndARevertNameTheBranchAndTheCommit() {
        let pick = OperationProgress(operation: .cherryPick, current: Self.current)
        #expect(ConflictWording.sides(operation: .cherryPick, progress: pick, branch: "main")
            == SideLabels(ours: "main", theirs: "fedcba9 Fix the parser"))
        let revert = OperationProgress(operation: .revert, current: Self.current)
        #expect(ConflictWording.sides(operation: .revert, progress: revert, branch: "main")
            == SideLabels(ours: "main", theirs: "undoing fedcba9"))
        #expect(ConflictWording.sides(operation: .cherryPick, progress: nil, branch: nil)
            == SideLabels(ours: "HEAD", theirs: "the picked commit"))
        #expect(ConflictWording.sides(operation: .revert, progress: nil, branch: "main")
            == SideLabels(ours: "main", theirs: "the revert"))
    }

    @Test func aSquashAndGitAmHaveTheirOwnIncomingSide() {
        #expect(ConflictWording.sides(operation: .squash, progress: nil, branch: "main")
            == SideLabels(ours: "main", theirs: "the squashed commits"))
        #expect(ConflictWording.sides(operation: .applyingPatches, progress: nil, branch: "main")
            == SideLabels(ours: "main", theirs: "the patch"))
    }

    @Test func aLongSubjectIsCut() {
        let long = CommitRef(sha: Self.sha, subject: String(repeating: "x", count: 80))
        let labels = ConflictWording.sides(
            operation: .cherryPick, progress: OperationProgress(operation: .cherryPick, current: long),
            branch: "main")
        #expect(labels.theirs == "fedcba9 " + String(repeating: "x", count: 50) + "\u{2026}")
    }

    // MARK: - The kind

    @Test func everyKindIsSaidInWords() {
        #expect(ConflictWording.kind(Self.file(.bothModified), sides: Self.sides) == "Changed on both sides")
        #expect(ConflictWording.kind(Self.file(.bothAdded, base: nil), sides: Self.sides) == "Added on both sides")
        #expect(ConflictWording.kind(Self.file(.deletedByUs, ours: nil), sides: Self.sides)
            == "Deleted in main, changed in feature")
        #expect(ConflictWording.kind(Self.file(.deletedByThem, theirs: nil), sides: Self.sides)
            == "Changed in main, deleted in feature")
        #expect(ConflictWording.kind(Self.file(.addedByUs, base: nil, theirs: nil), sides: Self.sides)
            == "Added only in main")
        #expect(ConflictWording.kind(Self.file(.addedByThem, base: nil, ours: nil), sides: Self.sides)
            == "Added only in feature")
        #expect(ConflictWording.kind(Self.file(.bothDeleted, ours: nil, theirs: nil), sides: Self.sides)
            == "Deleted on both sides")
    }

    @Test func theFlagsAreSaid() {
        let modeOnly = Self.file(.bothAdded, base: nil, ours: Self.stage("100644", "b"), theirs: Self.stage("100755", "b"))
        #expect(modeOnly.isModeOnly)
        #expect(ConflictWording.kind(modeOnly, sides: Self.sides)
            == "Added on both sides with the same content but different modes (644 and 755)")
        let link = Self.file(.bothModified, ours: Self.stage("120000"))
        #expect(ConflictWording.kind(link, sides: Self.sides) == "Changed on both sides (a symbolic link)")
        let sub = Self.file(.bothModified, base: Self.stage("160000"), ours: Self.stage("160000"), theirs: Self.stage("160000"))
        #expect(ConflictWording.kind(sub, sides: Self.sides) == "Changed on both sides (a submodule)")
    }

    @Test func theRowBadgeIsGitsTwoLetters() {
        #expect(ConflictWording.badge(.bothModified) == "UU")
        #expect(ConflictWording.badge(.bothAdded) == "AA")
        #expect(ConflictWording.badge(.deletedByUs) == "DU")
        #expect(ConflictWording.badge(.deletedByThem) == "UD")
        #expect(ConflictWording.badge(.addedByUs) == "AU")
        #expect(ConflictWording.badge(.addedByThem) == "UA")
        #expect(ConflictWording.badge(.bothDeleted) == "DD")
    }

    // MARK: - Why there are no blocks

    @Test func everyWholeFileReasonIsASentence() {
        #expect(ConflictWording.wholeFile(.binary)
            == "Git can't draw conflict blocks in a binary file. Keep one side's version whole.")
        #expect(ConflictWording.wholeFile(.symlink)
            == "One side is a symbolic link, which can only be kept whole.")
        #expect(ConflictWording.wholeFile(.modeOnly)
            == "Both sides added the same content; only the file mode differs.")
        #expect(ConflictWording.wholeFile(.deletion)
            == "One side deleted the file, so there are no blocks to choose between.")
        #expect(ConflictWording.wholeFile(.oneSided)
            == "Only one side has a file at this path, so there are no blocks to choose between.")
        #expect(ConflictWording.wholeFile(.mergeAttribute("binary"))
            == "The file's merge attribute is \"binary\", so git did not merge it line by line. Keep one "
            + "side's version whole.")
        #expect(ConflictWording.wholeFile(.unparsable)
            == "Gitter couldn't split this conflict into blocks. Keep one side's version whole, or "
            + "resolve it in your editor.")
    }

    @Test func aSubmoduleAndAChangedFileExplainThemselves() {
        #expect(ConflictWording.submodule
            == "This is a submodule conflict, which Gitter can't resolve yet. In a terminal, check out "
            + "the commit you want inside the submodule, then stage the submodule here.")
        #expect(ConflictWording.changedSinceConflict("f.txt")
            == "\"f.txt\" was changed since git wrote the conflict, so its blocks aren't shown. Take a "
            + "side \u{2014} Gitter keeps a copy of the file in the Stashes list first \u{2014} or finish "
            + "it in your editor and use Mark Resolved.")
    }

    // MARK: - The chooser

    @Test func theChooserSaysWhereItIs() {
        #expect(ConflictWording.position(1, of: 5) == "Conflict 2 of 5")
        #expect(ConflictWording.chosen(3, of: 5) == "3 of 5 chosen")
        #expect(ConflictWording.choice(.ours) == "Ours")
        #expect(ConflictWording.choice(.theirs) == "Theirs")
        #expect(ConflictWording.choice(.oursThenTheirs) == "Both (ours first)")
        #expect(ConflictWording.choice(.theirsThenOurs) == "Both (theirs first)")
        #expect(ConflictWording.resolveHelp(remaining: 0) == "Write the chosen blocks to the file and stage it")
        #expect(ConflictWording.resolveHelp(remaining: 2) == "Choose a side for every conflict first (2 left)")
        #expect(ConflictWording.resolveHelp(remaining: 1) == "Choose a side for every conflict first (1 left)")
        #expect(ConflictWording.side(.ours, Self.sides) == "Ours \u{2014} main")
        #expect(ConflictWording.side(.theirs, Self.sides) == "Theirs \u{2014} feature")
    }

    @Test func everyActionHasItsTitle() {
        let text = Self.file(.bothModified)
        #expect(ConflictWording.title(.resolveFile, text) == "Resolve File")
        #expect(ConflictWording.title(.takeOurs, text) == "Take Ours")
        #expect(ConflictWording.title(.takeTheirs, text) == "Take Theirs")
        #expect(ConflictWording.title(.openInEditor, text) == "Open in Editor")
        #expect(ConflictWording.title(.markResolved, text) == "Mark Resolved")
        #expect(ConflictWording.title(.delete, Self.file(.deletedByUs, ours: nil)) == "Delete the File")
        #expect(ConflictWording.title(.keep, Self.file(.deletedByUs, ours: nil)) == "Keep Their Version")
        #expect(ConflictWording.title(.keep, Self.file(.deletedByThem, theirs: nil)) == "Keep Our Version")
        #expect(ConflictWording.title(.takeOurs, Self.file(.addedByUs, base: nil, theirs: nil)) == "Keep Our Version")
        #expect(ConflictWording.title(.takeTheirs, Self.file(.addedByThem, base: nil, ours: nil)) == "Keep Their Version")
        let modeOnly = Self.file(.bothAdded, base: nil, ours: Self.stage("100644", "b"), theirs: Self.stage("100755", "b"))
        #expect(ConflictWording.title(.takeOurs, modeOnly) == "Keep Ours (mode 644)")
        #expect(ConflictWording.title(.takeTheirs, modeOnly) == "Keep Theirs (mode 755)")
    }

    @Test func everyActionSaysWhatItDoes() {
        let text = Self.file(.bothModified)
        #expect(ConflictWording.help(.takeOurs, text, Self.sides) == "Use the whole file as main has it, and stage it")
        #expect(ConflictWording.help(.takeTheirs, text, Self.sides) == "Use the whole file as feature has it, and stage it")
        #expect(ConflictWording.help(.delete, text, Self.sides) == "Resolve the conflict by deleting the file")
        #expect(ConflictWording.help(.keep, Self.file(.deletedByUs, ours: nil), Self.sides)
            == "Keep the file as feature has it, and stage it")
        #expect(ConflictWording.help(.keep, Self.file(.deletedByThem, theirs: nil), Self.sides)
            == "Keep the file as main has it, and stage it")
        #expect(ConflictWording.help(.openInEditor, text, Self.sides) == "Open the file in its default app")
        #expect(ConflictWording.help(.markResolved, text, Self.sides) == "Stage the file as it is now")
        #expect(ConflictWording.help(.resolveFile, text, Self.sides) == "Write the chosen blocks to the file and stage it")
    }

    // MARK: - Sheets

    @Test func theReplaceSheetSaysWhereTheCopyGoes() {
        #expect(ConflictWording.replaceTitle("f.txt") == "Replace the edited \"f.txt\"?")
        #expect(ConflictWording.replaceBody("f.txt")
            == "\"f.txt\" was changed since git wrote the conflict. Gitter keeps a copy in the Stashes "
            + "list before replacing it.")
        #expect(ConflictWording.replaceDestination("f.txt")
            == "The copy goes to the Stashes list as \"Replaced by Gitter: f.txt\".")
        let text = Self.file(.bothModified)
        #expect(ConflictWording.replaceThen(.blocks([.ours]), text, Self.sides)
            == "Then the chosen blocks are written to the file, and it is staged.")
        #expect(ConflictWording.replaceThen(.take(.theirs), text, Self.sides)
            == "Then the whole file is taken from feature, and it is staged.")
        #expect(ConflictWording.replaceThen(.delete, text, Self.sides)
            == "Then the file is deleted, and the deletion is staged.")
        #expect(ConflictWording.replaceThen(.keep, Self.file(.deletedByUs, ours: nil), Self.sides)
            == "Then the file is kept as feature has it, and it is staged.")
        #expect(ConflictWording.replaceButton(.blocks([.ours]), text) == "Resolve File")
        #expect(ConflictWording.replaceButton(.take(.ours), text) == "Take Ours")
        #expect(ConflictWording.replaceButton(.delete, text) == "Delete the File")
        #expect(ConflictWording.replaceButton(.keep, Self.file(.deletedByThem, theirs: nil)) == "Keep Our Version")
    }

    /// `leftoverMarkers` can over-count (a content line that is exactly an opening marker), so no
    /// sentence promises a number of blocks.
    @Test func theMarkResolvedSheetPromisesNoCount() {
        #expect(ConflictWording.markResolvedTitle("f.txt") == "Mark \"f.txt\" resolved with conflict markers in it?")
        #expect(ConflictWording.markResolvedBody("f.txt")
            == "\"f.txt\" still contains conflict markers. Marking it resolved stages the file with the "
            + "markers in it, and the next commit would contain them unless the file is edited first.")
        #expect(ConflictWording.markResolvedButton == "Mark Resolved Anyway")
        let body = ConflictWording.markResolvedBody("f.txt")
        #expect(!body.contains { $0.isNumber })
    }

    @Test func theReopenSheetSaysWhatComesBackAndWhereTheResolutionGoes() {
        #expect(ConflictWording.reopenTitle("f.txt") == "Reopen the conflict in \"f.txt\"?")
        #expect(ConflictWording.reopenBody("f.txt", .markers, Self.sides)
            == "Git's conflict comes back in place of the resolution: \"f.txt\" gets its conflict "
            + "markers again and is unmerged until it is resolved again.")
        #expect(ConflictWording.reopenDestination("f.txt")
            == "The resolution as it is now \u{2014} the staged file and the file on disk \u{2014} goes "
            + "to the Stashes list first as \"Reopened by Gitter: f.txt\".")
        #expect(ConflictWording.reopenButton == "Reopen Conflict")
        #expect(ConflictWording.reopenMenuItem == "Reopen Conflict\u{2026}")
        #expect(ConflictWording.reopenOffer("f.txt")
            == "The conflict in \"f.txt\" was resolved. It can be reopened while the operation is in progress.")
    }

    /// Fix round 1: reopening a binary puts ours' bytes back with no markers, a mode-only add
    /// puts ours' mode back, a driver writes the file again (measured, `ReopenedFileTests`) —
    /// each said with the operation's side names, where a rebase's "ours" is the upstream.
    @Test func theReopenSheetSaysWhatComesBackForEachKind() {
        let rebase = SideLabels(ours: "upstream (1234567)", theirs: "your commit fedcba9 Fix")
        #expect(ConflictWording.reopenBody("b.bin", .oursVersion, Self.sides)
            == "Git's conflict comes back in place of the resolution, without conflict markers: git "
            + "can't merge \"b.bin\" line by line, so the file goes back to the version from main and "
            + "is unmerged until it is resolved again.")
        #expect(ConflictWording.reopenBody("b.bin", .oursVersion, rebase)
            == "Git's conflict comes back in place of the resolution, without conflict markers: git "
            + "can't merge \"b.bin\" line by line, so the file goes back to the version from upstream "
            + "(1234567) and is unmerged until it is resolved again.")
        #expect(ConflictWording.reopenBody("n.sh", .oursMode, rebase)
            == "Git's conflict comes back in place of the resolution: the content of \"n.sh\" stays as "
            + "it is, its mode goes back to the one in upstream (1234567), and it is unmerged until it "
            + "is resolved again.")
        #expect(ConflictWording.reopenBody("t.txt", .driver("mine"), Self.sides)
            == "Git's conflict comes back in place of the resolution: the \"mine\" merge driver writes "
            + "\"t.txt\" again, and it is unmerged until it is resolved again.")
        // Final review L170: an attribute that tells git not to merge the file (text too) is
        // not "can't merge line by line".
        #expect(ConflictWording.reopenBody("t.txt", .oursByAttribute("unset"), Self.sides)
            == "Git's conflict comes back in place of the resolution, without conflict markers: the "
            + "merge attribute of \"t.txt\" is unset (-merge, or the binary attribute), which tells git "
            + "not to merge it, so the file goes back to the version from main and is unmerged until it "
            + "is resolved again.")
        #expect(ConflictWording.reopenBody("t.txt", .oursByAttribute("binary"), rebase)
            == "Git's conflict comes back in place of the resolution, without conflict markers: the "
            + "merge attribute of \"t.txt\" is \"binary\", which tells git not to merge it, so the file "
            + "goes back to the version from upstream (1234567) and is unmerged until it is resolved again.")
        for kind in [ReopenedFile.oursByAttribute("unset"), .oursByAttribute("binary")] {
            #expect(!ConflictWording.reopenBody("t.txt", kind, Self.sides).contains("line by line"))
        }
        for kind in [ReopenedFile.oursVersion, .oursByAttribute("unset"), .oursMode, .driver("mine")] {
            #expect(!ConflictWording.reopenBody("f", kind, Self.sides).contains("markers again"))
        }
    }

    // MARK: - Refusals

    @Test func everyConflictErrorIsASentence() {
        #expect(ConflictWording.error(.changedSinceShown("f.txt"))
            == "\"f.txt\" changed after it was shown, so nothing was written. Look at it again, then choose.")
        #expect(ConflictWording.error(.wouldReplaceEdits("f.txt"))
            == "\"f.txt\" was changed since git wrote the conflict, so nothing was written.")
        #expect(ConflictWording.error(.stageMissing("f.txt", .theirs))
            == "\"f.txt\" has no theirs version: that side deleted it. Nothing was written.")
        #expect(ConflictWording.error(.stageMissing("f.txt", .ours))
            == "\"f.txt\" has no ours version: that side deleted it. Nothing was written.")
        #expect(ConflictWording.error(.notAvailable("f.txt"))
            == "That can't be done to \"f.txt\" now, so nothing was written.")
        #expect(ConflictWording.error(.choicesDoNotMatch("f.txt"))
            == "The conflict in \"f.txt\" changed after it was shown, so nothing was written. Look at it "
            + "again, then choose.")
        #expect(ConflictWording.error(.leftoverMarkers(3))
            == "The file still contains conflict markers, so nothing was staged.")
        #expect(ConflictWording.error(.pathTypeChanged("f.txt"))
            == "\"f.txt\" is no longer a file \u{2014} a folder stands there, or a folder on its path is "
            + "now a file \u{2014} so nothing was written: git would delete what is there.")
    }

    @MainActor @Test func theBannerDescribesAConflictError() {
        #expect(RepositoryStore.describe(ConflictError.notAvailable("f.txt"))
            == ConflictWording.error(.notAvailable("f.txt")))
    }

    // MARK: - Notices

    @Test func everyResolutionHasItsNotice() {
        let receipt = ConflictReceipt(path: "f.txt", recorded: nil)
        #expect(ConflictWording.done(.blocks([.ours]), receipt, Self.sides) == "Resolved \"f.txt\".")
        #expect(ConflictWording.done(.take(.ours), receipt, Self.sides)
            == "Resolved \"f.txt\" with the whole file from main.")
        #expect(ConflictWording.done(.delete, receipt, Self.sides) == "Resolved \"f.txt\" by deleting it.")
        #expect(ConflictWording.done(.keep, receipt, Self.sides) == "Resolved \"f.txt\" by keeping the file.")
        let recorded = ConflictReceipt(path: "f.txt", recorded: Self.record)
        #expect(ConflictWording.done(.take(.theirs), recorded, Self.sides)
            == "Resolved \"f.txt\" with the whole file from feature. The edited file is in the Stashes "
            + "list as \"Replaced by Gitter: f.txt\".")
        #expect(ConflictWording.marked("f.txt") == "Marked \"f.txt\" resolved.")
        let reopened = Stash(
            sha: Self.sha, index: 0, reflogSubject: "On main: Reopened by Gitter: f.txt", parents: ["p1", "p2"],
            date: Date(timeIntervalSince1970: 1_800_000_000))
        #expect(ConflictWording.reopened(ConflictReceipt(path: "f.txt", recorded: reopened))
            == "Reopened the conflict in \"f.txt\". The resolution is in the Stashes list as \"Reopened by "
            + "Gitter: f.txt\".")
        #expect(ConflictWording.reopened(ConflictReceipt(path: "f.txt", recorded: nil))
            == "Reopened the conflict in \"f.txt\".")
        #expect(NoticeWording.title(.showStash(Self.record)) == "Show Copy")
    }

    @Test func stageAllSaysWhatItLeftOut() {
        #expect(ConflictWording.stageAllSkipped(2) == "2 conflicted files were left out — resolve them first")
        #expect(ConflictWording.stageAllSkipped(1) == "1 conflicted file was left out — resolve it first")
    }

    // MARK: - Discard during an operation (A2)

    /// In the conservative case (no operation paths) the refused paths may be the user's own
    /// staged changes, so the sentence never claims they are the operation's.
    @Test func aStagedSideRefusalNamesTheFilesWithoutClaimingThem() {
        let text = DiscardWording.refusal(.partOfOperation(["z.txt"]))
        #expect(text
            == "Can't discard the staged changes in \"z.txt\" while an operation is in progress: they may "
            + "be part of its result, which its commit would lose. Nothing was discarded. Its unstaged "
            + "changes, if any, can still be discarded on their own.")
        #expect(DiscardWording.refusal(.partOfOperation(["y.txt", "z.txt"])).hasSuffix(
            "Nothing was discarded. Their unstaged changes, if any, can still be discarded on their own."))
        #expect(!text.contains("are part of"))
        #expect(DiscardWording.untrackedPartRefused(.partOfOperation(["z.txt"]))
            == "The untracked files were not moved to the Trash: the staged changes in \"z.txt\" can't be "
            + "discarded while an operation is in progress.")
    }

    @Test func aWholeFileUndoWaitsForTheOperationToEnd() {
        #expect(DiscardWording.undoRefused(.operationInProgress(.rebase))
            == "Couldn't undo yet: Undo Discard can't put whole files back while a rebase is in progress; "
            + "it works once the rebase ends, and until then the copy stays in the Stashes list.")
        #expect(DiscardWording.refusal(.operationInProgress(.merge))
            == "Undo Discard can't put whole files back while a merge is in progress; it works once the "
            + "merge ends, and until then the copy stays in the Stashes list.")
        #expect(DiscardWording.done([DiscardWordingTests.unstaged], during: .cherryPick)
            == "Discarded the unstaged changes to \"a.txt\". Undo Discard can't put whole files back while "
            + "a cherry-pick is in progress; it works once the cherry-pick ends, and until then the copy "
            + "stays in the Stashes list.")
        // Lines and the Trash come back during an operation: nothing to add.
        #expect(DiscardWording.done([DiscardWordingTests.lines], during: .merge) == "Discarded 3 lines of \"a.txt\".")
        #expect(DiscardWording.done([DiscardWordingTests.unstaged], during: nil)
            == "Discarded the unstaged changes to \"a.txt\".")
    }

    /// The notice and its Undo stay when every undo only waits for the operation; anything else
    /// (something ran, or failed for another reason) ends the notice as before.
    @MainActor @Test func anUndoThatOnlyWaitsKeepsItsNotice() {
        let waiting: Result<UndoDiscardOutcome, Error> = .failure(DiscardRefusal.operationInProgress(.merge))
        let other: Result<UndoDiscardOutcome, Error> = .failure(DiscardRefusal.unmerged(["a.txt"]))
        let back: Result<UndoDiscardOutcome, Error> = .success(.restored)
        let receipt = DiscardWordingTests.unstaged
        #expect(RepositoryStore.onlyWaitingForTheOperation([(receipt, waiting)]))
        #expect(RepositoryStore.onlyWaitingForTheOperation([(receipt, waiting), (receipt, waiting)]))
        #expect(!RepositoryStore.onlyWaitingForTheOperation([(receipt, waiting), (receipt, back)]))
        #expect(!RepositoryStore.onlyWaitingForTheOperation([(receipt, other)]))
        #expect(!RepositoryStore.onlyWaitingForTheOperation([]))
    }
}
