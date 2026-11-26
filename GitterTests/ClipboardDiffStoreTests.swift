import AppKit
import Foundation
import GitCore
import Testing

@testable import Gitter

@MainActor @Suite(.leavesTheRealDefaultsAlone) struct ClipboardDiffStoreTests {
    fileprivate static let original = "first\nbefore\nlast\n"
    private static let changed = "first\nafter\nlast\n"
    fileprivate static let patch =
        """
        diff --git a/a.txt b/a.txt
        --- a/a.txt
        +++ b/a.txt
        @@ -1,3 +1,3 @@
         first
        -before
        +after
         last

        """

    @Test(.timeLimit(.minutes(10))) func previewUsesTheTextOnTheClipboardWhenInvoked() async throws {
        let repo = try ScratchRepo("destination")
        defer { repo.remove() }
        try Self.commitOriginal(to: repo)
        try repo.commit("other.txt", "base\n", "keep independent staged edits")
        try repo.write("other.txt", "staged\n")
        try repo.git("add", "--", "other.txt")
        let cached = try repo.git("diff", "--cached")
        let head = try repo.git("rev-parse", "HEAD")
        let backend = TestBackend()
        let events = RecordingEventLog()
        let (store, _, cleanup) = makeTestStore(backend: backend, eventLog: events.eventLog)
        defer { cleanup() }
        defer { await releaseAndSettle([backend], [store]) }
        await open(store, repo.url)

        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.paste-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try #require(pasteboard.setString(Self.patch, forType: .string))
        let planning = backend.hold(.planClipboardPatch)
        store.requestPasteDiff(from: pasteboard)
        #expect(RepositoryCommands.isOff(store, \.pasteDiffBlockedReason))
        #expect(await waitUntil("patch planning") { planning.waiting })
        pasteboard.clearContents()
        try #require(pasteboard.setString("other clipboard content", forType: .string))
        planning.release()
        await waitUntilIdle(store)

        guard case .clipboardPatch(let preview) = store.activeSheet else {
            Issue.record("The patch preview never opened")
            return
        }
        #expect(preview.destination == store.root)
        #expect(preview.destination.lastPathComponent == "destination")
        let plan = preview.plan
        #expect(plan.headLabel == "main")
        #expect(plan.text == Self.patch)
        #expect(plan.files.map(\.path) == ["a.txt"])
        #expect(plan.files.map(\.kind) == [.modified])
        #expect(plan.files.map(\.additions) == [1])
        #expect(plan.files.map(\.deletions) == [1])
        #expect(!backend.calls.contains(.applyClipboardPatch))
        #expect(try Self.file(repo) == Self.original)

        store.confirmClipboardPatch(preview.id)
        await waitUntilIdle(store)
        #expect(store.activeSheet == nil)
        #expect(backend.calls.filter { $0 == .applyClipboardPatch }.count == 1)
        #expect(try Self.file(repo) == Self.changed)
        #expect(try repo.git("diff", "--cached") == cached)
        #expect(try repo.git("rev-parse", "HEAD") == head)
        #expect(store.unstagedFiles.contains { $0.path == "a.txt" })
        #expect(events.lines.contains { $0.hasPrefix("notice ") && $0.hasSuffix(": \(ClipboardPatchWording.applied)") })
    }

    @Test(.timeLimit(.minutes(10))) func cancelAndReopeningTheWindowCannotApplyThePreview() async throws {
        let repo = try ScratchRepo("first")
        defer { repo.remove() }
        let next = try ScratchRepo("second")
        defer { next.remove() }
        try Self.commitOriginal(to: repo)
        try Self.commitOriginal(to: next)
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.cancel-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try #require(pasteboard.setString(Self.patch, forType: .string))
        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        guard case .clipboardPatch(let cancelled) = store.activeSheet else {
            Issue.record("The patch preview never opened")
            return
        }
        #expect(RepositoryCommands.isOff(store, \.pasteDiffBlockedReason))
        store.cancelClipboardPatch(cancelled.id)
        store.confirmClipboardPatch(cancelled.id)
        #expect(!backend.calls.contains(.applyClipboardPatch))
        #expect(try Self.file(repo) == Self.original)

        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        guard case .clipboardPatch(let previous) = store.activeSheet else {
            Issue.record("The new patch preview never opened")
            return
        }
        await open(store, next.url)
        #expect(store.activeSheet == nil)
        store.confirmClipboardPatch(previous.id)
        #expect(!backend.calls.contains(.applyClipboardPatch))
        #expect(try Self.file(repo) == Self.original)
        #expect(try Self.file(next) == Self.original)
    }

