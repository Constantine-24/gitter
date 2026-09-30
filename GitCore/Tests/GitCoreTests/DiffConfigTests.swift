import Foundation
import Testing

@testable import GitCore

/// The user's diff config must not change the diffs Gitter parses.
///
/// Every parsed `git diff` read (`workingCopyDiff`'s staged, unstaged and untracked reads, and
/// the discard sheet's two batched reads) is porcelain, so it reads the user's `diff.*` keys.
/// Measured on git 2.54 (fix/diff-config-prefix): `diff.mnemonicPrefix`, `diff.noprefix`,
/// `diff.srcPrefix` and `diff.dstPrefix` rename the `a/` `b/` the parser reads, so every diff
/// vanished; `diff.external` (and `GIT_EXTERNAL_DIFF`) made each read die with exit 128; a
/// textconv driver put its output in place of the file's lines; `diff.submodule=log|diff`
/// replaced a gitlink's diff with a log or with the submodule's own files; and
/// `diff.suppressBlankEmpty` writes a blank context line as an empty line, which cut a hunk
/// short at the first blank line. Each case here is set in the repository's own `.git/config`
/// and read through the real backend, against the same reads with the key unset.
@Suite struct DiffConfigTests {
    private let backend = CLIGitBackend()

    /// A key that changes how git writes a diff (or runs something else in its place).
    struct ConfigKey: Sendable, CustomTestStringConvertible {
        let key: String
        let value: String
        /// `.git/info/attributes`, for a driver that needs a path to name it.
        var attributes: String?

        var testDescription: String { "\(key)=\(value)" }

        func configure(_ repo: TestRepo) async throws {
            if let attributes { try repo.write(".git/info/attributes", attributes) }
            try await repo.git(["config", key, value])
        }
    }

    static let formatKeys: [ConfigKey] = [
        ConfigKey(key: "diff.mnemonicPrefix", value: "true"),
        ConfigKey(key: "diff.noprefix", value: "true"),
        ConfigKey(key: "diff.srcPrefix", value: "X/"),
        ConfigKey(key: "diff.dstPrefix", value: "Y/"),
        ConfigKey(key: "diff.external", value: "/usr/bin/false"),
        ConfigKey(key: "diff.tc.textconv", value: "sed s/^/TC:/", attributes: "* diff=tc\n"),
    ]

