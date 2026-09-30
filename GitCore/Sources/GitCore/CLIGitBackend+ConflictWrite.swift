import Darwin
import Foundation

/// Writing a resolution (M 7–M 11, M 27, M 28). See `GitConflictBackend` for the contract;
/// this file is about how git is asked.
///
/// Every write starts with `currentDocument`: the path's index entries and worktree hash
/// against the snapshot, then the document read again, so the recording decision
/// (`matchesGitsConflict`) is the repository's as it is now, not as it was shown. Every path
/// goes to git as one `:(literal)` pathspec, and no vector names more than that one path:
/// `restore --ours|--theirs` deletes a file whose stage is missing and discards an unstaged
/// change on a path that is not conflicted (M 27), so it is only ever given the one path this
/// file has just checked.
extension CLIGitBackend {
    /// The message of the entry filed before bytes git did not write are replaced.
    static let replacedByGitter = "Replaced by Gitter: "
    /// The message of the entry filed before a resolution is reopened.
    static let reopenedByGitter = "Reopened by Gitter: "

    public func resolve(
        _ snapshot: ConflictSnapshot, choices: [BlockChoice], recordIfEdited: Bool, at root: URL
    ) async throws -> ConflictReceipt {
        let path = snapshot.file.path
        let document = try await currentDocument(snapshot, at: root)
        guard case .blocks(let segments) = document.presentation else { throw ConflictError.notAvailable(path) }
        let blocks = segments.count { if case .block = $0 { true } else { false } }
        guard choices.count == blocks else { throw ConflictError.choicesDoNotMatch(path) }

        let recorded = try await recordUnlessWrittenByGit(document, recordIfEdited: recordIfEdited, at: root)
        // The parse rebuild's text is in worktree form (`cat-file --filters`), so the composed
        // bytes are what git would write, and `add` cleans them for the index (M 9 route b).
        var bytes = Data()
        var next = choices.makeIterator()
        for segment in segments {
            switch segment {
            case .common(let text): bytes.append(text)
            case .block(let block): bytes.append(Self.compose(block, next.next()!))
            }
        }
        try Self.writeInPlace(bytes, to: path, executable: snapshot.file.ours?.mode == "100755", at: root)
        _ = try await run(["add", "--", literalPathspec(path)], cwd: root)
        return ConflictReceipt(path: path, recorded: recorded)
    }

    public func take(
        _ side: ConflictSide, _ snapshot: ConflictSnapshot, recordIfEdited: Bool, at root: URL
    ) async throws -> ConflictReceipt {
        let path = snapshot.file.path
        let document = try await currentDocument(snapshot, at: root)
        // `restore` with a missing stage exits 0 and deletes the file (M 27).
        guard (side == .ours ? snapshot.file.ours : snapshot.file.theirs) != nil else {
            throw ConflictError.stageMissing(path, side)
        }
        let recorded = try await recordUnlessWrittenByGit(document, recordIfEdited: recordIfEdited, at: root)
        try await restore(side, path, at: root)
        _ = try await run(["add", "--", literalPathspec(path)], cwd: root)
        return ConflictReceipt(path: path, recorded: recorded)
    }

    public func delete(_ snapshot: ConflictSnapshot, recordIfEdited: Bool, at root: URL) async throws -> ConflictReceipt {
        let path = snapshot.file.path
        let document = try await currentDocument(snapshot, at: root)
        // `rm` of an unmerged file deletes it whatever it holds (M 28): for DU, bytes that are
        // not stage 3's are the user's.
        let recorded = try await recordUnlessWrittenByGit(document, recordIfEdited: recordIfEdited, at: root)
        _ = try await run(["rm", "-q", "--", literalPathspec(path)], cwd: root)
        return ConflictReceipt(path: path, recorded: recorded)
    }

