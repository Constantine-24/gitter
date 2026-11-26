import AppKit
import Foundation
import GitCore
import Testing

@testable import Gitter

@MainActor @Suite(.leavesTheRealDefaultsAlone) struct ClipboardCopyViewsTests {
    @Test(.timeLimit(.minutes(10))) func historicalViewsCopyTheirOwnForwardPatches() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "before\n", "base")
        try repo.git("branch", "baseline")
        try repo.commit("a.txt", "committed\n", "tip")
        let tip = try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .newlines)
        try repo.write("a.txt", "stashed\n")
        try repo.git("stash", "push", "--message", "clipboard source")
        let stash = try repo.git("rev-parse", "stash@{0}").trimmingCharacters(in: .newlines)
        try repo.write("a.txt", "working copy only\n")

        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.copy-views-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        for (selection, change) in [
            (Selection.commit(tip), "committed"),
            (.stash(stash), "stashed"),
            (.comparisonChanges, "committed"),
        ] {
            if selection == .comparisonChanges {
                store.compare("refs/heads/baseline", "refs/heads/main")
            } else {
                store.select(selection)
            }
            try #require(await waitUntil("the historical selection") { store.selection == selection })
            store.selectPath("a.txt")
            try #require(await waitUntil("the displayed historical patch") { !store.diff.isEmpty })
            let file = try #require(store.diff.first)
            let hunk = try #require(file.hunks.first)
            #expect(!store.canPartiallyStage(file))
            for hunkID in [nil, hunk.id] {
                pasteboard.clearContents()
                store.copyDiff(file, hunkID: hunkID, to: pasteboard)
                let text = try #require(pasteboard.string(forType: .string))
                #expect(text.contains("+\(change)\n"))
                #expect(!text.contains("+working copy only\n"))
            }
        }
    }

    @Test(.timeLimit(.minutes(10))) func copyAllChangesUsesTheSelectedHistoricalDiff() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "before\n", "base")
        try repo.git("branch", "baseline")
        try repo.write("a.txt", "committed\n")
        try repo.write("second.txt", "another committed file\n")
        try repo.git("add", "--", "a.txt", "second.txt")
        try repo.git("commit", "-qm", "tip")
        let tip = try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .newlines)
        try repo.write("a.txt", "stashed\n")
        try repo.write("untracked.txt", "another stashed file\n")
        try repo.git("stash", "push", "--include-untracked", "--message", "clipboard source")
        let stash = try repo.git("rev-parse", "stash@{0}").trimmingCharacters(in: .newlines)
        try repo.write("a.txt", "working copy only\n")

        let (store, cleanup) = await openedTestStore(repo)
        defer { cleanup() }
        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.copy-all-views-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }

        for (selection, change, extra) in [
            (Selection.commit(tip), "committed", "second.txt"),
            (.stash(stash), "stashed", "untracked.txt"),
            (.comparisonChanges, "committed", "second.txt"),
        ] {
            if selection == .comparisonChanges {
                store.compare("refs/heads/baseline", "refs/heads/main")
                try #require(await waitUntil("the branch comparison") { store.selection == .comparisonChanges })
            } else {
                store.select(selection)
            }
            #expect(store.canCopyAllChanges)
            store.requestCopyAllChanges(to: pasteboard)
            let export = try #require(store.copyAllChangesTask)
            await export.value
            let text = try #require(pasteboard.string(forType: .string))
            #expect(text.contains("+\(change)\n"))
            #expect(text.contains("diff --git a/\(extra) b/\(extra)\n"))
            #expect(!text.contains("+working copy only\n"))
        }
    }

    @Test(.timeLimit(.minutes(10))) func refreshingAComparisonInvalidatesItsPendingCopy() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "base\n", "base")
        try repo.git("branch", "baseline")
        try repo.commit("a.txt", "previous tip\n", "first tip")
        let backend = TestBackend()
        let (store, cleanup) = await openedTestStore(repo, backend: backend)
        defer { cleanup() }
        let pasteboard = NSPasteboard(name: .init("dev.penzin.Gitter.tests.copy-comparison-refresh-\(UUID().uuidString)"))
        defer { pasteboard.releaseGlobally() }
        defer {
            backend.releaseAll()
            await store.copyAllChangesTask?.value
        }
        try #require(Clipboard.copy("clipboard before comparison refresh", to: pasteboard))
        let changeCount = pasteboard.changeCount

        store.compare("refs/heads/baseline", "refs/heads/main")
        try #require(await waitUntil("initial comparison") { store.selection == .comparisonChanges })
        let readingOldTip = backend.hold(.copyAllChanges)
        store.requestCopyAllChanges(to: pasteboard)
        let oldCopy = try #require(store.copyAllChangesTask)
        try #require(await waitUntil("the copy of the old comparison") { readingOldTip.waiting })
        try repo.commit("a.txt", "new tip\n", "second tip")
        let newTip = try repo.git("rev-parse", "HEAD").trimmingCharacters(in: .newlines)
        store.refreshComparison()
        try #require(await waitUntil("refreshed comparison") { store.comparison?.b.id == newTip })
        #expect(store.selection == .comparisonChanges)
        readingOldTip.release()
        await oldCopy.value
        #expect(pasteboard.changeCount == changeCount)

        store.requestCopyAllChanges(to: pasteboard)
        let freshCopy = try #require(store.copyAllChangesTask)
        await freshCopy.value
        let patch = try #require(pasteboard.string(forType: .string))
        #expect(patch.contains("+new tip\n"))
        #expect(!patch.contains("+previous tip\n"))
    }
}
