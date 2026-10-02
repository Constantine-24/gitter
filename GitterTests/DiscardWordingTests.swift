import Foundation
import GitCore
import Testing

@testable import Gitter

/// Every sentence a discard puts on screen, pinned: the sheet's rows, title, button and
/// destination, the notice after a discard, every refusal and failure, every undo outcome, and
/// why an entry point is off. Pure — no store, no repository, no `UserDefaults`.
@Suite struct DiscardWordingTests {

    static let sha = "a1b2c3d4e5f60718293a4b5c6d7e8f9012345678"
    static let noDiffs = DiscardExpectation.diffs([])
    static let noItems = DiscardExpectation.untracked([])
    static let record = Stash(
        sha: sha, index: 0, reflogSubject: "Discarded by Gitter: a.txt", parents: ["p1", "p2"],
        date: Date(timeIntervalSince1970: 1_800_000_000))
    static let patch = Patch(text: "", hasContextFreeHunk: false, path: "a.txt", oldBlob: nil, newBlob: nil)

    static func receipt(_ request: DiscardRequest, trashed: [String: URL] = [:]) -> DiscardReceipt {
        let tracked: Bool = if case .untracked = request { false } else { true }
        return DiscardReceipt(
            request: request, record: tracked ? record : nil, headAtDiscard: "h", trashed: trashed)
    }

    static let unstaged = receipt(.unstaged(paths: ["a.txt"], expected: noDiffs))
    static let staged = receipt(.stagedAndUnstaged(paths: ["p"], expected: noDiffs))
    /// A line discard as GitCore returns a successful one: with what the file was left as, and
    /// which form its bytes had — what its undo checks against.
    static let lines = DiscardReceipt(
        request: .lines(path: "a.txt", patch: patch, lineCount: 3, expected: noDiffs), record: record,
        headAtDiscard: "h", trashed: [:],
        afterDiscard: DiscardedFileState(worktree: Data("x\n".utf8), indexEntry: "e", head: "h"),
        recordedForm: .raw)
    /// The same discard whose state could not be read afterwards: GitCore's undo refuses it.
    static let linesUnverified = receipt(.lines(path: "a.txt", patch: patch, lineCount: 3, expected: noDiffs))
    static let oneLine = receipt(.lines(path: "a.txt", patch: patch, lineCount: 1, expected: noDiffs))
    static let trash = URL(fileURLWithPath: "/Users/x/.Trash")
    static let untracked = receipt(
        .untracked(paths: ["u.txt", "ud/"], expected: noItems),
        trashed: ["u.txt": trash.appending(path: "u.txt"), "ud/": trash.appending(path: "ud")])

    // MARK: - Rows

