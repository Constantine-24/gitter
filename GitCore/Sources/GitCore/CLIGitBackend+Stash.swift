import Foundation

/// The stash: list, show, push, apply, pop and drop. See `GitStashBackend` for what each
/// method promises; the path-limited push is in `CLIGitBackend+StashRecord.swift`.
///
/// Every vector here is one complete array literal beginning with its subcommand, spelled as
/// `ForceFlagScannerTests.allowsTheWorkingCopyOperationsThisMilestoneNeeds` pins it: the
/// scanner permits `stash` only in whole shapes.
extension CLIGitBackend: GitStashBackend {
    public func stashes(at root: URL) async throws -> [Stash] {
        let data = try await run(
            ["stash", "list", "-z", "--format=%H%x1f%gd%x1f%gs%x1f%ct%x1f%P"], cwd: root)
        return StashListParser.parse(data)
    }

    /// `diff-tree` with two tree-ish arguments prints no commit-id line, and with explicit
    /// `--no-color --no-ext-diff -U3` it ignores `diff.noprefix`, `diff.srcPrefix`,
    /// `color.ui`, `diff.external` and `diff.context` (M A.6).
    public func stashDiff(_ stash: Stash, at root: URL) async throws -> [FileDiff] {
        let sha = stash.sha
        let tracked = try await run(
            ["diff-tree", "-p", "--no-color", "--no-ext-diff", "-U3", "-M", "\(sha)^1", sha],
            cwd: root)
        var diffs = DiffParser.parse(tracked)
        if stash.hasUntrackedPart {
            // The third parent against git's empty tree: every untracked file as an addition.
            let untracked = try await run(
                ["diff-tree", "-p", "--no-color", "--no-ext-diff", "-U3", "4b825dc642cb6eb9a060e54bf8d69288fbee4904", "\(sha)^3"],
                cwd: root)
            diffs += DiffParser.parse(untracked)
        }
        return diffs
    }
}

// MARK: - Push, apply, pop, drop

extension CLIGitBackend {
    public func stashAll(message: String?, includeUntracked: Bool, at root: URL) async throws -> StashPushOutcome {
        if let operation = try await operationInProgress(at: root) {
            throw StashRefusal.operationInProgress(operation)
        }
        let status = try await stashStatus(at: root)
        let unmerged = status.files.filter { $0.staged == .unmerged }.map(\.path)
        if !unmerged.isEmpty { throw StashRefusal.unmergedPaths(unmerged) }
        let intentToAdd = try await intentToAddPaths(in: status, at: root)
        if !intentToAdd.isEmpty { throw StashRefusal.intentToAdd(intentToAdd) }
        // A file and a directory that swapped places, refused with or without `-u`.
        let typeChanged = Self.typeChangedDeletions(in: status, under: root)
        if !typeChanged.isEmpty { throw StashRefusal.pathTypeChanged(typeChanged) }

        // `--message ""` is git's own `WIP on <branch>: <sha> <subject>` (M 17).
        let m = message ?? ""
        let before = try await stashRef(at: root)
        let result = try await runWithEnvironment(
            includeUntracked
                ? ["stash", "push", "-q", "--message", m, "--include-untracked"]
                : ["stash", "push", "-q", "--message", m],
            cwd: root, extra: [:], allowedExitCodes: [1, 128])
        let after = try await stashRef(at: root)

        guard let after, after != before else {
            // Nothing filed. Exit 0 is "no local changes to save" (M 5); anything else is a
            // refusal to name, or git's own words.
            guard result.exitCode == 0 else { throw Self.pushFailure(result) }
            // Except one exit 0 that did save: an entry that is the very commit already at
            // `stash@{0}` (same trees, parents and message, made in the same second), which git
            // files by adding nothing (measured) while it cleans the files all the same. Told
            // apart by the files: changes git saves were there before and are gone now.
            if let before, Self.hasChangesAPushSaves(status, includeUntracked: includeUntracked),
                !Self.hasChangesAPushSaves(try await stashStatus(at: root), includeUntracked: includeUntracked)
            {
                return .saved(try await listedStash(before, at: root))
            }
            return .nothingToSave
        }
        let stash = try await listedStash(after, at: root)
        if result.exitCode != 0 {
            return .savedWithError(stash, gitsWords: Self.words(result))
        }
        if try await holdsNothing(stash, at: root), try await isStill(stash, at: root) {
            _ = try await run(["stash", "drop", "-q", "stash@{\(stash.index)}"], cwd: root)
            return .nothingToSave
        }
        return .saved(stash)
    }

