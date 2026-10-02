import Foundation
import GitCore
import Testing

@testable import Gitter

/// The operation bar's two buttons: readiness × mutating × sheet → Continue's and Skip's state,
/// what Continue does when it is on (run, or ask first), the files Stage All would sweep in, the
/// composer's prefill and its comment-line note. Pure: no store, no git.
@MainActor @Suite struct OperationBarStateTests {

    static let commit = CommitRef(sha: "9f8e7d6c5b4a39281706f5e4d3c2b1a098765432", subject: "Change the parser")
    static let message = PendingMessage(text: "Change the parser\n\nBody line", commentChar: "#")

    static func stop(
        _ operation: RepositoryOperation = .rebase, _ readiness: ContinueReadiness? = .ready,
        skip: SkipReadiness? = .ready(paths: ["a.txt"]), current: CommitRef? = commit,
        message: PendingMessage? = message, otherStagedAtEmpty: [String] = [], unstagedAtEmpty: [String] = []
    ) -> OperationStop {
        OperationStop(
            operation: operation,
            progress: OperationProgress(operation: operation, step: 1, total: 2, current: current),
            continueReadiness: readiness, skipReadiness: skip, pendingMessage: message,
            otherStagedAtEmpty: otherStagedAtEmpty, unstagedAtEmpty: unstagedAtEmpty)
    }

    static func state(
        _ stop: OperationStop?, operation: RepositoryOperation = .rebase, mutating: Bool = false, sheet: Bool = false,
        hasMessage: Bool = true
    ) -> BarActionState {
        OperationBarState.continueState(operation, stop, isMutating: mutating, sheetUp: sheet, hasMessage: hasMessage)
    }

    // MARK: - Continue: readiness

