import Darwin
import Foundation

/// Discard and its undo. See `GitWorkingCopyBackend.discard` and `undoDiscard` for what each
/// promises, and `DiscardTypes.swift` for the values.
///
/// **Every worktree `git apply` Gitter runs is in this file** (the index one, `--cached`, is
/// `applyToIndex` in `+WorkingCopy.swift`). Never with `--unidiff-zero`: reverse-applied, a
/// pure-addition hunk without context deleted an identical line elsewhere (M 9). A patch with a
/// context-free hunk is refused instead (`needsWholeFile`). `--whitespace=nowarn` on both
/// directions: `apply.whitespace=fix` would silently change the lines it puts back, and
/// `=error` would refuse them (M 9).
///
/// Every git vector is one array literal, optionally `+ paths`, and every `restore` carries
/// `--no-recurse-submodules` (under `submodule.recurse=true`, `restore --worktree -- sub`
/// throws away the work inside a submodule, M A.5).
extension CLIGitBackend {

    // MARK: - What the sheet shows

    public func discardExpectation(tracked paths: [String], includingStaged: Bool, at root: URL) async throws
        -> DiscardExpectation
    {
        var diffs: [FileDiff] = []
        for path in paths {
            if includingStaged {
                diffs += try await workingCopyDiff(at: root, path: path, staged: true)
            }
            // Without an index entry (a staged deletion, a rename's source) there is no
            // unstaged side, and `workingCopyDiff` would read the path as an untracked file.
            if try await !indexPaths([path], at: root).isEmpty {
                diffs += try await workingCopyDiff(at: root, path: path, staged: false)
            }
        }
        return .diffs(diffs)
    }

    public func discardExpectation(untracked paths: [String], at root: URL) async throws -> DiscardExpectation {
        .untracked(paths.compactMap { Self.untrackedItem($0, under: root) })
    }

    /// `path` as `UntrackedItem` describes it, read with `lstat`; nil when nothing is there.
    static func untrackedItem(_ path: String, under root: URL) -> UntrackedItem? {
        let top = root.appendingPathComponent(StashRecord.withoutTrailingSlash(path)).path
        guard let first = lstatInfo(top) else { return nil }
        let isDirectory = first.st_mode & S_IFMT == S_IFDIR
        var size = UInt64(max(first.st_size, 0))
        var latest = modificationDate(first)
        if isDirectory, let enumerator = FileManager.default.enumerator(atPath: top) {
            for case let relative as String in enumerator {
                guard let info = lstatInfo(top + "/" + relative) else { continue }
                size += UInt64(max(info.st_size, 0))
                latest = max(latest, modificationDate(info))
            }
        }
        return UntrackedItem(path: path, isDirectory: isDirectory, size: size, modificationDate: latest)
    }

    private static func lstatInfo(_ path: String) -> stat? {
        var info = stat()
        return lstat(path, &info) == 0 ? info : nil
    }

    private static func modificationDate(_ info: stat) -> Date {
        Date(timeIntervalSince1970: TimeInterval(info.st_mtimespec.tv_sec)
            + TimeInterval(info.st_mtimespec.tv_nsec) / 1_000_000_000)
    }

    /// The expectation `request` is checked against now: the same reads the sheet was built
    /// from (see `DiscardExpectation`).
    private func currentExpectation(of request: DiscardRequest, at root: URL) async throws -> DiscardExpectation {
        switch request {
        case .unstaged(let paths, _): return try await discardExpectation(tracked: paths, includingStaged: false, at: root)
        case .stagedAndUnstaged(let paths, _): return try await discardExpectation(tracked: paths, includingStaged: true, at: root)
        case .lines(let path, _, _, _): return try await discardExpectation(tracked: [path], includingStaged: false, at: root)
        case .untracked(let paths, _): return try await discardExpectation(untracked: paths, at: root)
        }
    }

    // MARK: - Discard

