import AppKit
import Foundation
import GitCore
import GitCoreTestSupport
import Testing

@testable import Gitter

/// Task 7, never lose a draft: every action of Gitter's own that would write over or remove a file
/// whose draft has changes asks first, and Cancel does nothing at all (Ruling 35); Done asks before
/// it drops read-only drafts with changes (Ruling 36); closing a window asks for that window's
/// drafts, a hidden window's final close too. On real git, through the store; the window side is
/// recorded (`HiddenWindowRecorder`). The quit's question is `QuitFlowTests.QuitDraftTests`.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct ResolverDraftGuardTests {
    typealias Fixture = ResolverStoreTests

    /// `path`'s draft with a change in it (Take Ours on its first conflict), focus mode opened on
    /// it first if it is not up.
    static func changedDraft(
        _ store: RepositoryStore, _ path: String = "a.txt", sourceLocation: SourceLocation = #_sourceLocation
    ) async -> ResolverDraft? {
        if store.resolverFocus == nil {
            _ = await Fixture.openDraft(store, path, sourceLocation: sourceLocation)
        } else {
            store.focusResolverFile(path)
            await waitUntil("\(path)'s draft", sourceLocation: sourceLocation) { store.resolverDrafts[path] != nil }
        }
        store.resolverTake(.ours)
        #expect(store.resolverDrafts[path]?.hasUserChanges == true, sourceLocation: sourceLocation)
        return store.resolverDrafts[path]
    }

    static func question(_ paths: [String], _ purpose: DraftQuestion.Purpose = .action) -> DraftQuestion {
        DraftQuestion(paths: paths, purpose: purpose)
    }

    static func asked(_ store: RepositoryStore) -> DraftQuestion? {
        if case .discardDrafts(let question) = store.activeSheet { question } else { nil }
    }

    /// A cherry-pick of `topic` onto `main`, stopped with two conflicts in each of `a.txt` and
    /// `b.txt`: Skip is offered.
    static func stoppedPick() throws -> ScratchRepo {
        let repo = try ScratchRepo()
        try repo.write("a.txt", Fixture.base)
        try repo.write("b.txt", Fixture.base)
        try repo.git("add", ".")
        try repo.git("commit", "-m", "base")
        try repo.git("switch", "-c", "topic")
        try repo.write("a.txt", Fixture.theirs)
        try repo.write("b.txt", Fixture.theirs)
        try repo.git("commit", "-qam", "topic")
        try repo.git("switch", "-q", "main")
        try repo.write("a.txt", Fixture.ours)
        try repo.write("b.txt", Fixture.ours)
        try repo.git("commit", "-qam", "main")
        try repo.gitExpectingFailure("cherry-pick", "topic")
        return repo
    }

    // MARK: - Discard questions

    /// Mark Resolved over a draft with changes asks first, naming the file; Cancel reads, writes
    /// and drops nothing. Discard Changes drops the draft, then Mark Resolved runs as ever — the
    /// file on disk still has its markers, so its own question comes, and the focused file is
    /// read afresh rather than left waiting.
    @Test(.timeLimit(.minutes(10))) func markResolvedAsksWhenADraftHasChanges() async throws {
        let repo = try Fixture.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        let draft = try #require(await Self.changedDraft(store))
        let bytes = try Fixture.file(repo, "a.txt")

        store.markSelectedResolved()
        try #require(Self.asked(store) == Self.question(["a.txt"]))
        #expect(ConflictWording.draftQuestionTitle(Self.question(["a.txt"])) == "Discard your changes to \"a.txt\"?")
        #expect(ConflictWording.draftQuestionButton(Self.question(["a.txt"])) == "Discard Changes")

        store.cancelDiscardDrafts()
        await waitUntilIdle(store)
        #expect(store.activeSheet == nil)
        #expect(store.resolverDrafts["a.txt"] == draft, "the draft, its document and its undo history as they were")
        #expect(!backend.calls.contains(.markResolved))
        #expect(try Fixture.file(repo, "a.txt") == bytes)
        #expect(try Fixture.isUnmerged(repo, "a.txt"))

        store.markSelectedResolved()
        store.confirmDiscardDrafts(Self.question(["a.txt"]))
        #expect(store.resolverDrafts["a.txt"] == nil)
        await waitUntil("the markers question") {
            if case .markResolved = store.activeSheet { true } else { false }
        }
        #expect(backend.calls.contains(.markResolved))
        store.activeSheet = nil
        await waitUntil("the file read afresh") { store.resolverDrafts["a.txt"] != nil }
        #expect(store.resolverDrafts["a.txt"]?.hasUserChanges == false)
        #expect(store.resolverDrafts["a.txt"]?.detached == nil)
        #expect(try Fixture.isUnmerged(repo, "a.txt"))
    }

    /// A pristine draft never asks: Mark Resolved and the row's stage button go straight to the
    /// write (here its markers question).
    @Test(.timeLimit(.minutes(10))) func aPristineDraftNeverAsks() async throws {
        let repo = try Fixture.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        let draft = try #require(await Fixture.openDraft(store))
        #expect(!draft.hasUserChanges)

        store.markSelectedResolved()
        #expect(Self.asked(store) == nil)
        await waitUntil("the markers question") {
            if case .markResolved = store.activeSheet { true } else { false }
        }
        #expect(backend.calls.filter { $0 == .markResolved }.count == 1)
        store.activeSheet = nil
        await waitUntilIdle(store)

        let row = try #require(store.snapshot?.status.files.first { $0.path == "a.txt" })
        store.stage(row)
        #expect(Self.asked(store) == nil)
        await waitUntil("the markers question again") {
            if case .markResolved = store.activeSheet { true } else { false }
        }
        #expect(backend.calls.filter { $0 == .markResolved }.count == 2)
    }

    /// The row's stage button (Space, the + button) and a whole-file Take over a draft with
    /// changes ask too; Discard Changes then takes the file, and its draft is gone.
    @Test(.timeLimit(.minutes(10))) func theStageButtonAndAWholeFileTakeAsk() async throws {
        let repo = try Fixture.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        let draft = try #require(await Self.changedDraft(store))

        let row = try #require(store.snapshot?.status.files.first { $0.path == "a.txt" })
        store.stage(row)
        #expect(Self.asked(store) == Self.question(["a.txt"]))
        store.cancelDiscardDrafts()

        store.takeSide(.theirs)
        #expect(Self.asked(store) == Self.question(["a.txt"]))
        store.cancelDiscardDrafts()
        await waitUntilIdle(store)
        #expect(store.resolverDrafts["a.txt"] == draft)
        #expect(!backend.calls.contains(.markResolved) && !backend.calls.contains(.take))
        #expect(try Fixture.isUnmerged(repo, "a.txt"))

        store.takeSide(.theirs)
        store.confirmDiscardDrafts(Self.question(["a.txt"]))
        await waitUntil("a.txt taken") { (try? Fixture.isUnmerged(repo, "a.txt")) == false }
        await waitUntilIdle(store)
        #expect(try Fixture.file(repo, "a.txt") == Data(Fixture.theirs.utf8))
        #expect(store.resolverDrafts["a.txt"] == nil)
    }

    /// Skip asks after its own sheet, about every draft with changes (the stop's files all go
    /// back), and Cancel skips nothing; Discard Changes skips, leaving no draft kept as "outside".
    /// Abort's question is its own sheet, which names the files with drafts (the line read from
    /// `changedDraftPaths`); its Cancel keeps them, and the abort drops them rather than keeping
    /// them as ended outside.
    @Test(.timeLimit(.minutes(10))) func skipAndAbortAsk() async throws {
        let pick = try Self.stoppedPick()
        defer { pick.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(pick, backend: backend)
        defer { cleanup() }
        #expect(store.operationInProgress == .cherryPick)
        let draft = try #require(await Self.changedDraft(store))

        func skipSheet() async throws -> String {
            store.requestSkip()
            await waitUntil("the Skip sheet") {
                if case .skip = store.activeSheet { true } else { store.operationInProgress == nil }
            }
            guard case .skip(_, let current, _) = store.activeSheet else { throw CancellationError() }
            return current.sha
        }
        store.confirmSkip(stoppedAt: try await skipSheet())
        try #require(Self.asked(store) == Self.question(["a.txt"]))
        store.cancelDiscardDrafts()
        await waitUntilIdle(store)
        #expect(!backend.calls.contains(.skip))
        #expect(store.operationInProgress == .cherryPick)
        #expect(store.resolverDrafts["a.txt"] == draft)

        store.confirmSkip(stoppedAt: try await skipSheet())
        store.confirmDiscardDrafts(Self.question(["a.txt"]))
        await waitUntil("the skip") { store.operationInProgress == nil }
        await waitUntilIdle(store)
        #expect(backend.calls.contains(.skip))
        #expect(store.resolverDrafts.isEmpty, "none kept as ended outside")
        #expect(store.notice?.text != ConflictWording.operationEndedOutside(.cherryPick))

        // Abort.
        let merge = try Fixture.stoppedMerge()
        defer { merge.remove() }
        let mergeBackend = TestBackend()
        let (other, otherCleanup) = await openedTestStore(merge, backend: mergeBackend)
        defer { otherCleanup() }
        let mergeDraft = try #require(await Self.changedDraft(other))
        other.requestAbort()
        #expect(other.activeSheet == .abort(.merge))
        #expect(other.changedDraftPaths == ["a.txt"])
        #expect(
            ConflictWording.abortDrafts(other.changedDraftPaths)
                == "Your changes to \"a.txt\" in Resolve Conflicts are discarded too.")
        other.activeSheet = nil
        await waitUntilIdle(other)
        #expect(!mergeBackend.calls.contains(.abort))
        #expect(other.operationInProgress == .merge)
        #expect(other.resolverDrafts["a.txt"] == mergeDraft)

        other.requestAbort()
        other.confirmAbort(.merge)
        await waitUntil("the abort") { other.operationInProgress == nil }
        await waitUntilIdle(other)
        #expect(other.resolverDrafts.isEmpty, "dropped, not kept as ended")
        #expect(other.resolverFocus == nil)
    }

    /// Take for N Files asks once, after its sheet, listing every file with a changed draft;
    /// Cancel takes nothing, Discard Changes takes every file.
    @Test(.timeLimit(.minutes(10))) func takeForFilesAsksOnceListingDrafts() async throws {
        let repo = try Fixture.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        _ = try #require(await Self.changedDraft(store, "a.txt"))
        _ = try #require(await Self.changedDraft(store, "b.txt"))
        let drafts = store.resolverDrafts

        func takeSheet() async throws -> TakeForFilesPlan {
            store.takeSideForFiles(["a.txt", "b.txt"], .ours)
            await waitUntil("the Take sheet") {
                if case .takeForFiles = store.activeSheet { true } else { store.resolverFiles.isEmpty }
            }
            guard case .takeForFiles(let plan) = store.activeSheet else { throw CancellationError() }
            return plan
        }
        store.confirmTakeForFiles(try await takeSheet())
        let both = Self.question(["a.txt", "b.txt"])
        try #require(Self.asked(store) == both)
        #expect(ConflictWording.draftQuestionTitle(both) == "Discard your changes to \"a.txt\" and \"b.txt\"?")
        #expect(ConflictWording.draftQuestionButton(both) == "Discard Changes")
        store.cancelDiscardDrafts()
        await waitUntilIdle(store)
        #expect(!backend.calls.contains(.take))
        #expect(store.resolverDrafts == drafts)
        #expect(try Fixture.isUnmerged(repo, "a.txt") && Fixture.isUnmerged(repo, "b.txt"))

        store.confirmTakeForFiles(try await takeSheet())
        store.confirmDiscardDrafts(both)
        await waitUntil("both taken") { store.resolverFiles.isEmpty }
        await waitUntilIdle(store)
        #expect(backend.calls.filter { $0 == .take }.count == 2)
        #expect(store.resolverDrafts.isEmpty)
        #expect(try !Fixture.isUnmerged(repo, "a.txt") && !Fixture.isUnmerged(repo, "b.txt"))
    }

    /// Opening another repository (a worktree) in this window asks about its drafts; Cancel keeps
    /// the repository and the drafts, Discard Changes opens it.
    @Test(.timeLimit(.minutes(10))) func openingAnotherRepositoryHereAsks() async throws {
        let repo = try Fixture.stoppedMerge()
        defer { repo.remove() }
        let other = try ScratchRepo("other")
        defer { other.remove() }
        try other.commit("a.txt", "one\n", "first")
        let test = TestRegistry()
        defer { test.remove() }
        let store = await test.opened(repo)
        let draft = try #require(await Self.changedDraft(store))

        #expect(test.registry.open(other.url, kind: .worktreeHere, front: store) == .useFront(store))
        try #require(Self.asked(store) == Self.question(["a.txt"]))
        store.cancelDiscardDrafts()
        #expect(store.root.map(RepositoryWindow.init(url:)) == RepositoryWindow(url: repo.url))
        #expect(store.resolverDrafts["a.txt"] == draft)

        test.registry.open(other.url, kind: .worktreeHere, front: store)
        store.confirmDiscardDrafts(Self.question(["a.txt"]))
        await waitUntil("the other repository") {
            store.root.map(RepositoryWindow.init(url:)) == RepositoryWindow(url: other.url)
        }
        #expect(store.resolverDrafts.isEmpty)
    }

    // MARK: - Done (Ruling 36)

    /// Done asks before it drops an edited read-only draft: one names its file (Discard
    /// Changes), several are counted (Discard and Close). Cancel keeps focus mode and the draft.
    @Test(.timeLimit(.minutes(10))) func doneAsksBeforeDroppingAnEditedReadOnlyDraft() async throws {
        let repo = try Fixture.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        _ = try #require(await Self.changedDraft(store, "a.txt"))
        _ = try #require(await Self.changedDraft(store, "b.txt"))
        try repo.git("add", "a.txt")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.resolverDrafts["a.txt"]?.detached == .resolvedOutside)
        let drafts = store.resolverDrafts

        store.requestCloseResolver()
        let one = Self.question(["a.txt"], .done)
        #expect(Self.asked(store) == one)
        #expect(ConflictWording.draftQuestionTitle(one) == "Discard your changes to \"a.txt\"?")
        #expect(ConflictWording.draftQuestionButton(one) == "Discard Changes")
        store.cancelDiscardDrafts()
        #expect(store.resolverFocus != nil)
        #expect(store.resolverDrafts == drafts)

        try repo.git("add", "b.txt")
        await store.refresh()
        await waitUntilIdle(store)
        store.requestCloseResolver()
        let two = Self.question(["a.txt", "b.txt"], .done)
        #expect(Self.asked(store) == two)
        #expect(
            ConflictWording.draftQuestionTitle(two)
                == "You have changes in 2 conflicted files that aren't saved. Close anyway?")
        #expect(ConflictWording.draftQuestionButton(two) == "Discard and Close")
        store.confirmDiscardDrafts(two)
        #expect(store.resolverFocus == nil)
        #expect(store.resolverDrafts.isEmpty)
    }

    /// A pristine read-only draft goes at Done without a question, and an edited draft changed
    /// outside is kept (Ruling 25), asking nothing either.
    @Test(.timeLimit(.minutes(10))) func doneDropsPristineReadOnlyDraftsSilently() async throws {
        let repo = try Fixture.stoppedMerge()
        defer { repo.remove() }
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        _ = try #require(await Fixture.openDraft(store, "a.txt"))
        _ = try #require(await Self.changedDraft(store, "b.txt"))
        try repo.git("add", "a.txt")
        try repo.write("b.txt", "changed in a terminal\n")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(store.resolverDrafts["a.txt"]?.detached == .resolvedOutside)
        #expect(store.resolverDrafts["b.txt"]?.detached == .changedOutside)

        store.requestCloseResolver()
        #expect(store.activeSheet == nil)
        #expect(store.resolverFocus == nil)
        #expect(store.resolverDrafts.keys.sorted() == ["b.txt"])
    }

    // MARK: - Closing

    /// A window's close asks about its own store's drafts only, counted; Cancel keeps the window
    /// and every draft, Discard and Close closes it. The other window is not asked or touched.
    @Test(.timeLimit(.minutes(10))) func closeAsksForThisWindowsDraftsOnly() async throws {
        let first = try Fixture.stoppedMerge()
        defer { first.remove() }
        let second = try Fixture.stoppedMerge()
        defer { second.remove() }
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let a = await test.opened(first)
        let b = await test.opened(second)
        _ = try #require(await Self.changedDraft(a, "a.txt"))
        _ = try #require(await Self.changedDraft(a, "b.txt"))
        _ = try #require(await Self.changedDraft(b, "a.txt"))
        let aDrafts = a.resolverDrafts
        let bDrafts = b.resolverDrafts
        let windowA = HiddenWindowTests.window()
        let windowB = HiddenWindowTests.window()
        test.registry.attach(windowA, to: a)
        test.registry.attach(windowB, to: b)

        #expect(windowA.delegate?.windowShouldClose?(windowA) == false)
        #expect(recorder.closeQuestions.map(\.count) == [2])
        #expect(recorder.closeQuestions.first?.window === windowA)
        let cancel = try #require(recorder.closeAnswer)
        cancel(false)
        #expect(!a.isClosed)
        #expect(a.resolverDrafts == aDrafts)

        #expect(windowA.delegate?.windowShouldClose?(windowA) == false)
        let discard = try #require(recorder.closeAnswer)
        discard(true)
        #expect(a.isClosed)
        #expect(a.resolverDrafts.isEmpty)
        #expect(recorder.closeQuestions.map(\.count) == [2, 2], "asked about A's window only")
        #expect(!b.isClosed)
        #expect(b.resolverDrafts == bDrafts)
        #expect(b.activeSheet == nil)
    }

    /// A window hidden while it works asks nothing as it hides; its final close, once the work has
    /// ended, asks app-modally. Cancel brings it back with its draft; Discard and Close, the next
    /// time, closes it for real.
    @Test(.timeLimit(.minutes(10))) func aHiddenWindowsFinalCloseAsks() async throws {
        let repo = try Fixture.stoppedMerge()
        defer { repo.remove() }
        let recorder = HiddenWindowRecorder()
        let test = TestRegistry(hiddenWindows: recorder.environment)
        defer { test.remove() }
        let (store, backend, window) = await HiddenWindowTests.attachedStore(repo, in: test)
        defer { await releaseAndSettle([backend], [store]) }
        let draft = try #require(await Self.changedDraft(store))

        /// A stage of a new untracked file, held, with the window closed under it: hidden.
        func hideWhileStaging(_ path: String) async throws -> StuckCall {
            try repo.write(path, "new\n")
            await store.refresh()
            await waitUntilIdle(store)
            let row = try #require(store.snapshot?.status.files.first { $0.path == path })
            let gate = backend.hold(.stage)
            store.stage(row)
            #expect(await waitUntil("the stage parked") { gate.waiting })
            #expect(window.delegate?.windowShouldClose?(window) == false)
            #expect(store.isHidden)
            return gate
        }

        let gate = try await hideWhileStaging("c.txt")
        #expect(recorder.closeQuestions.isEmpty, "a hide asks nothing")
        gate.release()
        await waitUntil("the final close's question") { !recorder.closeQuestions.isEmpty || !recorder.closed.isEmpty }
        try #require(recorder.closeQuestions.count == 1)
        #expect(recorder.closeQuestions.first?.window == nil, "app-modal: the window is out of sight")
        #expect(recorder.closeQuestions.first?.count == 1)
        #expect(recorder.closed.isEmpty)

        let cancel = try #require(recorder.closeAnswer)
        cancel(false)
        #expect(recorder.fronted == [window])
        #expect(!store.isHidden)
        #expect(!store.isClosed)
        #expect(store.resolverDrafts["a.txt"] == draft)

        let again = try await hideWhileStaging("d.txt")
        again.release()
        await waitUntil("the second question") { recorder.closeQuestions.count == 2 }
        let discard = try #require(recorder.closeAnswer)
        discard(true)
        #expect(recorder.closed == [window])
        await waitUntilGone(store, from: test.registry)
        #expect(store.isClosed)
        #expect(store.resolverDrafts.isEmpty)
    }

    /// The close question as built: its sentence, Cancel first with Return, then the destructive
    /// Discard and Close — or Discard and Quit for the quit.
    @Test func theCloseQuestionIsBuiltWithCancelAsTheDefault() {
        let alert = HiddenWindowEnvironment.makeCloseQuestion(3)
        #expect(alert.messageText == "You have changes in 3 conflicted files that aren't saved. Close anyway?")
        #expect(alert.buttons.map(\.title) == ["Cancel", "Discard and Close"])
        #expect(alert.buttons.first?.keyEquivalent == "\r")
        #expect(alert.buttons.last?.hasDestructiveAction == true)
        let quit = HiddenWindowEnvironment.makeCloseQuestion(1, discard: ConflictWording.discardAndQuit)
        #expect(quit.messageText == "You have changes in 1 conflicted file that isn't saved. Close anyway?")
        #expect(quit.buttons.map(\.title) == ["Cancel", "Discard and Quit"])
    }
}

