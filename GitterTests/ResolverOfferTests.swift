import Foundation
import GitCore
import Testing

@testable import Gitter

/// What the resolver offers for each kind of conflict, pure (Ruling 12: Delete only for a
/// deletion, Keep only for DU/UD; a submodule gets none). Resolve File is focus mode's, on the
/// draft, never an offer.
@Suite struct ResolverOfferTests {

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

    // MARK: - A text conflict

    @Test func aTextConflictOffersTheWholeFileTakesNotResolveFile() {
        #expect(ResolverOffer.actions(for: Self.document(.blocks(Self.segments)))
            == [.takeOurs, .takeTheirs, .openInEditor, .markResolved])
        // Edited since the conflict: the same.
        #expect(ResolverOffer.actions(for: Self.document(.blocks(Self.segments), matches: false))
            == [.takeOurs, .takeTheirs, .openInEditor, .markResolved])
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
}
