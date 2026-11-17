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
        // The ICU code the tree-sitter core compiles (lib/src/unicode/utf8.h, utf16.h) and its
        // licence, as tree-sitter distributes it: the Unicode notice and the older IBM one.
        #expect(text.contains("ICU (Unicode, Inc.): portions of the tree-sitter core"))
        #expect(text.contains("utf8.h and utf16.h"))
        #expect(text.contains("COPYRIGHT AND PERMISSION NOTICE (ICU 58 and later)"))
        #expect(text.contains("Copyright © 1991-2019 Unicode, Inc. All rights reserved."))
        #expect(text.contains("Copyright (c) 1995-2016 International Business Machines Corporation and others"))
        // One section per package compiled in, each headed by its name, then the Kotlin queries'
        // notice: a section heading sits alone between two rules of `=`.
        let lines = text.components(separatedBy: "\n")
        let rule = String(repeating: "=", count: 78)
        let headings = lines.indices.dropFirst().dropLast().filter { lines[$0 - 1] == rule && lines[$0 + 1] == rule }
            .map { lines[$0].components(separatedBy: " (").first ?? "" }
        let grammars = [
            "bash", "c", "cpp", "css", "go", "html", "java", "javascript", "json", "kotlin", "markdown", "python",
            "ruby", "rust", "scss", "swift", "typescript", "yaml",
        ].map { "tree-sitter-\($0)" }
        #expect(headings == ["swift-tree-sitter", "tree-sitter", "ICU"] + grammars + ["nvim-treesitter highlight queries"])
    }
}