    public func discard(_ request: DiscardRequest, trasher: any Trasher, at root: URL) async throws -> DiscardReceipt {
        guard !request.paths.isEmpty else { throw DiscardRefusal.nothingSelected }
        if let operation = try await operationInProgress(at: root) {
            throw DiscardRefusal.operationInProgress(operation)
        }
        if case .untracked(let paths, let expected) = request {
            return try await discardUntracked(paths, expected: expected, request: request, trasher: trasher, at: root)
        }

        // 1. Guard: the record's own refusals, then what this kind can take.
        let survey = try await Self.discardRefusal {
            try await StashRecord.survey(paths: request.paths, backend: self, at: root)
        }
        let notTracked = survey.paths.filter { path in
            let inIndex = !(survey.entries[path] ?? []).isEmpty
            if case .stagedAndUnstaged = request { return !inIndex && survey.headModes[path] == nil }
            return !inIndex
        }
        if !notTracked.isEmpty { throw DiscardRefusal.notTracked(notTracked) }
        if case .lines(let path, let patch, _, let expected) = request {
            try Self.guardLines(path: path, patch: patch, expected: expected)
        }

        // 2. Stale check.
        let now = try await currentExpectation(of: request, at: root)
        guard now == request.expected else { throw DiscardRefusal.changedSinceShown(request.paths) }
        guard case .diffs(let diffs) = now, !diffs.isEmpty else { throw DiscardRefusal.nothingSelected }

        // 3. Record, before anything is overwritten.
        let record = try await Self.discardRefusal {
            try await StashRecord.record(paths: survey.paths, message: request.recordMessage, backend: self, at: root)
        }
        let receipt = DiscardReceipt(
            request: request, record: record, headAtDiscard: record.parents.first ?? "", trashed: [:])

        // 4. Change.
        do {
            switch request {
            case .unstaged:
                _ = try await run(["restore", "--no-recurse-submodules", "--worktree", "--"] + survey.paths.map(literalPathspec), cwd: root)
            case .stagedAndUnstaged:
                _ = try await run(["restore", "--no-recurse-submodules", "--source=HEAD", "--staged", "--worktree", "--"] + survey.paths.map(literalPathspec), cwd: root)
            case .lines(_, let patch, _, _):
                try await applyToWorktree(patch, reverse: true, at: root)
            case .untracked:
                break
            }
        } catch {
            // `restore` and the worktree `apply` are all or nothing (M 9, A.5), so a failure
            // normally changed nothing — and when the same reads prove that, the record is
            // noise and goes again, by its verified position. Anything else keeps it.
            let unchanged = (try? await currentExpectation(of: request, at: root)) == request.expected
            if unchanged, (try? await dropRecord(record, at: root)) == true { throw error }
            throw DiscardFailure(receipt: receipt, gitsWords: Self.gitsWords(error))
        }
        return receipt
    }

    /// `.untracked`: no record — git has no copy of an untracked file, so the Trash is the copy.
    private func discardUntracked(
        _ paths: [String], expected: DiscardExpectation, request: DiscardRequest, trasher: any Trasher,
        at root: URL
    ) async throws -> DiscardReceipt {
        let nested = paths.filter { StashRecord.isInsideAnotherRepository($0, under: root) }
        if !nested.isEmpty { throw DiscardRefusal.nestedRepositories(nested) }
        // Status must still show each one as untracked (itself, or under an untracked
        // directory): a path git tracks, or ignores, is not what the sheet showed.
        let status = try await stashStatus(at: root)
        let notUntracked = paths.filter { path in
            let bare = StashRecord.withoutTrailingSlash(path)
            return !status.files.contains { file in
                file.isUntracked
                    && (StashRecord.withoutTrailingSlash(file.path) == bare
                        || (file.path.hasSuffix("/") && bare.hasPrefix(file.path)))
            }
        }
        if !notUntracked.isEmpty { throw DiscardRefusal.changedSinceShown(notUntracked) }

        let now = try await discardExpectation(untracked: paths, at: root)
        guard now == expected else { throw DiscardRefusal.changedSinceShown(paths) }
        guard case .untracked(let items) = now, !items.isEmpty else { throw DiscardRefusal.nothingSelected }

        let head = try await headSha(at: root)
        // One at a time, keeping each URL: the Trash may rename an item (M 15), so a failure
        // part-way must say what already went and where.
        var trashed: [String: URL] = [:]
        for path in paths {
            do {
                trashed[path] = try trasher.trash(root.appendingPathComponent(StashRecord.withoutTrailingSlash(path)))
            } catch {
                throw DiscardFailure(
                    receipt: DiscardReceipt(request: request, record: nil, headAtDiscard: head, trashed: trashed),
                    gitsWords: "\(path) could not be moved to the Trash: \(error.localizedDescription)")
            }
        }
        return DiscardReceipt(request: request, record: nil, headAtDiscard: head, trashed: trashed)
    }

