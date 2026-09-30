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
        // merge-file ends every side of a block with a line terminator (Ruling 9, measured): in
        // a block that ends the file, a stage whose last line has none looks as if it had one.
        // The file then ends as the last side written ends in its stage.
        if case .block(let block)? = segments.last, let choice = choices.last,
            let last = Self.lastSideWritten(block, choice), !last.bytes.isEmpty
        {
            let stage = try await stageText(last.stage, of: path, at: root)
            bytes.removeLast(Self.addedTerminator(side: last.bytes, stage: stage))
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
        let worktree = Self.conflictWorktree(of: path, at: root)?.bytes ?? Data()
        // `diff --check` is blind under `-diff` or a diff driver with `binary=true` (measured,
        // fix round 2: no output, exit 0, the markers still there), so the worktree is also
        // scanned for git's opening marker at the path's size, and the larger count wins. The
        // scan also counts a content line that is exactly such a marker (M 5), which git's
        // check skips: a refusal `allowingMarkers` overrides, never a marker staged.
        let scanned = Self.openingMarkers(
            in: worktree, markerSize: try await conflictAttributes(of: path, at: root).markerSize)
        // Fail closed: a report no record could be read from still means markers.
        guard let lines = Self.leftoverMarkerLines(in: data, path: path) else { return max(scanned, 1) }
        guard !lines.isEmpty else { return scanned }
        // A block is its opening line. The numbers are of the text git checked — the worktree
        // cleaned, which has the worktree's lines; a filter that rewrites line starts leaves
        // no `<` to see, and then git's finding is still one block at least.
        let text = worktree.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false)
        let opening = lines.count { n in n >= 1 && n <= text.count && text[n - 1].first == UInt8(ascii: "<") }
        return max(opening, 1, scanned)
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
        try Self.refuseChangedPathType(path, at: root)
        guard try await canReopen(path, at: root) else { throw ConflictError.notAvailable(path) }
        // `restore --merge` replaces the resolution in the index and the worktree without a
        // trace (M 11): both are filed first, always.
        let recorded = try await StashRecord.record(
            paths: [path], message: Self.reopenedByGitter + path, backend: self, at: root)
        _ = try await run(["restore", "--no-recurse-submodules", "--merge", "--", literalPathspec(path)], cwd: root)
        return ConflictReceipt(path: path, recorded: recorded)
    }

    /// The line numbers of `diff --check`'s `<path>:<n>: leftover conflict marker` records,
    /// read over the whole output: git prints the name raw (measured: not quoted, a newline in
    /// it included), so a record is `path`, `:`, digits and the message, starting at the output's
    /// start or after a newline. nil when the output names a leftover marker more often than
    /// records could be read — the caller then counts markers anyway. Whitespace errors (the
    /// same exit code) are neither.
    static func leftoverMarkerLines(in output: Data, path: String) -> [Int]? {
        let bytes = [UInt8](output)
        let prefix = Array((path + ":").utf8)
        let suffix = Array(": leftover conflict marker\n".utf8)
        let newline = UInt8(ascii: "\n")
        var lines: [Int] = []
        var index = 0
        while index < bytes.count {
            if index == 0 || bytes[index - 1] == newline, bytes[index...].starts(with: prefix) {
                var end = index + prefix.count
                var number = 0
                while end < bytes.count, (UInt8(ascii: "0")...UInt8(ascii: "9")).contains(bytes[end]), number < 1 << 40 {
                    number = number * 10 + Int(bytes[end] - UInt8(ascii: "0"))
                    end += 1
                }
                if end > index + prefix.count, bytes[end...].starts(with: suffix) {
                    lines.append(number)
                    index = end + suffix.count
                    continue
                }
            }
            index += 1
        }
        let mentioned = Self.occurrences(of: Array(": leftover conflict marker".utf8), in: bytes)
        return lines.count < mentioned ? nil : lines
    }

    /// Lines of `text` that open a conflict block as git writes one at `markerSize`: exactly
    /// that many `<`, then a space, or the end of the line (`\r\n` or `\n`, or the end of text).
    static func openingMarkers(in text: Data, markerSize: Int) -> Int {
        let less = UInt8(ascii: "<")
        return text.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false).count { line in
            let run = line.prefix { $0 == less }.count
            guard run == markerSize else { return false }
            let rest = line.dropFirst(run)
            return rest.isEmpty || rest.first == UInt8(ascii: " ") || rest.elementsEqual([UInt8(ascii: "\r")])
        }
    }

    private static func occurrences(of needle: [UInt8], in bytes: [UInt8]) -> Int {
        guard !needle.isEmpty, bytes.count >= needle.count else { return 0 }
        var count = 0
        var index = 0
        while index <= bytes.count - needle.count {
            if bytes[index..<(index + needle.count)].elementsEqual(needle) {
                count += 1
                index += needle.count
            } else {
                index += 1
            }
        }
        return count
    }

    // MARK: - Steps

    /// The document of `snapshot`'s path as it is now. `.notAvailable` for a submodule, then
    /// `.pathTypeChanged` (see `refuseChangedPathType`), then `.changedSinceShown` when its
    /// stages or its worktree hash are not the snapshot's (a stage-0 entry — staged, or the
    /// operation aborted — included).
    private func currentDocument(_ snapshot: ConflictSnapshot, at root: URL) async throws -> ConflictDocument {
        let file = snapshot.file
        // A gitlink's path is a directory by nature; no write is offered for it at all.
        if file.isSubmodule { throw ConflictError.notAvailable(file.path) }
        try Self.refuseChangedPathType(file.path, at: root)
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

    /// Throws `.pathTypeChanged` unless `path` is a regular file, a symlink or nothing, under
    /// leading components that are directories or nothing. Measured (fix round 1):
    /// `restore --ours|--theirs` over a directory standing at the path deletes the untracked
    /// files in it, and under a leading component that is now a file replaces that file with a
    /// directory — both exit 0; `conflictWorktree` reads either as "no file", so nothing would
    /// be recorded, and the record refuses a type-changed path anyway.
    static func refuseChangedPathType(_ path: String, at root: URL) throws {
        let components = path.split(separator: "/", omittingEmptySubsequences: true)
        var url = root
        for (index, component) in components.enumerated() {
            url = url.appendingPathComponent(String(component))
            var info = stat()
            guard lstat(url.path, &info) == 0 else {
                // Nothing here, and so nothing below: safe. Anything unreadable is not.
                if errno == ENOENT { return }
                throw ConflictError.pathTypeChanged(path)
            }
            let type = info.st_mode & S_IFMT
            let isLast = index == components.count - 1
            guard isLast ? (type == S_IFREG || type == S_IFLNK) : type == S_IFDIR else {
                throw ConflictError.pathTypeChanged(path)
            }
        }
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

    /// The stage (2 or 3) and bytes of the side `choice` writes last, skipping an empty one;
    /// nil when neither side has bytes.
    static func lastSideWritten(_ block: ConflictBlock, _ choice: BlockChoice) -> (stage: Int, bytes: Data)? {
        let ours = (stage: 2, bytes: block.ours), theirs = (stage: 3, bytes: block.theirs)
        let order: [(stage: Int, bytes: Data)]
        switch choice {
        case .ours: order = [ours]
        case .theirs: order = [theirs]
        case .oursThenTheirs: order = [theirs, ours]
        case .theirsThenOurs: order = [ours, theirs]
        }
        return order.first { !$0.bytes.isEmpty }
    }

    /// How many bytes at the end of `side` — a block side that ends the file — merge-file
    /// added, told from the stage it came from (worktree form): none when the stage ends in
    /// `\n`; else 1 when the stage ends with `side` less its last `\n`, 2 when it ends with
    /// `side` less a final `\r\n`. merge-file adds `\r\n` only in a file whose lines are CRLF, and
    /// a lone `\n` otherwise — after a last line ending in `\r` too (fix round 2, measured) — so
    /// the stage decides, never the bytes alone. Anything else: none.
    static func addedTerminator(side: Data, stage: Data) -> Int {
        func stageEnds(with tail: Data) -> Bool {
            stage.count >= tail.count && stage.suffix(tail.count).elementsEqual(tail)
        }
        guard stage.last != UInt8(ascii: "\n"), side.last == UInt8(ascii: "\n") else { return 0 }
        if stageEnds(with: side.dropLast(1)) { return 1 }
        if side.dropLast().last == UInt8(ascii: "\r"), stageEnds(with: side.dropLast(2)) { return 2 }
        return 0
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
