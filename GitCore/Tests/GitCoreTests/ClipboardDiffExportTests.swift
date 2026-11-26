import Foundation
import Testing

@testable import GitCore

@Suite struct ClipboardDiffExportTests {
    private let backend = CLIGitBackend()

    @Test func copiesEveryFileFromRootCommitAndPreservesItsBytes() async throws {
        let source = try await TestRepo.makeEmpty()
        defer { source.cleanUp() }
        let destination = try await TestRepo.makeEmpty()
        defer { destination.cleanUp() }
        let paths = ["a space", "folder/é", "empty"]
        let contents = ["a\r\nb  \r\n", "without newline", ""]
        for (path, content) in zip(paths, contents) {
            try source.write(path, content)
        }
        try await source.commitAll("root")
        let commit = try await source.headSha()
        try source.write(paths[0], "current work should not enter the export\n")

        let export = try #require(await backend.copyAllChanges(.commit(commit), at: source.root))
        #expect(export.fileCount == paths.count)
        let plan = try await backend.planClipboardPatch(export.text, at: destination.root)
        try await backend.applyClipboardPatch(plan, at: destination.root)
        for (path, content) in zip(paths, contents) {
            #expect(try Data(contentsOf: destination.root.appendingPathComponent(path)) == Data(content.utf8))
        }
    }