    public func apply(_ stash: Stash, at root: URL) async throws -> StashApplyOutcome {
        if let operation = try await operationInProgress(at: root) {
            throw StashRefusal.operationInProgress(operation)
        }
        // Checked first, not only because git refuses them (M 13): conflicts are read from
        // `ls-files -u` afterwards, and one that was there before is not the apply's.
        let unmerged = try await unmergedPaths(at: root)
        if !unmerged.isEmpty { throw StashRefusal.unmergedPaths(unmerged) }

        let sha = stash.sha
        let result = try await runWithEnvironment(
            ["stash", "apply", "-q", "--no-index", sha],
            cwd: root, extra: Self.rerereOff(ProcessInfo.processInfo.environment),
            allowedExitCodes: [1, 128])
        if result.exitCode == 0 { return .applied }

        // Refused before anything changed: the tracked "would be overwritten" block, and the
        // untracked one (a file the entry adds exists untracked).
        if case .wouldOverwrite(let tracked, let untracked)? = BranchRefusalParser.parse(stderr: result.stderr) {
            return .refused(wouldOverwrite: tracked + untracked)
        }
        // With `-q` a conflict prints nothing (M A.1). Reported ahead of an untracked file
        // that was not restored, when both happen: the unmerged index is what blocks the next
        // step, and the entry is kept either way.
        let conflicts = try await unmergedPaths(at: root)
        if !conflicts.isEmpty { return .conflicts(conflicts) }
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        switch StashFailureParser.parse(stdout: stdout, stderr: result.stderr) {
        case .untrackedAlreadyExists(let files)?: return .partiallyApplied(untrackedNotRestored: files)
        case .unmerged(let paths)?: throw StashRefusal.unmergedPaths(paths)
        case .intentToAdd(let paths)?: throw StashRefusal.intentToAdd(paths)
        default: return .failed(gitsWords: Self.words(result))
        }
    }

    public func pop(_ stash: Stash, at root: URL) async throws -> StashApplyOutcome {
        guard try await isStill(stash, at: root) else { throw StashRefusal.stashListChanged }
        let outcome = try await apply(stash, at: root)
        // Only a clean apply drops, and only the entry that is still this one (see the
        // protocol for the list changing in between).
        if outcome == .applied, try await isStill(stash, at: root) {
            _ = try await run(["stash", "drop", "-q", "stash@{\(stash.index)}"], cwd: root)
        }
        return outcome
    }

    public func drop(_ stash: Stash, at root: URL) async throws {
        guard try await isStill(stash, at: root) else { throw StashRefusal.stashListChanged }
        _ = try await run(["stash", "drop", "-q", "stash@{\(stash.index)}"], cwd: root)
    }

    // MARK: - Helpers shared with the record

    /// Whether `stash@{index}` still names `stash.sha`. `-q --verify` exits 1 when there is no
    /// `refs/stash` at all and 128 past the end of the list (measured); both are "no".
    func isStill(_ stash: Stash, at root: URL) async throws -> Bool {
        let data = try await run(
            ["rev-parse", "-q", "--verify", "stash@{\(stash.index)}"], cwd: root, allowedExitCodes: [1, 128])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == stash.sha
    }

    /// `refs/stash`, or nil when there is none. The before/after pair of these is what decides
    /// whether a push or store filed an entry (M A.7).
    func stashRef(at root: URL) async throws -> String? {
        let data = try await run(["rev-parse", "-q", "--verify", "refs/stash"], cwd: root, allowedExitCodes: [1])
        let sha = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return sha.isEmpty ? nil : sha
    }

    /// The listed entry whose sha is `sha` — `stash@{0}` unless the list moved again.
    func listedStash(_ sha: String, at root: URL) async throws -> Stash {
        guard let stash = try await stashes(at: root).first(where: { $0.sha == sha }) else {
            throw GitError.commandFailed(
                exitCode: 0, stderr: "The stash entry \(sha) was filed but is no longer listed.")
        }
        return stash
    }

    /// The working copy's status, with nested repositories marked — what the refusals read.
    ///
    /// `--untracked-files=normal`: under `status.showUntrackedFiles=no` an untracked path
    /// would otherwise look unchanged (M 16).
    func stashStatus(at root: URL) async throws -> WorkingCopyStatus {
        let data = try await run(["status", "--porcelain=v2", "-z", "--untracked-files=normal"], cwd: root)
        return Self.markingNestedRepositories(in: StatusParser.parse(data), under: root)
    }