    /// GitCore's argument guard (Ruling 26) reaches the banner as an ordinary error, saying which
    /// command was not run and why — not that nothing ran: earlier commands of the same action (a
    /// record, say) may have.
    @MainActor @Test func tooManyArgumentsIsAnOrdinaryErrorSentence() {
        #expect(
            RepositoryStore.describe(GitError.tooManyArguments(count: 5_003, limit: 4_000))
                == "Gitter stopped before a git command that needed 5003 arguments, more than the 4000 one git "
                + "process can take; that command did not run.")
    }

    @Test func everyRowKindSaysWhatItLoses() {
        #expect(DiscardWording.loss(.counts(added: 12, removed: 3)) == "+12 \u{2212}3")
        #expect(DiscardWording.loss(.counts(added: 0, removed: 7)) == "+0 \u{2212}7")
        #expect(DiscardWording.loss(.binary) == "binary file")
        #expect(DiscardWording.loss(.noLineChanges) == "no line changes")
        #expect(DiscardWording.loss(.lines(3)) == "3 lines")
        #expect(DiscardWording.loss(.lines(1)) == "1 line")
        #expect(DiscardWording.loss(.untrackedFile) == "untracked \u{2192} Trash")
        #expect(DiscardWording.loss(.untrackedFolder) == "untracked folder \u{2192} Trash")
    }

    @Test func aRowsLossIsCountedFromTheDiffsTheSheetShows() {
        let hunk = Hunk(
            header: "@@ -1,2 +1,3 @@", oldStart: 1, oldCount: 2, newStart: 1, newCount: 3,
            lines: [
                DiffLine(id: 0, kind: .context, oldNumber: 1, newNumber: 1, text: "a"),
                DiffLine(id: 1, kind: .removed, oldNumber: 2, newNumber: nil, text: "b"),
                DiffLine(id: 2, kind: .added, oldNumber: nil, newNumber: 2, text: "B"),
                DiffLine(id: 3, kind: .added, oldNumber: nil, newNumber: 3, text: "C"),
            ])
        let modified = FileDiff(oldPath: "f", newPath: "f", kind: .modified, isBinary: false, hunks: [hunk])
        let binary = FileDiff(oldPath: "b", newPath: "b", kind: .modified, isBinary: true, hunks: [])
        let renamed = FileDiff(oldPath: "o", newPath: "n", kind: .renamed, isBinary: false, hunks: [])
        #expect(DiscardWording.Loss(of: [modified]) == .counts(added: 2, removed: 1))
        // Both sides of a staged-side sheet add up.
        #expect(DiscardWording.Loss(of: [modified, modified]) == .counts(added: 4, removed: 2))
        #expect(DiscardWording.Loss(of: [modified, binary]) == .binary)
        #expect(DiscardWording.Loss(of: [renamed]) == .noLineChanges)
        #expect(DiscardWording.Loss(of: []) == .noLineChanges)
    }

    /// A binary change under `plan b/` and one to a file named like the tail of its path, as
    /// git writes them (no `---`/`+++` lines). The header used to be split at the wrong ` b/`,
    /// so the row for `plan b/blob.bin` lost nothing and `blob.bin`'s row took its diff.
    @MainActor @Test func eachRowUnderAPathWithBSlashIsCountedFromItsOwnDiff() {
        let output = """
            diff --git a/blob.bin b/blob.bin
            index 3e3315e1b02129d197721a8a0b56dd88862f454d..88768efdf77ec78c9a995f94881793be6a41752b 100644
            --- a/blob.bin
            +++ b/blob.bin
            @@ -1 +1 @@
            -a
            +b
            diff --git a/plan b/blob.bin b/plan b/blob.bin
            index 88768efdf77ec78c9a995f94881793be6a41752b..3e3315e1b02129d197721a8a0b56dd88862f454d 100644
            Binary files a/plan b/blob.bin and b/plan b/blob.bin differ

            """
        let files = ["blob.bin", "plan b/blob.bin"].map {
            FileStatus(path: $0, originalPath: nil, staged: nil, unstaged: .modified)
        }

        let rows = RepositoryStore.rows(for: files, diffs: DiffParser.parse(Data(output.utf8)))

        #expect(rows.map(\.name) == ["blob.bin", "plan b/blob.bin"])
        #expect(rows.map(\.loses) == ["+1 \u{2212}1", "binary file"])
    }

    @Test func previewLinesAreMarkedAndCapped() {
        #expect(
            DiscardWording.preview(DiffLine(id: 0, kind: .added, oldNumber: nil, newNumber: 1, text: "new\r"))
                == "+ new")
        #expect(
            DiscardWording.preview(DiffLine(id: 1, kind: .removed, oldNumber: 1, newNumber: nil, text: "old"))
                == "\u{2212} old")
        #expect(DiscardWording.previewMore(3) == "\u{2026} and 3 more lines")
        #expect(DiscardWording.previewMore(1) == "\u{2026} and 1 more line")
    }

    // MARK: - The sheet

    @Test func theDestinationSaysWhereTheCopyGoes() {
        #expect(
            DiscardWording.destination(record: "Discarded by Gitter: a.txt", untracked: false)
                == "A copy goes to the Stashes list as \"Discarded by Gitter: a.txt\".")
        #expect(
            DiscardWording.destination(record: nil, untracked: true)
                == "Untracked files go to the Trash.")
        #expect(
            DiscardWording.destination(record: "Discarded by Gitter: a.txt", untracked: true)
                == "A copy goes to the Stashes list as \"Discarded by Gitter: a.txt\". Untracked "
                + "files go to the Trash.")
    }

    @Test func theTitleNamesWhatIsDiscarded() {
        #expect(
            DiscardWording.title([Self.unstaged.request], all: false)
                == "Discard the unstaged changes to \"a.txt\"?")
        #expect(
            DiscardWording.title([Self.lines.request], all: false) == "Discard 3 lines of \"a.txt\"?")
        #expect(
            DiscardWording.title([Self.oneLine.request], all: false) == "Discard 1 line of \"a.txt\"?")
        #expect(
            DiscardWording.title([Self.untracked.request], all: false)
                == "Move \"u.txt\" and \"ud/\" to the Trash?")
        #expect(
            DiscardWording.title([Self.unstaged.request, Self.untracked.request], all: false)
                == "Discard the unstaged changes to \"a.txt\" and move \"u.txt\" and \"ud/\" to the "
                + "Trash?")
        #expect(
            DiscardWording.title([Self.unstaged.request, Self.untracked.request], all: true)
                == "Discard all unstaged changes?")
    }

    @Test func theStagedSideTitleSaysStagedAndUnstagedChanges() {
        #expect(
            DiscardWording.title([Self.staged.request], all: false)
                == "Discard the staged and unstaged changes to \"p\"?")
    }

    @Test func namesInATitleAreCappedAtThree() {
        let request = DiscardRequest.unstaged(paths: ["a", "b", "c", "d", "e"], expected: Self.noDiffs)
        #expect(
            DiscardWording.title([request], all: false)
                == "Discard the unstaged changes to \"a\", \"b\", \"c\" and 2 more?")
    }

    @Test func theConfirmButtonSaysWhatItDoes() {
        #expect(DiscardWording.confirmButton([Self.unstaged.request], all: false) == "Discard")
        #expect(DiscardWording.confirmButton([Self.staged.request], all: false) == "Discard")
        #expect(DiscardWording.confirmButton([Self.lines.request], all: false) == "Discard 3 Lines")
        #expect(DiscardWording.confirmButton([Self.oneLine.request], all: false) == "Discard 1 Line")
        #expect(DiscardWording.confirmButton([Self.untracked.request], all: false) == "Move to Trash")
        #expect(
            DiscardWording.confirmButton([Self.unstaged.request, Self.untracked.request], all: true)
                == "Discard All")
    }

    @Test func theStaleLineSaysTheConfirmWillBeRefused() {
        #expect(
            DiscardWording.sheetStale
                == "This changed after it was shown. Discarding will be refused; close this and "
                + "ask again.")
    }

    // MARK: - After a discard

    @Test func theNoticeNamesWhatWasDiscarded() {
        #expect(DiscardWording.done([Self.unstaged]) == "Discarded the unstaged changes to \"a.txt\".")
        #expect(
            DiscardWording.done([Self.staged]) == "Discarded the staged and unstaged changes to \"p\".")
        #expect(DiscardWording.done([Self.lines]) == "Discarded 3 lines of \"a.txt\".")
        #expect(
            DiscardWording.done([Self.untracked])
                == "Discarded \"u.txt\" and \"ud/\" (moved to the Trash, where Finder's Put Back "
                + "also restores them).")
        #expect(
            DiscardWording.done([Self.unstaged, Self.untracked])
                == "Discarded the unstaged changes to \"a.txt\"; moved \"u.txt\" and \"ud/\" to the "
                + "Trash, where Finder's Put Back also restores them.")
        // Discard All… with more than three files: the capped list must not run into the next.
        let four = Self.receipt(.unstaged(paths: ["a", "b", "c", "d"], expected: Self.noDiffs))
        #expect(
            DiscardWording.done([four, Self.untracked])
                == "Discarded the unstaged changes to \"a\", \"b\", \"c\" and 1 more; moved "
                + "\"u.txt\" and \"ud/\" to the Trash, where Finder's Put Back also restores them.")
    }

    /// Minor 1: a line discard whose state could not be read afterwards cannot be undone here
    /// (GitCore's undo would refuse it), so no Undo is offered, and the notice names the copy.
    @Test func aDiscardTheUndoCannotCheckIsNotOfferedAndNamesItsCopy() {
        #expect(DiscardWording.isUndoable(Self.lines))
        #expect(!DiscardWording.isUndoable(Self.linesUnverified))
        #expect(
            !DiscardWording.isUndoable(
                DiscardReceipt(
                    request: Self.lines.request, record: Self.record, headAtDiscard: "h", trashed: [:],
                    afterDiscard: Self.lines.afterDiscard, recordedForm: nil)))
        #expect(DiscardWording.isUndoable(Self.unstaged))
        #expect(DiscardWording.isUndoable(Self.staged))
        #expect(DiscardWording.isUndoable(Self.untracked))
        #expect(
            !DiscardWording.isUndoable(
                Self.receipt(.untracked(paths: ["u.txt"], expected: Self.noItems))))
        #expect(
            DiscardWording.done([Self.linesUnverified])
                == "Discarded 3 lines of \"a.txt\". Undo Discard can't check the file, so it is not "
                + "offered; the copy is in the Stashes list as \"Discarded by Gitter: a.txt\". "
                + "Stage the file's other changes before you apply it there.")
    }

    /// A Trash that failed part-way: the notice names only what did go.
    @Test func theNoticeNamesOnlyWhatReachedTheTrash() {
        let partial = Self.receipt(
            .untracked(paths: ["u.txt", "v.txt"], expected: Self.noItems),
            trashed: ["u.txt": Self.trash.appending(path: "u.txt")])
        #expect(
            DiscardWording.done([partial])
                == "Discarded \"u.txt\" (moved to the Trash, where Finder's Put Back also restores it).")
    }

    @Test func theUndoButtonIsNamed() {
        #expect(NoticeWording.title(.undoDiscard([Self.unstaged])) == "Undo Discard")
    }

    // MARK: - Refusals

    @Test func everyRefusalIsASentence() {
        // `.operationInProgress` (only Undo throws it now) and `.partOfOperation` are pinned in
        // `ConflictWordingTests` (A2 Task 5).
        #expect(
            DiscardWording.refusal(.unmerged(["c.txt"]))
                == "Can't discard \"c.txt\": it has unresolved conflicts. Resolve them and stage "
                + "the file first.")
        #expect(
            DiscardWording.refusal(.unmerged(["c.txt", "d.txt"]))
                == "Can't discard \"c.txt\" and \"d.txt\": they have unresolved conflicts. Resolve "
                + "them and stage the files first.")
        #expect(
            DiscardWording.refusal(.intentToAdd(["n.txt"]))
                == "Can't discard \"n.txt\": it is only marked to be added (git add -N), and no "
                + "copy of it can be kept. Stage it fully or unstage it first.")
        #expect(
            DiscardWording.refusal(.submodules(["sub"]))
                == "Can't discard \"sub\": it is a submodule, and no copy of the work inside one "
                + "can be kept.")
        #expect(
            DiscardWording.refusal(.nestedRepositories(["inner/"]))
                == "Can't discard \"inner/\": it belongs to another repository (a submodule, or a "
                + "repository inside this one).")
        #expect(
            DiscardWording.refusal(.needsWholeFile("a.txt"))
                == "Can't discard only some lines of \"a.txt\": its changes can only be discarded "
                + "as a whole file. Nothing was discarded. Discard Changes… on the file discards "
                + "all of its unstaged changes.")
        #expect(
            DiscardWording.refusal(.changedSinceShown(["a.txt"]))
                == "The file changed after this was shown; nothing was discarded.")
        #expect(
            DiscardWording.refusal(.changedSinceShown(["a.txt", "b.txt"]))
                == "The files changed after this was shown; nothing was discarded.")
        #expect(
            DiscardWording.refusal(.pathTypeChanged(["p"]))
                == "Can't discard: \"p\" changed between a file and a folder. Discarding would lose "
                + "what is there now. Put it back, or commit the change first.")
        #expect(
            DiscardWording.refusal(.nothingSelected)
                == "Nothing was discarded: there are no changes left to discard.")
        #expect(
            DiscardWording.refusal(.notTracked(["a.txt"]))
                == "Can't discard \"a.txt\": git no longer tracks it. Nothing was discarded.")
    }

    @Test func aFileFolderSwapIsNamedTheWayTheDiskShowsIt() {
        #expect(
            DiscardWording.typeChanged([.fileBecameFolder("p")])
                == "Can't discard: \"p\" was a file and is now a folder. Discarding would lose "
                + "what is there now. Put it back, or commit the change first.")
    }

    /// Discard All's second half, refused after the first half discarded: the sentence must not
    /// say that nothing was discarded.
    @Test func aRefusedUntrackedPartSaysOnlyThatPartStayed() {
        #expect(
            DiscardWording.untrackedPartRefused(.changedSinceShown(["u.txt"]))
                == "The untracked files were not moved to the Trash: \"u.txt\" changed after this "
                + "was shown.")
        #expect(
            DiscardWording.untrackedPartRefused(.nestedRepositories(["inner/"]))
                == "The untracked files were not moved to the Trash: \"inner/\" belongs to another "
                + "repository (a submodule, or a repository inside this one).")
    }

    /// Any other error: before anything was written, or after a change GitCore proved changed
    /// nothing (it drops the record again then).
    @Test func anyOtherErrorIsInGitsWords() {
        #expect(
            DiscardWording.discardError("error: pathspec 'x' did not match\n")
                == "Couldn't discard: error: pathspec 'x' did not match. Nothing was discarded.")
        #expect(
            DiscardWording.untrackedPartFailed("fatal: nope.")
                == "The untracked files were not moved to the Trash: fatal: nope.")
    }

    // MARK: - Failures part-way

    /// Where the copy is, and that the file may be partly restored — never "apply it from the
    /// Stashes list", which git then refuses too (ruling 3).
    /// Minor 2: GitCore refused a line discard (the file is not in its checkout form) and could
    /// not drop the record it had made. Nothing was discarded, so nothing "may be partly
    /// restored"; the record is what is left over. GitCore's own words, as it throws them.
    @Test func aLineDiscardThatChangedNothingButLeftItsRecordSaysSo() {
        let failure = DiscardFailure(
            receipt: Self.linesUnverified,
            gitsWords: "a.txt is not in its checkout form, so its lines cannot be discarded alone; "
                + "nothing was discarded, and the record made for it could not be removed.")
        let text = DiscardWording.failure(failure)
        #expect(
            text
                == "Couldn't discard 3 lines of \"a.txt\": \"a.txt\" is not in its checkout form, so "
                + "its lines cannot be discarded alone; nothing was discarded, and the record made "
                + "for it could not be removed. The file was not changed; the record is in the "
                + "Stashes list as \"Discarded by Gitter: a.txt\". Discard Changes… on the file "
                + "discards all of its unstaged changes.")
        #expect(!text.contains("partly"))
    }

    @Test func aTrackedFailureSaysWhereTheCopyIsAndThatTheFileMayBePartlyRestored() {
        let failure = DiscardFailure(
            receipt: Self.unstaged, gitsWords: "error: unable to unlink old 'a.txt'\n")
        #expect(
            DiscardWording.failure(failure)
                == "Discarding the unstaged changes to \"a.txt\" did not finish: error: unable to "
                + "unlink old 'a.txt'. \"a.txt\" may be partly restored; a copy of the changes as "
                + "they were is in the Stashes list as \"Discarded by Gitter: a.txt\".")
        #expect(!DiscardWording.failure(failure).contains("apply"))
    }

    @Test func aTrashFailureNamesWhatAlreadyWent() {
        let some = DiscardFailure(
            receipt: Self.receipt(
                .untracked(paths: ["u.txt", "v.txt"], expected: Self.noItems),
                trashed: ["u.txt": Self.trash.appending(path: "u.txt")]),
            gitsWords: "v.txt could not be moved to the Trash: Permission denied.")
        #expect(
            DiscardWording.failure(some)
                == "Moving \"u.txt\" and \"v.txt\" to the Trash did not finish: v.txt could not be "
                + "moved to the Trash: Permission denied. Already in the Trash: \"u.txt\".")
        let none = DiscardFailure(
            receipt: Self.receipt(.untracked(paths: ["v.txt"], expected: Self.noItems)),
            gitsWords: "v.txt could not be moved to the Trash: Permission denied.")
        #expect(
            DiscardWording.failure(none)
                == "Moving \"v.txt\" to the Trash did not finish: v.txt could not be moved to the "
                + "Trash: Permission denied. Nothing was moved.")
    }

    // MARK: - Undo

    @Test func everyUndoOutcomeIsASentence() {
        #expect(DiscardWording.undone(.restored, of: Self.unstaged, headMoved: false) == "Restored \"a.txt\".")
        #expect(DiscardWording.undone(.restored, of: Self.lines, headMoved: false) == "Restored 3 lines of \"a.txt\".")
        #expect(
            DiscardWording.undone(.restored, of: Self.untracked, headMoved: false)
                == "Restored \"u.txt\" and \"ud/\" from the Trash.")
        #expect(
            DiscardWording.undone(.restoredUnstaged, of: Self.staged, headMoved: true)
                == "Restored \"p\"; its staged part came back unstaged because a commit was made "
                + "since.")
        #expect(
            DiscardWording.undone(.restoredUnstaged, of: Self.staged, headMoved: false)
                == "Restored \"p\"; its staged part came back unstaged because something was "
                + "staged since.")
        #expect(
            DiscardWording.undone(.restoredUnverified(recordKept: Self.record), of: Self.lines, headMoved: false)
                == "Restored 3 lines of \"a.txt\", but the file could not be checked against the "
                + "copy, so the copy stays in the Stashes list.")
        #expect(
            // GitCore's own words, unquoted; the wording quotes the name like every other.
            DiscardWording.undone(.refused("a.txt, or HEAD, moved since the discard.", recordKept: Self.record),
                of: Self.lines, headMoved: false)
                == "Couldn't undo: \"a.txt\", or HEAD, moved since the discard; the copy is still in "
                + "the Stashes list.")
        #expect(
            DiscardWording.undone(.refused("error: something\nelse", recordKept: nil), of: Self.unstaged, headMoved: false)
                == "Couldn't undo: error: something else; the copy is no longer in the Stashes "
                + "list.")
        #expect(
            DiscardWording.undone(.conflicted(["a.txt"], recordKept: Self.record), of: Self.unstaged, headMoved: false)
                == "Undo brought the changes back with conflicts in \"a.txt\". Resolve them, then "
                + "stage the files; the copy is still in the Stashes list.")
        #expect(
            DiscardWording.undone(.partiallyRestored(notRestored: ["u.txt"]), of: Self.untracked, headMoved: false)
                == "Restored \"ud/\" from the Trash. Couldn't put \"u.txt\" back: something of that "
                + "name is there again. It is still in the Trash.")
        #expect(
            DiscardWording.undone(
                .partiallyRestored(notRestored: ["u.txt", "ud/"]), of: Self.untracked, headMoved: false)
                == "Couldn't put \"u.txt\" and \"ud/\" back: something of those names is there "
                + "again. They are still in the Trash.")
    }

    /// git refused an apply over files changed since the discard, and GitCore passes their names:
    /// a list of paths is not a reason on its own.
    @Test func aRefusalThatIsOnlyTheFilesItWouldOverwriteSaysTheyChanged() {
        #expect(
            DiscardWording.undone(.refused("a.txt", recordKept: Self.record), of: Self.unstaged, headMoved: false)
                == "Couldn't undo: \"a.txt\" changed since the discard; the copy is still in the "
                + "Stashes list.")
    }

    @Test func onlyAFullRestoreIsANotice() {
        #expect(DiscardWording.isNotice(.restored))
        #expect(DiscardWording.isNotice(.restoredUnstaged))
        #expect(!DiscardWording.isNotice(.restoredUnverified(recordKept: nil)))
        #expect(!DiscardWording.isNotice(.refused("x", recordKept: nil)))
        #expect(!DiscardWording.isNotice(.conflicted([], recordKept: nil)))
        #expect(!DiscardWording.isNotice(.partiallyRestored(notRestored: ["u"])))
    }

    @Test func anUndoThatCouldNotRunSaysWhy() {
        #expect(
            DiscardWording.undoRefused(.unmerged(["c.txt"]))
                == "Couldn't undo: \"c.txt\" has unresolved conflicts; the copy is still in the Stashes list.")
        #expect(
            DiscardWording.undoFailed(DiscardFailure(receipt: Self.staged, gitsWords: "fatal: nope\n"))
                == "Restored \"p\", but not its staged part: fatal: nope. The copy, which holds "
                + "it, is still in the Stashes list.")
        #expect(
            DiscardWording.undoError("fatal: bad object")
                == "Couldn't undo: fatal: bad object; the copy is still in the Stashes list.")
    }

    // MARK: - Why an entry point is off

    @Test func everyBlockedFileSaysWhy() {
        #expect(
            DiscardWording.blocked(.unmerged("c.txt"))
                == "\"c.txt\" has unresolved conflicts. Resolve them and stage the file first.")
        #expect(
            DiscardWording.blocked(.intentToAdd("n.txt"))
                == "\"n.txt\" is only marked to be added (git add -N), and no copy of it can be "
                + "kept. Stage it fully or unstage it first.")
        #expect(
            DiscardWording.blocked(.submodule("sub"))
                == "\"sub\" is a submodule, and no copy of the work inside one can be kept.")
        #expect(
            DiscardWording.blocked(.anotherRepository("inner/"))
                == "\"inner/\" belongs to another repository (a submodule, or a repository inside "
                + "this one).")
        #expect(
            DiscardWording.blocked(.noCommitYet)
                == "Tracked changes can't be discarded before the first commit: there is no commit "
                + "to keep a copy of them on. Untracked files can still be moved to the Trash.")
        #expect(
            DiscardWording.blocked(.typeChanged(.fileBecameFolder("p")))
                == "\"p\" was a file and is now a folder; discarding would lose what is there now. "
                + "Put it back, or commit the change first.")
    }

    @Test func theWholeRepositoryReasonsAreSentences() {
        #expect(DiscardWording.nothingToDiscard == "There are no unstaged changes to discard.")
    }

    @Test func theEntryPointsAreNamed() {
        #expect(DiscardWording.discardChanges == "Discard Changes…")
        #expect(DiscardWording.moveToTrash == "Move to Trash…")
        #expect(DiscardWording.discardStaged == "Discard Staged and Unstaged Changes…")
        #expect(DiscardWording.discardAll == "Discard All…")
        #expect(DiscardWording.discardHunk == "Discard Hunk…")
        #expect(DiscardWording.discardFile == "Discard File…")
        #expect(DiscardWording.discardLines(1) == "Discard 1 Line…")
        #expect(DiscardWording.discardLines(4) == "Discard 4 Lines…")
        #expect(
            DiscardWording.discardAllHelp
                == "Discard every unstaged change: tracked files are restored, untracked ones go to "
                + "the Trash")
    }
}