    /// `p` with two unstaged hunks, `s` with a staged edit, `u.txt` untracked.
    private func makeLab() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("p", numbered(20))
        try repo.write("s", numbered(20))
        try await repo.commitAll("root")
        try repo.write("p", numbered(20, [3: "3 p", 15: "15 p"]))
        try repo.write("s", numbered(20, [2: "2 staged"]))
        try await repo.git(["add", "s"])
        try repo.write("u.txt", "u1\nu2\n")
        return repo
    }

    /// Every parsed read of the lab, as the app makes it.
    private struct Reads: Equatable {
        let staged: [FileDiff]
        let unstaged: [FileDiff]
        let untracked: [FileDiff]
        let sheet: DiscardExpectation
    }

    private func read(_ repo: TestRepo) async throws -> Reads {
        Reads(
            staged: try await backend.workingCopyDiff(at: repo.root, path: "s", staged: true),
            unstaged: try await backend.workingCopyDiff(at: repo.root, path: "p", staged: false),
            untracked: try await backend.workingCopyDiff(at: repo.root, path: "u.txt", staged: false),
            sheet: try await backend.discardExpectation(tracked: ["p", "s"], includingStaged: true, at: repo.root))
    }

    @Test(arguments: formatKeys)
    func everyReadIsWhatGitsDefaultsGive(_ key: ConfigKey) async throws {
        let repo = try await makeLab()
        defer { repo.cleanUp() }
        let defaults = try await read(repo)
        // The baseline is the diff the parser is built for, so an equal read below is a real one.
        #expect(defaults.staged.map(\.displayPath) == ["s"])
        #expect(defaults.unstaged.map(\.displayPath) == ["p"])
        #expect(defaults.unstaged.first?.hunks.count == 2)
        #expect(defaults.untracked.map(\.displayPath) == ["u.txt"])
        #expect(defaults.untracked.first?.kind == .added)
        #expect(defaults.sheet == .diffs(defaults.unstaged + defaults.staged))

        try await key.configure(repo)

        let configured = try await read(repo)
        #expect(configured.staged == defaults.staged, "staged")
        #expect(configured.unstaged == defaults.unstaged, "unstaged")
        #expect(configured.untracked == defaults.untracked, "untracked")
        #expect(configured.sheet == defaults.sheet, "the discard sheet's batched read")
    }

    /// Staging, unstaging and both discards, under the key, checked against git's own bytes.
    @Test(arguments: formatKeys)
    func stagingAndDiscardingRoundTrip(_ key: ConfigKey) async throws {
        let repo = try await makeLab()
        defer { repo.cleanUp() }
        try await key.configure(repo)
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }

        // A hunk staged.
        let unstaged = try await loadDiff(repo, "p")
        try await applySelection(repo, unstaged, direction: .stage, hunks: [try hunkID(unstaged, containing: "15 p")])
        #expect(try await indexText(repo, "p") == numbered(20, [15: "15 p"]))

        // Lines unstaged.
        let staged = try await loadDiff(repo, "s", staged: true)
        try await applySelection(repo, staged, direction: .unstage, lines: changedLineIDs(staged, "2", "2 staged"))
        #expect(try await indexText(repo, "s") == numbered(20))

        // Lines discarded: the hunk left unstaged in `p`.
        let rest = try await loadDiff(repo, "p")
        _ = try await backend.discard(
            try linesRequest(rest, hunks: everyHunkID(rest), lines: changedLineIDs(rest, "3", "3 p")),
            trasher: trasher, at: repo.root)
        #expect(try repo.bytes("p") == Data(numbered(20, [15: "15 p"]).utf8))
        #expect(try await indexText(repo, "p") == numbered(20, [15: "15 p"]))

        // A whole file discarded, through the batched read.
        let expected = try await backend.discardExpectation(tracked: ["s"], includingStaged: false, at: repo.root)
        _ = try await backend.discard(.unstaged(paths: ["s"], expected: expected), trasher: trasher, at: repo.root)
        #expect(try repo.bytes("s") == Data(numbered(20).utf8))
    }

    // MARK: - diff.suppressBlankEmpty

    /// `b` with a blank line between two changed lines of one hunk, unstaged; `c` the same,
    /// staged.
    private func makeBlankLab() async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("b", Self.blank)
        try repo.write("c", Self.blank)
        try await repo.commitAll("root")
        try repo.write("c", Self.blank(line3: "3 c", line5: "5 c"))
        try await repo.git(["add", "c"])
        try repo.write("b", Self.blank(line3: "3 b", line5: "5 b"))
        return repo
    }

    private static let blank = "1\n2\n3\n\n5\n6\n7\n"
    private static func blank(line3 three: String = "3", line5 five: String = "5") -> String {
        "1\n2\n\(three)\n\n\(five)\n6\n7\n"
    }

    @Test func aBlankContextLineWrittenEmptyIsStillContext() async throws {
        let repo = try await makeBlankLab()
        defer { repo.cleanUp() }
        let unstaged = try await backend.workingCopyDiff(at: repo.root, path: "b", staged: false)
        let staged = try await backend.workingCopyDiff(at: repo.root, path: "c", staged: true)
        let sheet = try await backend.discardExpectation(tracked: ["b", "c"], includingStaged: true, at: repo.root)
        #expect(unstaged.first?.hunks.first?.lines.contains { $0.kind == .added && $0.text == "5 b" } == true)

        try await repo.git(["config", "diff.suppressBlankEmpty", "true"])
        // The key is live: git now writes the blank line as an empty one.
        let raw = String(decoding: try await repo.git(["diff", "--", "b"]), as: UTF8.self)
        #expect(raw.contains("+3 b\n\n-5\n"), "\(raw)")

        #expect(try await backend.workingCopyDiff(at: repo.root, path: "b", staged: false) == unstaged)
        #expect(try await backend.workingCopyDiff(at: repo.root, path: "c", staged: true) == staged)
        #expect(try await backend.discardExpectation(tracked: ["b", "c"], includingStaged: true, at: repo.root) == sheet)
    }

    @Test func linesAroundABlankLineRoundTripUnderSuppressBlankEmpty() async throws {
        let repo = try await makeBlankLab()
        defer { repo.cleanUp() }
        try await repo.git(["config", "diff.suppressBlankEmpty", "true"])
        let trasher = try FakeTrasher()
        defer { trasher.cleanUp() }

        // The line after the blank one, staged alone.
        let b = try await loadDiff(repo, "b")
        try await applySelection(repo, b, direction: .stage, hunks: everyHunkID(b), lines: changedLineIDs(b, "5", "5 b"))
        #expect(try await indexText(repo, "b") == Self.blank(line5: "5 b"))

        // The line before it, discarded alone.
        let rest = try await loadDiff(repo, "b")
        _ = try await backend.discard(
            try linesRequest(rest, hunks: everyHunkID(rest), lines: changedLineIDs(rest, "3", "3 b")),
            trasher: trasher, at: repo.root)
        #expect(try repo.bytes("b") == Data(Self.blank(line5: "5 b").utf8))

        // A whole hunk unstaged, then the same hunk discarded.
        let c = try await loadDiff(repo, "c", staged: true)
        try await applySelection(repo, c, direction: .unstage)
        #expect(try await indexText(repo, "c") == Self.blank)
        let worktreeC = try await loadDiff(repo, "c")
        _ = try await backend.discard(
            try linesRequest(worktreeC, hunks: everyHunkID(worktreeC), lines: nil), trasher: trasher, at: repo.root)
        #expect(try repo.bytes("c") == Data(Self.blank.utf8))
    }

    /// `diff-tree` reads the key too (measured), so History and the stash sheet need the same.
    @Test func historyAndTheStashReadABlankLineUnderSuppressBlankEmpty() async throws {
        let repo = try await makeBlankLab()
        defer { repo.cleanUp() }
        try await repo.git(["commit", "-q", "-m", "c"])
        let sha = try await repo.headSha()
        guard case .saved(let stash) = try await backend.stashAll(message: "b", includeUntracked: false, at: repo.root)
        else {
            Issue.record("the stash was not saved")
            return
        }
        let history = try await backend.commitDiff(at: repo.root, sha: sha, path: nil)
        let stashed = try await backend.stashDiff(stash, at: repo.root)
        #expect(history.first?.hunks.first?.lines.contains { $0.text == "5 c" } == true)
        #expect(stashed.first?.hunks.first?.lines.contains { $0.text == "5 b" } == true)

        try await repo.git(["config", "diff.suppressBlankEmpty", "true"])

        #expect(try await backend.commitDiff(at: repo.root, sha: sha, path: nil) == history)
        #expect(try await backend.stashDiff(stash, at: repo.root) == stashed)
    }

    // MARK: - diff.submodule

    /// A gitlink moved back one commit: git's default is the two `Subproject commit` lines;
    /// `log` prints a `Submodule sub …:` log instead and `diff` the submodule's own files.
    @Test(arguments: ["log", "diff"])
    func aGitlinkIsReadInItsShortFormUnderDiffSubmodule(_ value: String) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        let sub = TestRepo(root: repo.root.appendingPathComponent("sub"))
        try FileManager.default.createDirectory(at: sub.root, withIntermediateDirectories: true)
        try await sub.git(["init", "-q", "-b", "main"])
        for text in ["one", "two"] {
            try sub.write("s", text + "\n")
            try await sub.git(["add", "s"])
            try await sub.git(["-c", "user.name=T", "-c", "user.email=t@t", "commit", "-q", "-m", text])
        }
        try await repo.git(["add", "sub"])
        try await repo.git(["commit", "-q", "-m", "sub"])
        try await sub.git(["checkout", "-q", "HEAD~1"])

        let unstaged = try await backend.workingCopyDiff(at: repo.root, path: "sub", staged: false)
        let sheet = try await backend.discardExpectation(tracked: ["sub"], includingStaged: true, at: repo.root)
        #expect(unstaged.map(\.displayPath) == ["sub"])
        #expect(unstaged.first?.hunks.first?.lines.contains { $0.text.hasPrefix("Subproject commit") } == true)

        try await repo.git(["config", "diff.submodule", value])

        #expect(try await backend.workingCopyDiff(at: repo.root, path: "sub", staged: false) == unstaged)
        #expect(try await backend.discardExpectation(tracked: ["sub"], includingStaged: true, at: repo.root) == sheet)
    }
}