    /// `.lines` takes only a plain modification of a text file that is valid UTF-8, shown as
    /// exactly one diff, and a patch made from that diff with no context-free hunk.
    private static func guardLines(path: String, patch: Patch, expected: DiscardExpectation) throws {
        guard case .diffs(let shown) = expected, shown.count == 1, let file = shown.first,
            file.displayPath == path, PatchBuilder.supportsPartialDiscard(file), !patch.hasContextFreeHunk
        else { throw DiscardRefusal.needsWholeFile(path) }
        // A patch from another diff than the one shown is stale by definition.
        guard patch.path == path, patch.oldBlob == file.oldBlob, patch.newBlob == file.newBlob else {
            throw DiscardRefusal.changedSinceShown([path])
        }
    }

    // MARK: - Undo

    public func undoDiscard(_ receipt: DiscardReceipt, trasher: any Trasher, at root: URL) async throws
        -> UndoDiscardOutcome
    {
        if case .untracked = receipt.request {
            return restoreFromTrash(receipt, trasher: trasher, at: root)
        }
        guard let record = receipt.record else {
            throw GitError.commandFailed(exitCode: -1, stderr: "This discard left no record to bring back.")
        }
        if let operation = try await operationInProgress(at: root) {
            throw DiscardRefusal.operationInProgress(operation)
        }

        if case .lines(_, let patch, _, _) = receipt.request {
            do {
                try await applyToWorktree(patch, reverse: false, at: root)
            } catch {
                return .refused(Self.gitsWords(error), recordKept: try await listed(record, at: root))
            }
            _ = try? await dropRecord(record, at: root)
            return .restored
        }

        // Step 1: the record, as a user apply would (`-q --no-index`, rerere off).
        let applied = try await Self.discardRefusal { try await self.apply(record, at: root) }
        switch applied {
        case .applied: break
        case .refused(let files): return .refused(files.joined(separator: "\n"), recordKept: try await listed(record, at: root))
        case .conflicts(let paths): return .conflicted(paths, recordKept: try await listed(record, at: root))
        case .partiallyApplied(let files): return .partiallyRestored(notRestored: files)
        case .failed(let words): return .refused(words, recordKept: try await listed(record, at: root))
        }

        var outcome = UndoDiscardOutcome.restored
        if case .stagedAndUnstaged(let paths, _) = receipt.request {
            // Step 2, only on the HEAD the record was made on: after a new commit it would
            // stage a reversal of that commit's change (M B b).
            if try await headSha(at: root) == receipt.headAtDiscard {
                do {
                    try await restoreStagedPart(of: record, paths: paths, at: root)
                } catch {
                    throw DiscardFailure(receipt: receipt, gitsWords: Self.gitsWords(error))
                }
            } else {
                outcome = .restoredUnstaged
            }
        }
        // The content is back whatever the drop does; a list that changed under it keeps the
        // record, listed where the next read shows it.
        _ = try? await dropRecord(record, at: root)
        return outcome
    }

