import GitCore
import Testing

@testable import Gitter

/// Characterisation: what `OperationWording.swift` says today about each of the six operations,
/// pinned so that a change to any of these sentences is a deliberate one.
@Suite struct OperationWordingTests {

    struct Wording: Sendable, CustomTestStringConvertible {
        let operation: RepositoryOperation
        let note: String
        let conflictsNote: String
        let abortButtonTitle: String
        let abortedNotice: String

        var testDescription: String { "\(operation)" }
    }

    static let wordings: [Wording] = [
        Wording(
            operation: .merge,
            note: "Merge in progress — commit to complete it.",
            conflictsNote: "Merge in progress — resolve the conflicts, then commit.",
            abortButtonTitle: "Abort Merge…",
            abortedNotice: "Merge aborted."),
        Wording(
            operation: .cherryPick,
            note: "Cherry-pick in progress — continue when ready.",
            conflictsNote: "Cherry-pick in progress — resolve the conflicts, then continue.",
            abortButtonTitle: "Abort Cherry-Pick…",
            abortedNotice: "Cherry-pick aborted."),
        Wording(
            operation: .revert,
            note: "Revert in progress — continue when ready.",
            conflictsNote: "Revert in progress — resolve the conflicts, then continue.",
            abortButtonTitle: "Abort Revert…",
            abortedNotice: "Revert aborted."),
        Wording(
            operation: .rebase,
            note: "Rebase in progress — continue when ready.",
            conflictsNote: "Rebase in progress — resolve the conflicts, then continue.",
            abortButtonTitle: "Abort Rebase…",
            abortedNotice: "Rebase aborted."),
        Wording(
            operation: .applyingPatches,
            note: "Patch application in progress — run `git am --continue` in a terminal.",
            conflictsNote:
                "Patch application in progress — resolve the conflicts, then run "
                + "`git am --continue` in a terminal.",
            abortButtonTitle: "Stop Applying Patches…",
            abortedNotice: "Stopped applying patches."),
        Wording(
            operation: .squash,
            note: "Squash pending — commit to finish.",
            conflictsNote: "Squash in progress — resolve the conflicts, then commit.",
            abortButtonTitle: "Undo Squash…",
            abortedNotice: "Squash undone."),
    ]

    /// All six operations are in the table, once each.
    @Test func coversEveryOperation() {
        let operations = Self.wordings.map(\.operation)
        #expect(Set(operations).count == 6)
        #expect(operations.count == 6)
    }

    @Test(arguments: wordings)
    func noteWithoutConflicts(_ wording: Wording) {
        #expect(wording.operation.note(hasConflicts: false) == wording.note)
    }

    @Test(arguments: wordings)
    func noteWithConflicts(_ wording: Wording) {
        #expect(wording.operation.note(hasConflicts: true) == wording.conflictsNote)
    }

    @Test(arguments: wordings)
    func abortButtonTitle(_ wording: Wording) {
        #expect(wording.operation.abortButtonTitle == wording.abortButtonTitle)
    }

    @Test(arguments: wordings)
    func abortedNotice(_ wording: Wording) {
        #expect(wording.operation.abortedNotice == wording.abortedNotice)
    }

    // MARK: - What an abort does to commits (final review I2)

    static let c1 = CommitRef(sha: "1a2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d", subject: "c1 f")
    static let c2 = CommitRef(sha: "2b3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e", subject: "c2 adds n")
    static let c3 = CommitRef(sha: "3c4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f", subject: "c3 adds o")
    static let c4 = CommitRef(sha: "4d5e6f708192a3b4c5d6e7f8091a2b3c4d5e6f70", subject: "c4")

    /// Measured: after an in-app Continue of a range, `--abort` resets to `sequencer/head` — the
    /// commits the range made leave the branch, reachable only from the reflog.
    @Test func aRangeAbortNamesTheCommitsItRemoves() {
        #expect(RepositoryOperation.cherryPick.abortHistory(.commits([Self.c1]))
            == "Your branch goes back to where it was before the cherry-pick began. The 1 commit this "
            + "cherry-pick already made, 1a2b3c4 \"c1 f\", leaves the branch; it stays in git's reflog "
            + "for a while.")
        #expect(RepositoryOperation.revert.abortHistory(.commits([Self.c1, Self.c2]))
            == "Your branch goes back to where it was before the revert began. The 2 commits this "
            + "revert already made, 1a2b3c4 \"c1 f\" and 2b3c4d5 \"c2 adds n\", leave the branch; "
            + "they stay in git's reflog for a while.")
        #expect(RepositoryOperation.cherryPick.abortHistory(.commits([Self.c1, Self.c2, Self.c3, Self.c4]))
            == "Your branch goes back to where it was before the cherry-pick began. The 4 commits this "
            + "cherry-pick already made, 1a2b3c4 \"c1 f\", 2b3c4d5 \"c2 adds n\", 3c4d5e6 \"c3 adds o\" "
            + "and 1 more, leave the branch; they stay in git's reflog for a while.")
    }

    /// Never "exactly where they were" when it cannot be told.
    @Test func anUnreadRangeAbortSaysItMayRemoveCommits() {
        let sentence = RepositoryOperation.cherryPick.abortHistory(.unknown)
        #expect(sentence
            == "Your branch goes back to where it was before the cherry-pick began: any commit this "
            + "cherry-pick already made leaves the branch, and stays in git's reflog for a while.")
        #expect(!sentence.contains("exactly where they were"))
    }

    @Test func nothingMadeKeepsTheOldSentences() {
        #expect(RepositoryOperation.cherryPick.abortHistory(.none)
            == "Your branch and history go back to exactly where they were.")
        #expect(RepositoryOperation.applyingPatches.abortHistory(.patches)
            == "The patches already applied leave the branch: nothing but the reflog will reach those commits afterwards.")
        #expect(RepositoryOperation.rebase.abortHistory(.none)
            == "Your branch goes back to the commit it was on before the rebase.")
    }
}
