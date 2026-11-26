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
}
