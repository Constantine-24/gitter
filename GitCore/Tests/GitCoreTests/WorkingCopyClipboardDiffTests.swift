import Foundation
import Testing

@testable import GitCore

@Suite struct WorkingCopyClipboardDiffTests {
    private let backend = CLIGitBackend()

    @Test func copiesTheNetChangeAndAppliesItWithoutChangingSourceStaging() async throws {
        let source = try await TestRepo.makeEmpty()
        defer { source.cleanUp() }
        let destination = try await TestRepo.makeEmpty()
        defer { destination.cleanUp() }
        for repo in [source, destination] {
            try repo.write(".gitignore", "ignored\n")
            // Match a Git checkout, without the text-encoding xattr from String.write.
            try Data("old\n\nunchanged context\n".utf8).write(to: repo.root.appendingPathComponent("both"))
            try Data("removed\n".utf8).write(to: repo.root.appendingPathComponent("removed"))
            try Data("original\n".utf8).write(to: repo.root.appendingPathComponent("recreated"))
            try await repo.commitAll("base")
        }

        try source.write("both", "staged only\n\nunchanged context\n")
        try await source.git(["add", "--", "both"])
        try source.write("both", "current\n\nunchanged context\n")
        try await source.git(["rm", "--", "recreated"])
        try source.write("recreated", "new at the same path\n")
        try FileManager.default.removeItem(at: source.root.appendingPathComponent("removed"))
        try source.write("directory/new file[1]", "untracked\n")
        try source.write("empty", "")
        try source.write("ignored", "ignored\n")
        try await source.git(["config", "diff.noprefix", "true"])
        try await source.git(["config", "diff.suppressBlankEmpty", "true"])
        try await source.git(["config", "diff.outputIndicatorNew", "!"])
        try await source.git(["config", "status.showUntrackedFiles", "no"])

        let index = source.root.appendingPathComponent(".git/index")
        let originalIndex = try Data(contentsOf: index)
        let existingObjects = try await source.git(["count-objects", "-v"])
        let head = try await source.headSha()

        let patch = try await backend.workingCopyClipboardDiff(at: source.root)
        let text = try #require(String(data: patch, encoding: .utf8))
        let plan = try await backend.planClipboardPatch(text, at: destination.root)
        #expect(plan.files.map(\.path) == ["both", "directory/new file[1]", "empty", "recreated", "removed"])

        try await backend.applyClipboardPatch(plan, at: destination.root)
        for path in ["both", "directory/new file[1]", "empty", "recreated"] {
            #expect(try Data(contentsOf: destination.root.appendingPathComponent(path))
                    == Data(contentsOf: source.root.appendingPathComponent(path)))
        }
        #expect(!FileManager.default.fileExists(atPath: destination.root.appendingPathComponent("removed").path))
        #expect(!FileManager.default.fileExists(atPath: destination.root.appendingPathComponent("ignored").path))
        #expect(try Data(contentsOf: index) == originalIndex)
        #expect(try await source.git(["count-objects", "-v"]) == existingObjects)
        #expect(try await source.headSha() == head)
    }

    @Test func anUnbornRepositoryCanExportUntrackedAndStagedPathsTogether() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("staged", "staged\n")
        try await repo.git(["add", "--", "staged"])
        try repo.write("staged", "on disk\n")
        try repo.write("new", "only on disk\n")

        let patch = try await backend.workingCopyClipboardDiff(at: repo.root)
        let files = DiffParser.parse(patch)
        #expect(files.map(\.displayPath) == ["new", "staged"])
        #expect(files.map(\.kind) == [.added, .added])
        #expect(String(decoding: patch, as: UTF8.self).contains("+on disk\n"))
    }

    @Test func anUnbornRepositoryDoesNotCreateARealIndex() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("untracked", "only on disk\n")

        let patch = try await backend.workingCopyClipboardDiff(at: repo.root)

        #expect(DiffParser.parse(patch).map(\.displayPath) == ["untracked"])
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent(".git/index").path))
    }

    @Test(arguments: [false, true])
    func copiesARacyTrackedEditThroughTheIndexSnapshot(withUntracked: Bool) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.git(["config", "core.trustctime", "false"])
        let fm = FileManager.default
        let sameTime = Date(timeIntervalSince1970: 1_605_600_000)
        let file = repo.root.appendingPathComponent("tracked")
        let index = repo.root.appendingPathComponent(".git/index")
        try repo.write("tracked", "old\n")
        try fm.setAttributes([.modificationDate: sameTime], ofItemAtPath: file.path)
        try await repo.commitAll("base")
        try fm.setAttributes([.modificationDate: sameTime], ofItemAtPath: index.path)
        try Data("new\n".utf8).write(to: file)
        try fm.setAttributes([.modificationDate: sameTime], ofItemAtPath: file.path)
        if withUntracked {
            try repo.write("other", "untracked\n")
            let destination = index.appendingPathExtension("actual")
            try fm.moveItem(at: index, to: destination)
            try fm.createSymbolicLink(at: index, withDestinationURL: destination)
        }
        let indexBytes = try Data(contentsOf: index)
        #expect(try await repo.git(["diff", "--name-only", "HEAD", "--"]) == Data("tracked\n".utf8))

        let result = try await backend.copyAllChanges(.workingCopy, at: repo.root)
        let copied = try #require(result)

        #expect(copied.fileCount == (withUntracked ? 2 : 1))
        #expect(copied.text.contains("+new\n"))
        #expect(try Data(contentsOf: index) == indexBytes)
        if withUntracked {
            #expect(try fm.destinationOfSymbolicLink(atPath: index.path) == index.appendingPathExtension("actual").path)
        }
    }

    @Test func refusesWarningsWhenGitCannotReadATrackedPath() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write(".gitignore", "inner/\n")
        try repo.write("inner/tracked", "base\n")
        try await repo.git(["add", "--force", "--", "inner/tracked"])
        try await repo.commitAll("base")
        try repo.write("other", "ordinary file\n")
        let directory = repo.root.appendingPathComponent("inner")
        let fm = FileManager.default
        try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: directory.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path) }

        await #expect {
            try await backend.copyAllChanges(.workingCopy, at: repo.root)
        } throws: { error in
            guard case GitError.commandFailed(_, let stderr) = error else { return false }
            return stderr.contains("inner/") && stderr.contains("Permission denied")
        }
    }

    @Test func refusesTheWholeExportAndNamesAnUnmergedPath() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("conflict", "base\n")
        try repo.write("other", "base\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-c", "theirs"])
        try repo.write("conflict", "theirs\n")
        try await repo.commitAll("theirs")
        try await repo.git(["switch", "main"])
        try repo.write("conflict", "ours\n")
        try await repo.commitAll("ours")
        try await repo.git(["merge", "--no-edit", "theirs"], allowedExitCodes: [1])
        try repo.write("other", "ordinary edit\n")

        await #expect(throws: ClipboardDiffExportRefusal.unsupportedPaths(["conflict"])) {
            try await backend.copyAllChanges(.workingCopy, at: repo.root)
        }
    }

    @Test func copiesThroughLinkedAndSplitIndexesWithoutStagingUntrackedFiles() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("file", "base\n")
        try await repo.commitAll("base")
        let linked = TestRepo(root: repo.root.deletingLastPathComponent()
            .appendingPathComponent("gitter-linked-\(UUID().uuidString)", isDirectory: true))
        defer { linked.cleanUp() }
        try await repo.git(["worktree", "add", "-q", "-b", "linked", linked.root.path])
        try await repo.git(["config", "core.splitIndex", "true"])
        try linked.write("file", "staged\n")
        try await linked.git(["add", "--", "file"])
        try linked.write("file", "on disk\n")
        try linked.write("new", "only on disk\n")

        let patch = try await backend.workingCopyClipboardDiff(at: linked.root)

        #expect(DiffParser.parse(patch).map(\.displayPath) == ["file", "new"])
        #expect(try await linked.indexContent(of: "file") == Data("staged\n".utf8))
        #expect(try await !linked.isInIndex("new"))
        #expect(try await repo.indexContent(of: "file") == Data("base\n".utf8))
    }

    @Test func doesNotRunPostIndexChangeHooksForItsTemporaryIndex() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("first", "first\n")
        try await repo.commitAll("base")
        try repo.writeExecutable(".git/hooks/post-index-change", "#!/bin/sh\nprintf called >hook-ran\n")
        try repo.write("new", "only on disk\n")

        let patch = try await backend.workingCopyClipboardDiff(at: repo.root)

        #expect(DiffParser.parse(patch).map(\.displayPath) == ["new"])
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("hook-ran").path))
    }

    @Test func refusesANestedRepositoryByName() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("first", "first\n")
        try await repo.commitAll("base")
        try await repo.git(["init", "-q", "nested"])
        try repo.write("nested/file", "not part of the parent repository\n")
        try repo.write("another", "part of the parent repository\n")

        await #expect(throws: ClipboardDiffExportRefusal.unsupportedPaths(["nested/"])) {
            try await backend.workingCopyClipboardDiff(at: repo.root)
        }
    }

    @Test(arguments: ["clean", "process"], ["fixture", ""])
    func refusesAChangedFilteredPathWithoutRunningItsDriver(command: String, driver: String) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write(".gitattributes", "*.driver filter=\(driver)\n")
        try repo.write("tracked.driver", "old\n")
        try await repo.commitAll("base")
        let script = command == "process" ? "printf called >filter-ran" : "printf called >filter-ran; cat"
        try await repo.git(["config", "filter.\(driver).\(command)", script])
        try await repo.git(["config", "filter.\(driver).required", "true"])
        try repo.write("tracked.driver", "tracked change\n")
        try repo.write("untracked.driver", "untracked change\n")
        try repo.write("plain", "ordinary file\n")

        await #expect(throws: ClipboardDiffExportRefusal.unsupportedPaths(["tracked.driver", "untracked.driver"])) {
            try await backend.workingCopyClipboardDiff(at: repo.root)
        }
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("filter-ran").path))
    }

    @Test func anUnchangedFilteredPathDoesNotBlockOrdinaryChanges() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write(".gitattributes", "*.driver filter=fixture\n")
        try repo.write("tracked.driver", "old\n")
        try await repo.commitAll("base")
        try await repo.git(["config", "filter.fixture.clean", "printf called >filter-ran; cat"])
        try repo.write("plain", "ordinary file\n")

        let patch = try await backend.workingCopyClipboardDiff(at: repo.root)

        #expect(DiffParser.parse(patch).map(\.displayPath) == ["plain"])
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("filter-ran").path))
    }

    @Test func refusesADirtyNestedSubmoduleWithoutRunningItsDriver() async throws {
        let parent = try await TestRepo.makeEmpty()
        defer { parent.cleanUp() }
        let child = try await TestRepo.makeEmpty()
        defer { child.cleanUp() }
        let leaf = try await TestRepo.makeEmpty()
        defer { leaf.cleanUp() }
        try leaf.write(".gitattributes", "*.driver filter=nested\n")
        try leaf.write("tracked.driver", "old\n")
        try await leaf.commitAll("leaf")
        try await child.git(["-c", "protocol.file.allow=always", "submodule", "add", "--", leaf.root.path, "leaf"])
        try await child.commitAll("child")
        try await parent.git(["-c", "protocol.file.allow=always", "submodule", "add", "--", child.root.path, "sub"])
        try await parent.git(["-c", "protocol.file.allow=always", "submodule", "update", "--init", "--recursive"])
        try await parent.commitAll("parent")
        let checkout = TestRepo(root: parent.root.appendingPathComponent("sub/leaf", isDirectory: true))
        try await checkout.git(["config", "filter.nested.clean", "printf called >filter-ran; cat"])
        try parent.write(".gitattributes", "plain filter=nested\n")
        try parent.write("plain", "ordinary file\n")

        let clean = try await backend.copyAllChanges(.workingCopy, at: parent.root)
        #expect(clean?.fileCount == 2)
        try checkout.write("tracked.driver", "new\n")

        await #expect(throws: ClipboardDiffExportRefusal.unsupportedPaths(["sub"])) {
            try await backend.copyAllChanges(.workingCopy, at: parent.root)
        }
        #expect(!FileManager.default.fileExists(atPath: checkout.root.appendingPathComponent("filter-ran").path))
    }
}
