import CryptoKit
import Foundation

/// Reading a conflict: classification, the two rebuilds and the comparison. See
/// `GitConflictBackend` for the contract; this file is about how git is asked.
///
/// Both rebuilds are `merge-file --object-id --diff-algorithm=histogram` over the index stages
/// (`:2:p`, `:1:p`, `:3:p`), which writes the merged text as a blob and prints its id, then
/// `cat-file --filters --path=p <id>`, which turns that blob into the bytes a checkout of `p`
/// would write — end of line conversion, smudge filter and all (M 3). Histogram because a
/// merge (ort) diffs with it and merge-file's default, myers, draws other blocks for about one
/// conflict in twenty (fix round 1). Fixed labels (`ours`, `base`, `theirs`): the labels git
/// wrote are not recoverable (M 26), and the comparison ignores them.
extension CLIGitBackend: GitConflictBackend {
    public func conflictDocument(for file: ConflictedFile, at root: URL) async throws -> ConflictDocument {
        let worktree = Self.conflictWorktree(of: file.path, at: root)
        let snapshot = ConflictSnapshot(file: file, worktreeHash: worktree.map { Self.sha256($0.bytes) })
        func document(_ presentation: ConflictPresentation, matches: Bool) -> ConflictDocument {
            ConflictDocument(
                snapshot: snapshot, presentation: presentation, matchesGitsConflict: matches,
                worktree: worktree?.bytes)
        }

        if file.isSubmodule { return document(.submodule, matches: false) }
        // What the merge machinery wrote (M 21) — read only while an operation is in progress:
        // a `stash apply` writes one too and nothing removes it (measured, fix round 1).
        let written: AutoMergeEntry =
            try await operationInProgress(at: root) != nil ? try await autoMergeEntry(file.path, at: root) : .unknown
        func wholeFile(_ reason: WholeFileReason, left: LeftInWorktree) async throws -> ConflictDocument {
            var matches = try await isWritten(written, worktree, markerSize: nil, path: file.path, at: root)
            if !matches { matches = try await isLeft(left, worktree, path: file.path, at: root) }
            return document(.wholeFile(reason: reason), matches: matches)
        }

        if let reason = Self.wholeFileReason(of: file) {
            return try await wholeFile(reason, left: Self.leftInWorktree(by: file))
        }
        guard let ours = file.ours else { return try await wholeFile(.oneSided, left: .nothingKnown) }

        let attributes = try await conflictAttributes(of: file.path, at: root)
        if let driver = try await mergeDriver(attributes.merge, at: root) {
            return try await wholeFile(.mergeAttribute(driver.name), left: driver.keepsOurs ? .stage(2) : .nothingKnown)
        }
        // An add/add has no stage 1: git merged against nothing, which is the empty blob. It
        // need not exist in the object store — merge-file knows it (measured, A2 Task 1).
        let base = file.base == nil ? Self.emptyBlob(like: ours.blob) : ":1:\(file.path)"

        // 1. Compare: the user's style (merge-file reads `merge.conflictStyle`, M 2) at git's
        //    marker size (it does not read the attribute, M 3), labels removed on both sides.
        //    `AUTO_MERGE` first: it is what git wrote, where merge-file can still differ
        //    (conflicts separated only by non-alphanumeric lines, a filter that rewrites marker
        //    lines, a driver). Either one equal is enough; an absent `AUTO_MERGE` can only cost
        //    a false "changed". A leftover one (see `GitConflictBackend.conflictDocument`)
        //    matches only a worktree holding that earlier result for this very path.
        guard
            let compare = try await rebuild(
                file.path, base: base, diff3: false, markerSize: attributes.markerSize, at: root)
        else { return try await wholeFile(.binary, left: .stage(2)) }
        let size = attributes.markerSize
        let isWrittenByGit = try await isWritten(written, worktree, markerSize: size, path: file.path, at: root)
        let matches =
            isWrittenByGit
            || worktree.map {
                !$0.isSymlink
                    && ConflictParser.withoutLabels($0.bytes, markerSize: size)
                        == ConflictParser.withoutLabels(compare.text, markerSize: size)
            } ?? false

        // 2. Parse: diff3, sized past every marker-like run in the stages (M 5).
        var stages: [Data] = []
        for (n, stage) in [(1, file.base), (2, file.ours), (3, file.theirs)] where stage != nil {
            stages.append(try await stageText(n, of: file.path, at: root))
        }
        let safe = ConflictParser.safeMarkerSize(stages)
        guard let parse = try await rebuild(file.path, base: base, diff3: true, markerSize: safe, at: root)
        else { return try await wholeFile(.binary, left: .stage(2)) }
        // merge-file's exit code counts the blocks it wrote, up to 127 (measured): a parse that
        // found another number read the text wrongly (a filter rewrote the markers). And a
        // conflicted path whose rebuild has no block at all (git merged with other options,
        // `-X diff-algorithm=myers`) offers nothing to choose.
        guard let segments = ConflictParser.parse(parse.text, markerSize: safe) else {
            return document(.wholeFile(reason: .unparsable), matches: matches)
        }
        let blocks = segments.count { if case .block = $0 { true } else { false } }
        guard blocks > 0, Self.agrees(blocks, with: parse.blocks) else {
            return document(.wholeFile(reason: .unparsable), matches: matches)
        }
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

    /// What git leaves in the worktree for a whole-file path when it wrote no markers (M 1,
    /// measured at merge, rebase, cherry-pick, squash and `rebase --apply` stops in fix round
    /// 1): the path's own stage, no file, or — for a driver's output — nothing a stage can say.
    enum LeftInWorktree { case stage(Int), noFile, nothingKnown }

    /// Ours for a symlink or mode-only add/add, UD (rename/delete included) and AU; theirs for
    /// DU and UA; no file for DD.
    static func leftInWorktree(by file: ConflictedFile) -> LeftInWorktree {
        switch file.kind {
        case .deletedByUs, .addedByThem: return .stage(3)
        case .deletedByThem, .addedByUs, .bothModified, .bothAdded: return .stage(2)
        case .bothDeleted: return .noFile
        }
    }

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

    /// The driver git merged the path with, when it is not the text merge `merge-file` repeats;
    /// nil for text. `keepsOurs`: git's binary driver, which leaves ours' bytes (M 33).
    ///
    /// As git chooses (fix round 1, measured): `-merge` (`unset`) is the binary driver;
    /// `merge` set, or `text`, is text; unspecified means `merge.default`, or text when that is
    /// unset; any other name is a driver the user defines with `merge.<name>.driver` — and
    /// when nobody did (`merge=lfs` in a clone without LFS's config), git merges text and
    /// writes markers, and so is it here (Ruling 8). `binary` and `union` are git's own.
    private func mergeDriver(_ attribute: String, at root: URL) async throws -> (name: String, keepsOurs: Bool)? {
        switch attribute {
        case "set": return nil
        case "unset": return (attribute, true)
        case "unspecified":
            let fallback = try await conflictConfigValue("merge.default", at: root)
            return fallback.isEmpty ? nil : try await namedDriver(fallback, at: root)
        default: return try await namedDriver(attribute, at: root)
        }
    }

    /// A driver by name: one the user defined wins over git's own, as in git.
    private func namedDriver(_ name: String, at root: URL) async throws -> (name: String, keepsOurs: Bool)? {
        if !(try await conflictConfigValue("merge.\(name).driver", at: root)).isEmpty { return (name, false) }
        switch name {
        case "binary": return (name, true)
        case "union": return (name, false)
        default: return nil
        }
    }

    /// One configuration value, or `""` when the key is not set (`--get` exits 1, as it does
    /// for a name no key can have).
    private func conflictConfigValue(_ key: String, at root: URL) async throws -> String {
        let data = try await run(["config", "--get", key], cwd: root, allowedExitCodes: [1])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - What git wrote

    /// The path's entry in `AUTO_MERGE`'s tree. `unknown` when there is no operation or no
    /// `AUTO_MERGE`; `absent` when the tree has no such path — git wrote no file there (DD).
    enum AutoMergeEntry { case unknown, absent, entry(mode: String, oid: String) }

    private func autoMergeEntry(_ path: String, at root: URL) async throws -> AutoMergeEntry {
        let resolved = try await run(["rev-parse", "-q", "--verify", "AUTO_MERGE^{tree}"], cwd: root, allowedExitCodes: [1])
        let tree = String(decoding: resolved, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !tree.isEmpty else { return .unknown }
        // `ls-tree -z`: `<mode> SP <type> SP <oid> TAB <path> NUL`.
        let data = try await run(["ls-tree", "-z", "--full-tree", tree, "--", literalPathspec(path)], cwd: root)
        for record in [UInt8](data).split(separator: 0) {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")),
                Array(record[record.index(after: tab)...]) == Array(path.utf8)
            else { continue }
            let fields = record[..<tab].split(separator: UInt8(ascii: " ")).map { String(decoding: $0, as: UTF8.self) }
            guard fields.count == 3 else { continue }
            return .entry(mode: fields[0], oid: fields[2])
        }
        return .absent
    }

    /// Whether the worktree is `AUTO_MERGE`'s entry: the same symlink target, or the entry's
    /// bytes in worktree form (label-normalised at `markerSize` when given), or no file where
    /// the tree has none.
    private func isWritten(
        _ written: AutoMergeEntry, _ worktree: (bytes: Data, isSymlink: Bool)?, markerSize: Int?,
        path: String, at root: URL
    ) async throws -> Bool {
        switch written {
        case .unknown: return false
        case .absent: return worktree == nil
        case .entry(let mode, let oid):
            guard let worktree else { return false }
            return try await equals(worktree, object: oid, mode: mode, markerSize: markerSize, path: path, at: root)
        }
    }

    /// Whether the worktree is what git leaves for a whole-file path (`leftInWorktree`).
    private func isLeft(
        _ left: LeftInWorktree, _ worktree: (bytes: Data, isSymlink: Bool)?, path: String, at root: URL
    ) async throws -> Bool {
        switch left {
        case .nothingKnown: return false
        case .noFile: return worktree == nil
        case .stage(let n):
            guard let worktree else { return false }
            let modes = try await stageModes(of: path, at: root)
            guard let mode = modes[n] else { return false }
            return try await equals(worktree, object: ":\(n):\(path)", mode: mode, markerSize: nil, path: path, at: root)
        }
    }

    /// A symlink against a 120000 object's raw bytes; a file against a regular object's bytes in
    /// worktree form. Anything else (a gitlink, a type change) is not equal.
    private func equals(
        _ worktree: (bytes: Data, isSymlink: Bool), object: String, mode: String, markerSize: Int?,
        path: String, at root: URL
    ) async throws -> Bool {
        if worktree.isSymlink {
            guard mode == "120000" else { return false }
            return try await run(["cat-file", "blob", object], cwd: root) == worktree.bytes
        }
        guard mode == "100644" || mode == "100755" else { return false }
        let text = try await run(["cat-file", "--filters", "--path=\(path)", object], cwd: root)
        guard let markerSize else { return text == worktree.bytes }
        return ConflictParser.withoutLabels(text, markerSize: markerSize)
            == ConflictParser.withoutLabels(worktree.bytes, markerSize: markerSize)
    }

    /// Stage → mode for `path`'s index entries (`ls-files -s`).
    private func stageModes(of path: String, at root: URL) async throws -> [Int: String] {
        let data = try await run(["ls-files", "-s", "-z", "--", literalPathspec(path)], cwd: root)
        var modes: [Int: String] = [:]
        for record in [UInt8](data).split(separator: 0) {
            guard let tab = record.firstIndex(of: UInt8(ascii: "\t")),
                Array(record[record.index(after: tab)...]) == Array(path.utf8)
            else { continue }
            let fields = record[..<tab].split(separator: UInt8(ascii: " ")).map { String(decoding: $0, as: UTF8.self) }
            if fields.count == 3, let stage = Int(fields[2]) { modes[stage] = fields[0] }
        }
        return modes
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
                ["merge-file", "--object-id", "--diff-algorithm=histogram", "--diff3", "--marker-size=\(markerSize)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(path)", base, ":3:\(path)"],
                cwd: root, extra: [:], allowedExitCodes: codes)
            : try await runWithEnvironment(
                ["merge-file", "--object-id", "--diff-algorithm=histogram", "--marker-size=\(markerSize)", "-L", "ours", "-L", "base", "-L", "theirs", ":2:\(path)", base, ":3:\(path)"],
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
    func stageText(_ n: Int, of path: String, at root: URL) async throws -> Data {
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

    // MARK: - Reopening

    /// See `GitConflictBackend.canReopen`. The resolve-undo record (`ls-files --resolve-undo`,
    /// the format of `ls-files -s`, M 24) outlives commits and a finished rebase, so the
    /// operation is asked first: a reopen after it ended recreates `u UU` with nothing to
    /// commit it into (M 11). Measured (A2 Task 2): `restore --merge` of a path whose record
    /// lacks stage 2 or 3 — a kept or `rm`-resolved deletion — fails with "does not have all
    /// necessary versions"; of a symlink it writes a link whose target is the marker text; of
    /// a binary file it writes ours, as the merge did.
    public func canReopen(_ path: String, at root: URL) async throws -> Bool {
        guard try await operationInProgress(at: root) != nil else { return false }
        let undo = try await run(["ls-files", "--resolve-undo", "-z", "--", literalPathspec(path)], cwd: root)
        var modes: [String: String] = [:]
        for entry in Self.indexRecords(undo) where entry.path == path { modes[entry.stage] = entry.mode }
        guard modes["2"] != nil, modes["3"] != nil,
            modes.values.allSatisfy({ $0 == "100644" || $0 == "100755" })
        else { return false }
        // Resolved, and not by `rm`: a stage-0 entry and no other.
        let index = try await run(["ls-files", "-s", "-z", "--", literalPathspec(path)], cwd: root)
        let stages = Self.indexRecords(index).filter { $0.path == path }.map(\.stage)
        return stages == ["0"]
    }

    // MARK: - The worktree

    /// The bytes at `path` as git would hash them: a symlink's target path (never followed), a
    /// regular file's content; nil for a missing path, a directory or anything unreadable.
    static func conflictWorktree(of path: String, at root: URL) -> (bytes: Data, isSymlink: Bool)? {
        let url = root.appendingPathComponent(path)
        guard let type = try? FileManager.default.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
        else { return nil }
        switch type {
        case .typeSymbolicLink:
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            let count = readlink(url.path, &buffer, buffer.count)
            guard count >= 0 else { return nil }
            return (buffer.withUnsafeBytes { Data($0.prefix(count)) }, true)
        case .typeRegular:
            return (try? Data(contentsOf: url)).map { ($0, false) }
        default:
            return nil
        }
    }

    /// SHA-256, lowercase hex.
    static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}
