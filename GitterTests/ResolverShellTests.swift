import AppKit
import Foundation
import GitCore
import Testing

@testable import Gitter

/// Focus mode's shell, pure: the card's words, the toolbar's decisions (Abort only with an
/// operation, Resolve File off while a conflict waits or the draft can't be written, Done the
/// default once every file is resolved), the sidebar's rows and their trailing text, the bars
/// above the columns, what the centre shows, Escape, a conflicted row's Return and double-click,
/// and the palette's light and dark values. No view and no git.
@MainActor @Suite struct ResolverShellTests {

    // MARK: - Fixtures

    static let stage = ConflictStage(mode: "100644", blob: "a")

    static func file(
        _ path: String = "f.txt", _ kind: ConflictKind = .bothModified, base: ConflictStage? = stage,
        ours: ConflictStage? = stage, theirs: ConflictStage? = stage
    ) -> ConflictedFile {
        ConflictedFile(path: path, kind: kind, base: base, ours: ours, theirs: theirs)
    }

    static func block(_ n: Int) -> ConflictBlock {
        ConflictBlock(ours: Data("o\(n)\n".utf8), base: Data("b\(n)\n".utf8), theirs: Data("t\(n)\n".utf8))
    }

    /// top, conflict, mid, conflict, end: chunks 0…4.
    static let segments: [ConflictSegment] = [
        .common(Data("top\n".utf8)), .block(block(1)), .common(Data("mid\n".utf8)), .block(block(2)),
        .common(Data("end\n".utf8)),
    ]

    static func conflict(
        _ presentation: ConflictPresentation = .blocks(segments), file: ConflictedFile = file(), matches: Bool = true
    ) -> ConflictDocument {
        ConflictDocument(
            snapshot: ConflictSnapshot(file: file, worktreeHash: "h"), presentation: presentation,
            matchesGitsConflict: matches, worktree: Data("x\n".utf8))
    }

    static let sides = ConflictSides(
        ours: Data("o\n".utf8), base: Data("b\n".utf8), theirs: Data("t\n".utf8), markerSize: 7)

    /// A draft on `segments`, `taken` conflicts taken (in order), `detached` as given.
    static func draft(taken: Int = 0, detached: DraftDetachment? = nil) throws -> ResolverDraft {
        let document = conflict()
        var result = try #require(ResolverDocument(document: document, sides: sides))
        for id in RepositoryStore.conflictIDs(result).prefix(taken) { _ = result.take(.ours, chunk: id) }
        return ResolverDraft(
            document: result, sides: sides, snapshot: document.snapshot, history: ResolverHistory(),
            detached: detached)
    }

    // MARK: - The card

    @Test func cardTextNamesKindAndCount() {
        #expect(ConflictWording.card(kind: "Changed on both sides", count: 3) == "Changed on both sides \u{00B7} 3 conflicts")
        #expect(ConflictWording.card(kind: "Added on both sides", count: 1) == "Added on both sides \u{00B7} 1 conflict")
        // A whole-file kind, or a read still to land: the kind alone.
        #expect(ConflictWording.card(kind: "Deleted in main, changed in topic", count: nil)
            == "Deleted in main, changed in topic")
        #expect(ConflictWording.resolveConflictsButton == "Resolve Conflicts\u{2026}")

