import Foundation
import Testing

@testable import GitCore

@Suite struct ClipboardPatchBackendTests {
    private let backend = CLIGitBackend()

    @Test func appliesRegularFilesInOneUnstagedChange() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a space.txt", "first\nold\nlast\n")
        try repo.write("gone.txt", "gone\n")
        try repo.write("empty-old", "")
        try repo.write("elsewhere", "original\n")
        try await repo.commitAll("root")
        let head = try await repo.headSha()

        try repo.write("a space.txt", "first\nnew  \nlast\n")
        try repo.write("folder/é.txt", "added\n")
        try repo.write("empty-new", "")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("gone.txt"))
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("empty-old"))
        try await repo.git(["add", "-A"])
        let patch = String(decoding: try await repo.git(["diff", "--cached", "--no-renames"]), as: UTF8.self)
        try await repo.git(["restore", "--source=HEAD", "--staged", "--worktree", "--", "."])

        try repo.write("elsewhere", "staged\n")
        try await repo.git(["add", "elsewhere"])
        try repo.write("elsewhere", "unrelated work\n")
        let indexURL = repo.root.appendingPathComponent(".git/index")
        let index = try Data(contentsOf: indexURL)
        let plan = try await backend.planClipboardPatch(patch, at: repo.root)
        #expect(plan.text == patch)
        #expect(plan.files.map(\.path) == ["a space.txt", "empty-new", "empty-old", "folder/é.txt", "gone.txt"])
        #expect(plan.files.map(\.kind) == [.modified, .added, .deleted, .added, .deleted])
        #expect(plan.files.map(\.additions) == [1, 0, 0, 1, 0])
        #expect(plan.files.map(\.deletions) == [1, 0, 0, 0, 1])
        #expect(try Data(contentsOf: indexURL) == index)
        #expect(try String(contentsOf: repo.root.appendingPathComponent("a space.txt"), encoding: .utf8) == "first\nold\nlast\n")

        try await backend.applyClipboardPatch(plan, at: repo.root)

        #expect(try String(contentsOf: repo.root.appendingPathComponent("a space.txt"), encoding: .utf8) == "first\nnew  \nlast\n")
        #expect(try String(contentsOf: repo.root.appendingPathComponent("folder/é.txt"), encoding: .utf8) == "added\n")
        #expect(try Data(contentsOf: repo.root.appendingPathComponent("empty-new")).isEmpty)
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("empty-old").path))
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("gone.txt").path))
        #expect(try String(contentsOf: repo.root.appendingPathComponent("elsewhere"), encoding: .utf8) == "unrelated work\n")
        #expect(try Data(contentsOf: indexURL) == index)
        #expect(try await repo.headSha() == head)
    }

    @Test func rejectsWholePatchWhenOneFileDoesNotMatch() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a", "first\nold\nlast\n")
        try repo.write("b", "first\nother\nlast\n")
        try await repo.commitAll("root")
        let indexURL = repo.root.appendingPathComponent(".git/index")
        let index = try Data(contentsOf: indexURL)

        await #expect(throws: GitError.self) {
            try await backend.planClipboardPatch(modification("a") + modification("b"), at: repo.root)
        }
        #expect(try String(contentsOf: repo.root.appendingPathComponent("a"), encoding: .utf8) == "first\nold\nlast\n")
        #expect(try String(contentsOf: repo.root.appendingPathComponent("b"), encoding: .utf8) == "first\nother\nlast\n")
        #expect(try Data(contentsOf: indexURL) == index)
    }

    @Test func revalidatesPreimagesAndSymbolicHead() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a", "first\nold\nlast\n")
        try await repo.commitAll("root")
        let plan = try await backend.planClipboardPatch(modification("a"), at: repo.root)

        // The original hunk still matches, with a new line beyond its context.
        try repo.write("a", "first\nold\nlast\nnew work\n")
        await #expect(throws: ClipboardPatchRefusal.self) {
            try await backend.applyClipboardPatch(plan, at: repo.root)
        }
        #expect(try String(contentsOf: repo.root.appendingPathComponent("a"), encoding: .utf8) == "first\nold\nlast\nnew work\n")

        try await repo.git(["restore", "a"])
        try await repo.git(["switch", "-c", "same-commit"])
        await #expect(throws: ClipboardPatchRefusal.self) {
            try await backend.applyClipboardPatch(plan, at: repo.root)
        }
        #expect(try String(contentsOf: repo.root.appendingPathComponent("a"), encoding: .utf8) == "first\nold\nlast\n")
    }

    @Test func supportsUnbornHeadAndRejectsAnIgnoredOccupant() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write(".git/info/exclude", "added\n")
        let patch = addition("added")
        let plan = try await backend.planClipboardPatch(patch, at: repo.root)
        #expect(plan.headLabel.contains("main"))
        try repo.write("added", "ignored data\n")
        await #expect(throws: ClipboardPatchRefusal.self) {
            try await backend.planClipboardPatch(patch, at: repo.root)
        }
        await #expect(throws: ClipboardPatchRefusal.self) {
            try await backend.applyClipboardPatch(plan, at: repo.root)
        }
        #expect(try String(contentsOf: repo.root.appendingPathComponent("added"), encoding: .utf8) == "ignored data\n")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("added"))
        try await backend.applyClipboardPatch(plan, at: repo.root)
        #expect(try String(contentsOf: repo.root.appendingPathComponent("added"), encoding: .utf8) == "new\n")
        #expect(!(try await repo.isInIndex("added")))
    }

    @Test(arguments: ["../escaped", ".git/config", "link/added", "nested/added"])
    func rejectsUnsafePaths(_ path: String) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let outside = try await TestRepo.makeEmpty()
        defer { outside.cleanUp() }
        try FileManager.default.createSymbolicLink(at: repo.root.appendingPathComponent("link"), withDestinationURL: outside.root)
        try repo.write("nested/.git", "gitdir: non-existent\n")
        await #expect(throws: ClipboardPatchRefusal.self) {
            try await backend.planClipboardPatch(addition(path), at: repo.root)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.root.appendingPathComponent("added").path))
    }

    @Test(arguments: ["staged", "intent-to-add", "assume-unchanged", "skip-worktree", "conversion", "operation"])
    func rejectsUnsafeRepositoryState(_ state: String) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a", "first\nold\nlast\n")
        try await repo.commitAll("root")
        let patch: String
        switch state {
        case "staged":
            try repo.write("a", "first\nold\nlast\nnew work\n")
            try await repo.git(["add", "a"])
            patch = modification("a")
        case "intent-to-add":
            try repo.write("added", "")
            try await repo.git(["add", "-N", "added"])
            try FileManager.default.removeItem(at: repo.root.appendingPathComponent("added"))
            patch = addition("added")
        case "assume-unchanged", "skip-worktree":
            try await repo.git(["update-index", "--" + state, "a"])
            try repo.write("a", "first\nold\nlast\nnew work\n")
            patch = modification("a")
        case "conversion":
            try repo.write(".gitattributes", "a filter=example\n")
            patch = modification("a")
        default:
            try repo.write(".git/SQUASH_MSG", "pending\n")
            patch = modification("a")
        }
        await #expect(throws: ClipboardPatchRefusal.self) {
            try await backend.planClipboardPatch(patch, at: repo.root)
        }
    }

    @Test func ignoresGitApplyWhitespaceOverrides() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a", "first changed\nold\nlast\n")
        try await repo.commitAll("root")
        try await repo.git(["config", "apply.ignoreWhitespace", "change"])
        let patch = modification("a").replacingOccurrences(of: " first\n", with: " first    changed\n")
        await #expect(throws: GitError.self) {
            try await backend.planClipboardPatch(patch, at: repo.root)
        }
    }

    @Test func rejectsNonUnifiedAndPathChangingSections() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a", "first\nold\nlast\n")
        try await repo.commitAll("root")
        let validPatch = modification("a")
        for patch in [
            "plain text\n",
            "diff --git a/a b/a\nold mode 100644\nnew mode 100755\n",
            "diff --git a/a b/b\nsimilarity index 100%\nrename from a\nrename to b\n",
            "diff --git a/a b/a\nBinary files a/a and b/a differ\n",
            validPatch.replacingOccurrences(of: "+++ b/a\n", with: "+++ b/another\n"),
            validPatch + validPatch,
            validPatch + "not part of the patch\n"
        ] {
            await #expect(throws: ClipboardPatchRefusal.self) {
                try await backend.planClipboardPatch(patch, at: repo.root)
            }
        }
    }

    @Test func rejectsAStagedDeletionThatAliasesAnAddition() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("Foo", "tracked\n")
        try await repo.commitAll("root")
        try await repo.git(["rm", "Foo"])

        await #expect(throws: ClipboardPatchRefusal.self) {
            try await backend.planClipboardPatch(addition("foo"), at: repo.root)
        }
    }

    @Test func refusesConversionAttributesAfterEmptyValues() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("a", "first\nold\nlast\n")
        try await repo.commitAll("root")
        try repo.write(".gitattributes", "a custom= filter=unset\n")

        await #expect(throws: ClipboardPatchRefusal.self) {
            try await backend.planClipboardPatch(modification("a"), at: repo.root)
        }
    }

    @Test func appliesExecutableAndNoNewlineChanges() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.writeExecutable("removing", "old")
        try await repo.commitAll("root")
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("removing"))
        try repo.writeExecutable("adding", "new")
        try await repo.git(["add", "-A"])
        let patch = String(decoding: try await repo.git(["diff", "--cached", "--no-renames"]), as: UTF8.self)
        try await repo.git(["restore", "--source=HEAD", "--staged", "--worktree", "--", "."])

        let plan = try await backend.planClipboardPatch(patch, at: repo.root)
        #expect(plan.files.map(\.kind) == [.added, .deleted])
        try await backend.applyClipboardPatch(plan, at: repo.root)
        let added = repo.root.appendingPathComponent("adding")
        #expect(try Data(contentsOf: added) == Data("new".utf8))
        #expect(FileManager.default.isExecutableFile(atPath: added.path))
        #expect(!FileManager.default.fileExists(atPath: repo.root.appendingPathComponent("removing").path))
        #expect(!(try await repo.isInIndex("adding")))
        #expect(try await repo.isInIndex("removing"))
    }

    private func modification(_ path: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        --- a/\(path)
        +++ b/\(path)
        @@ -1,3 +1,3 @@
         first
        -old
        +new
         last

        """
    }

    private func addition(_ path: String) -> String {
        """
        diff --git a/\(path) b/\(path)
        new file mode 100644
        --- /dev/null
        +++ b/\(path)
        @@ -0,0 +1 @@
        +new

        """
    }
}
