import Foundation
import GitCore
import Testing

@testable import Gitter

/// The resolver's choices and what it offers, pure: choices are kept per `ConflictSnapshot` and
/// dropped when it changes, Resolve File needs a choice for every block, the preview is GitCore's
/// own composition, and each kind of conflict offers its own actions (Ruling 12: Delete only for
/// a deletion, Keep only for DU/UD; a submodule gets none).
@Suite struct ResolverChoiceTests {

    static func stage(_ mode: String = "100644", _ blob: String = "a") -> ConflictStage {
        ConflictStage(mode: mode, blob: blob)
    }

    static func file(
        _ kind: ConflictKind, base: ConflictStage? = stage(), ours: ConflictStage? = stage(),
        theirs: ConflictStage? = stage()
    ) -> ConflictedFile {
        ConflictedFile(path: "f.txt", kind: kind, base: base, ours: ours, theirs: theirs)
    }

    static let blockA = ConflictBlock(ours: Data("o1\n".utf8), base: Data("b1\n".utf8), theirs: Data("t1\n".utf8))
    static let blockB = ConflictBlock(ours: Data("o2\r\n".utf8), base: nil, theirs: Data())
    static let segments: [ConflictSegment] = [
        .common(Data("top\n".utf8)), .block(blockA), .common(Data("mid\n".utf8)), .block(blockB),
        .common(Data("end\n".utf8)),
    ]

    static func snapshot(_ hash: String?, file: ConflictedFile = file(.bothModified)) -> ConflictSnapshot {
        ConflictSnapshot(file: file, worktreeHash: hash)
    }

    static func document(
        _ presentation: ConflictPresentation, file: ConflictedFile = file(.bothModified), matches: Bool = true,
        worktree: Data? = Data("x\n".utf8)
    ) -> ConflictDocument {
        ConflictDocument(
            snapshot: snapshot("h", file: file), presentation: presentation, matchesGitsConflict: matches,
            worktree: worktree)
    }

    // MARK: - Choices follow the snapshot

    @Test func choicesStayWhileTheSnapshotIsTheSame() {
        var choices = ResolverChoices()
        choices.show(Self.snapshot("h1"), blockCount: 2)
        choices.choose(0, .theirs)
        choices.show(Self.snapshot("h1"), blockCount: 2)
        #expect(choices.choices == [0: .theirs])
    }

    @Test func choicesResetWhenTheWorktreeHashChanges() {
        var choices = ResolverChoices()
        choices.show(Self.snapshot("h1"), blockCount: 2)
        choices.choose(0, .theirs)
        choices.choose(1, .ours)
        choices.show(Self.snapshot("h2"), blockCount: 2)
        #expect(choices.choices.isEmpty)
    }

    @Test func choicesResetWhenTheStagesChange() {
        var choices = ResolverChoices()
        choices.show(Self.snapshot("h1"), blockCount: 2)
        choices.choose(1, .oursThenTheirs)
        let moved = Self.file(.bothModified, theirs: Self.stage("100644", "other"))
        choices.show(Self.snapshot("h1", file: moved), blockCount: 2)
        #expect(choices.choices.isEmpty)
    }

    @Test func choicesResetWhenAnotherFileIsShownAndWhenNothingIs() {
        var choices = ResolverChoices()
        choices.show(Self.snapshot("h1"), blockCount: 1)
        choices.choose(0, .ours)
        choices.show(nil, blockCount: 0)
        #expect(choices.choices.isEmpty)
        #expect(choices.snapshot == nil)
    }

    @Test func aChoiceOutsideTheBlocksIsIgnored() {
        var choices = ResolverChoices()
        choices.show(Self.snapshot("h1"), blockCount: 2)
        choices.choose(2, .ours)
        choices.choose(-1, .ours)
        #expect(choices.choices.isEmpty)
        var none = ResolverChoices()
        none.choose(0, .ours)
        #expect(none.choices.isEmpty)
    }

    // MARK: - Resolve File

    @Test func resolveFileNeedsAChoiceForEveryBlock() {
        var choices = ResolverChoices()
        choices.show(Self.snapshot("h1"), blockCount: 2)
        #expect(choices.ordered == nil)
        #expect(choices.remaining == 2)
        choices.choose(1, .theirs)
        #expect(choices.ordered == nil)
        #expect(choices.remaining == 1)
        choices.choose(0, .theirsThenOurs)
        #expect(choices.ordered == [.theirsThenOurs, .theirs])
        #expect(choices.remaining == 0)
    }

