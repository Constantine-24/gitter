import Foundation
import GitCore
import Testing

@testable import Gitter

/// The pure decisions behind the discard entry points: which discard a hunk offers, and which
/// files a discard is off for (and why). No store, no repository, no `UserDefaults`.
@Suite struct DiscardDecisionTests {

    // MARK: - Fixtures

    /// `@@ -1,3 +1,3 @@`: context, a removed and an added line, context.
    static let hunkWithContext = Hunk(
        header: "@@ -1,3 +1,3 @@", oldStart: 1, oldCount: 3, newStart: 1, newCount: 3,
        lines: [
            DiffLine(id: 0, kind: .context, oldNumber: 1, newNumber: 1, text: "a"),
            DiffLine(id: 1, kind: .removed, oldNumber: 2, newNumber: nil, text: "b"),
            DiffLine(id: 2, kind: .added, oldNumber: nil, newNumber: 2, text: "B"),
            DiffLine(id: 3, kind: .context, oldNumber: 3, newNumber: 3, text: "c"),
        ])

    /// A one-line file changed whole: no context line at all.
    static let contextFreeHunk = Hunk(
        header: "@@ -1 +1 @@", oldStart: 1, oldCount: 1, newStart: 1, newCount: 1,
        lines: [
            DiffLine(id: 0, kind: .removed, oldNumber: 1, newNumber: nil, text: "x"),
            DiffLine(id: 1, kind: .added, oldNumber: nil, newNumber: 1, text: "y"),
        ])

    static func file(
        _ hunk: Hunk, kind: FileDiffKind = .modified, isValidUTF8: Bool = true, isBinary: Bool = false
    ) -> FileDiff {
        FileDiff(
            oldPath: kind == .added ? nil : "f.txt", newPath: kind == .deleted ? nil : "f.txt",
            kind: kind, isBinary: isBinary, hunks: [hunk],
            oldBlob: String(repeating: "1", count: 40), newBlob: String(repeating: "2", count: 40),
            isValidUTF8: isValidUTF8)
    }

    // MARK: - What a hunk offers