    @Test(.timeLimit(.minutes(10))) func aCancelledCallbackCannotAuthorizeAnotherPreview() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.commitOriginal(to: repo)
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        let composed = Self.patch.replacingOccurrences(of: "+after", with: "+caf\u{e9}")
        let decomposed = Self.patch.replacingOccurrences(of: "+after", with: "+cafe\u{301}")
        #expect(composed == decomposed)
        #expect(Data(composed.utf8) != Data(decomposed.utf8))
        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.presentation-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try #require(Clipboard.copy(composed, to: pasteboard))
        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        guard case .clipboardPatch(let old) = store.activeSheet else {
            Issue.record("The first patch preview never opened")
            return
        }
        store.cancelClipboardPatch(old.id)

        try #require(Clipboard.copy(decomposed, to: pasteboard))
        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        guard case .clipboardPatch(let current) = store.activeSheet else {
            Issue.record("The second patch preview never opened")
            return
        }
        #expect(Data(current.plan.text.utf8) == Data(decomposed.utf8))
        #expect(current.id != old.id)
        store.confirmClipboardPatch(old.id)
        await waitUntilIdle(store)
        #expect(store.activeSheet == .clipboardPatch(current))
        #expect(!backend.calls.contains(.applyClipboardPatch))
        #expect(try Self.file(repo) == Self.original)

