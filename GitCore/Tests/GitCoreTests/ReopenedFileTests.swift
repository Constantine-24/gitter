import Foundation
import Testing

@testable import GitCore

/// What Reopen Conflict… puts back, read before it runs (A2 Task 5, fix round 1), so its
/// confirmation can say it. Measured on git 2.54: `restore --merge` writes markers for text,
/// stage 2's bytes for a binary or a `merge=binary` path ("warning: Cannot merge binary files",
/// exit 0), stage 2's mode for a mode-only add/add, and a driver's output for a driver. Each test
/// then reopens and checks the worktree against the prediction, so none can pass by itself.
@Suite struct ReopenedFileTests {

    static let backend = CLIGitBackend()

    /// A merge of `feature` into `main` stopped on `path`, each side writing its own bytes.
    static func merge(
        _ path: String, base: String, ours: String, theirs: String, attributes: String? = nil,
        config: [(String, String)] = []
    ) async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        for (key, value) in config { try await repo.git(["config", key, value]) }
        if let attributes { try repo.write(".gitattributes", attributes) }
        try repo.write("keep.txt", "keep\n")
        try repo.write(path, base)
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "feature"])
        try repo.write(path, theirs)
        try await repo.commitAll("theirs")
        try await repo.git(["switch", "-q", "main"])
        try repo.write(path, ours)
        try await repo.commitAll("ours")
        try await repo.git(["merge", "--no-edit", "feature"], allowedExitCodes: [1])
        try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")
        return repo
    }

    static func resolve(_ repo: TestRepo, _ path: String, with text: String) async throws {
        try repo.write(path, text)
        try await repo.git(["add", "--", path])
    }

    static func reopen(_ repo: TestRepo, _ path: String) async throws {
        _ = try await backend.reopen(
            path, expectingWorktreeHash: ConflictSnapshot.worktreeHash(of: path, at: repo.root), at: repo.root)
    }

    static func stage2(_ repo: TestRepo, _ path: String) async throws -> Data {
        try await repo.git(["cat-file", "blob", ":2:\(path)"])
    }

    @Test func textGetsItsMarkersBack() async throws {
        let repo = try await Self.merge("t.txt", base: "a\nb\nc\n", ours: "a\nX\nc\n", theirs: "a\nB\nc\n")
        defer { repo.cleanUp() }
        try await Self.resolve(repo, "t.txt", with: "a\nX\nc\n")

        #expect(try await Self.backend.reopenedFile("t.txt", at: repo.root) == .markers)

        try await Self.reopen(repo, "t.txt")
        let text = String(decoding: try repo.bytes("t.txt"), as: UTF8.self)
        #expect(text.contains("<<<<<<< ") && text.contains(">>>>>>> "))
    }

    @Test func aBinaryGoesBackToOursWithNoMarkers() async throws {
        let repo = try await Self.merge("b.bin", base: "b\0base", ours: "b\0ours", theirs: "b\0theirs")
        defer { repo.cleanUp() }
        try await Self.resolve(repo, "b.bin", with: "b\0theirs")

        #expect(try await Self.backend.reopenedFile("b.bin", at: repo.root) == .oursVersion)

        try await Self.reopen(repo, "b.bin")
        #expect(try repo.bytes("b.bin") == Data("b\0ours".utf8))
        #expect(try repo.bytes("b.bin") == (try await Self.stage2(repo, "b.bin")))
    }

    @Test func aMergeBinaryAttributeGoesBackToOurs() async throws {
        let repo = try await Self.merge(
            "t.txt", base: "a\nb\nc\n", ours: "a\nX\nc\n", theirs: "a\nB\nc\n", attributes: "t.txt merge=binary\n")
        defer { repo.cleanUp() }
        try await Self.resolve(repo, "t.txt", with: "a\nB\nc\n")

        #expect(try await Self.backend.reopenedFile("t.txt", at: repo.root) == .oursVersion)

        try await Self.reopen(repo, "t.txt")
        #expect(try repo.bytes("t.txt") == Data("a\nX\nc\n".utf8))
    }

    @Test func aModeOnlyAddGoesBackToOursMode() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("keep.txt", "keep\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "feature"])
        try repo.write("n.sh", "same\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root.appending(path: "n.sh").path)
        try await repo.commitAll("theirs")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("n.sh", "same\n")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: repo.root.appending(path: "n.sh").path)
        try await repo.commitAll("ours")
        try await repo.git(["merge", "--no-edit", "feature"], allowedExitCodes: [1])
        try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: repo.root.appending(path: "n.sh").path)
        try await repo.git(["add", "--", "n.sh"])

        #expect(try await Self.backend.reopenedFile("n.sh", at: repo.root) == .oursMode)

        try await Self.reopen(repo, "n.sh")
        let mode = try FileManager.default.attributesOfItem(atPath: repo.root.appending(path: "n.sh").path)[.posixPermissions] as? Int
        #expect(mode.map { $0 & 0o111 } == 0)
        #expect(try repo.bytes("n.sh") == Data("same\n".utf8))
    }

    @Test func aDriverWritesTheFileAgain() async throws {
        let repo = try await Self.merge(
            "t.txt", base: "a\nb\nc\n", ours: "a\nX\nc\n", theirs: "a\nB\nc\n", attributes: "t.txt merge=mine\n",
            config: [("merge.mine.driver", "printf DRIVER > %A; exit 1")])
        defer { repo.cleanUp() }
        try await Self.resolve(repo, "t.txt", with: "a\nB\nc\n")

        #expect(try await Self.backend.reopenedFile("t.txt", at: repo.root) == .driver("mine"))

        try await Self.reopen(repo, "t.txt")
        #expect(try repo.bytes("t.txt") == Data("DRIVER".utf8))
    }

    @Test func nothingToReopenIsNil() async throws {
        let repo = try await Self.merge("t.txt", base: "a\nb\nc\n", ours: "a\nX\nc\n", theirs: "a\nB\nc\n")
        defer { repo.cleanUp() }
        #expect(try await Self.backend.reopenedFile("keep.txt", at: repo.root) == nil)
        // Still unmerged: no resolve-undo record yet.
        #expect(try await Self.backend.reopenedFile("t.txt", at: repo.root) == nil)
    }
}