// MARK: - Quitting

extension QuitFlowTests {

    /// Task 7: the quit asks about drafts with changes in every window, once, before the
    /// network-lane question, on the same held reply. The questions and the replies are recorded
    /// (`QuitGuard.environment`), so no alert is raised and no reply of true reaches the host.
    /// Nested in `QuitFlowTests` for its `.serialized`: "under way" is the app's one static state.
    @MainActor @Suite(.leavesTheRealDefaultsAlone) struct QuitDraftTests {

        @MainActor final class Questions {
            var titles: [String] = []
            var buttons: [[String]] = []
            var answers: [@MainActor (NSApplication.ModalResponse) -> Void] = []
            var replies: [Bool] = []

            var environment: QuitGuard.Environment {
                QuitGuard.Environment(
                    present: { alert, _, answer in
                        self.titles.append(alert.messageText)
                        self.buttons.append(alert.buttons.map(\.title))
                        self.answers.append(answer)
                    },
                    reply: { self.replies.append($0) })
            }
        }

        private func install() -> (Questions, restore: @MainActor () -> Void) {
            let questions = Questions()
            QuitGuard.environment = questions.environment
            return (
                questions,
                {
                    QuitGuard.environment = .live
                    QuitFlow.quitEnded()
                    AppModel.windows.endAppTermination()
                }
            )
        }

