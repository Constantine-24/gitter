import CryptoKit
import Foundation
import Testing

@testable import GitCore

/// `conflictDocument`: the two rebuilds (M 2, M 3, M 26), whole-file classification (M 33)
/// and special names (RF4), on real conflicts.
@Suite struct ConflictReadTests {
    // MARK: - Helpers

    static func conflict(_ repo: TestRepo, _ path: String) async throws -> ConflictedFile {
        let files = try await CLIGitBackend().snapshot(at: repo.root).status.files
        return try #require(files.first { $0.path == path }?.conflict, "\(path) is not conflicted")
    }

    static func document(_ repo: TestRepo, _ path: String) async throws -> ConflictDocument {
        try await CLIGitBackend().conflictDocument(for: try await conflict(repo, path), at: repo.root)
    }

    static func blocks(_ document: ConflictDocument) -> [ConflictBlock]? {
        guard case .blocks(let segments) = document.presentation else { return nil }
        return segments.compactMap { if case .block(let block) = $0 { return block } else { return nil } }
    }

    /// Lines of `data` that open a block at git's size: exactly `size` `<`, then a space or the
    /// end of the line.
    static func openingMarkers(in data: Data, size: Int) -> Int {
        data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).filter { line in
            let run = line.prefix { $0 == UInt8(ascii: "<") }.count
            guard run == size else { return false }
            let rest = line.dropFirst(size)
            return rest.isEmpty || rest.first == UInt8(ascii: " ") || rest.first == UInt8(ascii: "\r")
        }.count
    }

    /// `merge-file --diff3`'s exit code for `path`: its count of blocks (M 2).
    static func mergeFileBlockCount(_ repo: TestRepo, _ path: String) async throws -> Int32 {
        let result = try await CLIGitBackend().runWithEnvironment(
            [
                "merge-file", "--object-id", "--diff-algorithm=histogram", "--diff3", "--marker-size=7", "-L", "ours", "-L", "base",
                "-L", "theirs", ":2:\(path)", ":1:\(path)", ":3:\(path)",
            ], cwd: repo.root, extra: [:], allowedExitCodes: Set(1...127))
        return result.exitCode
    }

    /// Removes `AUTO_MERGE`, as a stop that never wrote one (or a stale one git removed) would
    /// leave it: the comparison then rests on the merge-file rebuild or the stage alone.
    static func dropAutoMerge(_ repo: TestRepo) async throws {
        let url = try await ConflictFixtures.gitPath(repo, "AUTO_MERGE")
        #expect(FileManager.default.fileExists(atPath: url.path), "the stop wrote no AUTO_MERGE to drop")
        try FileManager.default.removeItem(at: url)
    }

    static func worktree(_ repo: TestRepo, _ path: String) throws -> Data {
        try Data(contentsOf: repo.root.appendingPathComponent(path))
    }

    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Configurations git writes differently (M 2, M 3)

    enum Setting: String, CaseIterable, Sendable {
        case plain, diff3, zdiff3, autocrlf, eolCRLF, smudgeFilter, markerSize9

        var gitMarkerSize: Int { self == .markerSize9 ? 9 : 7 }
        var crlf: Bool { self == .autocrlf || self == .eolCRLF }

        func apply(_ repo: TestRepo) async throws {
            switch self {
            case .plain: break
            case .diff3: try await repo.git(["config", "merge.conflictStyle", "diff3"])
            case .zdiff3: try await repo.git(["config", "merge.conflictStyle", "zdiff3"])
            case .autocrlf: try await repo.git(["config", "core.autocrlf", "true"])
            case .eolCRLF: try repo.write(".gitattributes", "*.txt text eol=crlf\n")
            case .smudgeFilter:
                // A filter that leaves marker lines alone: the case the comparison can be exact
                // for. One that rewrites them is `aFilterThatRewritesMarkerLinesIsNotParsed`.
                try await repo.git(["config", "filter.at.smudge", "sed s/@@/SMUDGED/"])
                try await repo.git(["config", "filter.at.clean", "sed s/SMUDGED/@@/"])
                try repo.write(".gitattributes", "f.txt filter=at\n")
            case .markerSize9: try repo.write(".gitattributes", "f.txt conflict-marker-size=9\n")
            }
        }
    }

    /// With `AUTO_MERGE` (what the merge machinery wrote) and without it, where only the
    /// merge-file rebuild can say "matches".
    @Test(arguments: Setting.allCases, [true, false])
    func aTextConflictIsTwoBlocksThatMatchWhatGitWrote(setting: Setting, autoMerge: Bool) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified, prepare: setting.apply)
        defer { repo.cleanUp() }
        if !autoMerge { try await Self.dropAutoMerge(repo) }
        let written = try Self.worktree(repo, "f.txt")

        let document = try await Self.document(repo, "f.txt")

        let blocks = try #require(Self.blocks(document), "\(document.presentation)")
        #expect(document.matchesGitsConflict)
        // Ruling 2: the parse rebuild's blocks = merge-file's exit code = git's own markers.
        #expect(blocks.count == 2)
        #expect(Int32(blocks.count) == (try await Self.mergeFileBlockCount(repo, "f.txt")))
        #expect(blocks.count == Self.openingMarkers(in: written, size: setting.gitMarkerSize))
        // Worktree form, byte-exact.
        let eol = setting.crlf ? "\r\n" : "\n"
        #expect(blocks[0] == ConflictBlock(
            ours: Data("two OURS\(eol)".utf8), base: Data("two\(eol)".utf8), theirs: Data("two THEIRS\(eol)".utf8)))
        #expect(blocks[1] == ConflictBlock(
            ours: Data("nine OURS\(eol)".utf8), base: Data("nine\(eol)".utf8), theirs: Data("nine THEIRS\(eol)".utf8)))
        if setting == .smudgeFilter {
            guard case .blocks(let segments) = document.presentation, case .common(let middle) = segments[2]
            else { Issue.record("no common text between the blocks"); return }
            #expect(String(decoding: middle, as: UTF8.self).contains("five SMUDGED"))
        }
        #expect(document.worktree == written)
        #expect(document.snapshot.worktreeHash == Self.sha256(written))
        #expect(document.snapshot.file == (try await Self.conflict(repo, "f.txt")))
    }

    @Test(arguments: Setting.allCases, [true, false])
    func anAppendedLineIsNotWhatGitWrote(setting: Setting, autoMerge: Bool) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified, prepare: setting.apply)
        defer { repo.cleanUp() }
        if !autoMerge { try await Self.dropAutoMerge(repo) }
        var edited = try Self.worktree(repo, "f.txt")
        edited.append(Data("appended\(setting.crlf ? "\r\n" : "\n")".utf8))
        try edited.write(to: repo.root.appendingPathComponent("f.txt"))

        let document = try await Self.document(repo, "f.txt")

        #expect(!document.matchesGitsConflict)
        #expect(Self.blocks(document)?.count == 2)
        #expect(document.worktree == edited)
        #expect(document.snapshot.worktreeHash == Self.sha256(edited))
    }

    /// The non-vacuous pair, with and without `AUTO_MERGE`: untouched → true; one content line
    /// edited → false.
    @Test(arguments: [true, false])
    func anEditedContentLineIsNotWhatGitWrote(autoMerge: Bool) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        if !autoMerge { try await Self.dropAutoMerge(repo) }
        #expect(try await Self.document(repo, "f.txt").matchesGitsConflict)
        let written = String(decoding: try Self.worktree(repo, "f.txt"), as: UTF8.self)
        let edited = written.replacingOccurrences(of: "four\n", with: "four EDITED\n")
        #expect(edited != written)
        try Data(edited.utf8).write(to: repo.root.appendingPathComponent("f.txt"))

        #expect(!(try await Self.document(repo, "f.txt").matchesGitsConflict))
    }

    @Test func onlyRelabellingAMarkerLineStillMatches() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let written = String(decoding: try Self.worktree(repo, "f.txt"), as: UTF8.self)
        let relabelled = written.replacingOccurrences(of: "<<<<<<< HEAD", with: "<<<<<<< my label")
        #expect(relabelled != written)
        try Data(relabelled.utf8).write(to: repo.root.appendingPathComponent("f.txt"))

        #expect(try await Self.document(repo, "f.txt").matchesGitsConflict)
    }

    @Test func aResolvedBlockIsNotWhatGitWrote() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        let written = String(decoding: try Self.worktree(repo, "f.txt"), as: UTF8.self)
        let resolved = written.replacingOccurrences(
            of: "<<<<<<< HEAD\ntwo OURS\n=======\ntwo THEIRS\n>>>>>>> theirs\n", with: "two OURS\n")
        #expect(resolved != written)
        try Data(resolved.utf8).write(to: repo.root.appendingPathComponent("f.txt"))

        #expect(!(try await Self.document(repo, "f.txt").matchesGitsConflict))
    }

    @Test func aMissingWorktreeFileHasNoHashAndDoesNotMatch() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified)
        defer { repo.cleanUp() }
        try FileManager.default.removeItem(at: repo.root.appendingPathComponent("f.txt"))

        let document = try await Self.document(repo, "f.txt")

        #expect(document.worktree == nil)
        #expect(document.snapshot.worktreeHash == nil)
        #expect(!document.matchesGitsConflict)
        #expect(Self.blocks(document)?.count == 2)
    }

    /// A smudge filter that prefixes every line (M 26's `S:`) rewrites the markers too: nothing
    /// can be split. Whether the file is what git wrote is still known — `AUTO_MERGE` holds
    /// exactly that, and the untouched file equals it. Without `AUTO_MERGE` the merge-file
    /// rebuild cannot tell (its `S:<<<<<<< ours` keeps a label no rule strips), and says false.
    @Test(arguments: [true, false])
    func aFilterThatRewritesMarkerLinesIsNotParsed(autoMerge: Bool) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified) { repo in
            try await repo.git(["config", "filter.pfx.smudge", "sed s/^/S:/"])
            try await repo.git(["config", "filter.pfx.clean", "sed s/^S://"])
            try repo.write(".gitattributes", "f.txt filter=pfx\n")
        }
        defer { repo.cleanUp() }
        #expect(String(decoding: try Self.worktree(repo, "f.txt"), as: UTF8.self).contains("S:<<<<<<< HEAD"))
        if !autoMerge { try await Self.dropAutoMerge(repo) }

        let document = try await Self.document(repo, "f.txt")

        #expect(document.presentation == .wholeFile(reason: .unparsable))
        #expect(document.matchesGitsConflict == autoMerge)
    }

    /// merge-file joins two conflicts separated only by lines with no letter or digit (closing
    /// braces) into one block; git's merge keeps them apart (merge-file runs xdiff at
    /// `ZEALOUS_ALNUM`, a merge at `ZEALOUS`; histogram does not change it, measured). So in
    /// the default style only `AUTO_MERGE` can say the untouched file matches; without it the
    /// answer is the safe "changed". diff3 coalesces neither way, and the parse rebuild (always
    /// diff3) has both blocks.
    @Test(arguments: [false, true], [true, false])
    func conflictsSeparatedOnlyByPunctuation(diff3: Bool, autoMerge: Bool) async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        if diff3 { try await repo.git(["config", "merge.conflictStyle", "diff3"]) }
        try repo.write("f.txt", "a\n}\n}\n}\n}\n}\nb\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "theirs"])
        try repo.write("f.txt", "aT\n}\n}\n}\n}\n}\nbT\n")
        try await repo.commitAll("theirs")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", "aO\n}\n}\n}\n}\n}\nbO\n")
        try await repo.commitAll("ours")
        try await repo.git(["merge", "--no-edit", "theirs"], allowedExitCodes: [1])
        try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")
        #expect(Self.openingMarkers(in: try Self.worktree(repo, "f.txt"), size: 7) == 2)
        if !autoMerge { try await Self.dropAutoMerge(repo) }

        let document = try await Self.document(repo, "f.txt")

        #expect(document.matchesGitsConflict == (autoMerge || diff3))
        #expect(Self.blocks(document)?.count == 2)
    }

    // MARK: - Who started it (M 6, M 26)

    @Test(arguments: ConflictOperation.allCases)
    func everyOperationsLabelsMatch(operation: ConflictOperation) async throws {
        let repo = try await ConflictFixtures.stopped(operation, kind: .bothModified)
        defer { repo.cleanUp() }

        let document = try await Self.document(repo, "f.txt")

        #expect(document.matchesGitsConflict)
        #expect(Self.blocks(document)?.count == 2)
    }

    @Test(arguments: ["x~1", "@{-1}", "-m custom"])
    func aMergeStartedWithAnyArgumentMatches(started: String) async throws {
        let repo = try await ConflictFixtures.history(.bothModified)
        defer { repo.cleanUp() }
        try await repo.git(["switch", "-q", "theirs"])
        try repo.write("later.txt", "later\n")
        try await repo.commitAll("later")
        try await repo.git(["branch", "x"])
        try await repo.git(["switch", "-q", "main"])
        switch started {
        case "x~1": try await repo.git(["merge", "--no-edit", "x~1"], allowedExitCodes: [1])
        case "@{-1}":
            try await repo.git(["switch", "-q", "x"])
            try await repo.git(["switch", "-q", "main"])
            try await repo.git(["merge", "--no-edit", "@{-1}"], allowedExitCodes: [1])
        default: try await repo.git(["merge", "-m", "custom message", "x"], allowedExitCodes: [1])
        }
        try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")
        let written = String(decoding: try Self.worktree(repo, "f.txt"), as: UTF8.self)
        // The label git wrote is not a name Gitter could have guessed.
        #expect(!written.contains(">>>>>>> theirs\n"), "\(written)")

        #expect(try await Self.document(repo, "f.txt").matchesGitsConflict)
    }

    /// rerere replays a recorded resolution: still `u UU`, no markers — not what the stages
    /// rebuild to (M 4), and reported as such.
    @Test func aRerereReplayDoesNotMatch() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified) { repo in
            try await repo.git(["config", "rerere.enabled", "true"])
        }
        defer { repo.cleanUp() }
        try repo.write("f.txt", "resolved\n")
        try await repo.git(["add", "f.txt"])
        try await repo.git(["commit", "-q", "--no-edit"])
        try await repo.git(["reset", "-q", "--hard", "HEAD~1"])
        try await repo.git(["merge", "--no-edit", "theirs"], allowedExitCodes: [1])
        try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")
        #expect(try Self.worktree(repo, "f.txt") == Data("resolved\n".utf8))

        let document = try await Self.document(repo, "f.txt")

        #expect(!document.matchesGitsConflict)
        #expect(Self.blocks(document)?.count == 2)
    }

    // MARK: - Whole file (M 1, M 33)

    static let wholeFileCases: [(ConflictFixtureKind, String, WholeFileReason)] = [
        (.binary, "bin.dat", .binary),
        (.symlink, "link", .symlink),
        (.modeOnly, "mode.sh", .modeOnly),
        (.deletedByUs, "du.txt", .deletion),
        (.deletedByThem, "ud.txt", .deletion),
        (.renameDelete, "rd-ours.txt", .deletion),
        (.renameRename, "rr.txt", .deletion),
        (.renameRename, "rr-ours.txt", .oneSided),
        (.renameRename, "rr-theirs.txt", .oneSided),
        (.mergeBinary, "mb.txt", .mergeAttribute("binary")),
    ]

    /// Each whole-file kind matches what git left — `AUTO_MERGE`'s entry, or without it the
    /// stage git kept (ours for binary, symlink, mode, `merge=binary`, UD, AU; theirs for DU
    /// and UA; no file for DD) — and stops matching once the path is touched.
    @Test(arguments: wholeFileCases.flatMap { c in [true, false].map { (c.0, c.1, c.2, $0) } })
    func aPathGitDidNotDrawBlocksInIsWholeFile(
        kind: ConflictFixtureKind, path: String, reason: WholeFileReason, autoMerge: Bool
    ) async throws {
        let repo = try await ConflictFixtures.merge(kind: kind)
        defer { repo.cleanUp() }
        if !autoMerge { try await Self.dropAutoMerge(repo) }

        let document = try await Self.document(repo, path)

        #expect(document.presentation == .wholeFile(reason: reason))
        #expect(document.matchesGitsConflict)

        let url = repo.root.appendingPathComponent(path)
        if kind == .symlink {
            try FileManager.default.removeItem(at: url)
            try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: "elsewhere")
        } else {
            try? FileManager.default.removeItem(at: url)
            try Data("touched\n".utf8).write(to: url)
        }
        #expect(!(try await Self.document(repo, path).matchesGitsConflict), "\(path) after a touch")
    }

    /// `-merge` keeps ours like `merge=binary` (M 33).
    @Test(arguments: [true, false])
    func mergeUnsetIsWholeFile(autoMerge: Bool) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified) { repo in
            try repo.write(".gitattributes", "f.txt -merge\n")
        }
        defer { repo.cleanUp() }
        if !autoMerge { try await Self.dropAutoMerge(repo) }

        let document = try await Self.document(repo, "f.txt")

        #expect(document.presentation == .wholeFile(reason: .mergeAttribute("unset")))
        #expect(document.matchesGitsConflict)
    }

    /// A driver of the user's wrote its own bytes (M 3): nothing to rebuild or split, and only
    /// `AUTO_MERGE` knows what those bytes were.
    @Test(arguments: [true, false])
    func aCustomMergeDriverIsWholeFile(autoMerge: Bool) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified) { repo in
            try await repo.git(["config", "merge.drv.driver", "printf 'DRIVER OUTPUT\\n' > %A; exit 1"])
            try repo.write(".gitattributes", "f.txt merge=drv\n")
        }
        defer { repo.cleanUp() }
        #expect(try Self.worktree(repo, "f.txt") == Data("DRIVER OUTPUT\n".utf8))
        if !autoMerge { try await Self.dropAutoMerge(repo) }

        let document = try await Self.document(repo, "f.txt")

        #expect(document.presentation == .wholeFile(reason: .mergeAttribute("drv")))
        #expect(document.matchesGitsConflict == autoMerge)
    }

    /// A driver the attributes name but the configuration does not define: git merges text and
    /// writes markers (measured) — `merge=lfs` after `git lfs track` in a clone without LFS's
    /// config is the everyday case (Ruling 8: plain text).
    @Test(arguments: ["nodriver", "lfs"])
    func anUndefinedMergeDriverIsText(driver: String) async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified) { repo in
            try repo.write(".gitattributes", "f.txt merge=\(driver)\n")
        }
        defer { repo.cleanUp() }
        #expect(Self.openingMarkers(in: try Self.worktree(repo, "f.txt"), size: 7) == 2)

        let document = try await Self.document(repo, "f.txt")

        #expect(Self.blocks(document)?.count == 2)
        #expect(document.matchesGitsConflict)
    }

    /// `merge.default` names the driver for a path whose `merge` attribute is unspecified.
    @Test func mergeDefaultBinaryIsWholeFile() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified) { repo in
            try await repo.git(["config", "merge.default", "binary"])
        }
        defer { repo.cleanUp() }
        #expect(Self.openingMarkers(in: try Self.worktree(repo, "f.txt"), size: 7) == 0)

        let document = try await Self.document(repo, "f.txt")

        #expect(document.presentation == .wholeFile(reason: .mergeAttribute("binary")))
        #expect(document.matchesGitsConflict)
    }

    @Test func mergeDefaultNamingAnUndefinedDriverIsText() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified) { repo in
            try await repo.git(["config", "merge.default", "nodriver"])
        }
        defer { repo.cleanUp() }

        #expect(Self.blocks(try await Self.document(repo, "f.txt"))?.count == 2)
    }

    @Test func mergeDefaultNamingADefinedDriverIsThatDriver() async throws {
        let repo = try await ConflictFixtures.merge(kind: .bothModified) { repo in
            try await repo.git(["config", "merge.default", "drv"])
            try await repo.git(["config", "merge.drv.driver", "printf 'DRIVER OUTPUT\\n' > %A; exit 1"])
        }
        defer { repo.cleanUp() }

        #expect(try await Self.document(repo, "f.txt").presentation == .wholeFile(reason: .mergeAttribute("drv")))
    }

    /// `AUTO_MERGE` is read only while an operation is in progress: a `stash apply` writes one
    /// too (measured) and nothing clears it, so outside an operation it may be stale. Here it
    /// is fresh and equal to the driver's output — and still not consulted.
    @Test func aStashApplysAutoMergeIsNotConsulted() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try await repo.git(["config", "merge.drv.driver", "printf 'DRIVER OUTPUT\\n' > %A; exit 1"])
        try repo.write(".gitattributes", "f.txt merge=drv\n")
        try repo.write("f.txt", ConflictFixtures.baseText)
        try await repo.commitAll("base")
        try repo.write("f.txt", ConflictFixtures.theirsText)
        try await repo.git(["stash", "push", "-q"])
        try repo.write("f.txt", ConflictFixtures.oursText)
        try await repo.commitAll("ours")
        try await repo.git(["stash", "apply", "-q"], allowedExitCodes: [1])
        try await ConflictFixtures.requireUnmerged(repo)
        try await ConflictFixtures.requireGitPath(repo, "AUTO_MERGE")
        #expect(try Self.worktree(repo, "f.txt") == Data("DRIVER OUTPUT\n".utf8))
        let autoMerge = try await repo.git(["cat-file", "blob", "AUTO_MERGE:f.txt"])
        #expect(autoMerge == Data("DRIVER OUTPUT\n".utf8))

        let document = try await Self.document(repo, "f.txt")

        #expect(document.presentation == .wholeFile(reason: .mergeAttribute("drv")))
        #expect(!document.matchesGitsConflict)
    }

    // MARK: - The diff algorithm (fix round 1)

    /// A merge diffs with histogram (ort's default); merge-file's default is myers. On this
    /// input (the reviewer's fuzz, seed 7, repo 13) the myers rebuild of an untouched file
    /// differs from what git wrote, the histogram one does not. Without `AUTO_MERGE`, so the
    /// rebuild alone answers.
    @Test func theRebuildDiffsAsTheMergeDid() async throws {
        let repo = try await Self.conflicted(
            base: "b\n}\n}\nb\n}\n}\na\n", ours: "b\n}\n}\nb\n}\na\n",
            theirs: "c6\n}\n{3\nb\n}\n}\n}\na\n}\n")
        defer { repo.cleanUp() }
        try await Self.dropAutoMerge(repo)
        // Not vacuous: myers really does rebuild something else here.
        let myers = try await CLIGitBackend().runWithEnvironment(
            ["merge-file", "--object-id", "--diff-algorithm=myers", "-L", "ours", "-L", "base", "-L", "theirs", ":2:f.txt", ":1:f.txt", ":3:f.txt"],
            cwd: repo.root, extra: [:], allowedExitCodes: Set(1...127))
        let myersText = try await repo.git(["cat-file", "blob", String(decoding: myers.stdout, as: UTF8.self).trimmingCharacters(in: .newlines)])
        let written = try Self.worktree(repo, "f.txt")
        #expect(ConflictParser.withoutLabels(myersText, markerSize: 7) != ConflictParser.withoutLabels(written, markerSize: 7))

        let document = try await Self.document(repo, "f.txt")

        #expect(document.matchesGitsConflict)
        #expect(Self.blocks(document)?.isEmpty == false)
    }

    /// A conflicted path merge-file merges cleanly (git ran with `-X diff-algorithm=myers`; the
    /// histogram rebuild has no conflict): a blocks view with no block would offer nothing to
    /// choose. Whole file instead.
    @Test func aRebuildWithNoBlockIsNotBlocks() async throws {
        let repo = try await Self.conflicted(
            base: "if (y) {\nc\nc\nb\nb\n", ours: "if (y) {\nif (y) {2\nc\nb\n",
            theirs: "if (y) {\nc\nc\nc\nb\nb\n", options: ["-X", "diff-algorithm=myers"])
        defer { repo.cleanUp() }

        let document = try await Self.document(repo, "f.txt")

        #expect(document.presentation == .wholeFile(reason: .unparsable))
        #expect(document.matchesGitsConflict)
    }

    /// The same with stages git could leave behind but merge-file merges under any algorithm:
    /// ours and theirs made the same change (index built by hand).
    @Test func identicalSidesAreNotBlocks() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f.txt", "a\n")
        try await repo.commitAll("base")
        let base = try await repo.revParse(":f.txt")
        try repo.write("f.txt", "b\n")
        try await repo.git(["add", "f.txt"])
        let side = try await repo.revParse(":f.txt")
        try await repo.git(["update-index", "--force-remove", "f.txt"])
        // `--index-info` reads stdin, which the runner closes; a shell gives it a file.
        let info = repo.root.appendingPathComponent(".git/index-info")
        try Data("100644 \(base) 1\tf.txt\n100644 \(side) 2\tf.txt\n100644 \(side) 3\tf.txt\n".utf8).write(to: info)
        _ = try await isolatedRunner().run(
            "/bin/sh", ["-c", "/usr/bin/git update-index --index-info < .git/index-info"], cwd: repo.root)
        #expect(try await Self.conflict(repo, "f.txt").kind == .bothModified)

        #expect(try await Self.document(repo, "f.txt").presentation == .wholeFile(reason: .unparsable))
    }

    /// A merge of one file from the three texts given, stopped with its conflict.
    static func conflicted(base: String, ours: String, theirs: String, options: [String] = []) async throws -> TestRepo {
        let repo = try await TestRepo.makeEmpty()
        try repo.write("f.txt", base)
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "theirs"])
        try repo.write("f.txt", theirs)
        try await repo.commitAll("theirs")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", ours)
        try await repo.commitAll("ours")
        try await repo.git(["merge", "--no-edit"] + options + ["theirs"], allowedExitCodes: [1])
        try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")
        return repo
    }

    @Test func aSubmoduleIsItsOwnPresentation() async throws {
        let repo = try await ConflictFixtures.merge(kind: .submodule)
        defer { repo.cleanUp() }

        let document = try await Self.document(repo, "sub")

        #expect(document.presentation == .submodule)
        #expect(!document.matchesGitsConflict)
    }

    /// add/add has no stage 1: the base is the empty blob, an empty base section. Against an
    /// empty base diff3 lifts nothing out, so the whole file is the one block (git's default
    /// style draws `one` and `three` outside it, which the comparison does not mind).
    @Test(arguments: [ConflictOperation.merge, .rebase])
    func anAddAddConflictIsBlocksWithAnEmptyBase(operation: ConflictOperation) async throws {
        let repo = try await ConflictFixtures.stopped(operation, kind: .bothAdded)
        defer { repo.cleanUp() }

        let document = try await Self.document(repo, "aa.txt")

        #expect(Self.blocks(document) == [
            ConflictBlock(ours: Data("one\nOURS\nthree\n".utf8), base: Data(), theirs: Data("one\nTHEIRS\nthree\n".utf8))
        ])
        #expect(document.matchesGitsConflict)
    }

    @Test func aStashApplyConflictIsReadLikeAnyOther() async throws {
        let repo = try await ConflictFixtures.stashApplyConflict()
        defer { repo.cleanUp() }

        let document = try await Self.document(repo, "f.txt")

        #expect(Self.blocks(document)?.count == 2)
        #expect(document.matchesGitsConflict)
    }

    /// Marker-like content lines in the stages (RF1): git's own file is ambiguous (M 5), the
    /// chooser's blocks are not — the parse rebuild is sized past them.
    @Test func markerLikeContentIsReadAsContent() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write("f.txt", "top\nx\nmiddle\nm2\nm3\nm4\nm5\ny\nbottom\n")
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "theirs"])
        try repo.write("f.txt", "top\n=======\nT\n>>>>>>> fake\nmiddle\nm2\nm3\nm4\nm5\n|||||||\nbottom\n")
        try await repo.commitAll("theirs")
        try await repo.git(["switch", "-q", "main"])
        try repo.write("f.txt", "top\n<<<<<<< fake\nO\n=======\nmiddle\nm2\nm3\nm4\nm5\n<<<<<<<<\nbottom\n")
        try await repo.commitAll("ours")
        try await repo.git(["merge", "--no-edit", "theirs"], allowedExitCodes: [1])
        try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")

        let document = try await Self.document(repo, "f.txt")

        #expect(document.matchesGitsConflict)
        #expect(Self.blocks(document) == [
            ConflictBlock(
                ours: Data("<<<<<<< fake\nO\n=======\n".utf8), base: Data("x\n".utf8),
                theirs: Data("=======\nT\n>>>>>>> fake\n".utf8)),
            ConflictBlock(ours: Data("<<<<<<<<\n".utf8), base: Data("y\n".utf8), theirs: Data("|||||||\n".utf8)),
        ])
    }

    // MARK: - Names (RF4)

    static let specialNames = ["a*.txt", "a1.txt", "[x].txt", "x.txt", "-lead.txt", ":colon.txt", "sp ace.txt", "ünï.txt", "tab\there.txt"]

    /// Every name conflicts with lines of its own, and two carry `conflict-marker-size=9` (so a
    /// `check-attr` that read another name would rebuild at 7 and not match).
    @Test func eachSpecialNameReadsItsOwnStages() async throws {
        let repo = try await TestRepo.makeEmpty()
        defer { repo.cleanUp() }
        try repo.write(".gitattributes", ":colon.txt conflict-marker-size=9\n-lead.txt conflict-marker-size=9\n")
        for name in Self.specialNames { try repo.write(name, "a\nb\nc\n") }
        try await repo.commitAll("base")
        try await repo.git(["switch", "-q", "-c", "theirs"])
        for name in Self.specialNames { try repo.write(name, "a\nb THEIRS \(name)\nc\n") }
        try await repo.commitAll("theirs")
        try await repo.git(["switch", "-q", "main"])
        for name in Self.specialNames { try repo.write(name, "a\nb OURS \(name)\nc\n") }
        try await repo.commitAll("ours")
        try await repo.git(["merge", "--no-edit", "theirs"], allowedExitCodes: [1])
        try await ConflictFixtures.requireStopped(repo, marker: "MERGE_HEAD")
        #expect(Self.openingMarkers(in: try Self.worktree(repo, ":colon.txt"), size: 9) == 1)

        for name in Self.specialNames {
            let document = try await Self.document(repo, name)
            #expect(Self.blocks(document) == [
                ConflictBlock(
                    ours: Data("b OURS \(name)\n".utf8), base: Data("b\n".utf8),
                    theirs: Data("b THEIRS \(name)\n".utf8))
            ], "\(name)")
            #expect(document.matchesGitsConflict, "\(name)")
        }
    }

    // MARK: - A read writes nothing

    @Test(arguments: ConflictFixtureKind.allCases)
    func readingLeavesTheRepositoryAlone(kind: ConflictFixtureKind) async throws {
        let repo = try await ConflictFixtures.rebase(kind: kind)
        defer { repo.cleanUp() }
        let repoState = try await RepoState.capture(repo)
        let operationState = try await OperationState.capture(repo)
        let worktree = worktreeSnapshot(repo)
        #expect(operationState.fingerprint["REBASE_HEAD"] != nil)
        #expect(!repoState.index.isEmpty)

        for path in kind.unmergedPaths {
            _ = try await Self.document(repo, path)
        }

        try await assertRepoUnchanged(repo, since: repoState, worktree: worktree)
        try await assertOperationUnchanged(repo, since: operationState)
    }
}