    @Test func resolveFileIsOfferedOnlyWhereBlocksAreShown() {
        #expect(ResolverOffer.actions(for: Self.document(.blocks(Self.segments)))
            == [.resolveFile, .takeOurs, .takeTheirs, .openInEditor, .markResolved])
        // "Changed since the conflict": no chooser, the other actions stay.
        #expect(ResolverOffer.actions(for: Self.document(.blocks(Self.segments), matches: false))
            == [.takeOurs, .takeTheirs, .openInEditor, .markResolved])
        #expect(ResolverOffer.blocks(of: Self.document(.blocks(Self.segments))) == [Self.blockA, Self.blockB])
        #expect(ResolverOffer.blocks(of: Self.document(.blocks(Self.segments), matches: false)) == nil)
        #expect(ResolverOffer.blocks(of: Self.document(.wholeFile(reason: .binary))) == nil)
    }

    // MARK: - The preview is GitCore's composition

    @Test(arguments: [BlockChoice.ours, .theirs, .oursThenTheirs, .theirsThenOurs])
    func theBlockPreviewIsGitCoresComposition(choice: BlockChoice) {
        let expected: [BlockChoice: String] = [
            .ours: "o1\n", .theirs: "t1\n", .oursThenTheirs: "o1\nt1\n", .theirsThenOurs: "t1\no1\n",
        ]
        #expect(ResolverPreview.block(Self.blockA, choice) == Data(expected[choice]!.utf8))
        #expect(ResolverPreview.block(Self.blockA, choice) == Self.blockA.composed(choice))
        #expect(ResolverPreview.block(Self.blockA, nil) == nil)
    }

    @Test(arguments: [BlockChoice.ours, .theirs, .oursThenTheirs, .theirsThenOurs])
    func theFilePreviewIsGitCoresComposition(choice: BlockChoice) {
        var choices = ResolverChoices()
        choices.show(Self.snapshot("h1"), blockCount: 2)
        choices.choose(0, choice)
        #expect(ResolverPreview.file(Self.segments, choices) == nil)
        choices.choose(1, .ours)
        let composed = ConflictSegment.composed(Self.segments, choices: [choice, .ours])
        #expect(composed != nil)
        #expect(ResolverPreview.file(Self.segments, choices) == composed)
    }

    @Test func aSideIsShownAsTextAndAnEmptyOneSaysSo() {
        #expect(ResolverPreview.text(Data("a\r\nb\n".utf8)) == "a\nb")
        #expect(ResolverPreview.text(Data()) == ConflictWording.emptySide)
        #expect(ConflictWording.emptySide == "(nothing)")
    }

    // MARK: - What each kind offers (Ruling 12)

    @Test func aDeletionOffersKeepAndDelete() {
        let du = Self.file(.deletedByUs, ours: nil)
        #expect(ResolverOffer.actions(for: Self.document(.wholeFile(reason: .deletion), file: du))
            == [.keep, .delete, .openInEditor, .markResolved])
        let ud = Self.file(.deletedByThem, theirs: nil)
        #expect(ResolverOffer.actions(for: Self.document(.wholeFile(reason: .deletion), file: ud))
            == [.keep, .delete, .openInEditor, .markResolved])
        // No file on disk: nothing to open or to stage as it is.
        #expect(ResolverOffer.actions(for: Self.document(.wholeFile(reason: .deletion), file: ud, worktree: nil))
            == [.keep, .delete])
        let dd = Self.file(.bothDeleted, ours: nil, theirs: nil)
        #expect(ResolverOffer.actions(for: Self.document(.wholeFile(reason: .deletion), file: dd, worktree: nil))
            == [.delete])
    }

    @Test func aOneSidedAddOffersItsSideButNeverDelete() {
        let au = Self.file(.addedByUs, base: nil, theirs: nil)
        #expect(ResolverOffer.actions(for: Self.document(.wholeFile(reason: .oneSided), file: au))
            == [.takeOurs, .openInEditor, .markResolved])
        let ua = Self.file(.addedByThem, base: nil, ours: nil)
        #expect(ResolverOffer.actions(for: Self.document(.wholeFile(reason: .oneSided), file: ua))
            == [.takeTheirs, .openInEditor, .markResolved])
    }

    @Test func aWholeFileTextConflictOffersBothSides() {
        for reason in [WholeFileReason.binary, .symlink, .modeOnly, .mergeAttribute("binary"), .unparsable] {
            #expect(ResolverOffer.actions(for: Self.document(.wholeFile(reason: reason)))
                == [.takeOurs, .takeTheirs, .openInEditor, .markResolved])
        }
        #expect(!ResolverOffer.actions(for: Self.document(.wholeFile(reason: .binary))).contains(.delete))
    }

    @Test func aSubmoduleOffersNothing() {
        let sub = Self.file(.bothModified, base: Self.stage("160000"), ours: Self.stage("160000"), theirs: Self.stage("160000"))
        #expect(ResolverOffer.actions(for: Self.document(.submodule, file: sub)).isEmpty)
    }

    // MARK: - The store

    /// No repository and no document: a choice goes nowhere, and nothing is offered.
    @MainActor @Test func aStoreWithNoConflictKeepsNoChoices() {
        let store = RepositoryStore()
        store.chooseBlock(0, .ours)
        #expect(store.blockChoices.isEmpty)
        #expect(store.conflictDocument == nil)
        #expect(store.selectedConflict == nil)
        store.resolveSelectedFile()
        #expect(!store.isMutating)
        #expect(store.activeSheet == nil)
    }
}