        /// Two windows' stores, three files with changes: one question with the sum; Cancel ends
        /// the quit (`quitEnded`, a reply of false) and nothing is discarded or written.
        @Test(.timeLimit(.minutes(10))) func quitAsksOnceForAllWindowsDrafts() async throws {
            let first = try ResolverStoreTests.stoppedMerge()
            defer { first.remove() }
            let second = try ResolverStoreTests.stoppedMerge()
            defer { second.remove() }
            let (a, aCleanup) = await openedTestStore(first)
            defer { aCleanup() }
            let (b, bCleanup) = await openedTestStore(second)
            defer { bCleanup() }
            _ = try #require(await ResolverDraftGuardTests.changedDraft(a, "a.txt"))
            _ = try #require(await ResolverDraftGuardTests.changedDraft(a, "b.txt"))
            _ = try #require(await ResolverDraftGuardTests.changedDraft(b, "a.txt"))
            let drafts = [a.resolverDrafts, b.resolverDrafts]
            let bytes = try ResolverStoreTests.file(first, "a.txt")
            let (questions, restore) = install()
            defer { restore() }

            QuitFlow.delegateWasAsked()
            #expect(QuitGuard.changedDraftCount([a, b]) == 3)
            #expect(QuitGuard.shouldTerminate([a, b]) == .terminateLater)
            #expect(questions.titles == ["You have changes in 3 conflicted files that aren't saved. Close anyway?"])
            #expect(questions.buttons == [["Cancel", "Discard and Quit"]])
            #expect(questions.replies.isEmpty, "held until the answer")
            #expect(QuitFlow.isUnderWay)

            let answer = try #require(questions.answers.first)
            answer(.alertFirstButtonReturn)
            #expect(questions.replies == [false])
            #expect(!QuitFlow.isUnderWay, "the quit ended")
            #expect(questions.titles.count == 1, "asked once")
            #expect([a.resolverDrafts, b.resolverDrafts] == drafts)
            #expect(try ResolverStoreTests.file(first, "a.txt") == bytes)
        }

