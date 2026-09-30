import CryptoKit
import Foundation

/// Reading a conflict: classification, the two rebuilds and the comparison. See
/// `GitConflictBackend` for the contract; this file is about how git is asked.
///
/// Both rebuilds are `merge-file --object-id` over the index stages (`:2:p`, `:1:p`, `:3:p`),
/// which writes the merged text as a blob and prints its id, then `cat-file --filters
/// --path=p <id>`, which turns that blob into the bytes a checkout of `p` would write — end of
/// line conversion, smudge filter and all (M 3). Fixed labels (`ours`, `base`, `theirs`): the
/// labels git wrote are not recoverable (M 26), and the comparison ignores them.
extension CLIGitBackend: GitConflictBackend {
    public func conflictDocument(for file: ConflictedFile, at root: URL) async throws -> ConflictDocument {
        let worktree = Self.conflictWorktreeBytes(of: file.path, at: root)
        let snapshot = ConflictSnapshot(file: file, worktreeHash: worktree.map(Self.sha256))
        func document(_ presentation: ConflictPresentation, matches: Bool = false) -> ConflictDocument {
            ConflictDocument(
                snapshot: snapshot, presentation: presentation, matchesGitsConflict: matches,
                worktree: worktree)
        }

        if file.isSubmodule { return document(.submodule) }
        if let reason = Self.wholeFileReason(of: file) { return document(.wholeFile(reason: reason)) }
        guard let ours = file.ours else { return document(.wholeFile(reason: .oneSided)) }

        let attributes = try await conflictAttributes(of: file.path, at: root)
        if !Self.textMergeDrivers.contains(attributes.merge) {
            return document(.wholeFile(reason: .mergeAttribute(attributes.merge)))
        }
        // An add/add has no stage 1: git merged against nothing, which is the empty blob. It
        // need not exist in the object store — merge-file knows it (measured, A2 Task 1).
        let base = file.base == nil ? Self.emptyBlob(like: ours.blob) : ":1:\(file.path)"

        // 1. Compare: the user's style (merge-file reads `merge.conflictStyle`, M 2) at git's
        //    marker size (it does not read the attribute, M 3), labels removed on both sides.
        guard
            let compare = try await rebuild(
                file.path, base: base, diff3: false, markerSize: attributes.markerSize, at: root)
        else { return document(.wholeFile(reason: .binary)) }
        let matches = worktree.map {
            ConflictParser.withoutLabels($0, markerSize: attributes.markerSize)
                == ConflictParser.withoutLabels(compare.text, markerSize: attributes.markerSize)
        } ?? false

        // 2. Parse: diff3, sized past every marker-like run in the stages (M 5).
        var stages: [Data] = []
        for (n, stage) in [(1, file.base), (2, file.ours), (3, file.theirs)] where stage != nil {
            stages.append(try await stageText(n, of: file.path, at: root))
        }
        let size = ConflictParser.safeMarkerSize(stages)
        guard let parse = try await rebuild(file.path, base: base, diff3: true, markerSize: size, at: root)
        else { return document(.wholeFile(reason: .binary)) }
        // merge-file's exit code counts the blocks it wrote, up to 127 (measured): a parse that
        // found another number read the text wrongly (a filter rewrote the markers).
        guard let segments = ConflictParser.parse(parse.text, markerSize: size),
            Self.agrees(segments.count { if case .block = $0 { true } else { false } }, with: parse.blocks)
        else { return document(.wholeFile(reason: .unparsable), matches: matches) }
        return document(.blocks(segments), matches: matches)
    }

    // MARK: - Classification

    /// Why a path can only be taken whole, from its record alone; nil when it may have blocks.
    static func wholeFileReason(of file: ConflictedFile) -> WholeFileReason? {
        switch file.kind {
        case .deletedByUs, .deletedByThem, .bothDeleted: return .deletion
        case .addedByUs, .addedByThem: return .oneSided
        case .bothModified, .bothAdded: break
        }
        if file.isSymlink { return .symlink }
        if file.isModeOnly { return .modeOnly }
        return nil
    }

