import Foundation
import Testing

@testable import GitCore

@Suite struct ClipboardPatchCopyTests {
    @Test func wholeFileCopiesOnlyItsOwnSectionByteForByte() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let path = "a space b/a tab\t and café.txt"
        try repo.write(path, "anchor\r\nold\r\n\nwithout newline")
        try repo.write("z.txt", "old\n")
        try await repo.commitAll("root")
        try repo.write(path, "anchor\r\nnew\r\n\nno newline")
        try repo.write("z.txt", "new\n")
        try await repo.git(["config", "diff.suppressBlankEmpty", "true"])
        let arguments = ["diff", "--full-index", "-U3"]
        let expected = try await repo.git(arguments + ["--", path])
        let both = try await repo.git(arguments)
        let files = DiffParser.parse(both)
        #expect(files.count == 2)
        let file = try #require(files.first)
        let loaded = try await loadDiff(repo, path)
        try repo.write(path, "a later edit\n")

        #expect(file.canCopyClipboardPatch)
        #expect(file.displayPath == path)
        #expect(String(decoding: expected, as: UTF8.self).contains("+new\r\n\n"))
        #expect(Data(try #require(file.clipboardPatch()).utf8) == expected)
        #expect(Data(try #require(loaded.clipboardPatch()).utf8) == expected)
        #expect(file.clipboardPatch(hunkID: "unknown hunk") == nil)
    }

    @Test(arguments: ["", "one line without newline"])
    func addedAndDeletedFilesKeepTheirGitHeaders(_ contents: String) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let addedPath = "a space b/added.txt"
        let deletedPath = "another space/deleted.txt"
        try repo.write(deletedPath, contents)
        try await repo.commitAll("root")
        try repo.write(addedPath, contents)
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent(deletedPath))
        let added = try await loadDiff(repo, addedPath)
        let deleted = try await loadDiff(repo, deletedPath)
        let arguments = ["diff", "--full-index", "-U3"]
        let expectedAdded = try await repo.git(
            arguments + ["--no-index", "--", "/dev/null", addedPath], allowedExitCodes: [1])
        let expectedDeleted = try await repo.git(arguments + ["--", deletedPath])

        #expect(added.kind == .added)
        #expect(deleted.kind == .deleted)
        #expect(added.hunks.count == (contents.isEmpty ? 0 : 1))
        #expect(deleted.hunks.count == (contents.isEmpty ? 0 : 1))
        #expect(Data(try #require(added.clipboardPatch()).utf8) == expectedAdded)
        #expect(Data(try #require(deleted.clipboardPatch()).utf8) == expectedDeleted)
        if let hunk = added.hunks.first {
            #expect(Data(try #require(added.clipboardPatch(hunkID: hunk.id)).utf8) == expectedAdded)
        }
        if let hunk = deleted.hunks.first {
            #expect(Data(try #require(deleted.clipboardPatch(hunkID: hunk.id)).utf8) == expectedDeleted)
        }
    }

    @Test func isolatedLaterHunkAppliesToTheIntendedRepeatedContext() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let path = "repeated context.txt"
        let block = ["a", "b", "c", "old", "d", "e", "f", "", "between", "blocks"]
        let changed = ["a", "b", "c", "new", "d", "e", "f", "", "between", "blocks"]
        let old = (block + block + block).joined(separator: "\r\n")
        let expected = (block + changed + block).joined(separator: "\r\n")
        let earlierLines = (1...block.count).map { "inserted \($0)" }.joined(separator: "\r\n")
        try repo.write(path, old)
        try await repo.commitAll("root")
        try repo.write(path, earlierLines + "\r\n" + expected)
        let file = try await loadDiff(repo, path)
        #expect(file.hunks.count == 2)
        let later = try #require(file.hunks.last)
        #expect(later.newStart - later.oldStart == block.count)
        let patch = try #require(file.clipboardPatch(hunkID: later.id))

        try repo.write(path, old)
        let patchURL = repo.root.appendingPathComponent(".git/clipboard.patch")
        try Data(patch.utf8).write(to: patchURL)
        try await repo.git(["apply", "--", patchURL.path])
        #expect(try Data(contentsOf: repo.root.appendingPathComponent(path)) == Data(expected.utf8))
    }

    @Test func isolatedHunkPreservesMissingNewline() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let path = "partial.txt"
        try repo.write(path, "first\r\nold")
        try await repo.commitAll("root")
        try repo.write(path, "first\r\nnew")
        let file = try await loadDiff(repo, path)
        let hunk = try #require(file.hunks.first)
        let patch = try #require(file.clipboardPatch(hunkID: hunk.id))

        try repo.write(path, "first\r\nold")
        let patchURL = repo.root.appendingPathComponent(".git/clipboard.patch")
        try Data(patch.utf8).write(to: patchURL)
        try await repo.git(["apply", "--", patchURL.path])
        #expect(try Data(contentsOf: repo.root.appendingPathComponent(path)) == Data("first\r\nnew".utf8))
    }

    @Test(arguments: [false, true])
    func copiedPatchRoundTripsThroughClipboardImport(hunkOnly: Bool) async throws {
        let source = try await TestRepo.makeEmpty()
        defer { source.cleanUp() }
        let destination = try await TestRepo.makeEmpty()
        defer { destination.cleanUp() }
        let path = "space and tab\t/é.txt"
        let before = "anchor\r\nold\r\n\nwithout newline"
        let after = "anchor\r\nnew  \r\n\nupdated"
        for repo in [source, destination] {
            try repo.write(path, before)
            try await repo.commitAll("base")
        }
        try source.write(path, after)
        try await source.git(["config", "diff.suppressBlankEmpty", "true"])
        let diff = try await loadDiff(source, path)
        let hunkID = hunkOnly ? try #require(diff.hunks.first).id : nil
        let patch = try #require(diff.clipboardPatch(hunkID: hunkID))
        let backend = CLIGitBackend()
        let plan = try await backend.planClipboardPatch(patch, at: destination.root)

        #expect(plan.files.map(\.path) == [path])
        #expect(try Data(contentsOf: destination.root.appendingPathComponent(path)) == Data(before.utf8))
        try await backend.applyClipboardPatch(plan, at: destination.root)
        #expect(try Data(contentsOf: destination.root.appendingPathComponent(path)) == Data(after.utf8))
        #expect(try await destination.git(["diff", "--cached"]).isEmpty)
    }

    @Test func onlyRegularUTF8ContentChangesCanBeCopied() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let fm = FileManager.default
        try repo.write("binary", "plain\n")
        try repo.write("latin1", "plain\n")
        try repo.write("mode", "plain\n")
        try repo.write("regular", "plain\n")
        try repo.write("renamed", "specific renaming fixture\n")
        try repo.write("copied", "specific copy fixture\n")
        try repo.write("swapped", "plain\n")
        try fm.createSymbolicLink(atPath: repo.root.appendingPathComponent("link").path, withDestinationPath: "old")
        try await repo.commitAll("root")
        let initial = try await repo.headSha()
        try await repo.git(["update-index", "--add", "--cacheinfo", "160000,\(initial),submodule"])
        try await repo.git(["commit", "-qm", "gitlink base"])
        let second = try await repo.headSha()
        try await repo.git(["update-index", "--cacheinfo", "160000,\(second),submodule"])

        try Data([0x00, 0x42, 0x0a]).write(to: repo.root.appendingPathComponent("binary"))
        try Data([0x63, 0x61, 0x66, 0xe9, 0x0a]).write(to: repo.root.appendingPathComponent("latin1"))
        try repo.writeExecutable("mode", "modified contents as well\n")
        try repo.write("regular", "changed text\n")
        try await repo.git(["mv", "renamed", "new name"])
        try repo.write("new copy", "specific copy fixture\n")
        for path in ["link", "swapped"] {
            let url = repo.root.appendingPathComponent(path)
            try fm.removeItem(at: url)
            try fm.createSymbolicLink(atPath: url.path, withDestinationPath: "new")
        }
        try await repo.git(["add", "--", "binary", "latin1", "mode", "regular", "new copy", "link", "swapped"])
        let files = try await DiffParser.parse(repo.git(
            ["diff", "--cached", "--find-copies-harder", "-M", "-C", "--full-index", "-U3"]))
        let blocked = files.filter { $0.displayPath != "regular" }

        #expect(try #require(files.first { $0.displayPath == "regular" }).canCopyClipboardPatch)
        #expect(blocked.map(\.displayPath).sorted() == [
            "binary", "latin1", "link", "mode", "new copy", "new name", "submodule", "swapped", "swapped",
        ])
        #expect(blocked.contains { $0.kind == .renamed })
        #expect(blocked.contains { $0.kind == .copied })
        for file in blocked {
            #expect(!file.canCopyClipboardPatch, "\(file.displayPath)")
            #expect(file.clipboardPatch() == nil, "\(file.displayPath)")
            for hunk in file.hunks {
                #expect(file.clipboardPatch(hunkID: hunk.id) == nil, "\(file.displayPath)")
            }
        }
    }
}