    @Test func comparesCapturedTipsAndUsesTheFirstParentForMergeCommits() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("base", "base\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-c", "side"])
        try repo.write("side", "from side\n")
        try await repo.commitAll("side")
        let comparison = try await backend.compare("refs/heads/main", "refs/heads/side", at: repo.root)
        try repo.write("later", "branch moved\n")
        try await repo.commitAll("later")

        let compared = try #require(await backend.copyAllChanges(.comparison(comparison), at: repo.root))
        #expect(compared.fileCount == 1)
        #expect(compared.text.contains("diff --git a/side b/side"))
        #expect(!compared.text.contains("branch moved"))

        try await repo.git(["switch", "main"])
        try repo.write("main", "from main\n")
        try await repo.commitAll("main")
        try await repo.git(["merge", "--no-ff", "--no-edit", "side"])
        let merge = try await repo.headSha()
        let merged = try #require(await backend.copyAllChanges(.commit(merge), at: repo.root))
        #expect(merged.fileCount == 2)
        #expect(merged.text.contains("diff --git a/side b/side"))
        #expect(merged.text.contains("diff --git a/later b/later"))
        #expect(!merged.text.contains("diff --git a/main b/main"))
    }

    @Test func overlaysTheStashUntrackedTreeBeforeDiffingItAgainstItsBase() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("same", "base\n")
        try repo.write("tracked", "old tracked\n")
        try await repo.commitAll("base")
        try await repo.git(["rm", "--", "same"])
        try repo.write("same", "recreated\n")
        try repo.write("tracked", "new tracked\n")
        try repo.write("untracked", "saved untracked\n")
        try await repo.git(["stash", "push", "--include-untracked"])
        let stash = try #require(await backend.stashes(at: repo.root).first)
        let savedUntracked = try await repo.git(["ls-tree", "--name-only", "-r", "\(stash.sha)^3"])
        #expect(String(decoding: savedUntracked, as: UTF8.self) == "same\nuntracked\n")
        try repo.write("unrelated", "newer stash\n")
        try await repo.git(["stash", "push", "--include-untracked"])
        let objects = try await repo.git(["count-objects", "-v"])
        let refs = try await repo.git(["show-ref"])
        let indexURL = repo.root.appendingPathComponent(".git/index")
        let index = try Data(contentsOf: indexURL)

        let export = try #require(await backend.copyAllChanges(.stash(stash), at: repo.root))
        #expect(export.fileCount == 3)
        #expect(try await repo.git(["count-objects", "-v"]) == objects)
        #expect(try await repo.git(["show-ref"]) == refs)
        #expect(try Data(contentsOf: indexURL) == index)
        let plan = try await backend.planClipboardPatch(export.text, at: repo.root)
        #expect(plan.files.map(\.path) == ["same", "tracked", "untracked"])
        #expect(plan.files.map(\.kind) == [.modified, .modified, .added])
        try await backend.applyClipboardPatch(plan, at: repo.root)
        #expect(try Data(contentsOf: repo.root.appendingPathComponent("same")) == Data("recreated\n".utf8))
        #expect(try Data(contentsOf: repo.root.appendingPathComponent("tracked")) == Data("new tracked\n".utf8))
        #expect(try Data(contentsOf: repo.root.appendingPathComponent("untracked")) == Data("saved untracked\n".utf8))
    }

    @Test func namesBothPathsWhenAFileBecomesADirectory() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("path", "before\n")
        try await repo.commitAll("base")
        try await repo.git(["rm", "--", "path"])
        try repo.write("path/child", "after\n")
        try repo.write("supported", "ok\n")
        try await repo.commitAll("type change")
        let commit = try await repo.headSha()

        await #expect(throws: ClipboardDiffExportRefusal.unsupportedPaths(["path", "path/child"])) {
            try await backend.copyAllChanges(.commit(commit), at: repo.root)
        }
    }

    @Test func namesUnsupportedFilesInAnOtherwiseCopyableCommit() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("supported", "ok\n")
        try Data([0, 1, 2]).write(to: repo.root.appendingPathComponent("binary"))
        try Data([0xE9, 0x0A]).write(to: repo.root.appendingPathComponent("legacy encoding"))
        try await repo.commitAll("mixed")
        let commit = try await repo.headSha()

        await #expect(throws: ClipboardDiffExportRefusal.unsupportedPaths(["binary", "legacy encoding"])) {
            try await backend.copyAllChanges(.commit(commit), at: repo.root)
        }
    }

    @Test func anEmptyCommitExportsNoPatch() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.git(["commit", "--allow-empty", "-m", "empty"])
        let commit = try await repo.headSha()
        #expect(try await backend.copyAllChanges(.commit(commit), at: repo.root) == nil)
    }

    @Test func keepsInexactRenamesOutOfThePatchDespiteALowConfiguredLimit() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let north = (1...16).map { "north line \($0) with its own contents\n" }.joined()
        let south = (1...16).map { "south entry \($0) with entirely different text\n" }.joined()
        try repo.write("north-old.txt", north)
        try repo.write("south-old.txt", south)
        try await repo.commitAll("base")
        try await repo.git(["mv", "north-old.txt", "east-new.txt"])
        try await repo.git(["mv", "south-old.txt", "west-new.txt"])
        try repo.write("east-new.txt", north + "additional east line\n")
        try repo.write("west-new.txt", south + "additional west line\n")
        try await repo.commitAll("inexact renames")
        let commit = try await repo.headSha()
        try await repo.git(["config", "diff.renameLimit", "1"])

        await #expect(throws: ClipboardDiffExportRefusal.unsupportedPaths(
            ["east-new.txt", "north-old.txt", "south-old.txt", "west-new.txt"]
        )) {
            try await backend.copyAllChanges(.commit(commit), at: repo.root)
        }
    }

    @Test func historicalExportDoesNotLaunchTheFilesMonitor() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write(".gitattributes", "*.txt text\n")
        try repo.write("example.txt", "contents\n")
        try await repo.commitAll("root")
        let commit = try await repo.headSha()
        let marker = repo.root.appendingPathComponent(".git/fsmonitor-ran")
        try repo.writeExecutable(".git/clipboard-monitor", """
            #!/bin/sh
            printf 'ran\\n' >> .git/fsmonitor-ran
            printf 'token\\000'
            """)
        try await repo.git(["config", "core.fsmonitor", repo.root.appendingPathComponent(".git/clipboard-monitor").path])

        try await repo.git(["diff-tree", "--root", "--no-commit-id", "-p", "-r", commit])
        try #require(FileManager.default.fileExists(atPath: marker.path))
        try FileManager.default.removeItem(at: marker)

        let export = try #require(await backend.copyAllChanges(.commit(commit), at: repo.root))
        #expect(export.fileCount == 2)
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    @Test(arguments: [false, true])
    func namesInvalidUTF8PathsInGitsEscapedSpelling(binary: Bool) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let contents = binary ? "\0binary\n" : "text\n"
        try await repo.fastImport("""
            commit refs/heads/main
            committer Tester <t@t> 1234567890 +0000
            data 4
            root
            M 100644 inline "bad-\\377"
            data \(contents.utf8.count)
            \(contents)

            """)
        let commit = try await repo.headSha()
        try await repo.git(["config", "core.quotePath", "false"])
        let fileName = #""bad-\377""#

        await #expect(throws: ClipboardDiffExportRefusal.unsupportedPaths([fileName])) {
            try await backend.copyAllChanges(.commit(commit), at: repo.root)
        }
    }
}