    /// Every path with a conflict stage, once each, in index order.
    func unmergedPaths(at root: URL) async throws -> [String] {
        let data = try await run(["ls-files", "-u", "-z"], cwd: root)
        var seen = Set<String>()
        return Self.indexRecords(data).map(\.path).filter { seen.insert($0).inserted }
    }

    /// Every intent-to-add entry the status shows, including the two porcelain v2 cannot mark
    /// on its own:
    ///
    /// - a deleted one, `1 .D N... 100644 100644 000000 e69de29… e69de29… q`, which is the very
    ///   record a committed empty file deleted from the worktree gets (measured). An unstaged
    ///   deletion with nothing staged means the index entry equals HEAD's — unless the path is
    ///   not in HEAD at all, which only an intent-to-add entry can be.
    /// - the deleted half of a pair git reports as a rename (`2 .R … e` then `q`): the original
    ///   path, by the same test — a tracked file deleted in the worktree pairs the same way and
    ///   *is* in HEAD.
    func intentToAddPaths(in status: WorkingCopyStatus, at root: URL) async throws -> [String] {
        let marked = status.files.filter(\.isIntentToAdd).map(\.path)
        let candidates = status.files.filter { $0.staged == nil && $0.unstaged == .deleted }.map(\.path)
            + status.files.filter(\.isIntentToAdd).compactMap(\.originalPath)
        guard !candidates.isEmpty else { return marked }
        let inHEAD = try await paths(candidates, in: "HEAD", at: root)
        var seen = Set<String>()
        return (marked + candidates.filter { !inHEAD.contains($0) }).filter { seen.insert($0).inserted }
    }

    /// Which of `paths` the tree of `rev` has an entry for (a blob, a link, a gitlink, or a
    /// tree for a directory).
    func paths(_ paths: [String], in rev: String, at root: URL) async throws -> Set<String> {
        Set(try await modes(of: paths, in: rev, at: root).keys)
    }

    /// Each of `paths` that the tree of `rev` has an entry for, with its mode (`100644`,
    /// `100755`, `120000`, `160000`, or `040000` for a directory). `ls-tree` takes pathspecs, so
    /// each is literal; `<mode> SP <type> SP <object> TAB <path> NUL` per entry.
    func modes(of paths: [String], in rev: String, at root: URL) async throws -> [String: String] {
        guard !paths.isEmpty else { return [:] }
        let data = try await run(
            ["ls-tree", "-z", "--full-tree", rev, "--"] + paths.map(literalPathspec), cwd: root)
        var result: [String: String] = [:]
        for record in String(decoding: data, as: UTF8.self).split(separator: "\0") {
            guard let tab = record.firstIndex(of: "\t"), let space = record.firstIndex(of: " ") else { continue }
            result[String(record[record.index(after: tab)...])] = String(record[..<space])
        }
        return result
    }

    /// How `path` sits on disk against what git tracks there, read with `lstat` semantics (a
    /// symlink is a symlink, never what it points at):
    /// - a leading component that is a file or a symlink (`d` for `d/a`): git cannot see past
    ///   it, and restoring `d/a` would delete it;
    /// - a real directory where git tracks a file or a symlink (`tracksAFile`): status shows
    ///   only a deletion, and what is inside the directory is invisible to it.
    /// Either way, what is on disk is in no record, and a restore would overwrite it.
    static func hasChangedType(_ path: String, tracksAFile: Bool, under root: URL) -> Bool {
        let components = StashRecord.withoutTrailingSlash(path).split(separator: "/").map(String.init)
        var url = root
        for component in components.dropLast() {
            url = url.appendingPathComponent(component)
            guard let type = fileType(url) else { return false }  // absent: nothing hidden below
            if type != .typeDirectory { return true }
        }
        guard let last = components.last else { return false }
        return tracksAFile && fileType(url.appendingPathComponent(last)) == .typeDirectory
    }

