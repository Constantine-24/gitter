import AppKit
import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// Focus mode's store, on real git: opening, drafts kept per file with their undo, the two
/// writes (the block choices for a pristine all-taken Result, the text otherwise), the marker
/// question and the Replace sheet before any write, moving on after a write, next and previous
/// across files, several files at once, and drafts that outlive outside changes read-only.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct ResolverStoreTests {

    static let base = "top\nx\nmid\ny\nend\n"
    static let ours = "top\nmain x\nmid\nmain y\nend\n"
    static let theirs = "top\ntopic x\nmid\ntopic y\nend\n"

    /// A merge of `topic` into `main`, stopped with two conflicts in each of `a.txt` and `b.txt`
    /// (chunks 0…4: top, conflict, mid, conflict, end). `deleted`: `c.txt` too, changed on main
    /// and deleted on topic (UD, no theirs stage).
    static func stoppedMerge(deleted: Bool = false) throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.write("a.txt", base)
        try repo.write("b.txt", base)
        if deleted { try repo.write("c.txt", "c\n") }
        try repo.git("add", ".")
        try repo.git("commit", "-m", "base")
        try repo.git("switch", "-c", "topic")
        try repo.write("a.txt", theirs)
        try repo.write("b.txt", theirs)
        if deleted { try repo.git("rm", "-q", "c.txt") }
        try repo.git("commit", "-qam", "topic")
        try repo.git("switch", "-q", "main")
        try repo.write("a.txt", ours)
        try repo.write("b.txt", ours)
        if deleted { try repo.write("c.txt", "c main\n") }
        try repo.git("commit", "-qam", "main")
        try repo.gitExpectingFailure("merge", "topic")
        return repo
    }

    /// Opens focus mode on `path` (nil: the first file) and waits for its draft.
    static func openDraft(
        _ store: RepositoryStore, _ path: String? = nil, sourceLocation: SourceLocation = #_sourceLocation
    ) async -> ResolverDraft? {
        store.openResolver(at: path)
        guard let focused = store.resolverFocus?.path else {
            Issue.record("no focus", sourceLocation: sourceLocation)
            return nil
        }
        await waitUntil("the draft of \(focused)", sourceLocation: sourceLocation) {
            store.resolverDrafts[focused] != nil
        }
        return store.resolverDrafts[focused]
    }

    static func file(_ repo: ScratchRepo, _ path: String) throws -> Data {
        try Data(contentsOf: repo.url.appending(path: path))
    }

    /// The range of `needle` in the focused draft's Result.
    static func range(of needle: String, in store: RepositoryStore) -> NSRange {
        guard let path = store.resolverFocus?.path, let draft = store.resolverDrafts[path] else {
            return NSRange(location: NSNotFound, length: 0)
        }
        return (draft.document.resultText as NSString).range(of: needle)
    }

    static func isUnmerged(_ repo: ScratchRepo, _ path: String) throws -> Bool {
        !(try repo.git("ls-files", "-u", "--", path)).isEmpty
    }

    // MARK: - Opening

    @Test(.timeLimit(.minutes(10))) func openingFocusesTheFirstFileWithConflicts() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        #expect(store.resolverFocus == nil)
        #expect(store.resolverFiles.map(\.path) == ["a.txt", "b.txt"])

        let draft = try #require(await Self.openDraft(store))
        #expect(store.resolverFocus?.path == "a.txt")
        #expect(store.resolverFocus?.currentChunk == 1)
        #expect(draft.document.waitingCount == 2)
        #expect(!draft.hasUserChanges)
        #expect(draft.detached == nil)
        #expect(draft.snapshot.file == store.resolverFiles.first)
        #expect(draft.sides.ours == Data(Self.ours.utf8) && draft.sides.theirs == Data(Self.theirs.utf8))
        #expect(backend.calls.contains(.conflictSides))
        #expect(store.resolvedThisSession.isEmpty)
    }

    /// The sides are read with the document: when the file moves on between the reads, no draft
    /// is opened on them, and the refusal is the write's own "changed after it was shown".
    @Test(.timeLimit(.minutes(10))) func aDraftIsNotOpenedOnSidesThatMovedOn() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let once = Recorded(true)
        backend.hook(.conflictSides) {
            guard once.value else { return }
            once.set(false)
            try repo.write("a.txt", "changed meanwhile\n")
        }
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        defer { await releaseAndSettle([backend], [store]) }
        // The write in the hook wakes the watcher: its reload is held, so nothing reads the file
        // again before the assertions below.
        _ = backend.hold(.snapshot)

        store.openResolver(at: "a.txt")
        await waitUntil("the refusal") { store.lastError != nil }
        #expect(store.lastError == ConflictWording.error(.changedSinceShown("a.txt")))
        #expect(store.resolverDrafts["a.txt"] == nil)

        // Read again, the reads agree: the draft opens on the file as it is now.
        backend.releaseAll()
        await store.refresh()
        await waitUntil("the draft") { store.resolverDrafts["a.txt"] != nil }
        let draft = try #require(store.resolverDrafts["a.txt"])
        #expect(draft.snapshot.worktreeHash == ConflictSnapshot.worktreeHash(of: "a.txt", at: repo.url))
    }

    // MARK: - Drafts

    @Test(.timeLimit(.minutes(10))) func switchingFilesKeepsTheDraft() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))

        store.resolverTake(.ours)
        let taken = try #require(store.resolverDrafts["a.txt"]?.document)
        store.resolverReplace(Self.range(of: "mid", in: store), with: "middle")
        let typed = try #require(store.resolverDrafts["a.txt"]?.document.resultText)
        #expect(typed == "top\nmain x\nmiddle\nend\n")

        store.focusResolverFile("b.txt")
        await waitUntil("b's draft") { store.resolverDrafts["b.txt"] != nil }
        #expect(store.resolverFocus?.path == "b.txt")
        store.focusResolverFile("a.txt")
        #expect(store.resolverFocus?.path == "a.txt")
        #expect(store.resolverDrafts["a.txt"]?.document.resultText == typed)
        #expect(store.resolverDrafts["a.txt"]?.hasUserChanges == true)

        // The undo history came along.
        store.resolverUndo()
        #expect(store.resolverDrafts["a.txt"]?.document == taken)
        store.resolverUndo()
        #expect(store.resolverDrafts["a.txt"]?.document.isPristine == true)
        store.resolverRedo()
        #expect(store.resolverDrafts["a.txt"]?.document == taken)
    }

    /// A backspace with the caret in a waiting slot is refused: nothing changes, and nothing is
    /// pushed to undo (Ruling 14).
    @Test(.timeLimit(.minutes(10))) func theBreakBeforeASlotIsKeptWithNoUndoStep() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let draft = try #require(await Self.openDraft(store))
        let slot = draft.document.range(ofChunk: 3).location
        store.resolverReplace(NSRange(location: slot - 1, length: 1), with: "")
        let after = try #require(store.resolverDrafts["a.txt"])
        #expect(after.document == draft.document)
        #expect(!after.history.canUndo)
        #expect(after.document.waitingCount == 2)
    }

    @Test(.timeLimit(.minutes(10))) func showsBaseIsRemembered() async throws {
        let (store, defaults, cleanup) = makeTestStore()
        defer { cleanup() }
        #expect(!store.showsBase)
        store.showsBase = true
        #expect(defaults.bool(forKey: "resolverShowsBase"))
        let again = RepositoryStore(backend: CLIGitBackend(), defaults: defaults)
        #expect(again.showsBase)
    }

    // MARK: - Writing

    @Test(.timeLimit(.minutes(10))) func aPristineAllTakenFileUsesTheChoicesWrite() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))

        store.resolverTakeRest(.ours)
        #expect(store.resolverDrafts["a.txt"]?.document.blockChoices() == [.ours, .ours])
        store.resolveFocusedFile()
        await waitUntilIdle(store)

        #expect(backend.calls.filter { $0 == .resolve }.count == 1)
        #expect(!backend.calls.contains(.resolveText))
        #expect(try Self.file(repo, "a.txt") == Data(Self.ours.utf8))
        #expect(try !Self.isUnmerged(repo, "a.txt"))
        #expect(store.resolverDrafts["a.txt"] == nil)
        #expect(store.resolvedThisSession == ["a.txt"])
    }

    @Test(.timeLimit(.minutes(10))) func anEditedFileUsesTheTextWrite() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))

        store.resolverTakeRest(.theirs)
        store.resolverReplace(Self.range(of: "end", in: store), with: "the end")
        let shown = try #require(store.resolverDrafts["a.txt"]?.document.resultText)
        #expect(shown == "top\ntopic x\nmid\ntopic y\nthe end\n")
        store.resolveFocusedFile()
        await waitUntilIdle(store)

        #expect(backend.calls.filter { $0 == .resolveText }.count == 1)
        #expect(!backend.calls.contains(.resolve))
        #expect(try Self.file(repo, "a.txt") == Data(shown.utf8))
        #expect(try repo.git("show", ":0:a.txt") == shown)
        #expect(store.resolvedThisSession == ["a.txt"])
    }

    @Test(.timeLimit(.minutes(10))) func markersAskBeforeAnyWrite() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        let draft = try #require(await Self.openDraft(store))
        let before = try Self.file(repo, "a.txt")

        store.resolverTakeRest(.ours)
        store.resolverReplace(NSRange(location: 0, length: 0), with: "<<<<<<< typed\n")
        store.resolveFocusedFile()
        await waitUntilIdle(store)

        guard case .resolveWithMarkers(let snapshot, let pending)? = store.activeSheet else {
            Issue.record("no marker question: \(String(describing: store.activeSheet))")
            return
        }
        #expect(snapshot == draft.snapshot)
        #expect(try Self.file(repo, "a.txt") == before)
        #expect(!backend.calls.contains(.resolveText) && !backend.calls.contains(.resolve))
        #expect(try Self.isUnmerged(repo, "a.txt"))

        store.confirmResolveWithMarkers(snapshot, pending)
        await waitUntilIdle(store)
        #expect(store.activeSheet == nil)
        #expect(try Self.file(repo, "a.txt") == Data(("<<<<<<< typed\n" + Self.ours).utf8))
        #expect(try !Self.isUnmerged(repo, "a.txt"))
    }

    @Test(.timeLimit(.minutes(10))) func editedSinceRaisesTheReplaceSheet() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        try repo.write("a.txt", "edited in an editor\n")
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        let draft = try #require(await Self.openDraft(store))
        // The Result starts from git's conflict, not from the edited file.
        #expect(draft.document.waitingCount == 2)

        store.resolverTakeRest(.ours)
        store.resolveFocusedFile()
        await waitUntilIdle(store)
        #expect(store.activeSheet == .replaceHandEdited(draft.snapshot, .blocks([.ours, .ours])))
        #expect(try Self.file(repo, "a.txt") == Data("edited in an editor\n".utf8))

        store.confirmReplaceHandEdited(draft.snapshot, .blocks([.ours, .ours]))
        await waitUntilIdle(store)
        #expect(try Self.file(repo, "a.txt") == Data(Self.ours.utf8))
        #expect(try repo.git("stash", "list").contains("Replaced by Gitter: a.txt"))
        #expect(store.resolvedThisSession == ["a.txt"])
    }

    @Test(.timeLimit(.minutes(10))) func resolvingAdvancesToTheNextFile() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))

        store.resolverTakeRest(.ours)
        store.resolveFocusedFile()
        await waitUntilIdle(store)
        #expect(store.resolverFocus?.path == "b.txt")
        await waitUntil("b's draft") { store.resolverDrafts["b.txt"] != nil }
        #expect(store.resolverFocus?.currentChunk == 1)
        #expect(!store.resolverAllResolved)
        #expect(store.resolverFiles.map(\.path) == ["b.txt"])
    }

    @Test(.timeLimit(.minutes(10))) func theLastFileShowsAllResolved() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))
        store.resolverTakeRest(.ours)
        store.resolveFocusedFile()
        await waitUntilIdle(store)
        await waitUntil("b's draft") { store.resolverDrafts["b.txt"] != nil }

        store.resolverTakeRest(.theirs)
        store.resolveFocusedFile()
        await waitUntilIdle(store)
        #expect(store.resolverFiles.isEmpty)
        #expect(store.resolverAllResolved)
        #expect(store.resolverFocus != nil)
        #expect(store.resolvedThisSession == ["a.txt", "b.txt"])
        #expect(store.resolverDrafts.isEmpty)
    }

    // MARK: - Navigation

    @Test(.timeLimit(.minutes(10))) func nextConflictCrossesIntoTheNextFile() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))
        #expect(store.resolverFocus == ResolverFocus(path: "a.txt", currentChunk: 1))

        store.resolverNextConflict()
        #expect(store.resolverFocus == ResolverFocus(path: "a.txt", currentChunk: 3))
        store.resolverNextConflict()
        #expect(store.resolverFocus?.path == "b.txt")
        await waitUntil("b's draft") { store.resolverDrafts["b.txt"] != nil }
        #expect(store.resolverFocus == ResolverFocus(path: "b.txt", currentChunk: 1))

        // Back past b's first conflict: a's last.
        store.resolverPreviousConflict()
        #expect(store.resolverFocus == ResolverFocus(path: "a.txt", currentChunk: 3))
        store.resolverPreviousConflict()
        #expect(store.resolverFocus == ResolverFocus(path: "a.txt", currentChunk: 1))
    }

    // MARK: - Many files

    @Test(.timeLimit(.minutes(10))) func takeSideForFilesSkipsADeletionAndRecordsEdits() async throws {
        let repo = try Self.stoppedMerge(deleted: true)
        defer { repo.remove() }
        try repo.write("b.txt", "edited in an editor\n")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        #expect(store.resolverFiles.map(\.path) == ["a.txt", "b.txt", "c.txt"])
        _ = try #require(await Self.openDraft(store))

        store.takeSideForFiles(["a.txt", "b.txt", "c.txt"], .theirs)
        await waitUntil("the sheet") { store.activeSheet != nil }
        guard case .takeForFiles(let plan)? = store.activeSheet else {
            Issue.record("no take-for-files sheet: \(String(describing: store.activeSheet))")
            return
        }
        #expect(plan.side == .theirs)
        #expect(plan.files.map(\.file.path) == ["a.txt", "b.txt"])
        #expect(plan.copies == ["b.txt"])
        #expect(plan.skipped == [TakeForFilesPlan.Skipped(path: "c.txt", reason: .noSide)])
        #expect(!backend.calls.contains(.take))

        store.confirmTakeForFiles(plan)
        await waitUntilIdle(store)
        #expect(backend.calls.filter { $0 == .take }.count == 2)
        #expect(try Self.file(repo, "a.txt") == Data(Self.theirs.utf8))
        #expect(try Self.file(repo, "b.txt") == Data(Self.theirs.utf8))
        #expect(try repo.git("stash", "list").contains("Replaced by Gitter: b.txt"))
        #expect(try !repo.git("stash", "list").contains("Replaced by Gitter: a.txt"))
        #expect(try Self.isUnmerged(repo, "c.txt"))
        #expect(store.resolverFiles.map(\.path) == ["c.txt"])
        #expect(store.resolvedThisSession == ["a.txt", "b.txt"])
        #expect(store.resolverDrafts["a.txt"] == nil)
        #expect(store.resolverFocus?.path == "c.txt")
        let notice = try #require(store.stickyNotice ?? store.notice)
        #expect(notice.text.contains("\"c.txt\""))
    }

    // MARK: - Outside changes

    @Test(.timeLimit(.minutes(10))) func aDraftSurvivesAnOutsideChangeReadOnly() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))
        store.resolverTakeRest(.ours)
        store.resolverReplace(Self.range(of: "end", in: store), with: "mine")
        let kept = try #require(store.resolverDrafts["a.txt"])

        try repo.write("a.txt", "changed in a terminal\n")
        await store.refresh()
        await waitUntilIdle(store)

        let draft = try #require(store.resolverDrafts["a.txt"])
        #expect(draft.detached == .changedOutside)
        #expect(draft.document == kept.document)
        #expect(store.resolverFocus?.path == "a.txt")

        // Read-only: no write, no take, no typing.
        store.resolveFocusedFile()
        store.resolverTake(.theirs, chunk: 1)
        store.resolverReplace(NSRange(location: 0, length: 0), with: "x")
        await waitUntilIdle(store)
        #expect(!backend.calls.contains(.resolve) && !backend.calls.contains(.resolveText))
        #expect(store.activeSheet == nil)
        #expect(store.resolverDrafts["a.txt"]?.document == kept.document)
        #expect(try Self.file(repo, "a.txt") == Data("changed in a terminal\n".utf8))

        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.resolver-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        store.copyResult("a.txt", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == kept.document.resultText)

        // Reload reads the file again: a fresh draft, attached.
        store.reloadDraft("a.txt")
        #expect(store.resolverDrafts["a.txt"] == nil)
        await waitUntil("the reloaded draft") { store.resolverDrafts["a.txt"] != nil }
        let reloaded = try #require(store.resolverDrafts["a.txt"])
        #expect(reloaded.detached == nil && !reloaded.hasUserChanges)
        #expect(reloaded.snapshot.worktreeHash == ConflictSnapshot.worktreeHash(of: "a.txt", at: repo.url))
    }

    @Test(.timeLimit(.minutes(10))) func resolvedOutsideDetaches() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))
        store.resolverTake(.theirs)

        try repo.git("add", "a.txt")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.resolverDrafts["a.txt"]?.detached == .resolvedOutside)
        #expect(store.resolverDrafts["a.txt"]?.hasUserChanges == true)
        #expect(store.resolverFocus?.path == "a.txt")
    }

    @Test(.timeLimit(.minutes(10))) func operationEndedKeepsFocusOnlyWithChanges() async throws {
        // No changes: focus mode closes, and says why.
        let quiet = try Self.stoppedMerge()
        defer { quiet.remove() }
        let (store, cleanup) = await openedTestStore(quiet)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))
        try quiet.git("merge", "--abort")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.resolverFocus == nil)
        #expect(store.resolverDrafts.isEmpty)
        #expect((store.stickyNotice ?? store.notice)?.text == "The merge ended outside Gitter.")

        // With changes: it stays, the draft kept read-only, with the same notice.
        let busy = try Self.stoppedMerge()
        defer { busy.remove() }
        let (other, otherCleanup) = await openedTestStore(busy)
        defer { otherCleanup() }
        _ = try #require(await Self.openDraft(other))
        other.resolverTake(.ours)
        try busy.git("merge", "--abort")
        await other.refresh()
        await waitUntilIdle(other)
        #expect(other.resolverFocus?.path == "a.txt")
        #expect(other.resolverDrafts["a.txt"]?.detached == .operationEnded)
        #expect(other.resolverDrafts["a.txt"]?.hasUserChanges == true)
        #expect((other.stickyNotice ?? other.notice)?.text == "The merge ended outside Gitter.")
    }

    /// Gitter's own Abort ends the operation too, but not "outside Gitter": its reload is checked
    /// once the write is over, and says nothing of the kind.
    @Test(.timeLimit(.minutes(10))) func gittersOwnAbortIsNotAnOutsideEnd() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let eventLog = RecordingEventLog()
        let (store, _, cleanup) = makeTestStore(eventLog: eventLog.eventLog)
        defer { cleanup() }
        await open(store, repo.url)
        _ = try #require(await Self.openDraft(store))
        store.resolverTake(.ours)

        store.confirmAbort(.merge)
        await waitUntilIdle(store)
        #expect(store.operationInProgress == nil)
        #expect(!eventLog.lines.contains { $0.contains(ConflictWording.operationEndedOutside(.merge)) })
        #expect(store.notice?.text != ConflictWording.operationEndedOutside(.merge))
        #expect(store.stickyNotice?.text != ConflictWording.operationEndedOutside(.merge))
        // The draft with changes is kept read-only (asking first is the Abort sheet's).
        #expect(store.resolverDrafts["a.txt"]?.detached == .operationEnded)
    }

    // MARK: - Done

    @Test(.timeLimit(.minutes(10))) func doneDropsPristineDraftsAndKeepsChangedOnes() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))
        store.resolverTake(.ours)
        store.focusResolverFile("b.txt")
        await waitUntil("b's draft") { store.resolverDrafts["b.txt"] != nil }

        store.closeResolver()
        #expect(store.resolverFocus == nil)
        #expect(store.resolverDrafts.keys.sorted() == ["a.txt"])
        #expect(store.resolvedThisSession.isEmpty)

        // Back in: the kept draft is there as it was left.
        store.openResolver(at: "a.txt")
        #expect(store.resolverDrafts["a.txt"]?.hasUserChanges == true)
    }
}