    public func keep(_ snapshot: ConflictSnapshot, recordIfEdited: Bool, at root: URL) async throws -> ConflictReceipt {
        let path = snapshot.file.path
        let document = try await currentDocument(snapshot, at: root)
        var recorded: Stash?
        switch snapshot.file.kind {
        case .deletedByThem:
            // `add` keeps what is there, edits included; with the file gone it would stage a
            // deletion (M 28), so ours is put back first — there are no bytes to lose.
            if document.worktree == nil { try await restore(.ours, path, at: root) }
        case .deletedByUs:
            // git left theirs; anything else is overwritten by `restore --theirs` (M 28).
            if !document.matchesGitsConflict {
                recorded = try await recordUnlessWrittenByGit(document, recordIfEdited: recordIfEdited, at: root)
                try await restore(.theirs, path, at: root)
            }
        default:
            throw ConflictError.notAvailable(path)
        }
        _ = try await run(["add", "--", literalPathspec(path)], cwd: root)
        return ConflictReceipt(path: path, recorded: recorded)
    }

    public func leftoverMarkers(in path: String, at root: URL) async throws -> Int {
        // For an unmerged path, `diff --check` checks the worktree against the stages (a
        // combined diff): every marker line at the path's `conflict-marker-size` that no stage
        // holds is `<path>:<line>: leftover conflict marker` — three lines a block, four with
        // a base — and exits 2 (M 10, measured again in A2 Task 2 with a block resolved by
        // hand, with diff3, and under `color.ui=always`, which does not colour these lines).
        // Whitespace errors share the exit code and are not counted.
        let data = try await run(["diff", "--check", "--", literalPathspec(path)], cwd: root, allowedExitCodes: [2])
        let prefix = path + ":"
        let suffix = ": leftover conflict marker"
        let lines: [Int] = GitLines.split(data).compactMap { line in
            guard line.hasPrefix(prefix), line.hasSuffix(suffix) else { return nil }
            return Int(line.dropFirst(prefix.count).dropLast(suffix.count))
        }
        guard !lines.isEmpty else { return 0 }
        // A block is its opening line. The numbers are of the text git checked — the worktree
        // cleaned, which has the worktree's lines; a filter that rewrites line starts leaves
        // no `<` to see, and then git's finding is still one block at least.
        let worktree = Self.conflictWorktree(of: path, at: root)?.bytes ?? Data()
        let text = worktree.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        let opening = lines.count { n in n >= 1 && n <= text.count && text[n - 1].first == UInt8(ascii: "<") }
        return max(opening, 1)
    }

    public func markResolved(_ snapshot: ConflictSnapshot, allowingMarkers: Bool, at root: URL) async throws {
        let path = snapshot.file.path
        _ = try await currentDocument(snapshot, at: root)
        let left = try await leftoverMarkers(in: path, at: root)
        if left > 0, !allowingMarkers { throw ConflictError.leftoverMarkers(left) }
        _ = try await run(["add", "--", literalPathspec(path)], cwd: root)
    }

    public func reopen(_ path: String, expectingWorktreeHash: String?, at root: URL) async throws -> ConflictReceipt {
        guard Self.conflictWorktree(of: path, at: root).map({ Self.sha256($0.bytes) }) == expectingWorktreeHash else {
            throw ConflictError.changedSinceShown(path)
        }
        guard try await canReopen(path, at: root) else { throw ConflictError.notAvailable(path) }
        // `restore --merge` replaces the resolution in the index and the worktree without a
        // trace (M 11): both are filed first, always.
        let recorded = try await StashRecord.record(
            paths: [path], message: Self.reopenedByGitter + path, backend: self, at: root)
        _ = try await run(["restore", "--no-recurse-submodules", "--merge", "--", literalPathspec(path)], cwd: root)
        return ConflictReceipt(path: path, recorded: recorded)
    }

    // MARK: - Steps