    /// `lstat`'s answer: `attributesOfItem` does not follow a final symlink. Nil when absent.
    private static func fileType(_ url: URL) -> FileAttributeType? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
    }

    /// `ls-files -s -z` / `ls-files -u -z`: `<mode> SP <object> SP <stage> TAB <path> NUL`.
    static func indexRecords(_ data: Data) -> [(mode: String, sha: String, stage: String, path: String)] {
        String(decoding: data, as: UTF8.self).split(separator: "\0").compactMap { record in
            guard let tab = record.firstIndex(of: "\t") else { return nil }
            let fields = record[..<tab].split(separator: " ")
            guard fields.count == 3 else { return nil }
            return (String(fields[0]), String(fields[1]), String(fields[2]),
                    String(record[record.index(after: tab)...]))
        }
    }

    /// Whether a pushed entry holds nothing: its worktree tree and its index tree are both
    /// HEAD's, and it has no untracked part or an empty one. git files exactly that for an
    /// untracked nested repository under `-u` (M A.7). The index tree is compared too: a
    /// staged change whose worktree went back to HEAD has W's tree equal to HEAD's and is not
    /// empty.
    private func holdsNothing(_ stash: Stash, at root: URL) async throws -> Bool {
        let sha = stash.sha
        let data = try await run(
            stash.hasUntrackedPart
                ? ["rev-parse", "\(sha)^{tree}", "\(sha)^1^{tree}", "\(sha)^2^{tree}", "\(sha)^3^{tree}"]
                : ["rev-parse", "\(sha)^{tree}", "\(sha)^1^{tree}", "\(sha)^2^{tree}"],
            cwd: root)
        let trees = GitLines.split(data)
        guard trees.count >= 3, trees[0] == trees[1], trees[2] == trees[1] else { return false }
        return !stash.hasUntrackedPart || trees.count == 4 && trees[3] == Self.emptyTree
    }

    /// Whether `status` shows something a push takes: a tracked change that is not a
    /// submodule's (stash leaves those alone, M 14), or with `-u` an untracked file or
    /// directory that is not a nested repository (M 4).
    private static func hasChangesAPushSaves(_ status: WorkingCopyStatus, includeUntracked: Bool) -> Bool {
        status.files.contains { file in
            if file.isUntracked { return includeUntracked && !file.isNestedRepository }
            return file.unstaged != .ignored && !file.isSubmodule
        }
    }

    /// The deleted paths (and renames' original paths) that `hasChangedType` says swapped
    /// type. **Every one is refused, with or without `--include-untracked`** — one rule, with no
    /// ignored-file subtleties. What a full push would otherwise do (measured, git 2.54):
    /// - a tracked file replaced by a directory (`p` → `p/x`): a plain push puts the file back
    ///   and `p/x` is lost; with `-u` it is saved in the third parent, but an apply cannot put
    ///   it back (`fatal: cannot create directory at 'p': File exists`).
    /// - a path under what is now a file (`d/a` → the file `d`): a plain push puts the
    ///   directory back and the file `d` is lost. With `-u` a non-ignored `d` is saved in the
    ///   third parent, but an **ignored** one is not (`-u` never takes ignored files) and the
    ///   push's reset deletes it all the same (fix round 2).
    static func typeChangedDeletions(in status: WorkingCopyStatus, under root: URL) -> [String] {
        let deleted = status.files.filter { !$0.isSubmodule && ($0.staged == .deleted || $0.unstaged == .deleted) }
            .map(\.path)
            + status.files.filter { $0.staged == .renamed || $0.unstaged == .renamed }.compactMap(\.originalPath)
        var seen = Set<String>()
        return deleted.filter { seen.insert($0).inserted }.filter { path in
            hasChangedType(path, tracksAFile: true, under: root)
        }
    }

    /// git's empty tree.
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// A push that filed nothing and did not exit 0: the refusal it was, or git's own words.
    private static func pushFailure(_ result: ProcessRunner.StreamedResult) -> Error {
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        switch StashFailureParser.parse(stdout: stdout, stderr: result.stderr) {
        case .unmerged(let paths)?: return StashRefusal.unmergedPaths(paths)
        case .intentToAdd(let paths)?: return StashRefusal.intentToAdd(paths)
        default: return GitError.commandFailed(exitCode: result.exitCode, stderr: words(result))
        }
    }

    /// Everything git said, stderr first (where errors go), then stdout (where `needs merge`
    /// goes, M 13), trimmed.
    static func words(_ result: ProcessRunner.StreamedResult) -> String {
        let stdout = String(decoding: result.stdout, as: UTF8.self)
        return [result.stderr, stdout]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
    }
}
