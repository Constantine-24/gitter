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

    /// Per path, in the order named: its staged side (with `includingStaged`), then its
    /// unstaged side — exactly what `workingCopyDiff` gives for that one path — read with at
    /// most three git processes however many paths there are (final review I1: two per path
    /// made Discard All… of 200 files take seconds). Each diff is split back to the paths it
    /// belongs to; `DiscardScalingTests.theBatchedReadIsThePerPathRead` pins the equality.
    ///
    /// `--no-renames` is what keeps it equal. A single-file pathspec never pairs a rename (only
    /// one side matches), so the per-path read showed a staged rename as its source deleted and
    /// its destination added — and with both paths in one call, `-M` would pair them into one
    /// diff the sheet never showed. The format flags are `workingCopyDiff`'s, for its reasons:
    /// without them a user's `diff.noprefix` left every tracked discard `nothingSelected`.
    public func discardExpectation(tracked paths: [String], includingStaged: Bool, at root: URL) async throws
        -> DiscardExpectation
    {
        guard !paths.isEmpty else { return .diffs([]) }
        let staged: [FileDiff]
        if includingStaged {
            staged = DiffParser.parse(try await run(["diff", "--cached", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--full-index", "-U3", "--no-renames", "--"] + paths.map(literalPathspec), cwd: root))
        } else {
            staged = []
        }
        // Without an index entry (a staged deletion, a rename's source) there is no unstaged
        // side, and `workingCopyDiff` would read the path as an untracked file.
        let indexed = Self.coveredPaths(paths, by: try await indexPaths(paths, at: root))
        let unstaged: [FileDiff]
        if indexed.isEmpty {
            unstaged = []
        } else {
            let named = paths.filter(indexed.contains)
            unstaged = DiffParser.parse(try await run(["diff", "--no-color", "--no-ext-diff", "--no-textconv", "--submodule=short", "--src-prefix=a/", "--dst-prefix=b/", "--full-index", "-U3", "--no-renames", "--"] + named.map(literalPathspec), cwd: root))
        }
        let stagedOf = Self.grouping(staged, by: \.displayPath)
        let unstagedOf = Self.grouping(unstaged, by: \.displayPath)
        var diffs: [FileDiff] = []
        for path in paths {
            if includingStaged { diffs += stagedOf(path) }
            if indexed.contains(path) { diffs += unstagedOf(path) }
        }
        return .diffs(diffs)
    }

    /// The named paths a literal pathspec of theirs matches in `found`: the path itself, or
    /// something under it as a directory.
    static func coveredPaths(_ named: [String], by found: Set<String>) -> Set<String> {
        let directories = Set(found.flatMap { ancestors(of: $0) })
        return Set(named.filter { found.contains($0) || directories.contains($0) })
    }

    /// `items` for one literal pathspec each, in their order: those whose path is the named one
    /// or under it as a directory — what a read of that one path gives.
    static func grouping<T>(_ items: [T], by path: @escaping (T) -> String) -> (String) -> [T] {
        var exact: [String: [T]] = [:]
        var directories = Set<String>()
        for item in items {
            exact[path(item), default: []].append(item)
            directories.formUnion(ancestors(of: path(item)))
        }
        return { named in
            // A directory is rare (the sheet names files); order is kept by filtering in order.
            guard directories.contains(named) else { return exact[named] ?? [] }
            return items.filter { path($0) == named || path($0).hasPrefix(named + "/") }
        }
    }

    /// `a/b/c` → `a`, `a/b`.
    private static func ancestors(of path: String) -> [String] {
        var result: [String] = []
        var index = path.startIndex
        while let slash = path[index...].firstIndex(of: "/") {
            result.append(String(path[..<slash]))
            index = path.index(after: slash)
        }
        return result
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
        // No refusal for an operation in progress (A2): every discard mechanism leaves its
        // files alone and it concludes afterwards (M 20). Only the staged side of the
        // operation's own paths is refused, below.
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
        if case .stagedAndUnstaged(let paths, _) = request {
            let own = try await operationsOwn(paths, at: root)
            if !own.isEmpty { throw DiscardRefusal.partOfOperation(own) }
        }
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

        // 3b. A line discard only on a file in its checkout form: `git apply` writes the whole
        // file back through the checkout conversion, so an LF file under `autocrlf=true` would
        // come out all CRLF, a CRLF file under `autocrlf=input` all LF (fix round 3, measured).
        // The record's blob is the file's content as git reads it; its checkout form is what
        // the bytes must be. Checked before anything changes, so the record is noise if it
        // fails, and goes again.
        var recordedForm: RecordedForm?
        if case .lines(let path, _, _, _) = request {
            recordedForm = try await linesForm(of: path, in: record, at: root)
            guard recordedForm != nil else {
                guard (try? await dropRecord(record, at: root)) == true else {
                    throw DiscardFailure(
                        receipt: receipt,
                        gitsWords: "\(path) is not in its checkout form, so its lines cannot be discarded alone; "
                            + "nothing was discarded, and the record made for it could not be removed.")
                }
                throw DiscardRefusal.needsWholeFile(path)
            }
        }

        // 4. Change. Between the stale check (and the record) and this command is one process
        // start: an edit made in that window is overwritten and is in no record. No git option
        // closes it; it is the same window `applyToIndex` documents.
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
        // The discard is done. What it left is read for the undo's guard; a read that fails
        // now is not a failed discard, so the receipt goes without it, and its undo refuses.
        guard case .lines(let path, _, _, _) = request else { return receipt }
        return DiscardReceipt(
            request: request, record: record, headAtDiscard: receipt.headAtDiscard, trashed: [:],
            afterDiscard: try? await discardedFileState(of: path, at: root), recordedForm: recordedForm)
    }

    /// Which form of the record's blob `path`'s bytes are: `raw` when they are the blob itself
    /// and a checkout writes exactly that, `checkout` when they are the blob as a checkout
    /// writes it and that differs from the blob. Nil otherwise — the file is not in its
    /// checkout form — or when a side cannot be read.
    private func linesForm(of path: String, in record: Stash, at root: URL) async throws -> RecordedForm? {
        guard let bytes = try await worktreeBytes(of: path, at: root),
            let checkedOut = try? await recordedBytesAsCheckedOut(of: path, in: record, at: root),
            bytes == checkedOut
        else { return nil }
        return bytes == (try? await recordedBytes(of: path, in: record, at: root)) ? .raw : .checkout
    }

    /// `path` on every layer: its bytes, its index entry, HEAD. Throws when the file cannot be
    /// read.
    func discardedFileState(of path: String, at root: URL) async throws -> DiscardedFileState {
        let bytes = try Data(contentsOf: root.appendingPathComponent(path))
        let entry = try await run(["ls-files", "-s", "-z", "--", literalPathspec(path)], cwd: root)
        return DiscardedFileState(
            worktree: bytes, indexEntry: String(decoding: entry, as: UTF8.self), head: try await headSha(at: root))
    }

    /// `.untracked`: no record — git has no copy of an untracked file, so the Trash is the copy.
    private func discardUntracked(
        _ paths: [String], expected: DiscardExpectation, request: DiscardRequest, trasher: any Trasher,
        at root: URL
    ) async throws -> DiscardReceipt {
        // A repository further down an untracked directory (`? ud/` with `ud/inner/.git`) too:
        // the Trash would take it whole.
        let nested = paths.filter {
            StashRecord.isInsideAnotherRepository($0, under: root) || Self.holdsARepository($0, under: root)
        }
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

    /// Whether a directory at `path` has a `.git` (a directory or a file) anywhere below it.
    /// Symlinks are not followed (the enumerator does not descend into them).
    static func holdsARepository(_ path: String, under root: URL) -> Bool {
        let top = root.appendingPathComponent(StashRecord.withoutTrailingSlash(path)).path
        guard let info = lstatInfo(top), info.st_mode & S_IFMT == S_IFDIR,
            let enumerator = FileManager.default.enumerator(atPath: top)
        else { return false }
        for case let relative as String in enumerator where (relative as NSString).lastPathComponent == ".git" {
            return true
        }
        return false
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

        // A line discard's undo runs during an operation too: its forward patch on the
        // worktree, like the Trash's way back, leaves the operation's files alone (measured,
        // A2 Task 4), and it runs only onto exactly what the discard left.
        if case .lines(let path, let patch, _, _) = receipt.request {
            // Only onto exactly what the discard left, on every layer: in a file that moved on,
            // the patch's context can match elsewhere, and git applies it there at an offset
            // without a word (M 9; fix round 1 measured `NEW` put into the wrong one of two
            // identical blocks, and round 2 the same after the edit was staged or committed,
            // which leaves the unstaged diff as it was).
            let now = try? await discardedFileState(of: path, at: root)
            guard let now, now == receipt.afterDiscard else {
                return .refused(
                    "\(path), or HEAD, moved since the discard.", recordKept: try await listed(record, at: root))
            }
            do {
                try await applyToWorktree(patch, reverse: false, at: root)
            } catch {
                return .refused(Self.gitsWords(error), recordKept: try await listed(record, at: root))
            }
            // And the record is dropped only when the file is byte for byte its copy there, in
            // the one form the file had before the discard (`receipt.recordedForm`): raw, or as
            // a checkout writes it (`autocrlf`, `eol=crlf`: the blob is LF, the file CRLF). Only
            // that form is read — a smudge filter runs only for a `checkout` file. Both sides
            // must be read: two failed reads are not two equal files.
            let bytes = try await worktreeBytes(of: path, at: root)
            let recorded: Data?
            switch receipt.recordedForm {
            case .raw?: recorded = try? await recordedBytes(of: path, in: record, at: root)
            case .checkout?: recorded = try? await recordedBytesAsCheckedOut(of: path, in: record, at: root)
            case nil: recorded = nil
            }
            guard let bytes, bytes == recorded else {
                return .restoredUnverified(recordKept: try await listed(record, at: root))
            }
            _ = try? await dropRecord(record, at: root)
            return .restored
        }

        // The whole-file undo goes through `stash apply`, which an operation cannot take
        // (measured, A2 Task 4): over a conflict git refuses it (`could not write index`), and
        // otherwise it rewrites `AUTO_MERGE` — the operation's own paths (`operationPaths`)
        // would then be the record's. Refused until the operation is concluded or aborted; the
        // record stays listed.
        if let operation = try await operationInProgress(at: root) {
            throw DiscardRefusal.operationInProgress(operation)
        }

        // Whether the staged side moved since the discard, which left each path's index entry
        // at HEAD: step 2 would then overwrite that staged edit with the record's index.
        var stagedSince = false
        if case .stagedAndUnstaged(let paths, _) = receipt.request {
            stagedSince = try await hasStagedChanges(paths, at: root)
        }

        // Step 1: the record, as a user apply would (`-q --no-index`, rerere off).
        let applied = try await Self.discardRefusal { try await self.apply(record, at: root) }
        switch applied {
        case .applied: break
        case .refused(let files): return .refused(files.joined(separator: "\n"), recordKept: try await listed(record, at: root))
        case .conflicts(let paths): return .conflicted(paths, recordKept: try await listed(record, at: root))
        // Unreachable for a record, which has no untracked part (no third parent) — git reports
        // this only for an entry's untracked files. Should it happen, the tracked part did land
        // and something did not: kept, not dropped. `.appliedButKept` is pop's alone; `apply`
        // never returns it.
        case .partiallyApplied, .appliedButKept:
            return .restoredUnverified(recordKept: try await listed(record, at: root))
        case .failed(let words): return .refused(words, recordKept: try await listed(record, at: root))
        }

        var outcome = UndoDiscardOutcome.restored
        if case .stagedAndUnstaged(let paths, _) = receipt.request {
            // Step 2, only on the HEAD the record was made on — after a new commit it would
            // stage a reversal of that commit's change (M B b) — and only over an untouched
            // staged side.
            if !stagedSince, try await headSha(at: root) == receipt.headAtDiscard {
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

    /// Whether any of `paths` has a staged change (the index differs from HEAD).
    private func hasStagedChanges(_ paths: [String], at root: URL) async throws -> Bool {
        !(try await stagedPaths(paths, at: root)).isEmpty
    }

    /// The paths under `paths` with a staged change (the index differs from HEAD), each as git
    /// names it.
    private func stagedPaths(_ paths: [String], at root: URL) async throws -> Set<String> {
        let data = try await run(["diff", "--cached", "--name-only", "-z", "--no-renames", "--"] + paths.map(literalPathspec), cwd: root)
        return Set(String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init))
    }

    /// The named paths whose staged side is the operation's own result, as named — none when
    /// no operation is in progress (`DiscardRefusal.partOfOperation`). The operation's paths
    /// are `operationPaths` (M 21, M 31, Ruling 22); when that is nil nothing tells them apart,
    /// so every path with a staged change counts. A named directory counts when it holds one.
    private func operationsOwn(_ named: [String], at root: URL) async throws -> [String] {
        guard try await operationInProgress(at: root) != nil else { return [] }
        let own: Set<String>
        if let paths = try await operationPaths(at: root) {
            own = Set(paths)
        } else {
            own = try await stagedPaths(named, at: root)
        }
        guard !own.isEmpty else { return [] }
        let covered = Self.coveredPaths(named.map(StashRecord.withoutTrailingSlash), by: own)
        return named.filter { covered.contains(StashRecord.withoutTrailingSlash($0)) }
    }

    /// The bytes the record's worktree commit holds for `path`: `cat-file` reads the blob raw,
    /// with no filter or conversion.
    private func recordedBytes(of path: String, in record: Stash, at root: URL) async throws -> Data {
        try await run(["cat-file", "blob", "\(record.sha):\(path)"], cwd: root)
    }

    /// The same blob as a checkout would write it: `cat-file --filters` runs the path's
    /// end-of-line conversion and smudge filter over it.
    private func recordedBytesAsCheckedOut(of path: String, in record: Stash, at root: URL) async throws -> Data {
        try await run(["cat-file", "--filters", "\(record.sha):\(path)"], cwd: root)
    }

    /// The file's bytes on disk now; nil when it cannot be read.
    private func worktreeBytes(of path: String, at root: URL) async throws -> Data? {
        try? Data(contentsOf: root.appendingPathComponent(path))
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
    static func gitsWords(_ error: Error) -> String {
        if case GitError.commandFailed(_, let stderr) = error { return stderr }
        return error.localizedDescription
    }
}