        /// Discard and Quit drops every draft and goes on to the lane question about a write
        /// still running, on the same held reply; its Don't Quit then calls the quit off.
        @Test(.timeLimit(.minutes(10))) func quitDiscardsThenContinuesToTheLaneQuestion() async throws {
            let conflicted = try ResolverStoreTests.stoppedMerge()
            defer { conflicted.remove() }
            let pushing = try ScratchRepo("pushing")
            defer { pushing.remove() }
            _ = try HeldTransport.remoteOneCommitBehind(pushing)
            let (a, aCleanup) = await openedTestStore(conflicted)
            defer { aCleanup() }
            let backend = TestBackend()
            let (b, bCleanup) = await openedTestStore(pushing, backend: backend)
            defer { bCleanup() }
            defer { await releaseAndSettle([backend], [b]) }
            _ = try #require(await ResolverDraftGuardTests.changedDraft(a))
            let gate = backend.hold(.push)
            b.push()
            #expect(await waitUntil("the push parked") { gate.waiting })
            let push = try #require(b.remoteActivity)
            let (questions, restore) = install()
            defer { restore() }

            QuitFlow.delegateWasAsked()
            #expect(QuitGuard.shouldTerminate([a, b]) == .terminateLater)
            // Never answer the lane question here by mistake: its Stop and Quit replies later.
            try #require(questions.titles == [ConflictWording.closeQuestion(1)])

            let answer = try #require(questions.answers.first)
            answer(.alertSecondButtonReturn)
            #expect(a.resolverDrafts.isEmpty)
            #expect(questions.titles == [ConflictWording.closeQuestion(1), RemoteWording.quitDuringWriteTitle(push)])
            #expect(questions.replies.isEmpty, "still held, for the lane question")

            let laneAnswer = try #require(questions.answers.dropFirst().first)
            laneAnswer(.alertThirdButtonReturn)
            #expect(questions.replies == [false])
            #expect(!QuitFlow.isUnderWay)
        }