    /// `check-attr merge` values under which git merges text itself and `merge-file` draws the
    /// same blocks. `binary`, `unset` (`-merge`, the `binary` macro), `union` and a driver of
    /// the user's do not (M 33, M 3).
    static let textMergeDrivers: Set<String> = ["unspecified", "set", "text"]

    /// The `merge` attribute's value and the path's conflict marker size (7 unless the
    /// `conflict-marker-size` attribute is a positive number).
    ///
    /// The path is given plain: `check-attr` takes path names, not pathspecs, and looks
    /// `:(literal)f.txt` up as a file of that very name (measured, A2 Task 1). It globs nothing
    /// either, so `a*.txt` and `[x].txt` are asked about themselves.
    private func conflictAttributes(of path: String, at root: URL) async throws -> (merge: String, markerSize: Int) {
        let data = try await run(["check-attr", "-z", "merge", "conflict-marker-size", "--", path], cwd: root)
        // `-z`: `<path> NUL <attribute> NUL <value> NUL` per attribute.
        let fields = [UInt8](data).split(separator: 0, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        var values: [String: String] = [:]
        var index = 0
        while index + 2 < fields.count {
            values[fields[index + 1]] = fields[index + 2]
            index += 3
        }
        let size = values["conflict-marker-size"].flatMap(Int.init).flatMap { $0 > 0 ? $0 : nil } ?? 7
        return (values["merge"] ?? "unspecified", size)
    }

    // MARK: - Rebuilds

    /// One rebuild in worktree form, with the number of blocks merge-file reported (its exit
    /// code, capped at 127); nil when merge-file refused a binary stage (exit 255, M 33).
    private func rebuild(
        _ path: String, base: String, diff3: Bool, markerSize: Int, at root: URL
    ) async throws -> (blocks: Int32, text: Data)? {
        let codes = Set<Int32>(1...127).union([255])
        let result =
            diff3
            ? try await runWithEnvironment(
                ["merge-file", "--object-id", "--diff3", "--marker-size=\(markerSize)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(path)", base, ":3:\(path)"],
                cwd: root, extra: [:], allowedExitCodes: codes)
            : try await runWithEnvironment(
                ["merge-file", "--object-id", "--marker-size=\(markerSize)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(path)", base, ":3:\(path)"],
                cwd: root, extra: [:], allowedExitCodes: codes)
        if result.exitCode == 255 {
            guard result.stderr.contains("Cannot merge binary files") else {
                throw GitError.commandFailed(
                    exitCode: 255, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            }
            return nil
        }
        let oid = String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let text = try await run(["cat-file", "--filters", "--path=\(path)", oid], cwd: root)
        return (result.exitCode, text)
    }

    /// Stage `n` of `path` in worktree form: what `safeMarkerSize` measures, in the same form
    /// as the rebuild it sizes.
    private func stageText(_ n: Int, of path: String, at root: URL) async throws -> Data {
        let stage = ":\(n):\(path)"
        return try await run(["cat-file", "--filters", "--path=\(path)", stage], cwd: root)
    }

    /// The empty blob's id in the repository's hash: SHA-1 (40 hex digits) or SHA-256 (64),
    /// told apart by the length of an id the repository gave.
    static func emptyBlob(like id: String) -> String {
        id.utf8.count == 64
            ? "473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813"
            : "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391"
    }

    /// Whether `found` blocks is what an exit code of `reported` says: equal below 127, and at
    /// least 127 at the cap.
    static func agrees(_ found: Int, with reported: Int32) -> Bool {
        reported < 127 ? found == Int(reported) : found >= 127
    }

    // MARK: - The worktree

    /// The bytes at `path` as git would hash them: a symlink's target path (never followed), a
    /// regular file's content; nil for a missing path, a directory or anything unreadable.
    static func conflictWorktreeBytes(of path: String, at root: URL) -> Data? {
        let url = root.appendingPathComponent(path)
        guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        else { return nil }
        switch type {
        case .typeSymbolicLink:
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlink(url.path, &buffer, buffer.count)
            guard count >= 0 else { return nil }
            return buffer.withUnsafeBytes { Data($0.prefix(count)) }
        case .typeRegular:
            return try? Data(contentsOf: url)
        default:
            return nil
        }
    }

    /// SHA-256, lowercase hex.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