        store.confirmClipboardPatch(current.id)
        await waitUntilIdle(store)
        #expect(backend.calls.filter { $0 == .applyClipboardPatch }.count == 1)
        let file = try Data(contentsOf: repo.url.appending(path: "a.txt"))
        #expect(file == Data("first\ncafe\u{301}\nlast\n".utf8))
    }

    @Test(.timeLimit(.minutes(10))) func aCompetingSheetCanKeepItsPlaceWhileAPatchIsRead() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.commitOriginal(to: repo)
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        defer { await releaseAndSettle([backend], [store]) }

        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.competing-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try #require(Clipboard.copy(Self.patch, to: pasteboard))
        let planning = backend.hold(.planClipboardPatch)
        store.requestPasteDiff(from: pasteboard)
        #expect(await waitUntil("patch planning") { planning.waiting })
        store.activeSheet = .rename("main")
        planning.release()
        await waitUntilIdle(store)

        #expect(store.activeSheet == .rename("main"))
        #expect(store.lastError == "Close the open sheet and choose Paste Diff… again.")
        #expect(!backend.calls.contains(.applyClipboardPatch))
        #expect(try Self.file(repo) == Self.original)
    }

    @Test func destinationNamesShowEscapedControlsAndHiddenScalars() {
        #expect(
            ClipboardPatchWording.displayName("prefix\n.\u{301}name\u{202e}\\\u{200b}")
                == "prefix\\n.\\u{301}name\\u{202E}\\\\\\u{200B}")
        #expect(ClipboardPatchWording.displayName("cafe\u{301}") == "cafe\\u{301}")
    }

    @Test(.timeLimit(.minutes(10))) func destinationMovingAfterPreviewLeavesTheFilesAlone() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.commitOriginal(to: repo)
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.moved-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try #require(pasteboard.setString(Self.patch, forType: .string))
        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        guard case .clipboardPatch(let preview) = store.activeSheet else {
            Issue.record("The patch preview never opened")
            return
        }
        try repo.git("switch", "-c", "different")
        store.confirmClipboardPatch(preview.id)
        await waitUntilIdle(store)
        #expect(backend.calls.contains(.applyClipboardPatch))
        #expect(try Self.file(repo) == Self.original)
        #expect(try repo.git("status", "--porcelain").isEmpty)
        #expect(store.lastError == ClipboardPatchWording.destinationChanged)
        #expect(store.notice == nil)
    }

    @Test(.timeLimit(.minutes(10))) func missingAndInvalidClipboardTextUseTheErrorBanner() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.commitOriginal(to: repo)
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.invalid-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        store.requestPasteDiff(from: pasteboard)
        #expect(store.lastError == ClipboardPatchWording.noText)
        #expect(!backend.calls.contains(.planClipboardPatch))
        #expect(store.activeSheet == nil)
        try #require(pasteboard.setString("ordinary text", forType: .string))

        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        #expect(backend.calls.contains(.planClipboardPatch))
        #expect(store.activeSheet == nil)
        #expect(store.lastError == ClipboardPatchWording.invalid)
        #expect(try Self.file(repo) == Self.original)
    }

    @Test(.timeLimit(.minutes(10))) func copyUsesTheDisplayedStagedDiffAndCanLimitItToOneHunk() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        let middle = (1...18).map { "context \($0)\n" }.joined()
        try repo.commit("a.txt", "old-first\n\(middle)old-last\n", "first")
        try repo.write("a.txt", "staged-first\n\(middle)staged-last\n")
        try repo.git("add", "--", "a.txt")
        try repo.write("a.txt", "worktree-first\n\(middle)worktree-last\n")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }

        store.select("a.txt", staged: true)
        await waitUntil("the displayed staged diff") { store.diffIsStaged && !store.diff.isEmpty }
        let diff = try #require(store.diff.first)
        let first = try #require(diff.hunks.first)
        #expect(diff.hunks.count == 2)
        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.copy-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        store.copyDiff(diff, to: pasteboard)
        let whole = try #require(pasteboard.string(forType: .string))
        #expect(whole.contains("+staged-first\n") && whole.contains("+staged-last\n"))
        #expect(!whole.contains("worktree-first"))
        #expect(pasteboard.availableType(from: [.rtf, .html]) == nil)
        #expect(store.notice?.text == ClipboardPatchWording.copiedDiff)

        store.copyDiff(diff, hunkID: first.id, to: pasteboard)
        let onlyFirst = try #require(pasteboard.string(forType: .string))
        #expect(onlyFirst.contains("+staged-first\n"))
        #expect(!onlyFirst.contains("staged-last"))
        #expect(store.notice?.text == ClipboardPatchWording.copiedHunk)
    }

    @Test(.timeLimit(.minutes(10))) func aStagedRenameCannotBeCopiedAsAnAddition() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try Self.commitOriginal(to: repo)
        try repo.git("mv", "a.txt", "renamed.txt")
        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        #expect(store.stagedFiles.contains { $0.path == "renamed.txt" && $0.staged == .renamed })

        store.select("renamed.txt", staged: true)
        await waitUntil("the displayed rename") { store.diff.first?.displayPath == "renamed.txt" }
        let diff = try #require(store.diff.first)
        #expect(diff.kind == .added)
        #expect(!store.canCopyDiff(diff))
        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.rename-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try #require(pasteboard.setString("previous clipboard content", forType: .string))

        store.copyDiff(diff, to: pasteboard)
        #expect(pasteboard.string(forType: .string) == "previous clipboard content")
    }

    @Test(.timeLimit(.minutes(10))) func commandIsOffDuringAnOperationEvenAfterStagingTheResolution() async throws {
        let repo = try ResolverStoreTests.stoppedMerge()
        defer { repo.remove() }
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.conflicted-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        let independentPatch =
            """
            diff --git a/independent.txt b/independent.txt
            new file mode 100644
            --- /dev/null
            +++ b/independent.txt
            @@ -0,0 +1 @@
            +independent change

            """
        try #require(pasteboard.setString(independentPatch, forType: .string))

        #expect(RepositoryCommands.isOff(nil, \.pasteDiffBlockedReason))
        #expect(store.hasUnmergedFiles)
        #expect(RepositoryCommands.isOff(store, \.pasteDiffBlockedReason))
        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        #expect(!backend.calls.contains(.planClipboardPatch))

        _ = try #require(await ResolverStoreTests.openDraft(store))
        #expect(store.pasteDiffBlockedReason == ClipboardPatchWording.resolverOpen)
        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        #expect(!backend.calls.contains(.planClipboardPatch))
        store.closeResolver()

        for path in store.unmergedPaths {
            try repo.write(path, "resolved\n")
            try repo.git("add", "--", path)
        }
        await store.refresh()
        await waitUntilIdle(store)
        #expect(!store.hasUnmergedFiles)
        #expect(store.operationInProgress != nil)
        #expect(RepositoryCommands.isOff(store, \.pasteDiffBlockedReason))
        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        #expect(!backend.calls.contains(.planClipboardPatch))

        try repo.git("merge", "--abort")
        await store.refresh()
        await waitUntilIdle(store)
        #expect(!RepositoryCommands.isOff(store, \.pasteDiffBlockedReason))
        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        guard case .clipboardPatch(let preview) = store.activeSheet else {
            Issue.record("The independent patch should preview as soon as the merge ends")
            return
        }
        #expect(preview.plan.files.map(\.path) == ["independent.txt"])
        #expect(backend.calls.filter { $0 == .planClipboardPatch }.count == 1)
    }

    fileprivate static func commitOriginal(to repo: ScratchRepo) throws {
        try Data(original.utf8).write(to: repo.url.appending(path: "a.txt"))
        try repo.git("add", "--", "a.txt")
        try repo.git("commit", "-qm", "first")
    }

    fileprivate static func file(_ repo: ScratchRepo) throws -> String {
        try String(contentsOf: repo.url.appending(path: "a.txt"), encoding: .utf8)
    }
}

