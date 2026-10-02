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
}