        // The count is the document's blocks, edited since the conflict or not; none for a
        // whole-file kind or a submodule.
        #expect(ResolverShell.conflictCount(of: Self.conflict()) == 2)
        #expect(ResolverShell.conflictCount(of: Self.conflict(matches: false)) == 2)
        #expect(ResolverShell.conflictCount(of: Self.conflict(.wholeFile(reason: .binary))) == nil)
        #expect(ResolverShell.conflictCount(of: Self.conflict(.submodule)) == nil)
    }

    /// Return and a double-click on a conflicted row open focus mode; on any other row they
    /// stage or unstage, as before. Space and the row's button are not this.
    @Test func aConflictedRowOpensTheResolver() {
        let conflicted = FileStatus(path: "f.txt", originalPath: nil, staged: nil, unstaged: .unmerged, conflict: Self.file())
        let plain = FileStatus(path: "g.txt", originalPath: nil, staged: nil, unstaged: .modified)
        #expect(ResolverShell.primaryAction(for: conflicted) == .openResolver)
        #expect(ResolverShell.primaryAction(for: plain) == .toggle)
    }

    // MARK: - The toolbar

    @Test func toolbarShowsAbortOnlyWithAnOperation() {
        #expect(!ResolverShell.showsAbort(nil))
        for operation in [RepositoryOperation.merge, .rebase, .cherryPick, .revert, .squash, .applyingPatches] {
            #expect(ResolverShell.showsAbort(operation))
        }
        #expect(ConflictWording.focusTitle == "Resolve Conflicts")
        // The sentence under the title: today's operation wording, without its period.
        let merge = OperationProgress(operation: .merge, mergedName: "feature/metric-units")
        #expect(ConflictWording.focusSubtitle(.merge, merge, branch: "main") == "Merging feature/metric-units into main")
        #expect(ConflictWording.focusSubtitle(.squash, nil, branch: "main") == "Squash in progress")
        // No operation (Ruling 20).
        #expect(ConflictWording.focusSubtitle(nil, nil, branch: "main")
            == "Conflicts from applying a stash or undoing a discard")
    }

    @Test func resolveFileIsOffWhileWaiting() throws {
        #expect(!ResolverShell.resolveFileEnabled(nil, blocked: nil))
        #expect(!ResolverShell.resolveFileEnabled(try Self.draft(taken: 0), blocked: nil))
        #expect(!ResolverShell.resolveFileEnabled(try Self.draft(taken: 1), blocked: nil))
        #expect(ResolverShell.resolveFileEnabled(try Self.draft(taken: 2), blocked: nil))
        // A sheet up or a change running.
        #expect(!ResolverShell.resolveFileEnabled(try Self.draft(taken: 2), blocked: ConflictWording.busy))
        // Never over a newer file (Ruling 17): changed outside stays editable, but not written.
        #expect(!ResolverShell.resolveFileEnabled(try Self.draft(taken: 2, detached: .changedOutside), blocked: nil))
        #expect(!ResolverShell.resolveFileEnabled(try Self.draft(taken: 2, detached: .resolvedOutside), blocked: nil))

        #expect(ConflictWording.conflictsLeft(1) == "1 conflict left in this file")
        #expect(ConflictWording.conflictsLeft(3) == "3 conflicts left in this file")
        #expect(ConflictWording.conflictsLeft(0) == nil)
        #expect(ConflictWording.resolveHelp(remaining: 0) == "Write the Result to the file and stage it")
        #expect(ConflictWording.resolveHelp(remaining: 2) == "Choose a side for every conflict first (2 left)")
    }

    @Test func doneIsDefaultWhenAllResolved() {
        #expect(ResolverShell.doneIsDefault(allResolved: true, ended: false))
        #expect(!ResolverShell.doneIsDefault(allResolved: false, ended: false))
        // The footer: progress until then (Ruling 21), the spec's line once every file is.
        #expect(ConflictWording.filesResolved(1, of: 4) == "1 of 4 files resolved")
        #expect(ResolverShell.footerLine(.merge, allResolved: false, ended: false)
            == "Commit Merge comes back once every file is resolved.")
        #expect(ResolverShell.footerLine(.rebase, allResolved: false, ended: false)
            == "Continue Rebase comes back once every file is resolved.")
        #expect(ResolverShell.footerLine(nil, allResolved: false, ended: false) == nil)
        #expect(ResolverShell.footerLine(.merge, allResolved: true, ended: false) == "All files resolved \u{2014} press Done, then Continue")
        #expect(ResolverShell.footerLine(nil, allResolved: true, ended: false) == "All files resolved \u{2014} press Done")
    }

    /// The operation ended (outside Gitter, or by its own Abort) while drafts were kept
    /// (Ruling 24): the subtitle says which operation ended until Done, neither footer line shows,
    /// read-only rows are left out of the progress, and Done is the default.
    @Test func anEndedOperationSaysSoUntilDone() throws {
        let ended = try Self.draft(detached: .operationEnded)
        let attached = try Self.draft()
        #expect(ResolverShell.endedOperation(["a.txt": ended, "b.txt": attached], remembered: .merge) == .merge)
        #expect(ResolverShell.endedOperation(["b.txt": attached], remembered: .merge) == nil)
        #expect(ResolverShell.endedOperation(["a.txt": ended], remembered: nil) == nil)

        let merge = OperationProgress(operation: .merge, mergedName: "topic")
        #expect(ResolverShell.subtitle(nil, nil, branch: "main", ended: .merge) == "The merge ended outside Gitter.")
        #expect(ResolverShell.subtitle(nil, nil, branch: "main", ended: .rebase) == "The rebase ended outside Gitter.")
        #expect(ResolverShell.subtitle(.merge, merge, branch: "main", ended: nil) == "Merging topic into main")
        #expect(ResolverShell.subtitle(nil, nil, branch: "main", ended: nil)
            == "Conflicts from applying a stash or undoing a discard")

        #expect(ResolverShell.footerLine(nil, allResolved: true, ended: true) == nil)
        #expect(ResolverShell.footerLine(.merge, allResolved: false, ended: true) == nil)
        #expect(ResolverShell.doneIsDefault(allResolved: true, ended: true))
        #expect(ResolverShell.doneIsDefault(allResolved: false, ended: true))

        func row(_ path: String, _ status: ResolverRowStatus) -> ResolverRow {
            ResolverRow(path: path, status: status, isConflicted: false)
        }
        let progress = ResolverShell.progress([row("a", .readOnly), row("b", .resolved), row("c", .left(1))])
        #expect(progress.resolved == 1 && progress.total == 2)
        #expect(ResolverShell.progress([row("a", .readOnly)]).total == 0)
    }

    /// Done's tooltip is true for both kinds of draft it meets (Ruling 25).
    @Test func doneSaysWhatItKeeps() {
        #expect(ConflictWording.doneHelp
            == "Back to the repository. Your changes are kept until you resolve or discard them, except in a "
            + "file that was resolved or whose operation ended, whose changes are dropped.")
    }

    /// Reload is offered only for a draft changed outside, and asks first when the draft has
    /// changes (Ruling 26).
    @Test func reloadIsOfferedOnlyForAChangeOutside() throws {
        #expect(ResolverShell.offersReload(try Self.draft(detached: .changedOutside)))
        #expect(!ResolverShell.offersReload(try Self.draft(detached: .resolvedOutside)))
        #expect(!ResolverShell.offersReload(try Self.draft(detached: .operationEnded)))
        #expect(!ResolverShell.offersReload(try Self.draft()))
        #expect(ResolverShell.reloadAsks(try Self.draft(taken: 1, detached: .changedOutside)))
        #expect(!ResolverShell.reloadAsks(try Self.draft(detached: .changedOutside)))

        #expect(ConflictWording.reloadMenuItem == "Reload\u{2026}")
        #expect(ConflictWording.reloadQuestion == ConflictWording.bar(.changedOutside))
        #expect(ConflictWording.reload == "Reload")
        #expect(ConflictWording.cancel == "Cancel")
    }

    /// A focused path with neither a conflict nor a draft (its draft discarded or dropped) moves
    /// on: to the next file with conflicts in git's order, wrapping round, else the all-resolved
    /// state. It never waits for a read that will not come.
    @Test func aFocusWithNothingLeftMovesOn() {
        #expect(ResolverShell.focusAfterLosing("a.txt", files: ["a.txt", "b.txt"], drafts: []) == .stay)
        #expect(ResolverShell.focusAfterLosing("a.txt", files: ["b.txt"], drafts: ["a.txt"]) == .stay)
        #expect(ResolverShell.focusAfterLosing("b.txt", files: ["a.txt", "c.txt"], drafts: []) == .moveTo("c.txt"))
        #expect(ResolverShell.focusAfterLosing("c.txt", files: ["a.txt", "b.txt"], drafts: []) == .moveTo("a.txt"))
        #expect(ResolverShell.focusAfterLosing("a.txt", files: [], drafts: ["z.txt"]) == .allResolved)
    }

    /// "Conflict N of M" counts the focused file's conflicts; none without a draft.
    @Test func thePositionCountsTheFilesConflicts() throws {
        let draft = try Self.draft()
        #expect(ResolverShell.position(draft, current: 3) == "Conflict 2 of 2")
        #expect(ResolverShell.position(draft, current: 1) == "Conflict 1 of 2")
        #expect(ResolverShell.position(draft, current: nil) == nil)
        #expect(ResolverShell.position(nil, current: 1) == nil)
    }

    // MARK: - The sidebar

    @Test func sidebarStatusTexts() throws {
        #expect(ConflictWording.sidebarStatus(.left(2)) == "2 left")
        #expect(ConflictWording.sidebarStatus(.left(0)) == "0 left")
        #expect(ConflictWording.sidebarStatus(.resolved) == "Resolved")
        #expect(ConflictWording.sidebarStatus(.wholeFile) == "Whole file")
        #expect(ConflictWording.sidebarStatus(.readOnly) == "Read only")
        // A read still to land: no guessed number (Ruling 19).
        #expect(ConflictWording.sidebarStatus(.pending) == nil)

        // Which status: Resolved first; a draft's live count over the cached summary; the
        // summary; else pending.
        let draft = try Self.draft(taken: 1)
        #expect(ResolverShell.rowStatus(resolved: true, draft: draft, summary: .conflicts(5)) == .resolved)
        #expect(ResolverShell.rowStatus(resolved: false, draft: draft, summary: .conflicts(5)) == .left(1))
        #expect(ResolverShell.rowStatus(resolved: false, draft: nil, summary: .conflicts(5)) == .left(5))
        #expect(ResolverShell.rowStatus(resolved: false, draft: nil, summary: .wholeFile) == .wholeFile)
        #expect(ResolverShell.rowStatus(resolved: false, draft: nil, summary: nil) == .pending)
        // Changed outside is still edited (Ruling 17); resolved outside or ended is not.
        #expect(ResolverShell.rowStatus(resolved: false, draft: try Self.draft(detached: .changedOutside), summary: nil)
            == .left(2))
        #expect(ResolverShell.rowStatus(resolved: false, draft: try Self.draft(detached: .operationEnded), summary: nil)
            == .readOnly)
    }

    /// Every conflicted file, every file resolved this session and every draft kept after its
    /// file stopped being conflicted, once each, in git's order (bytes).
    @Test func sidebarRowsListEveryFileOnceInGitsOrder() throws {
        let files = [Self.file("b.txt"), Self.file("docs/z.md")]
        let kept = try Self.draft(detached: .resolvedOutside)
        let rows = ResolverShell.rows(
            files: files, resolved: ["a.txt", "b.txt"], drafts: ["c.txt": kept], summaries: ["docs/z.md": .wholeFile])
        #expect(rows.map(\.path) == ["a.txt", "b.txt", "c.txt", "docs/z.md"])
        #expect(rows.map(\.status) == [.resolved, .resolved, .readOnly, .wholeFile])
        #expect(rows.map(\.name) == ["a.txt", "b.txt", "c.txt", "z.md"])
        #expect(rows.map(\.folder) == [nil, nil, nil, "docs"])
        #expect(rows.map(\.isConflicted) == [false, true, false, true])
        #expect(ConflictWording.noFolder == "\u{2014}")
    }

    /// One row clicked focuses it; a ⌘- or ⇧-click adding a second only selects.
    @Test func aSingleSelectionMovesTheFocus() {
        #expect(ResolverShell.focusAfterSelection(["b.txt"], focused: "a.txt") == "b.txt")
        #expect(ResolverShell.focusAfterSelection(["a.txt"], focused: "a.txt") == nil)
        #expect(ResolverShell.focusAfterSelection(["a.txt", "b.txt"], focused: "a.txt") == nil)
        #expect(ResolverShell.focusAfterSelection([], focused: "a.txt") == nil)
    }

    // MARK: - The bars

    @Test func theBarsSayWhatHappened() throws {
        #expect(ResolverShell.bars(try Self.draft(), matchesGitsConflict: true, keptEditing: false).isEmpty)
        #expect(ResolverShell.bars(try Self.draft(), matchesGitsConflict: false, keptEditing: false)
            == [.editedAfterConflict])
        #expect(ResolverShell.bars(try Self.draft(detached: .changedOutside), matchesGitsConflict: true, keptEditing: false)
            == [.changedOutside])
        // Keep Editing hides it for this draft (Ruling 18).
        #expect(ResolverShell.bars(try Self.draft(detached: .changedOutside), matchesGitsConflict: true, keptEditing: true)
            .isEmpty)
        // Only the changed-outside bar is Keep Editing's.
        #expect(ResolverShell.bars(try Self.draft(detached: .resolvedOutside), matchesGitsConflict: true, keptEditing: true)
            == [.resolvedOutside])

        #expect(ConflictWording.bar(.editedAfterConflict)
            == "This file was edited after the conflict; resolving here replaces those edits. A copy will be kept.")
        #expect(ConflictWording.bar(.changedOutside)
            == "This file changed outside Gitter. Reload it to see the new version; your changes will be discarded.")
        #expect(ConflictWording.bar(.notEditable(.tooLarge)) == "This file is too large to edit here")
        #expect(ConflictWording.bar(.notEditable(.notUTF8)) == "This file isn't UTF-8 text")
        #expect(ConflictWording.reload == "Reload")
        #expect(ConflictWording.keepEditing == "Keep Editing")
        #expect(ConflictWording.copyResult == "Copy Result")
    }

    /// One bar describes the draft's state: a detached draft shows its detachment's bar only,
    /// never "edited after the conflict" as well; the not-editable line is a separate kind and
    /// still shows.
    @Test func oneBarDescribesTheDraftsState() throws {
        func bars(_ detached: DraftDetachment?, matches: Bool, kept: Bool = false) throws -> [ResolverBar] {
            ResolverShell.bars(try Self.draft(detached: detached), matchesGitsConflict: matches, keptEditing: kept)
        }
        // Attached.
        #expect(try bars(nil, matches: true) == [])
        #expect(try bars(nil, matches: false) == [.editedAfterConflict])
        // Each detachment, whether or not the file matched git's conflict.
        for matches in [true, false] {
            #expect(try bars(.changedOutside, matches: matches) == [.changedOutside])
            #expect(try bars(.resolvedOutside, matches: matches) == [.resolvedOutside])
            #expect(try bars(.operationEnded, matches: matches) == [.operationEnded])
            // Changed outside after Keep Editing: no bar at all, not the edited-after one.
            #expect(try bars(.changedOutside, matches: matches, kept: true) == [])
        }
    }

    /// Keep Editing is keyed by the draft's snapshot: a reloaded draft (another snapshot) shows
    /// the bar again when it, too, changes outside.
    @Test func keepEditingLastsForThatDraftOnly() throws {
        let draft = try Self.draft(detached: .changedOutside)
        #expect(ResolverShell.keptEditing(draft, kept: draft.snapshot))
        #expect(!ResolverShell.keptEditing(draft, kept: nil))
        let other = ConflictSnapshot(file: Self.file(), worktreeHash: "other")
        #expect(!ResolverShell.keptEditing(draft, kept: other))
    }

    // MARK: - The centre

    @Test func theCentreFollowsWhatWasRead() throws {
        let draft = try Self.draft()
        let failure = ConflictLoadFailure(path: "f.txt", message: "boom")
        #expect(ResolverShell.centre(path: "f.txt", draft: draft, document: nil, failure: failure, allResolved: false)
            == .columns)
        #expect(ResolverShell.centre(path: "f.txt", draft: nil, document: nil, failure: failure, allResolved: false)
            == .failed("boom"))
        #expect(ResolverShell.centre(
            path: "f.txt", draft: nil, document: Self.conflict(.wholeFile(reason: .binary)), failure: nil, allResolved: false)
            == .wholeFile(.binary))
        #expect(ResolverShell.centre(path: "f.txt", draft: nil, document: Self.conflict(.submodule), failure: nil, allResolved: false)
            == .submodule)
        // A text conflict whose draft is still to open, or another file's document.
        #expect(ResolverShell.centre(path: "f.txt", draft: nil, document: Self.conflict(), failure: nil, allResolved: false)
            == .loading)
        #expect(ResolverShell.centre(
            path: "g.txt", draft: nil, document: Self.conflict(.submodule), failure: failure, allResolved: false)
            == .loading)
        #expect(ResolverShell.centre(path: "f.txt", draft: nil, document: nil, failure: nil, allResolved: true)
            == .allResolved)
    }

    // MARK: - Escape

    @Test func escapeIsDoneOnlyWhenNoTextIsBeingEdited() {
        #expect(ResolverShell.escapeIsDone(isEscape: true, modified: false, ownWindow: true, sheetUp: false, editingText: false))
        #expect(!ResolverShell.escapeIsDone(isEscape: true, modified: false, ownWindow: true, sheetUp: false, editingText: true))
        #expect(!ResolverShell.escapeIsDone(isEscape: true, modified: false, ownWindow: true, sheetUp: true, editingText: false))
        #expect(!ResolverShell.escapeIsDone(isEscape: true, modified: false, ownWindow: false, sheetUp: false, editingText: false))
        #expect(!ResolverShell.escapeIsDone(isEscape: true, modified: true, ownWindow: true, sheetUp: false, editingText: false))
        #expect(!ResolverShell.escapeIsDone(isEscape: false, modified: false, ownWindow: true, sheetUp: false, editingText: false))
    }

    // MARK: - The palette

    /// The spec's "Look": each `Resolver/<Role>` colour, light and dark (the chrome's light values
    /// measured from the approved mockup).
    @Test(arguments: ResolverShellTests.palette)
    func thePaletteHasTheSpecsValues(role: String, light: String, dark: String) {
        #expect(Self.hex(role, .aqua) == light, "\(role) light")
        #expect(Self.hex(role, .darkAqua) == dark, "\(role) dark")
    }

    nonisolated static let palette: [(String, String, String)] = [
        ("Ours", "#0A84FF", "#0A84FF"), ("OursTint", "#EAF3FF", "#1B2E42"), ("OursWord", "#BFDBFF", "#17426D"),
        ("Theirs", "#BF5AF2", "#BF5AF2"), ("TheirsTint", "#F7EEFC", "#382840"), ("TheirsWord", "#E8CCF7", "#563368"),
        ("Resolved", "#34C759", "#34C759"), ("ResolvedTint", "#EAF7EE", "#213727"), ("Accent", "#F5821F", "#F5821F"),
        ("Filler", "#F3F3F6", "#2C2C2E"), ("Window", "#FFFFFF", "#1E1E1E"), ("Bar", "#F6F6F8", "#2A2A2C"),
        ("Sidebar", "#F2F2F5", "#252527"), ("Header", "#FAFAFC", "#242426"), ("Separator", "#E5E5EA", "#3A3A3C"),
        ("WaitingSlot", "#FFF6EE", "#3A2A1C"), ("SelectedFile", "#F2E2D6", "#423225"), ("Text", "#1C1C1E", "#F2F2F7"),
        ("SecondaryText", "#8E8E93", "#98989D"), ("LineNumber", "#AEAEB2", "#636366"),
        ("BadgeGreen", "#248A3D", "#6FDC8C"), ("BadgeOrange", "#B5590F", "#FFB066"),
        ("BadgePurple", "#8A3BB8", "#D69CF5"), ("Link", "#0A6BD6", "#4DA3FF"),
    ]

    static func hex(_ role: String, _ appearance: NSAppearance.Name) -> String? {
        guard let color = NSColor(named: "Resolver/\(role)"), let look = NSAppearance(named: appearance) else {
            return nil
        }
        var hex: String?
        look.performAsCurrentDrawingAppearance {
            guard let srgb = color.usingColorSpace(.sRGB) else { return }
            func byte(_ value: CGFloat) -> Int { Int((value * 255).rounded()) }
            hex = String(format: "#%02X%02X%02X", byte(srgb.redComponent), byte(srgb.greenComponent), byte(srgb.blueComponent))
        }
        return hex
    }
}
