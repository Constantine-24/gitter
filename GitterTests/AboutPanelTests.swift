import Foundation
import Testing

@testable import Gitter

/// P1 Task 2: what Gitter › About Gitter shows — "Version 0.1.0 (412, d410591)" for a packaged
/// build, and the version and build only for a build without a commit (a plain Xcode build).
@Suite struct AboutPanelTests {

    @Test func aPackagedBuildShowsItsBuildAndCommit() {
        let versions = AboutPanel.versions(info: [
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "412", "GitterCommit": "d410591",
        ])
        #expect(versions == ("0.1.0", "412, d410591"))
    }

    @Test func withoutACommitOnlyTheBuildIsShown() {
        let missing = AboutPanel.versions(info: ["CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "412"])
        #expect(missing == ("0.1.0", "412"))
        let empty = AboutPanel.versions(info: [
            "CFBundleShortVersionString": "0.1.0", "CFBundleVersion": "412", "GitterCommit": "",
        ])
        #expect(empty == ("0.1.0", "412"))
    }

    /// S1 Task 5: the About panel credits Tree-sitter and points at the licence file.
    @Test func creditsNameTreeSitter() {
        #expect(AboutPanel.credits.string == "Syntax colours by Tree-sitter. Licences: Acknowledgements.txt in Gitter's Resources.")
    }

    /// The licence notices ship in the app's Resources, and hold the notices the credits promise.
    @Test func acknowledgementsShipInTheAppResources() throws {
        let url = try #require(Bundle.main.url(forResource: "Acknowledgements", withExtension: "txt"))
        let text = try String(contentsOf: url, encoding: .utf8)
        #expect(text.contains("swift-tree-sitter"))
        #expect(text.contains("nvim-treesitter"))
        #expect(text.contains("Apache License"))
    }
}