    /// The document of `snapshot`'s path as it is now; `.changedSinceShown` when its stages or
    /// its worktree hash are not the snapshot's (a stage-0 entry — staged, or the operation
    /// aborted — included), `.notAvailable` for a submodule.
    private func currentDocument(_ snapshot: ConflictSnapshot, at root: URL) async throws -> ConflictDocument {
        let file = snapshot.file
        let data = try await run(["ls-files", "-s", "-z", "--", literalPathspec(file.path)], cwd: root)
        var stages: [String: ConflictStage] = [:]
        for entry in Self.indexRecords(data) where entry.path == file.path {
            stages[entry.stage] = ConflictStage(mode: entry.mode, blob: entry.sha)
        }
        guard !stages.isEmpty, stages["0"] == nil, stages["1"] == file.base, stages["2"] == file.ours,
            stages["3"] == file.theirs
        else { throw ConflictError.changedSinceShown(file.path) }
        let document = try await conflictDocument(for: file, at: root)
        guard document.snapshot.worktreeHash == snapshot.worktreeHash else {
            throw ConflictError.changedSinceShown(file.path)
        }
        if case .submodule = document.presentation { throw ConflictError.notAvailable(file.path) }
        return document
    }

    /// Files the worktree bytes as `Replaced by Gitter: <path>` when git did not write them —
    /// or refuses with `.wouldReplaceEdits` unless `recordIfEdited`. A missing file has no bytes
    /// to file.
    private func recordUnlessWrittenByGit(
        _ document: ConflictDocument, recordIfEdited: Bool, at root: URL
    ) async throws -> Stash? {
        let path = document.snapshot.file.path
        guard !document.matchesGitsConflict, document.worktree != nil else { return nil }
        guard recordIfEdited else { throw ConflictError.wouldReplaceEdits(path) }
        return try await StashRecord.record(
            paths: [path], message: Self.replacedByGitter + path, allowingUnmerged: true, backend: self, at: root)
    }

    /// `restore --ours|--theirs` of the one path: the stage in worktree form, its mode, a
    /// symlink as a symlink (M 27). Only for a stage that exists.
    private func restore(_ side: ConflictSide, _ path: String, at root: URL) async throws {
        switch side {
        case .ours: _ = try await run(["restore", "--no-recurse-submodules", "--ours", "--", literalPathspec(path)], cwd: root)
        case .theirs: _ = try await run(["restore", "--no-recurse-submodules", "--theirs", "--", literalPathspec(path)], cwd: root)
        }
    }

    static func compose(_ block: ConflictBlock, _ choice: BlockChoice) -> Data {
        switch choice {
        case .ours: return block.ours
        case .theirs: return block.theirs
        case .oursThenTheirs: return block.ours + block.theirs
        case .theirsThenOurs: return block.theirs + block.ours
        }
    }

    /// Writes `bytes` over the regular file at `path` **in place** — truncate, then write — so
    /// its permissions, the executable bit among them, stay; a temporary file renamed over it
    /// loses the bit and `add` stages 100644 (M 9). A symlink there (already filed, or git's) is
    /// replaced by a file, never written through; a missing file is created, executable when
    /// `executable`.
    static func writeInPlace(_ bytes: Data, to path: String, executable: Bool, at root: URL) throws {
        let url = root.appendingPathComponent(path)
        var info = stat()
        let found = lstat(url.path, &info) == 0
        if found, info.st_mode & S_IFMT == S_IFREG {
            let handle = try FileHandle(forWritingTo: url)
            defer { try? handle.close() }
            try handle.truncate(atOffset: 0)
            try handle.write(contentsOf: bytes)
            return
        }
        if found {
            guard info.st_mode & S_IFMT == S_IFLNK else {
                throw CocoaError(.fileWriteFileExists, userInfo: [NSFilePathErrorKey: url.path])
            }
            try FileManager.default.removeItem(at: url)
        }
        guard
            FileManager.default.createFile(
                atPath: url.path, contents: bytes, attributes: [.posixPermissions: executable ? 0o755 : 0o644])
        else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path]) }
    }
}
