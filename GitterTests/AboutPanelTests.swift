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
}