/// Uses QuitFlowTests' serialization for the injected process-wide quit state.
extension QuitFlowTests {
    @Test(.timeLimit(.minutes(10))) func applyingPatchKeepsItsWindowAndRefusesQuitUntilTheOutcomeArrives() async throws {
        let repo = try ScratchRepo("patch-destination")
        defer { repo.remove() }
        let next = try ScratchRepo("another-repository")
        defer { next.remove() }
        try ClipboardDiffStoreTests.commitOriginal(to: repo)
        try ClipboardDiffStoreTests.commitOriginal(to: next)
        let registry = TestRegistry()
        defer { registry.remove() }
        let backend = TestBackend()
        let store = registry.registry.makeStore(backend: backend)
        await open(store, repo.url)
        defer { await releaseAndSettle([backend], [store]) }

        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.pending-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        try #require(Clipboard.copy(ClipboardDiffStoreTests.patch, to: pasteboard))
        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        guard case .clipboardPatch(let preview) = store.activeSheet else {
            Issue.record("The patch preview never opened")
            return
        }

        let applying = backend.hold(.applyClipboardPatch)
        store.confirmClipboardPatch(preview.id)
        #expect(await waitUntil("the clipboard apply to park") { applying.waiting })
        #expect(store.isApplyingClipboardPatch)
        let destination = store.root

        #expect(registry.registry.open(next.url, kind: .worktreeHere, front: store) == .useFront(store))
        #expect(store.root == destination)
        #expect(store.lastError == "Wait for the clipboard patch to finish applying before replacing this repository.")

        var openedWindow: RepositoryWindow?
        registry.registry.openWindow = { openedWindow = $0 }
        _ = registry.registry.takePendingOpen()
        let wanted = RepositoryWindow(url: next.url)
        #expect(registry.registry.open(next.url, kind: .worktreeNewWindow, front: store) == .newWindow(wanted))
        #expect(openedWindow == wanted)
        #expect(store.root == destination)

        do {
            let previous = QuitGuard.environment
            var messages: [String] = []
            var replies: [Bool] = []
            QuitGuard.environment = .init(
                present: { alert, _, _ in messages.append(alert.informativeText) },
                reply: { replies.append($0) })
            defer {
                QuitGuard.environment = previous
                QuitGuard.calledOff(reply: { _ in })
            }
            #expect(QuitGuard.shouldTerminate([store]) == .terminateCancel)
            #expect(messages == ["Wait for the clipboard patch to finish applying before quitting Gitter."])
            #expect(replies.isEmpty)

            // A quit from the menu is refused before closing any other question.
            let (other, _, cleanOther) = makeTestStore()
            defer { cleanOther() }
            other.activeSheet = .rename("main")
            let flow = QuitFlowTests.Recorder()
            flow.stores = [store, other]
            let outcome = await QuitFlow.run(.menu, environment: flow.environment(poll: .milliseconds(5), bound: .seconds(1)))
            #expect(outcome == .applyingClipboardPatch)
            #expect(other.activeSheet == .rename("main"))
            #expect(flow.terminates == 0)
            #expect(messages.count == 2)
        }

        let refreshing = backend.hold(.snapshot)
        try Data("external edit\n".utf8).write(to: repo.url.appending(path: "a.txt"), options: .atomic)
        applying.release()
        #expect(await waitUntil("the apply refresh to park") { refreshing.waiting })
        #expect(store.isApplyingClipboardPatch)
        store.open(next.url)
        #expect(store.root == destination)
        refreshing.release()
        await waitUntilIdle(store)
        #expect(store.root == destination)
        #expect(!store.isApplyingClipboardPatch)
        #expect(store.lastError ==
            "The destination path “a.txt” is missing, changed, or already occupied. "
                + "Choose Paste Diff… to check it again.")
        #expect(store.notice == nil)
        #expect(try ClipboardDiffStoreTests.file(repo) == "external edit\n")
        #expect(try ClipboardDiffStoreTests.file(next) == ClipboardDiffStoreTests.original)

        await open(store, next.url)
        #expect(store.root == next.url.standardizedFileURL)
    }
}
