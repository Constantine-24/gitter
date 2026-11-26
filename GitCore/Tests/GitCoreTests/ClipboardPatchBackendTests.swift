import Darwin
import Foundation
import Testing

@testable import GitCore

@Suite struct ClipboardPatchBackendTests {
    private let backend = CLIGitBackend()

    @Test func appliesRegularFilesInOneUnstagedChange() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try write("a space.txt", "first\nold\nlast\n", in: repo)
        try write("gone.txt", "gone\n", in: repo)
        try write("empty-old", "", in: repo)
        try write("elsewhere", "original\n", in: repo)
        try await repo.commitAll("root")
        let head = try await repo.headSha()

        try write("a space.txt", "first\nnew  \nlast\n", in: repo)
        try write("folder/é.txt", "added\n", in: repo)
        try write("empty-new", "", in: repo)
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("gone.txt"))
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("empty-old"))
        try await repo.git(["add", "-A"])
        let patch = String(decoding: try await repo.git(["diff", "--cached", "--no-renames"]), as: UTF8.self)
        try await repo.git(["restore", "--source=HEAD", "--staged", "--worktree", "--", "."])

        try write("elsewhere", "staged\n", in: repo)
        try await repo.git(["add", "elsewhere"])
        try write("elsewhere", "unrelated work\n", in: repo)
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
        try write("a", "first\nold\nlast\n", in: repo)
        try write("b", "first\nother\nlast\n", in: repo)
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
        try write("a", "first\nold\nlast\n", in: repo)
        try await repo.commitAll("root")
        let plan = try await backend.planClipboardPatch(modification("a"), at: repo.root)

        // The original hunk still matches, with a new line beyond its context.
        try write("a", "first\nold\nlast\nnew work\n", in: repo)
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
        try write(".git/info/exclude", "added\n", in: repo)
        let patch = addition("added")
        let plan = try await backend.planClipboardPatch(patch, at: repo.root)
        #expect(plan.headLabel.contains("main"))
        try write("added", "ignored data\n", in: repo)
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
        try write("nested/.git", "gitdir: non-existent\n", in: repo)
        await #expect(throws: ClipboardPatchRefusal.self) {
            try await backend.planClipboardPatch(addition(path), at: repo.root)
        }
        #expect(!FileManager.default.fileExists(atPath: outside.root.appendingPathComponent("added").path))
    }

    @Test(arguments: ["staged", "intent-to-add", "assume-unchanged", "skip-worktree", "conversion", "operation"])
    func rejectsUnsafeRepositoryState(_ state: String) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try write("a", "first\nold\nlast\n", in: repo)
        try await repo.commitAll("root")
        let patch: String
        switch state {
        case "staged":
            try write("a", "first\nold\nlast\nnew work\n", in: repo)
            try await repo.git(["add", "a"])
            patch = modification("a")
        case "intent-to-add":
            try write("added", "", in: repo)
            try await repo.git(["add", "-N", "added"])
            try FileManager.default.removeItem(at: repo.root.appendingPathComponent("added"))
            patch = addition("added")
        case "assume-unchanged", "skip-worktree":
            try await repo.git(["update-index", "--" + state, "a"])
            patch = modification("a")
        case "conversion":
            try write(".gitattributes", "a filter=example\n", in: repo)
            patch = modification("a")
        default:
            try write(".git/SQUASH_MSG", "pending\n", in: repo)
            patch = modification("a")
        }
        await #expect(throws: ClipboardPatchRefusal.self) {
            try await backend.planClipboardPatch(patch, at: repo.root)
        }
        if state == "assume-unchanged" || state == "skip-worktree" {
            try await repo.git(["update-index", "--no-" + state, "a"])
            _ = try await backend.planClipboardPatch(patch, at: repo.root)
        }
    }

    @Test func ignoresGitApplyWhitespaceOverrides() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try write("a", "first changed\nold\nlast\n", in: repo)
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
        try write("a", "first\nold\nlast\n", in: repo)
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
        try write("Foo", "tracked\n", in: repo)
        try await repo.commitAll("root")
        try await repo.git(["rm", "Foo"])

        await #expect(throws: ClipboardPatchRefusal.self) {
            try await backend.planClipboardPatch(addition("foo"), at: repo.root)
        }
    }

    @Test func refusesConversionAttributesAfterEmptyValues() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try write("a", "first\nold\nlast\n", in: repo)
        try await repo.commitAll("root")
        try write(".gitattributes", "a custom= filter=unset\n", in: repo)

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

    @Test(arguments: ["worktree", "worktree admin", "common admin"])
    func refusesAReplacementDirectoryAtTheSamePath(_ replacement: String) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try write("a", "first\nold\nlast\n", in: repo)
        try await repo.commitAll("root")
        let root = repo.root.appendingPathExtension("linked")
        let worktree = TestRepo(root: root)
        defer { worktree.cleanUp() }
        try await repo.git(["worktree", "add", "-b", "linked", root.path])
        let plan = try await backend.planClipboardPatch(modification("a"), at: root)
        let directory: URL
        switch replacement {
        case "worktree":
            directory = root
        case "worktree admin":
            let gitDir = String(decoding: try await worktree.git(["rev-parse", "--absolute-git-dir"]), as: UTF8.self)
            directory = URL(fileURLWithPath: String(gitDir.dropLast()), isDirectory: true)
        default:
            directory = repo.root.appendingPathComponent(".git", isDirectory: true)
        }
        let original = directory.appendingPathExtension("original")
        let manager = FileManager.default
        try manager.moveItem(at: directory, to: original)
        defer { try? manager.removeItem(at: original) }
        try manager.copyItem(at: original, to: directory)
        #expect(try await worktree.headSha() == repo.headSha())

        await #expect(throws: ClipboardPatchRefusal.changedSinceShown) {
            try await backend.applyClipboardPatch(plan, at: root)
        }
        #expect(try String(contentsOf: root.appendingPathComponent("a"), encoding: .utf8) == "first\nold\nlast\n")
    }

    @Test func preservesOperationalGitApplyNumstatErrors() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try write("a", "first\nold\nlast\n", in: repo)
        try await repo.commitAll("root")
        let script = """
            #!/bin/sh
            for arg do
                if [ "$arg" = "--numstat" ]; then
                    printf '%s\n' 'fatal: clipboard fixture cannot read data' >&2
                    exit 128
                fi
            done
            exec /usr/bin/git "$@"
            """
        try repo.writeExecutable(".git/test-git", script)
        let backend = CLIGitBackend(gitPath: repo.root.appendingPathComponent(".git/test-git").path)
        await #expect(throws: GitError.commandFailed(exitCode: 128, stderr: "fatal: clipboard fixture cannot read data")) {
            try await backend.planClipboardPatch(modification("a"), at: repo.root)
        }
    }

    @Test(arguments: ["private permissions", "extended attribute", "hard link", "access control list", "file flags"])
    func refusesExistingMetadataThatGitApplyWouldLose(_ metadata: String) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try write("a", "first\nold\nlast\n", in: repo)
        try await repo.commitAll("root")
        let patch = modification("a")
        let plan = try await backend.planClipboardPatch(patch, at: repo.root)
        let file = repo.root.appendingPathComponent("a")
        let attributeName = "dev.penzin.Gitter.clipboard-test"
        let alias = repo.root.appendingPathComponent("alias")
        switch metadata {
        case "private permissions":
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        case "extended attribute":
            try #require(setxattr(file.path, attributeName, "test", 4, 0, 0) == 0)
        case "access control list":
            _ = try await ProcessRunner().run("/bin/chmod", ["+a", "everyone allow readattr", file.path], cwd: repo.root)
        case "file flags":
            try #require(chflags(file.path, UInt32(UF_NODUMP)) == 0)
        default:
            try FileManager.default.linkItem(at: file, to: alias)
        }

        await #expect(throws: ClipboardPatchRefusal.unsupportedFileMetadata("a")) {
            try await backend.applyClipboardPatch(plan, at: repo.root)
        }
        await #expect(throws: ClipboardPatchRefusal.unsupportedFileMetadata("a")) {
            try await backend.planClipboardPatch(patch, at: repo.root)
        }
        #expect(try String(contentsOf: file, encoding: .utf8) == "first\nold\nlast\n")
        switch metadata {
        case "private permissions":
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            #expect(attributes[.posixPermissions] as? Int == 0o600)
        case "extended attribute":
            var value = Data(count: 4)
            let count = value.withUnsafeMutableBytes { getxattr(file.path, attributeName, $0.baseAddress, $0.count, 0, 0) }
            #expect(count == 4)
            #expect(value == Data("test".utf8))
        case "access control list":
            let acl = try #require(acl_get_file(file.path, ACL_TYPE_EXTENDED))
            acl_free(UnsafeMutableRawPointer(acl))
        case "file flags":
            var info = stat()
            try #require(lstat(file.path, &info) == 0)
            #expect(info.st_flags == UInt32(UF_NODUMP))
        default:
            var fileInfo = stat(), aliasInfo = stat()
            try #require(lstat(file.path, &fileInfo) == 0 && lstat(alias.path, &aliasInfo) == 0)
            #expect(fileInfo.st_ino == aliasInfo.st_ino)
        }
    }

    @Test func finishesTheHeldGitWriteAfterCallerCancellation() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try write("a", "first\nold\nlast\n", in: repo)
        try await repo.commitAll("root")
        let script = """
            #!/bin/sh
            for arg do
                case "$arg" in
                    --numstat|--check) exec /usr/bin/git "$@" ;;
                    --whitespace=nowarn) writing=true ;;
                esac
            done
            if [ "$writing" = true ]; then
                state="${0%/*}"
                touch "$state/write-started"
                while [ ! -e "$state/release-write" ]; do sleep 0.01; done
            fi
            exec /usr/bin/git "$@"
            """
        try repo.writeExecutable(".git/test-git", script)
        let backend = CLIGitBackend(gitPath: repo.root.appendingPathComponent(".git/test-git").path)
        let started = repo.root.appendingPathComponent(".git/write-started")
        let release = repo.root.appendingPathComponent(".git/release-write")
        defer { try? Data().write(to: release) }
        let plan = try await backend.planClipboardPatch(modification("a"), at: repo.root)
        let root = repo.root
        let apply = Task { try await backend.applyClipboardPatch(plan, at: root) }
        for _ in 0..<500 where !FileManager.default.fileExists(atPath: started.path) {
            try await Task.sleep(for: .milliseconds(10))
        }
        let launched = FileManager.default.fileExists(atPath: started.path)
        apply.cancel()
        try Data().write(to: release)
        try #require(launched, "the confirmed write never reached the wrapper")
        try await apply.value
        #expect(try String(contentsOf: root.appendingPathComponent("a"), encoding: .utf8) == "first\nnew\nlast\n")
    }

    // String.write adds com.apple.TextEncoding on macOS. Ordinary Git fixtures
    // have only their bytes, like files Git checked out.
    private func write(_ path: String, _ contents: String, in repo: TestRepo) throws {
        let url = repo.root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
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