    /// `restore --source=<W>^2 --staged` of the named paths W^2 or the index knows: after step
    /// 1 that is every recorded path (M B.1), but one known to neither would fail the whole
    /// command (M A.5).
    private func restoreStagedPart(of record: Stash, paths named: [String], at root: URL) async throws {
        let sha = record.sha
        let paths = named.map(StashRecord.withoutTrailingSlash)
        let known = Set(try await modes(of: paths, in: "\(sha)^2", at: root).keys)
            .union(try await indexPaths(paths, at: root))
        let restorable = paths.filter(known.contains)
        guard !restorable.isEmpty else { return }
        _ = try await run(["restore", "--no-recurse-submodules", "--source=\(sha)^2", "--staged", "--"] + restorable.map(literalPathspec), cwd: root)
    }

    /// Each trashed item back where it was. A path that exists again is not overwritten
    /// (Cocoa error 516, M 15); the rest still come back.
    private func restoreFromTrash(_ receipt: DiscardReceipt, trasher: any Trasher, at root: URL) -> UndoDiscardOutcome {
        var notRestored: [String] = []
        for (path, trashed) in receipt.trashed.sorted(by: { $0.key < $1.key }) {
            do {
                try trasher.restore(trashed, to: root.appendingPathComponent(StashRecord.withoutTrailingSlash(path)))
            } catch {
                notRestored.append(path)
            }
        }
        return notRestored.isEmpty ? .restored : .partiallyRestored(notRestored: notRestored)
    }

    // MARK: - Helpers

    /// `git apply [--reverse] --whitespace=nowarn <tmpfile>` on the worktree: never `--cached`,
    /// never `--unidiff-zero`. Atomic: a hunk that does not fit leaves every file as it was
    /// (M 9). The patch file lives outside the repository, where it cannot show as untracked.
    private func applyToWorktree(_ patch: Patch, reverse: Bool, at root: URL) async throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gitter-discard-\(UUID().uuidString).diff")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try Data(patch.text.utf8).write(to: tmp)
        if reverse {
            _ = try await run(["apply", "--reverse", "--whitespace=nowarn", tmp.path], cwd: root)
        } else {
            _ = try await run(["apply", "--whitespace=nowarn", tmp.path], cwd: root)
        }
    }

    /// Drops the record, found again **by sha** — an entry pushed since moved it down, and the
    /// position the receipt remembers now names that entry — through the verified drop. True
    /// when it is no longer listed: dropped, or already gone. False when the list changed
    /// between the read and the drop (`stashListChanged`): the record stays.
    private func dropRecord(_ record: Stash, at root: URL) async throws -> Bool {
        guard let current = try await listed(record, at: root) else { return true }
        do {
            try await drop(current, at: root)
            return true
        } catch StashRefusal.stashListChanged {
            return false
        }
    }

    /// The record as the list shows it now, or nil when it is no longer listed.
    private func listed(_ record: Stash, at root: URL) async throws -> Stash? {
        try await stashes(at: root).first { $0.sha == record.sha }
    }

    /// Which of `paths` the index has an entry for (at any stage).
    private func indexPaths(_ paths: [String], at root: URL) async throws -> Set<String> {
        let data = try await run(["ls-files", "-z", "--"] + paths.map(literalPathspec), cwd: root)
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init))
    }

    /// HEAD's sha, or "" in a repository with no commits.
    private func headSha(at root: URL) async throws -> String {
        let data = try await run(["rev-parse", "-q", "--verify", "HEAD"], cwd: root, allowedExitCodes: [1])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `body`, with any refusal of the record's or the apply's (`StashRefusal`) thrown as the
    /// `DiscardRefusal` it matches.
    private static func discardRefusal<T>(_ body: () async throws -> T) async throws -> T {
        do {
            return try await body()
        } catch let refusal as StashRefusal {
            throw DiscardRefusal(refusal) ?? refusal
        }
    }

    /// git's own words for a failure, or the error's description.
    private static func gitsWords(_ error: Error) -> String {
        if case GitError.commandFailed(_, let stderr) = error { return stderr }
        return error.localizedDescription
    }
}