    @Test func readyAndOtherStagedAreOnAndEverythingElseSaysWhy() {
        #expect(Self.state(Self.stop(.rebase, .ready)) == .enabled)
        #expect(Self.state(Self.stop(.rebase, .otherStagedChanges(["n.txt"]))) == .enabled)
        #expect(
            Self.state(Self.stop(.rebase, .unresolved(["a.txt"])))
                == .disabled(ContinueWording.unresolved(["a.txt"])))
        #expect(
            Self.state(Self.stop(.rebase, .unstagedChanges(["x.txt"])))
                == .disabled(ContinueWording.unstaged(.rebase, ["x.txt"])))
        #expect(
            Self.state(Self.stop(.cherryPick, .unstagedChanges(["x.txt"])), operation: .cherryPick)
                == .disabled(ContinueWording.unstaged(.cherryPick, ["x.txt"])))
        #expect(
            Self.state(Self.stop(.rebase, .notContinuable))
                == .disabled(ContinueWording.notContinuable(.rebase)))
    }

    /// A rebase may go on past an empty result once it has asked (M 30); a cherry-pick or revert
    /// cannot, and says Skip — or, with other staged files, how out of the dead end (Ruling 20).
    @Test func anEmptyResultIsOnForARebaseAndOffForAPickOrRevert() {
        #expect(Self.state(Self.stop(.rebase, .emptyResult)) == .enabled)
        #expect(
            Self.state(Self.stop(.cherryPick, .emptyResult), operation: .cherryPick)
                == .disabled(ContinueWording.emptyResult(.cherryPick, Self.commit, otherStaged: [])))
        #expect(
            Self.state(Self.stop(.revert, .emptyResult, otherStagedAtEmpty: ["n.txt"]), operation: .revert)
                == .disabled(ContinueWording.emptyResult(.revert, Self.commit, otherStaged: ["n.txt"])))
    }

    /// Readiness names one case, and `.emptyResult` outranks unstaged changes, which git would
    /// still refuse: the rebase's own unstaged read decides.
    @Test func anEmptyRebaseWithUnstagedChangesIsOffForThose() {
        #expect(
            Self.state(Self.stop(.rebase, .emptyResult, unstagedAtEmpty: ["x.txt"]))
                == .disabled(ContinueWording.unstaged(.rebase, ["x.txt"])))
    }

    @Test func anEmptyRebaseWithNoStoppedCommitIsOff() {
        #expect(
            Self.state(Self.stop(.rebase, .emptyResult, current: nil))
                == .disabled(ContinueWording.noStoppedCommit(.rebase)))
    }

    @Test func aMissingMessageIsOffOnlyWhereGitHasOneToReplace() {
        #expect(Self.state(Self.stop(.rebase, .ready), hasMessage: false) == .disabled(ContinueWording.enterMessage))
        // An exec or break stop has no message file: the draft is not used.
        #expect(Self.state(Self.stop(.rebase, .ready, message: nil), hasMessage: false) == .enabled)
    }

    @Test func nothingReadYetOrAFailedReadSaysSo() {
        #expect(Self.state(nil) == .disabled(ContinueWording.reading(.rebase)))
        #expect(Self.state(Self.stop(.rebase, nil)) == .disabled(ContinueWording.reading(.rebase)))
        var failed = Self.stop(.rebase, nil)
        failed.readFailure = "boom"
        #expect(Self.state(failed) == .disabled(ContinueWording.readFailed(.rebase, "boom")))
        // A stop read for another operation is not this one's.
        #expect(Self.state(Self.stop(.cherryPick, .ready), operation: .rebase) == .disabled(ContinueWording.reading(.rebase)))
    }

    @Test func aMergeSquashOrAmIsNeverContinued() {
        for operation in [RepositoryOperation.merge, .squash, .applyingPatches] {
            #expect(!OperationBarState.isContinuable(operation))
            #expect(
                Self.state(Self.stop(operation, .ready), operation: operation)
                    == .disabled(ContinueWording.notContinuable(operation)))
        }
        for operation in [RepositoryOperation.rebase, .cherryPick, .revert] {
            #expect(OperationBarState.isContinuable(operation))
        }
    }

    // MARK: - Continue: mutating × sheet

    nonisolated static let readinesses: [ContinueReadiness] = [
        .ready, .unresolved(["a"]), .emptyResult, .unstagedChanges(["b"]), .otherStagedChanges(["c"]), .notContinuable,
    ]

    @Test(arguments: readinesses)
    func aSheetOrARunningChangeTurnsContinueOffWhateverTheReadiness(_ readiness: ContinueReadiness) {
        #expect(Self.state(Self.stop(.rebase, readiness), sheet: true) == .disabled(ContinueWording.blockedBySheet))
        #expect(Self.state(Self.stop(.rebase, readiness), mutating: true) == .disabled(ContinueWording.busy))
        #expect(
            Self.state(Self.stop(.rebase, readiness), mutating: true, sheet: true)
                == .disabled(ContinueWording.blockedBySheet))
    }

    /// The line under the bar is about the repository, never the moment: a sheet or a running
    /// change is not written there.
    @Test func theReasonLineSkipsTheMomentaryReasons() {
        let unresolved = Self.stop(.rebase, .unresolved(["a.txt"]))
        #expect(OperationBarState.reasonLine(.rebase, unresolved, hasMessage: true) == ContinueWording.unresolved(["a.txt"]))
        #expect(OperationBarState.reasonLine(.rebase, Self.stop(.rebase, .ready), hasMessage: true) == nil)
        #expect(OperationBarState.reasonLine(.merge, Self.stop(.merge, .ready), hasMessage: true) == nil)
    }

    // MARK: - What Continue does

    @Test func continueRunsOrAsksFirst() {
        #expect(OperationBarState.continueStep(Self.stop(.rebase, .ready)) == .run)
        #expect(OperationBarState.continueStep(Self.stop(.rebase, .otherStagedChanges(["n.txt"]))) == .confirmOthers(["n.txt"]))
        #expect(
            OperationBarState.continueStep(Self.stop(.rebase, .emptyResult))
                == .confirmEmpty(Self.commit, otherStaged: []))
        // Ruling 20: the other staged files go on the same sheet, and are what Continue acknowledges.
        #expect(
            OperationBarState.continueStep(Self.stop(.rebase, .emptyResult, otherStagedAtEmpty: ["n.txt"]))
                == .confirmEmpty(Self.commit, otherStaged: ["n.txt"]))
    }

    // MARK: - Skip

    @Test func skipIsOnOnlyWithAStoppedCommitAndReadyPaths() {
        func skip(_ stop: OperationStop?, operation: RepositoryOperation = .rebase, mutating: Bool = false, sheet: Bool = false)
            -> BarActionState
        {
            OperationBarState.skipState(operation, stop, isMutating: mutating, sheetUp: sheet)
        }
        #expect(skip(Self.stop(skip: .ready(paths: []))) == .enabled)
        #expect(skip(Self.stop(skip: .ready(paths: ["a"]))) == .enabled)
        // Task 3: an exec / break stop says `.ready` with no commit; Skip is not offered there.
        #expect(skip(Self.stop(skip: .ready(paths: []), current: nil)) == .disabled(ContinueWording.noCommitToSkip))
        #expect(skip(Self.stop(skip: .notSkippable)) == .disabled(ContinueWording.noCommitToSkip))
        #expect(skip(Self.stop(skip: .otherChanges(["o"]))) == .disabled(ContinueWording.skipOtherChanges(["o"])))
        #expect(skip(Self.stop(skip: .needsCleanPaths(["p"]))) == .disabled(ContinueWording.skipNeedsCleanPaths(["p"])))
        #expect(skip(Self.stop(skip: nil)) == .disabled(ContinueWording.reading(.rebase)))
        #expect(skip(nil) == .disabled(ContinueWording.reading(.rebase)))
        #expect(skip(Self.stop(skip: .ready(paths: [])), mutating: true) == .disabled(ContinueWording.busy))
        #expect(skip(Self.stop(skip: .ready(paths: [])), sheet: true) == .disabled(ContinueWording.blockedBySheet))
        #expect(
            skip(Self.stop(.merge, skip: .ready(paths: [])), operation: .merge)
                == .disabled(ContinueWording.notContinuable(.merge)))
        var failed = Self.stop(skip: nil)
        failed.readFailure = "boom"
        #expect(skip(failed) == .disabled(ContinueWording.readFailed(.rebase, "boom")))
    }

    // MARK: - The files

    static let files: [FileStatus] = [
        FileStatus(path: "own.txt", originalPath: nil, staged: .modified, unstaged: .modified),
        FileStatus(path: "other.txt", originalPath: nil, staged: .modified, unstaged: nil),
        FileStatus(path: "new.txt", originalPath: "old.txt", staged: .renamed, unstaged: nil),
        FileStatus(path: "c.txt", originalPath: nil, staged: .unmerged, unstaged: .unmerged),
        FileStatus(path: "loose.txt", originalPath: nil, staged: nil, unstaged: .modified),
        FileStatus(path: "untracked.txt", originalPath: nil, staged: nil, unstaged: .untracked),
        FileStatus(path: "sub", originalPath: nil, staged: nil, unstaged: .modified, isSubmodule: true),
    ]

    /// Ruling 20: `diff --cached --no-renames HEAD` minus the operation's paths — both names of
    /// a rename, never an unmerged path; unknown paths (nil) cannot tell, so none.
    @Test func theOtherStagedFilesAreTheStagedOnesOutsideTheOperation() {
        #expect(OperationBarState.otherStaged(in: Self.files, own: ["own.txt"]) == ["other.txt", "new.txt", "old.txt"])
        #expect(OperationBarState.otherStaged(in: Self.files, own: ["own.txt", "old.txt"]) == ["other.txt", "new.txt"])
        #expect(OperationBarState.otherStaged(in: Self.files, own: nil) == [])
    }

    /// What `rebase --continue` refuses: a tracked file whose worktree differs from the index —
    /// not untracked, not unmerged, not a submodule (git's own check ignores those).
    @Test func theUnstagedFilesAreTrackedOnes() {
        #expect(OperationBarState.unstaged(in: Self.files) == ["own.txt", "loose.txt"])
    }

    /// Stage All adds every unstaged change except an unmerged path (M 22); the confirmation
    /// names those outside the operation's paths — all of them when those are unknown.
    @Test func theStageAllSweepIsWhatItWouldAddOutsideTheOperation() {
        #expect(
            OperationBarState.stageAllSweep(Self.files, own: ["own.txt"])
                == ["loose.txt", "untracked.txt", "sub"])
        #expect(
            OperationBarState.stageAllSweep(Self.files, own: nil)
                == ["own.txt", "loose.txt", "untracked.txt", "sub"])
        #expect(OperationBarState.stageAllSweep(Self.files, own: ["own.txt", "loose.txt", "untracked.txt", "sub"]) == [])
    }

    // MARK: - The composer's note

    @Test func theCommentNoteIsForAPickOrRevertWithACommentLine() {
        let pick = Self.stop(.cherryPick, .ready)
        #expect(
            OperationBarState.commentNote(.cherryPick, pick, message: "Subject\n\n# kept?")
                == ContinueWording.commentNote("#"))
        #expect(OperationBarState.commentNote(.revert, Self.stop(.revert, .ready), message: "# Subject") != nil)
        #expect(OperationBarState.commentNote(.cherryPick, pick, message: "Subject\n\n  # indented") == nil)
        #expect(OperationBarState.commentNote(.cherryPick, pick, message: "Subject") == nil)
        // A rebase continues under `scissors`, which keeps them; a merge's `commit -F` keeps them.
        #expect(OperationBarState.commentNote(.rebase, Self.stop(.rebase, .ready), message: "# x") == nil)
        #expect(OperationBarState.commentNote(.merge, Self.stop(.merge, .ready), message: "# x") == nil)
        let semicolon = Self.stop(.cherryPick, .ready, message: PendingMessage(text: "S", commentChar: ";"))
        #expect(OperationBarState.commentNote(.cherryPick, semicolon, message: "S\n; x") == ContinueWording.commentNote(";"))
        #expect(OperationBarState.commentNote(.cherryPick, semicolon, message: "S\n# x") == nil)
    }

    // MARK: - The prefill

    @Test func anEmptyDraftIsPrefilledOnceForTheStop() {
        let draft = CommitDraft()
        let stop = Self.stop(.cherryPick, .ready)
        let key = ComposerPrefill.apply(stop, lastKey: nil, to: draft)
        #expect(key != nil)
        #expect(draft.subject == "Change the parser")
        #expect(draft.body == "Body line")
        // The user clears it: the same stop does not fill it again.
        draft.subject = ""
        draft.body = ""
        #expect(ComposerPrefill.apply(stop, lastKey: key, to: draft) == key)
        #expect(draft.subject.isEmpty)
    }

    @Test func aTypedDraftIsNeverOverwritten() {
        let draft = CommitDraft()
        draft.subject = "Mine"
        let key = ComposerPrefill.apply(Self.stop(.merge, nil, skip: nil), lastKey: nil, to: draft)
        #expect(key != nil)
        #expect(draft.subject == "Mine")
        #expect(draft.body.isEmpty)
        // Nor at the next stop.
        let next = Self.stop(.merge, nil, skip: nil, current: CommitRef(sha: "b", subject: "B"))
        _ = ComposerPrefill.apply(next, lastKey: key, to: draft)
        #expect(draft.subject == "Mine")
    }

    @Test func theNextStopReplacesAnUntouchedPrefillButNotAnEditedOne() {
        let draft = CommitDraft()
        let first = Self.stop(.rebase, .ready)
        let key = ComposerPrefill.apply(first, lastKey: nil, to: draft)
        let second = Self.stop(
            .rebase, .ready, current: CommitRef(sha: "b", subject: "Second"),
            message: PendingMessage(text: "Second", commentChar: "#"))
        let secondKey = ComposerPrefill.apply(second, lastKey: key, to: draft)
        #expect(secondKey != key)
        #expect(draft.subject == "Second")
        #expect(draft.body.isEmpty)

        draft.body = "edited"
        let third = Self.stop(
            .rebase, .ready, current: CommitRef(sha: "c", subject: "Third"),
            message: PendingMessage(text: "Third", commentChar: "#"))
        _ = ComposerPrefill.apply(third, lastKey: secondKey, to: draft)
        #expect(draft.subject == "Second")
        #expect(draft.body == "edited")
    }

    @Test func theOperationEndingTakesBackAnUntouchedPrefillOnly() {
        let draft = CommitDraft()
        let key = ComposerPrefill.apply(Self.stop(.merge, nil, skip: nil), lastKey: nil, to: draft)
        #expect(ComposerPrefill.apply(nil, lastKey: key, to: draft) == nil)
        #expect(draft.subject.isEmpty)

        let edited = CommitDraft()
        let editedKey = ComposerPrefill.apply(Self.stop(.merge, nil, skip: nil), lastKey: nil, to: edited)
        edited.subject = "Merge, reworded"
        #expect(ComposerPrefill.apply(nil, lastKey: editedKey, to: edited) == nil)
        #expect(edited.subject == "Merge, reworded")
    }

    @Test func aStopWithNoMessageFillsNothing() {
        let draft = CommitDraft()
        let exec = Self.stop(.rebase, .ready, current: nil, message: nil)
        #expect(ComposerPrefill.apply(exec, lastKey: nil, to: draft) != nil)
        #expect(draft.subject.isEmpty)
        // The message landing later (a read that failed first) is a different key, and fills.
        let later = Self.stop(.rebase, .ready, current: nil)
        let key = ComposerPrefill.apply(exec, lastKey: nil, to: draft)
        _ = ComposerPrefill.apply(later, lastKey: key, to: draft)
        #expect(draft.subject == "Change the parser")
    }
}
