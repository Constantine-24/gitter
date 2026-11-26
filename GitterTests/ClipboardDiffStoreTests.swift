import AppKit
import Foundation
import GitCore
import Testing

@testable import Gitter

@MainActor @Suite(.leavesTheRealDefaultsAlone) struct ClipboardDiffStoreTests {
    private static let original = "first\nbefore\nlast\n"
    private static let changed = "first\nafter\nlast\n"
    private static let patch =
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
        try repo.commit("a.txt", Self.original, "first")
        try repo.commit("other.txt", "base\n", "keep independent staged edits")
        try repo.write("other.txt", "staged\n")
        try repo.git("add", "--", "other.txt")
        let cached = try repo.git("diff", "--cached")
        let head = try repo.git("rev-parse", "HEAD")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        defer { await releaseAndSettle([backend], [store]) }

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

        guard case .clipboardPatch(let plan, let destination) = store.activeSheet else {
            Issue.record("The patch preview never opened")
            return
        }
        #expect(destination == store.root)
        #expect(destination.lastPathComponent == "destination")
        #expect(plan.headLabel == "main")
        #expect(plan.text == Self.patch)
        #expect(plan.files.map(\.path) == ["a.txt"])
        #expect(plan.files.map(\.kind) == [.modified])
        #expect(plan.files.map(\.additions) == [1])
        #expect(plan.files.map(\.deletions) == [1])
        #expect(!backend.calls.contains(.applyClipboardPatch))
        #expect(try Self.file(repo) == Self.original)

        store.confirmClipboardPatch(plan)
        await waitUntilIdle(store)
        #expect(store.activeSheet == nil)
        #expect(backend.calls.filter { $0 == .applyClipboardPatch }.count == 1)
        #expect(try Self.file(repo) == Self.changed)
        #expect(try repo.git("diff", "--cached") == cached)
        #expect(try repo.git("rev-parse", "HEAD") == head)
        #expect(store.unstagedFiles.contains { $0.path == "a.txt" })
        #expect(store.notice?.text == ClipboardPatchWording.applied)
    }

    @Test(.timeLimit(.minutes(10))) func cancelAndReopeningTheWindowCannotApplyThePreview() async throws {
        let repo = try ScratchRepo("first")
        defer { repo.remove() }
        let next = try ScratchRepo("second")
        defer { next.remove() }
        try repo.commit("a.txt", Self.original, "first")
        try next.commit("a.txt", Self.original, "first")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.cancel-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try #require(pasteboard.setString(Self.patch, forType: .string))
        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        guard case .clipboardPatch(let cancelled, _) = store.activeSheet else {
            Issue.record("The patch preview never opened")
            return
        }
        #expect(RepositoryCommands.isOff(store, \.pasteDiffBlockedReason))
        store.activeSheet = nil
        store.confirmClipboardPatch(cancelled)
        #expect(!backend.calls.contains(.applyClipboardPatch))
        #expect(try Self.file(repo) == Self.original)

        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        guard case .clipboardPatch(let previous, _) = store.activeSheet else {
            Issue.record("The new patch preview never opened")
            return
        }
        await open(store, next.url)
        #expect(store.activeSheet == nil)
        store.confirmClipboardPatch(previous)
        #expect(!backend.calls.contains(.applyClipboardPatch))
        #expect(try Self.file(repo) == Self.original)
        #expect(try Self.file(next) == Self.original)
    }

    @Test(.timeLimit(.minutes(10))) func destinationMovingAfterPreviewLeavesTheFilesAlone() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", Self.original, "first")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }

        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.moved-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        pasteboard.clearContents()
        try #require(pasteboard.setString(Self.patch, forType: .string))
        store.requestPasteDiff(from: pasteboard)
        await waitUntilIdle(store)
        guard case .clipboardPatch(let plan, _) = store.activeSheet else {
            Issue.record("The patch preview never opened")
            return
        }
        try repo.git("switch", "-c", "different")
        store.confirmClipboardPatch(plan)
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
        try repo.commit("a.txt", Self.original, "first")
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
        try repo.commit("a.txt", Self.original, "first")
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
        try #require(pasteboard.setString(Self.patch, forType: .string))

        #expect(RepositoryCommands.isOff(nil, \.pasteDiffBlockedReason))
        #expect(store.hasUnmergedFiles)
        #expect(RepositoryCommands.isOff(store, \.pasteDiffBlockedReason))
        store.requestPasteDiff(from: pasteboard)
        #expect(!backend.calls.contains(.planClipboardPatch))

        _ = try #require(await ResolverStoreTests.openDraft(store))
        #expect(store.pasteDiffBlockedReason == ClipboardPatchWording.resolverOpen)
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
        #expect(!backend.calls.contains(.planClipboardPatch))
    }

    private static func file(_ repo: ScratchRepo) throws -> String {
        try String(contentsOf: repo.url.appending(path: "a.txt"), encoding: .utf8)
    }
}
