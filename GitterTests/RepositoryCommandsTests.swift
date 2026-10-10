import Foundation
import Testing

@testable import Gitter

/// The menus' off-state decisions (`RepositoryCommands`), on the front window's store (E2 spec §2,
/// Menus): with no window, every repository item is off; and **while the front window's sheet is
/// up, every item is off** — Refresh (⌘R) included (Ruling 17), as the Repository items are.
@MainActor @Suite(.leavesTheRealDefaultsAlone) struct RepositoryCommandsTests {

    @Test(.timeLimit(.minutes(10))) func refreshIsOffWithNoRepositoryAndWhileTheSheetIsUp() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let test = TestRegistry()
        defer { test.remove() }
        let empty = test.registry.makeStore()
        let showing = await test.opened(repo)

        #expect(RepositoryCommands.refreshIsOff(nil))
        #expect(RepositoryCommands.refreshIsOff(empty))
        // The control: a repository and no sheet — Refresh is on.
        #expect(!RepositoryCommands.refreshIsOff(showing))

        showing.activeSheet = .rename("main")
        #expect(showing.activeSheet != nil)
        #expect(RepositoryCommands.refreshIsOff(showing))

        showing.activeSheet = nil
        #expect(!RepositoryCommands.refreshIsOff(showing))
    }

    /// The Repository menu's rule, which Refresh now follows: off with no window, off while the
    /// sheet is up even when the item's own reason is nil, and off for that reason.
    @Test(.timeLimit(.minutes(10))) func aRepositoryItemIsOffWithNoWindowUnderASheetOrForItsReason() async throws {
        let repo = try ScratchRepo()
        defer { repo.remove() }
        try repo.commit("a.txt", "one\n", "first")
        let test = TestRegistry()
        defer { test.remove() }
        let showing = await test.opened(repo)
        let noReason: (RepositoryStore) -> String? = { _ in nil }

        #expect(RepositoryCommands.isOff(nil, noReason))
        #expect(!RepositoryCommands.isOff(showing, noReason))
        #expect(RepositoryCommands.isOff(showing) { _ in "busy" })

        showing.activeSheet = .rename("main")
        #expect(RepositoryCommands.isOff(showing, noReason))
    }
}