        /// With every lane free, Discard and Quit quits: a reply of true, on the held path.
        @Test(.timeLimit(.minutes(10))) func quitDiscardsThenQuitsWhenTheLanesAreFree() async throws {
            let repo = try ResolverStoreTests.stoppedMerge()
            defer { repo.remove() }
            let (store, cleanup) = await openedTestStore(repo)
            defer { cleanup() }
            _ = try #require(await ResolverDraftGuardTests.changedDraft(store))
            let (questions, restore) = install()
            defer { restore() }

            QuitFlow.delegateWasAsked()
            #expect(QuitGuard.shouldTerminate([store]) == .terminateLater)
            try #require(questions.titles == [ConflictWording.closeQuestion(1)])
            let answer = try #require(questions.answers.first)
            answer(.alertSecondButtonReturn)
            #expect(questions.replies == [true])
            #expect(store.resolverDrafts.isEmpty)
            #expect(AppModel.windows.isTerminating)
        }

        /// No draft with changes, no question: the lanes decide as before.
        @Test func withNoChangedDraftTheQuitAsksNothing() {
            let (questions, restore) = install()
            defer { restore() }
            QuitFlow.delegateWasAsked()
            #expect(QuitGuard.shouldTerminate([]) == .terminateNow)
            #expect(questions.titles.isEmpty)
        }
    }
}
