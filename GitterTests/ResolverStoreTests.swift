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

    // MARK: - Whole-file side columns (Ruling 23)

    /// A merge stopped with `logo.bin` binary on both sides.
    static func binaryMerge() throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.write("logo.bin", "base\u{0}")
        try repo.git("add", ".")
        try repo.git("commit", "-m", "base")
        try repo.git("switch", "-c", "topic")
        try repo.write("logo.bin", "topic side\u{0}")
        try repo.git("commit", "-qam", "topic")
        try repo.git("switch", "-q", "main")
        try repo.write("logo.bin", "main\u{0}")
        try repo.git("commit", "-qam", "main")
        try repo.gitExpectingFailure("merge", "topic")
        return repo
    }

    /// Focus mode on a whole-file kind reads its stages for the side columns, with the document.
    @Test(.timeLimit(.minutes(10))) func aWholeFileKindReadsItsSidesForTheColumns() async throws {
        let repo = try Self.binaryMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        store.openResolver(at: "logo.bin")
        await waitUntil("the sides") { store.resolverWholeFileSides != nil }
        let read = try #require(store.resolverWholeFileSides)
        #expect(read.file.path == "logo.bin")
        #expect(read.sides.ours == Data("main\u{0}".utf8) && read.sides.theirs == Data("topic side\u{0}".utf8))
        #expect(store.resolverDrafts["logo.bin"] == nil)
        let file = try #require(store.resolverFiles.first)
        #expect(
            ConflictWording.wholeFileSideContent(file, .theirs, .binary, content: read.sides.theirs)
                == .description("Binary file, 11 bytes"))
    }

    /// A failed read of the stages leaves the side columns their short descriptions: the
    /// whole-file choices stay, never the failed state.
    @Test(.timeLimit(.minutes(10))) func aFailedSidesReadLeavesTheShortDescriptions() async throws {
        let repo = try Self.binaryMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        backend.fail(.conflictSides, with: GitError.commandFailed(exitCode: 128, stderr: "boom"))
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        store.openResolver(at: "logo.bin")
        await waitUntil("the stages' read") { backend.calls.contains(.conflictSides) }
        await store.conflictTask?.value
        #expect(store.resolverWholeFileSides == nil)
        #expect(store.conflictLoadFailure == nil)
        let centre = ResolverShell.centre(
            path: "logo.bin", draft: nil, document: store.selectedConflict, failure: store.conflictLoadFailure,
            allResolved: false)
        #expect(centre == .wholeFile(.binary))
    }

    // MARK: - The sidebar's summaries (Ruling 19)

    /// The summaries' reads and the focused file's own reads so far.
    static func documentReads(_ backend: TestBackend) -> Int {
        backend.calls.count { $0 == .conflictDocument }
    }

    /// Opens focus mode and waits for the draft, then for the store to go idle — the focused
    /// file's read and the summaries' included.
    static func openSettled(_ store: RepositoryStore) async throws {
        _ = try #require(await openDraft(store))
        await store.conflictTask?.value
        await waitUntilIdle(store)
    }

    /// Every row has its trailing text once focus mode is up: a text conflict its blocks, read
    /// through the document; a deletion "whole file" from its status record, with no read.
    @Test(.timeLimit(.minutes(10))) func everyRowGetsItsCountAfterOpening() async throws {
        let repo = try Self.stoppedMerge(deleted: true)
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        #expect(store.resolverSummaries.isEmpty)

        try await Self.openSettled(store)
        #expect(store.resolverSummaries.mapValues(\.summary) == ["a.txt": .conflicts(2), "b.txt": .conflicts(2), "c.txt": .wholeFile])
        #expect(store.resolverSummaries["b.txt"]?.record == store.resolverFiles.first { $0.path == "b.txt" })
        let rows = ResolverShell.rows(
            files: store.resolverFiles, resolved: store.resolvedThisSession, drafts: store.resolverDrafts,
            summaries: store.resolverSummaries.mapValues(\.summary))
        #expect(rows.map(\.status) == [.left(2), .left(2), .wholeFile])
        // a.txt and b.txt once each for the summaries, a.txt once more as the focused file; c.txt never.
        #expect(Self.documentReads(backend) == 3)

        // Done drops them.
        store.closeResolver()
        #expect(store.resolverSummaries.isEmpty)
    }

    /// A reload whose records are the same reads no summary again (the focused file's own read
    /// comes with every reload, as before); closing and opening again reads them all.
    @Test(.timeLimit(.minutes(10))) func aReloadWithTheSameRecordsReadsNothingAgain() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        try await Self.openSettled(store)
        let opened = Self.documentReads(backend)

        await store.refresh()
        await waitUntilIdle(store)
        await store.conflictTask?.value
        #expect(Self.documentReads(backend) - opened <= 1, "only the focused file's own read")
        #expect(store.resolverSummaries.mapValues(\.summary) == ["a.txt": .conflicts(2), "b.txt": .conflicts(2)])

        // Not vacuous: with the cache dropped, both are read again.
        let reloaded = Self.documentReads(backend)
        store.closeResolver()
        try await Self.openSettled(store)
        #expect(Self.documentReads(backend) - reloaded >= 2)
        #expect(store.resolverSummaries.mapValues(\.summary) == ["a.txt": .conflicts(2), "b.txt": .conflicts(2)])
    }

    /// `waitUntilIdle` waits for the summaries' read like any other read: with every document
    /// read slowed, the draft lands while b.txt's summary is still being read, and the wait still
    /// ends with both summaries in.
    @Test(.timeLimit(.minutes(10))) func waitUntilIdleWaitsForTheSummaryRead() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        backend.hook(.conflictDocument, .after) { try await Task.sleep(for: .milliseconds(800)) }
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))
        await waitUntilIdle(store)
        #expect(!store.isReadingResolverSummaries)
        #expect(store.resolverSummaries.mapValues(\.summary) == ["a.txt": .conflicts(2), "b.txt": .conflicts(2)])
    }

    /// A summary whose read fails leaves its row without text — never a guessed number — and is
    /// read again on the next reload.
    @Test(.timeLimit(.minutes(10))) func aFailedSummaryReadShowsNoTextAndIsRetried() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        backend.failConflictDocument(of: "b.txt", with: SummaryReadFailed())
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        try await Self.openSettled(store)
        #expect(store.resolverSummaries["b.txt"] == nil)
        let rows = ResolverShell.rows(
            files: store.resolverFiles, resolved: store.resolvedThisSession, drafts: store.resolverDrafts,
            summaries: store.resolverSummaries.mapValues(\.summary))
        #expect(rows.map(\.status) == [.left(2), .pending])
        #expect(rows.map { ConflictWording.sidebarStatus($0.status) } == ["2 left", nil])

        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.resolverSummaries["b.txt"]?.summary == .conflicts(2))
    }

    struct SummaryReadFailed: Error {}

    /// A file with a draft shows the draft's live waiting count, never the cached summary.
    @Test(.timeLimit(.minutes(10))) func aDraftsCountWinsOverTheSummary() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        try await Self.openSettled(store)
        store.resolverTake(.theirs)
        #expect(store.resolverSummaries["a.txt"]?.summary == .conflicts(2))
        let rows = ResolverShell.rows(
            files: store.resolverFiles, resolved: store.resolvedThisSession, drafts: store.resolverDrafts,
            summaries: store.resolverSummaries.mapValues(\.summary))
        #expect(rows.map(\.status) == [.left(1), .left(2)])
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

    /// A file changed in a terminal under a draft (Ruling 17, the spec's Keep Editing): the draft
    /// stays as it was, `.changedOutside`, and can still be typed in and taken from, with its
    /// undo; only its write is refused, since it would go over the newer file. Copy Result works,
    /// and Reload reads the file again.
    @Test(.timeLimit(.minutes(10))) func aDraftSurvivesAnOutsideChangeAndKeepsEditing() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))
        store.resolverTake(.ours, chunk: 1)
        store.resolverReplace(Self.range(of: "end", in: store), with: "mine")
        let kept = try #require(store.resolverDrafts["a.txt"])

        try repo.write("a.txt", "changed in a terminal\n")
        await store.refresh()
        await waitUntilIdle(store)

        let draft = try #require(store.resolverDrafts["a.txt"])
        #expect(draft.detached == .changedOutside)
        #expect(draft.document == kept.document)
        #expect(store.resolverFocus?.path == "a.txt")

        // Keep Editing: typing, a take and undo still work, and the history is kept.
        store.resolverReplace(NSRange(location: 0, length: 0), with: "x")
        store.resolverTake(.theirs, chunk: 3)
        let edited = try #require(store.resolverDrafts["a.txt"])
        #expect(edited.detached == .changedOutside)
        #expect(edited.document.resultText == "xtop\nmain x\nmid\ntopic y\nmine\n")
        store.resolverUndo()
        #expect(store.resolverDrafts["a.txt"]?.document.resultText == "xtop\nmain x\nmid\nmine\n")
        store.resolverRedo()
        #expect(store.resolverDrafts["a.txt"]?.document == edited.document)
        #expect(store.resolverDrafts["a.txt"]?.document.waitingCount == 0)

        // Never written over the newer file.
        store.resolveFocusedFile()
        await waitUntilIdle(store)
        #expect(!backend.calls.contains(.resolve) && !backend.calls.contains(.resolveText))
        #expect(store.activeSheet == nil)
        #expect(try Self.file(repo, "a.txt") == Data("changed in a terminal\n".utf8))

        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.resolver-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        store.copyResult("a.txt", to: pasteboard)
        #expect(pasteboard.string(forType: .string) == edited.document.resultText)

        // Reload reads the file again: a fresh draft, attached.
        store.reloadDraft("a.txt")
        #expect(store.resolverDrafts["a.txt"] == nil)
        await waitUntil("the reloaded draft") { store.resolverDrafts["a.txt"] != nil }
        let reloaded = try #require(store.resolverDrafts["a.txt"])
        #expect(reloaded.detached == nil && !reloaded.hasUserChanges)
        #expect(reloaded.snapshot.worktreeHash == ConflictSnapshot.worktreeHash(of: "a.txt", at: repo.url))
    }

    /// An index-only change — stage 3 replaced through `git`, the worktree bytes untouched — is
    /// an outside change too: the stages are compared, not only the file's hash.
    @Test(.timeLimit(.minutes(10))) func anIndexOnlyChangeDetaches() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))
        store.resolverTake(.ours)
        let bytes = try Self.file(repo, "a.txt")

        let blob = try repo.git(input: "top\nanother x\nmid\nanother y\nend\n", "hash-object", "-w", "--stdin")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        try repo.git(input: "100644 \(blob) 3\ta.txt\n", "update-index", "--index-info")
        #expect(try repo.git("ls-files", "-s", "--", "a.txt").contains("\(blob) 3\ta.txt"))
        await store.refresh()
        await waitUntilIdle(store)

        #expect(try Self.file(repo, "a.txt") == bytes)
        #expect(store.resolverDrafts["a.txt"]?.detached == .changedOutside)
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

        // Resolved outside, the draft is read-only: no typing, no take, no undo.
        let kept = try #require(store.resolverDrafts["a.txt"]?.document)
        store.resolverReplace(NSRange(location: 0, length: 0), with: "x")
        store.resolverTake(.ours, chunk: 3)
        store.resolverTakeRest(.ours)
        store.resolverUndo()
        #expect(store.resolverDrafts["a.txt"]?.document == kept)
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

    /// Which operation ended is remembered while its drafts are kept, for the subtitle, and
    /// forgotten at Done (Ruling 24).
    @Test(.timeLimit(.minutes(10))) func theEndedOperationIsRememberedUntilDone() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        #expect(store.resolverEndedOperation == nil)
        _ = try #require(await Self.openDraft(store))
        store.resolverTake(.ours)
        #expect(store.resolverEndedOperation == nil)

        try repo.git("merge", "--abort")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.resolverEndedOperation == .merge)
        #expect(ResolverShell.endedOperation(store.resolverDrafts, remembered: store.resolverEndedOperation) == .merge)
        #expect(ResolverShell.subtitle(
            store.operationInProgress, nil, branch: store.currentBranch,
            ended: ResolverShell.endedOperation(store.resolverDrafts, remembered: store.resolverEndedOperation))
            == "The merge ended outside Gitter.")

        store.closeResolver()
        #expect(store.resolverEndedOperation == nil)
    }

    /// Discard Changes on a draft whose file was resolved outside leaves a path with no
    /// conflict and no draft: the focus moves to the next file with conflicts (Ruling 26) rather
    /// than waiting for a read that never comes.
    @Test(.timeLimit(.minutes(10))) func discardingAResolvedOutsideDraftMovesTheFocusOn() async throws {
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
        #expect(store.resolverFocus?.path == "a.txt")

        store.discardDraft("a.txt")
        #expect(store.resolverFocus?.path == "b.txt")
        await waitUntil("b's draft") { store.resolverDrafts["b.txt"] != nil }
        #expect(ResolverShell.centre(
            path: "b.txt", draft: store.focusedDraft, document: store.selectedConflict,
            failure: store.conflictLoadFailure, allResolved: store.resolverAllResolved) == .columns)

        // The last one too: resolved outside, discarded, and the all-resolved state, not a spinner.
        store.resolverTake(.ours)
        try repo.git("add", "b.txt")
        await store.refresh()
        await waitUntilIdle(store)
        store.discardDraft("b.txt")
        #expect(store.resolverAllResolved)
        #expect(ResolverShell.centre(
            path: store.resolverFocus?.path, draft: store.focusedDraft, document: store.selectedConflict,
            failure: store.conflictLoadFailure, allResolved: store.resolverAllResolved) == .allResolved)
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
        // The Abort sheet named the draft with changes, and the abort drops it rather than keeping
        // it read-only under an "ended" label (Task 7, Ruling 35).
        #expect(store.resolverDrafts.isEmpty)
        #expect(store.resolverFocus == nil)
    }

    // MARK: - Done

    /// Done keeps an edited draft changed outside — it is still edited (Keep Editing), and opens
    /// again with its bar — and drops an edited one whose file was resolved outside (Ruling 25).
    @Test(.timeLimit(.minutes(10))) func doneKeepsAnEditedChangedOutsideDraftOnly() async throws {
        let repo = try Self.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        _ = try #require(await Self.openDraft(store))
        store.resolverTake(.ours)
        store.focusResolverFile("b.txt")
        await waitUntil("b's draft") { store.resolverDrafts["b.txt"] != nil }
        store.resolverTake(.theirs)

        try repo.write("a.txt", "changed in a terminal\n")
        try repo.git("add", "b.txt")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.resolverDrafts["a.txt"]?.detached == .changedOutside)
        #expect(store.resolverDrafts["b.txt"]?.detached == .resolvedOutside)

        store.closeResolver()
        #expect(store.resolverDrafts.keys.sorted() == ["a.txt"])
        #expect(store.resolverDrafts["a.txt"]?.detached == .changedOutside)
        #expect(store.resolverDrafts["a.txt"]?.hasUserChanges == true)

        store.openResolver(at: "a.txt")
        #expect(store.focusedDraft?.detached == .changedOutside)
        #expect(ResolverShell.bars(try #require(store.focusedDraft), matchesGitsConflict: false, keptEditing: false)
            == [.changedOutside])
    }

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