    @Test func aHunkWithContextOffersItselfOrItsSelectedLines() {
        let file = Self.file(Self.hunkWithContext)
        let id = Self.hunkWithContext.id
        #expect(HunkDiscardOffer.offer(for: file, hunk: id, lines: nil, onUnstagedSide: true) == .hunk)
        #expect(HunkDiscardOffer.offer(for: file, hunk: id, lines: [], onUnstagedSide: true) == .hunk)
        #expect(HunkDiscardOffer.offer(for: file, hunk: id, lines: [2], onUnstagedSide: true) == .lines(1))
        #expect(
            HunkDiscardOffer.offer(for: file, hunk: id, lines: [1, 2], onUnstagedSide: true) == .lines(2))
    }

    /// Ruling 4: a patch with a context-free hunk is never offered line-wise; the whole file is.
    @Test func aContextFreeHunkOffersTheWholeFile() {
        let file = Self.file(Self.contextFreeHunk)
        let id = Self.contextFreeHunk.id
        #expect(HunkDiscardOffer.offer(for: file, hunk: id, lines: nil, onUnstagedSide: true) == .wholeFile)
        #expect(HunkDiscardOffer.offer(for: file, hunk: id, lines: [1], onUnstagedSide: true) == .wholeFile)
    }

    /// `supportsPartialDiscard` is false: a deletion, a binary file, a diff that is not UTF-8.
    @Test func aFileThatCannotBeDiscardedLineWiseOffersTheWholeFile() {
        let id = Self.hunkWithContext.id
        for file in [
            Self.file(Self.hunkWithContext, kind: .deleted),
            Self.file(Self.hunkWithContext, isValidUTF8: false),
            Self.file(Self.hunkWithContext, isBinary: true),
        ] {
            #expect(HunkDiscardOffer.offer(for: file, hunk: id, lines: nil, onUnstagedSide: true) == .wholeFile)
        }
    }

    @Test func theStagedSideOffersNoDiscard() {
        let file = Self.file(Self.hunkWithContext)
        #expect(
            HunkDiscardOffer.offer(for: file, hunk: Self.hunkWithContext.id, lines: nil, onUnstagedSide: false)
                == nil)
    }

    /// Only context lines picked: nothing to discard.
    @Test func aSelectionOfNoChangedLineOffersNothing() {
        let file = Self.file(Self.hunkWithContext)
        #expect(
            HunkDiscardOffer.offer(for: file, hunk: Self.hunkWithContext.id, lines: [0], onUnstagedSide: true)
                == nil)
    }

    @Test func eachOfferHasItsButtonTitle() {
        #expect(HunkDiscardOffer.hunk.title == "Discard Hunk…")
        #expect(HunkDiscardOffer.lines(2).title == "Discard 2 Lines…")
        #expect(HunkDiscardOffer.wholeFile.title == "Discard File…")
    }

    // MARK: - Which files a discard is off for

    static func status(
        _ path: String, staged: ChangeKind? = nil, unstaged: ChangeKind? = .modified,
        submodule: Bool = false, intentToAdd: Bool = false, nested: Bool = false
    ) -> FileStatus {
        FileStatus(
            path: path, originalPath: nil, staged: staged, unstaged: unstaged, isSubmodule: submodule,
            isIntentToAdd: intentToAdd, isNestedRepository: nested)
    }

    @Test func aPlainChangeIsNotBlocked() {
        let files = [Self.status("a.txt"), Self.status("u.txt", unstaged: .untracked)]
        #expect(DiscardGate.block(for: files[0], among: files) == nil)
        #expect(DiscardGate.block(for: files[1], among: files) == nil)
    }

    @Test func unmergedIntentToAddSubmoduleAndNestedRepositoryAreBlocked() {
        let unmerged = Self.status("c.txt", staged: .unmerged, unstaged: .unmerged)
        let ita = Self.status("n.txt", unstaged: .added, intentToAdd: true)
        let sub = Self.status("sub", submodule: true)
        let nested = Self.status("inner/", unstaged: .untracked, nested: true)
        let files = [unmerged, ita, sub, nested]
        #expect(DiscardGate.block(for: unmerged, among: files) == .unmerged("c.txt"))
        #expect(DiscardGate.block(for: ita, among: files) == .intentToAdd("n.txt"))
        #expect(DiscardGate.block(for: sub, among: files) == .submodule("sub"))
        #expect(DiscardGate.block(for: nested, among: files) == .anotherRepository("inner/"))
    }

    /// Before the first commit a tracked discard has nothing to record its copy on (GitCore
    /// fails with git's `Not a valid object name HEAD`); an untracked item still goes to the Trash.
    @Test func beforeTheFirstCommitOnlyUntrackedItemsCanBeDiscarded() {
        let staged = Self.status("a.txt", staged: .added, unstaged: .modified)
        let untracked = Self.status("u.txt", unstaged: .untracked)
        let files = [staged, untracked]
        #expect(DiscardGate.block(for: staged, among: files, hasCommits: false) == .noCommitYet)
        #expect(DiscardGate.block(for: untracked, among: files, hasCommits: false) == nil)
        #expect(DiscardGate.block(for: staged, among: files, hasCommits: true) == nil)
    }

    /// A tracked file that is now a folder shows as a deletion and an untracked `p/`; a tracked
    /// folder that is now a file as `d/x` deleted and an untracked `d`. The restore would
    /// overwrite what is on disk, which is in no record.
    @Test func aFileFolderSwapIsBlockedOnTheTrackedSide() {
        let deleted = Self.status("p", unstaged: .deleted)
        let folder = Self.status("p/", unstaged: .untracked)
        #expect(DiscardGate.block(for: deleted, among: [deleted, folder]) == .typeChanged(.fileBecameFolder("p")))
        // The untracked folder itself can go to the Trash.
        #expect(DiscardGate.block(for: folder, among: [deleted, folder]) == nil)

        let inner = Self.status("d/x", unstaged: .deleted)
        let file = Self.status("d", unstaged: .untracked)
        #expect(
            DiscardGate.block(for: inner, among: [inner, file])
                == .typeChanged(.folderBecameFile(path: "d/x", file: "d")))

        // A deletion with nothing in its place is an ordinary discard.
        #expect(DiscardGate.block(for: deleted, among: [deleted]) == nil)
        // A sibling whose name only starts the same is not in the way.
        let sibling = Self.status("px", unstaged: .untracked)
        #expect(DiscardGate.block(for: deleted, among: [deleted, sibling]) == nil)
    }
}
