import Foundation

/// Gitter's own stash commit for exactly the named paths (M A.0) — what "stash selected
/// files" files, and what every discard files before it overwrites anything.
///
/// **The only file that may name `read-tree`, `update-index` or `write-tree`**
/// (`ForceFlagScanner.recordFile`). Each of them runs here with `GIT_INDEX_FILE` pointing at a
/// temporary index this type creates and removes; without it, `read-tree HEAD` would overwrite
/// the real index and drop every staged change, and `write-tree` rewrites the real index and
/// takes its lock (M 8). A scanner cannot see an environment, so it confines the three
/// subcommands to this file instead.
///
/// The steps (M A.0), every git call through `runWithEnvironment` or `run`:
/// 1. Read-only survey and refusals: `status`, one `ls-files -s -z` for all the paths,
///    `ls-tree HEAD`.
/// 2. `read-tree HEAD` into the temporary index (it creates the file).
/// 3. The paths the real index has no entry for (a staged deletion or rename source) in one
///    `update-index --force-remove`, then every real index entry of the paths through
///    `update-index --add --cacheinfo …`, at most `cacheinfoLimit` entries a call.
///    `write-tree`, `commit-tree -p HEAD`: the index commit I.
/// 4. `update-index --add --remove -- paths` reads the worktree as git would (content,
///    deletion, executable bit, the link itself — never `hash-object`, which follows links).
///    `write-tree`, `commit-tree -p HEAD -p I`: W.
/// 5. `stash store -q -m <message> W`, judged by `refs/stash` afterwards.
///
/// The real index, HEAD, every other ref and the worktree are untouched (M A.0,
/// `StashRecordTests.theRecordWritesOnlyRefsStash`).
struct StashRecord {
    /// The entry that was filed.
    let stash: Stash
    /// The named paths neither in the index nor in HEAD but present in the worktree: untracked
    /// files W now holds, which `restore` cannot touch (M A.5).
    let untracked: [String]
    /// The named paths the index or HEAD knows: what `restore --source=HEAD` can put back.
    let tracked: [String]

    /// The file-name prefix of every temporary index, under `NSTemporaryDirectory()`.
    static let temporaryIndexPrefix = "gitter-record-"

    /// The M A.0 steps. Returns the filed entry. Refuses (`StashRefusal`) no paths, and
    /// unmerged, intent-to-add, submodule and nested-repository paths, before running anything
    /// that writes. The temporary index lives under `NSTemporaryDirectory()` and is removed in
    /// a `defer`.
    static func record(paths: [String], message: String, backend: CLIGitBackend, at root: URL) async throws -> Stash {
        try await make(paths: paths, message: message, backend: backend, at: root).stash
    }

    /// `record`, keeping what it learnt about each path. `temporaryDirectory` is where the
    /// temporary index goes; only tests pass another one, to watch it being removed.
    static func make(
        paths named: [String], message: String, backend: CLIGitBackend, at root: URL,
        temporaryDirectory: URL = URL(fileURLWithPath: NSTemporaryDirectory())
    ) async throws -> StashRecord {
        // 1. Survey and refusals.
        let survey = try await survey(paths: named, backend: backend, at: root)
        let (paths, entries) = (survey.paths, survey.entries)
        let inHEAD = Set(survey.headModes.keys)

        // 2–4. Build I and W in a temporary index.
        let temporaryIndex = temporaryDirectory.appendingPathComponent(temporaryIndexPrefix + UUID().uuidString)
        defer {
            try? FileManager.default.removeItem(at: temporaryIndex)
            try? FileManager.default.removeItem(at: temporaryIndex.appendingPathExtension("lock"))
        }
        let index = ["GIT_INDEX_FILE": temporaryIndex.path]
        let head = try await backend.headDescription(at: root)

        _ = try await backend.runWithEnvironment(["read-tree", "HEAD"], cwd: root, extra: index)
        // One call for the paths the real index has no entry for, then the entries in calls of
        // at most `cacheinfoLimit` (final review I1: one process per entry made a discard of 200
        // files take seconds). The two sets are disjoint — a path with no entry has none under
        // it either — so removing first is the per-path order's result.
        let removed = paths.filter { (entries[$0] ?? []).isEmpty }
        if !removed.isEmpty {
            _ = try await backend.runWithEnvironment(["update-index", "--force-remove", "--"] + removed, cwd: root, extra: index)
        }
        for cacheinfo in cacheinfoArguments(paths.flatMap { entries[$0] ?? [] }) {
            _ = try await backend.runWithEnvironment(["update-index", "--add"] + cacheinfo, cwd: root, extra: index)
        }
        let i = try await commit(
            tree: try await writeTree(backend, index, root), parents: nil,
            message: "index on \(head.branch): \(head.summary)", backend: backend, at: root)
        // `update-index` takes file names, not pathspecs: no `:(literal)` here, and none needed.
        _ = try await backend.runWithEnvironment(["update-index", "--add", "--remove", "--"] + paths, cwd: root, extra: index)
        let w = try await commit(
            tree: try await writeTree(backend, index, root), parents: i,
            message: message, backend: backend, at: root)

        // 5. File it.
        let stash = try await file(w, message: message, backend: backend, at: root)
        let tracked = paths.filter { !(entries[$0] ?? []).isEmpty || inHEAD.contains($0) }
        let isTracked = Set(tracked)
        let untracked = paths.filter { p in
            !isTracked.contains(p)
                && (try? FileManager.default.attributesOfItem(atPath: root.appendingPathComponent(p).path)) != nil
        }
        return StashRecord(stash: stash, untracked: untracked, tracked: tracked)
    }

    /// `stash store -q -m <message> <w>`, then the entry it filed.
    ///
    /// Success is `refs/stash == w` afterwards, never the exit code (M A.7). That also covers
    /// the one case where store files nothing and is still right: `w` already *at*
    /// `stash@{0}`. git exits 0 then and adds no entry — not even the new message (measured) —
    /// and two records made in the same second from the same state are the same commit. The
    /// entry holding exactly this content is listed, so it is returned as it stands.
    static func file(_ w: String, message: String, backend: CLIGitBackend, at root: URL) async throws -> Stash {
        var failure: Error?
        do {
            _ = try await backend.run(["stash", "store", "-q", "-m", message, w], cwd: root)
        } catch {
            failure = error
        }
        guard try await backend.stashRef(at: root) == w else {
            throw failure ?? GitError.commandFailed(
                exitCode: 0, stderr: "git stash store did not file \(w).")
        }
        return try await backend.listedStash(w, at: root)
    }

    /// What step 1 learns about the named paths: each one's real index entries and HEAD mode.
    struct Survey {
        /// The named paths without a trailing slash, each once, in order.
        let paths: [String]
        /// `ls-files -s` of each path: empty when the index has no entry for it.
        let entries: [String: [(mode: String, sha: String, stage: String, path: String)]]
        /// Each path HEAD has an entry for, with its mode.
        let headModes: [String: String]
    }

    /// Step 1 alone: the read-only survey, then every refusal (`StashRefusal`) the record
    /// would throw, in its order. Writes nothing. `discard` runs it before its stale check, so
    /// that a refusal is reported as one even when the file also changed.
    static func survey(paths named: [String], backend: CLIGitBackend, at root: URL) async throws -> Survey {
        guard !named.isEmpty else { throw StashRefusal.nothingSelected }
        // `ud/` and `ud` are one path to git's index. A trailing slash would make `update-index`
        // skip a directory with only "Ignoring path ud/" and exit 0 — a record silently missing
        // it — where the bare name fails loudly ("is a directory").
        var seen = Set<String>()
        let paths = named.map(Self.withoutTrailingSlash).filter { seen.insert($0).inserted }

        // Read-only: every call here leaves the index alone (`GIT_OPTIONAL_LOCKS=0`).
        let status = try await backend.stashStatus(at: root)
        // One `ls-files` for every path, split back to each path what its own read gave: its
        // entry, or everything under it as a directory (final review I1: one process per path).
        let data = try await backend.run(["ls-files", "-s", "-z", "--"] + paths.map(backend.literalPathspec), cwd: root)
        let entriesOf = CLIGitBackend.grouping(CLIGitBackend.indexRecords(data), by: \.path)
        var entries: [String: [(mode: String, sha: String, stage: String, path: String)]] = [:]
        for p in paths { entries[p] = entriesOf(p) }
        let headModes = try await backend.modes(of: paths, in: "HEAD", at: root)
        try await refuse(named, entries: entries, headModes: headModes, status: status, backend: backend, at: root)
        return Survey(paths: paths, entries: entries, headModes: headModes)
    }

    // MARK: - Steps

    /// At most this many `--cacheinfo` entries go to one `update-index`: 1 000 entries of a
    /// 200-byte path are about 250 KB of arguments, well under macOS's `ARG_MAX` (1 MB).
    static let cacheinfoLimit = 1_000

    /// `--cacheinfo <mode>,<sha>,<path>` for each entry, in order, split into calls of at most
    /// `limit` entries. Every entry is stage 0: an unmerged path was refused in the survey.
    /// `--cacheinfo` because the runner's stdin is /dev/null, so `--index-info` has nothing to
    /// read; git splits the argument at the first two commas only, so a comma in a name is
    /// safe (RF4).
    static func cacheinfoArguments(
        _ entries: [(mode: String, sha: String, stage: String, path: String)], limit: Int = cacheinfoLimit
    ) -> [[String]] {
        stride(from: 0, to: entries.count, by: max(limit, 1)).map { start in
            entries[start..<min(start + max(limit, 1), entries.count)].flatMap { entry in
                ["--cacheinfo", "\(entry.mode),\(entry.sha),\(entry.path)"]
            }
        }
    }

    private static func writeTree(_ backend: CLIGitBackend, _ index: [String: String], _ root: URL) async throws -> String {
        let result = try await backend.runWithEnvironment(["write-tree"], cwd: root, extra: index)
        return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `commit-tree` on HEAD (and I, for W). It does not read `commit.gpgSign` (measured with a
    /// signing program that logs every call: none), and it runs no hooks (M 10).
    private static func commit(
        tree: String, parents i: String?, message m: String, backend: CLIGitBackend, at root: URL
    ) async throws -> String {
        let data: Data
        if let i {
            data = try await backend.run(["commit-tree", tree, "-p", "HEAD", "-p", i, "-m", m], cwd: root)
        } else {
            data = try await backend.run(["commit-tree", tree, "-p", "HEAD", "-m", m], cwd: root)
        }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Refusals

    /// Throws the first refusal that applies, in the order unmerged, intent-to-add,
    /// submodule, nested repository, type changed. Each lists the named paths it covers, as
    /// they were named.
    private static func refuse(
        _ named: [String], entries: [String: [(mode: String, sha: String, stage: String, path: String)]],
        headModes: [String: String], status: WorkingCopyStatus, backend: CLIGitBackend, at root: URL
    ) async throws {
        func entriesFor(_ p: String) -> [(mode: String, sha: String, stage: String, path: String)] {
            entries[withoutTrailingSlash(p)] ?? []
        }
        // The first status record for each path, looked up rather than searched for each
        // named path (a scan per path is quadratic in a Discard All… of many files).
        var byPath: [String: FileStatus] = [:]
        for file in status.files where byPath[withoutTrailingSlash(file.path)] == nil {
            byPath[withoutTrailingSlash(file.path)] = file
        }
        func record(_ p: String) -> FileStatus? { byPath[withoutTrailingSlash(p)] }

        // The record's `write-tree` would fail on them (M A.0); refusing first writes nothing.
        let unmerged = named.filter { p in
            entriesFor(p).contains { $0.stage != "0" } || record(p)?.staged == .unmerged
        }
        if !unmerged.isEmpty { throw StashRefusal.unmergedPaths(unmerged) }

        let intentToAdd = Set(try await backend.intentToAddPaths(in: status, at: root))
        let refusedIntentToAdd = named.filter { intentToAdd.contains(withoutTrailingSlash($0)) }
        if !refusedIntentToAdd.isEmpty { throw StashRefusal.intentToAdd(refusedIntentToAdd) }

        let submodules = named.filter { p in
            entriesFor(p).contains { $0.mode == "160000" } || record(p)?.isSubmodule == true
        }
        if !submodules.isEmpty { throw StashRefusal.submodules(submodules) }

        let nested = named.filter { isInsideAnotherRepository($0, under: root) }
        if !nested.isEmpty { throw StashRefusal.nestedRepositories(nested) }

        // A file and a directory swapped (fix round 1): `update-index --add --remove -- p` over
        // a directory drops `p` without recording what is inside, and the restore puts the file
        // back over it; a path under what is now a file makes the restore delete that file.
        let typeChanged = named.filter { p in
            let bare = withoutTrailingSlash(p)
            let isFileOrLink: (String) -> Bool = { $0 != "040000" && $0 != "160000" }
            let tracksAFile = entriesFor(p).contains { $0.path == bare && isFileOrLink($0.mode) }
                || headModes[bare].map(isFileOrLink) == true
            return CLIGitBackend.hasChangedType(p, tracksAFile: tracksAFile, under: root)
        }
        if !typeChanged.isEmpty { throw StashRefusal.pathTypeChanged(typeChanged) }
    }

    /// Whether `path`, or a directory on the way to it, holds a `.git` (a directory, or the
    /// file a linked worktree or submodule has) — a repository git will not look inside.
    static func isInsideAnotherRepository(_ path: String, under root: URL) -> Bool {
        var directory = root
        for component in withoutTrailingSlash(path).split(separator: "/") {
            directory = directory.appendingPathComponent(String(component))
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory),
                isDirectory.boolValue
            else { return false }
            if FileManager.default.fileExists(atPath: directory.appendingPathComponent(".git").path) {
                return true
            }
        }
        return false
    }

    static func withoutTrailingSlash(_ path: String) -> String {
        var path = Substring(path)
        while path.count > 1, path.hasSuffix("/") { path = path.dropLast() }
        return String(path)
    }
}

// MARK: - Stash selected files

extension CLIGitBackend {
    public func stashPaths(_ paths: [String], message: String, at root: URL) async throws -> StashPushOutcome {
        try await stashPaths(paths, message: message, trasher: FileManagerTrasher(), at: root)
    }

    /// `stashPaths` with the Trash the untracked files go to given, so tests can pass a
    /// folder instead of the user's Trash.
    ///
    /// **VERIFY (measured, git 2.54):** `restore --source=HEAD --staged --worktree` of an
    /// untracked path fails with `error: pathspec ':(literal)u' did not match any file(s) known
    /// to git` (exit 1), and restores **none** of the other paths given with it (M A.5); an
    /// untracked directory the same. So only the tracked paths are restored, and the untracked
    /// ones — already in W — are moved to the Trash one file at a time.
    func stashPaths(_ paths: [String], message: String, trasher: any Trasher, at root: URL) async throws -> StashPushOutcome {
        guard !paths.isEmpty else { throw StashRefusal.nothingSelected }
        if let operation = try await operationInProgress(at: root) {
            throw StashRefusal.operationInProgress(operation)
        }
        let status = try await stashStatus(at: root)
        let expanded = try await expandingUntrackedDirectories(paths, status: status, at: root)
        guard hasChanges(expanded, status: status) else { return .nothingToSave }

        let head = try await headDescription(at: root)
        let trimmed = message.trimmingCharacters(in: .whitespacesAndNewlines)
        // git's own form: `On <branch>: <message>`, or `WIP on <branch>: <sha> <subject>`.
        let reflogMessage = trimmed.isEmpty ? "WIP on \(head.branch): \(head.summary)" : "On \(head.branch): \(message)"
        let record = try await StashRecord.make(paths: expanded, message: reflogMessage, backend: self, at: root)

        do {
            if !record.untracked.isEmpty {
                // Held by W before anything leaves the worktree — checked, not assumed.
                let held = try await self.paths(record.untracked, in: record.stash.sha, at: root)
                let missing = record.untracked.filter { !held.contains($0) }
                guard missing.isEmpty else {
                    return .savedWithError(
                        record.stash,
                        gitsWords: "The stash entry does not hold \(missing.joined(separator: ", ")), so it was left in place.")
                }
            }
            if !record.tracked.isEmpty {
                _ = try await run(["restore", "--no-recurse-submodules", "--source=HEAD", "--staged", "--worktree", "--"] + record.tracked.map(literalPathspec), cwd: root)
            }
        } catch GitError.commandFailed(_, let stderr) {
            return .savedWithError(record.stash, gitsWords: stderr)
        } catch {
            return .savedWithError(record.stash, gitsWords: error.localizedDescription)
        }
        // One at a time, keeping each URL: a failure part-way must say what already went and
        // where, or those items could not be found again (the Trash may rename them, M 15).
        var trashed: [String: URL] = [:]
        for p in record.untracked {
            do {
                trashed[p] = try trasher.trash(root.appendingPathComponent(p))
            } catch {
                return .savedWithError(
                    record.stash,
                    gitsWords: "\(p) could not be moved to the Trash: \(error.localizedDescription)",
                    trashed: trashed)
            }
        }
        return .saved(record.stash)
    }

    /// An untracked directory (`? ud/` in status, M 16) named as a path becomes its untracked
    /// files that are not ignored — what `git stash push -u -- ud` takes (M 4). A nested
    /// repository stays as named, and so does one found inside the directory (`ud/nested/`):
    /// the record refuses both.
    private func expandingUntrackedDirectories(
        _ paths: [String], status: WorkingCopyStatus, at root: URL
    ) async throws -> [String] {
        var result: [String] = []
        for p in paths {
            let directory = StashRecord.withoutTrailingSlash(p) + "/"
            guard status.files.contains(where: { $0.isUntracked && !$0.isNestedRepository && $0.path == directory })
            else {
                result.append(p)
                continue
            }
            let data = try await run(
                ["ls-files", "-o", "-z", "--exclude-standard", "--", literalPathspec(directory)], cwd: root)
            result += String(decoding: data, as: UTF8.self).split(separator: "\0").map(String.init)
        }
        var seen = Set<String>()
        return result.filter { seen.insert($0).inserted }
    }

    /// Whether status shows a change for any of `paths`: as a path, as a rename's original
    /// path (a copy's original is unchanged by the copy), or under an untracked directory.
    /// A file that is only stat-dirty (touched) shows nothing, as it has nothing to save (M 5).
    private func hasChanges(_ paths: [String], status: WorkingCopyStatus) -> Bool {
        paths.contains { p in
            let bare = StashRecord.withoutTrailingSlash(p)
            return status.files.contains { file in
                let isRename = file.staged == .renamed || file.unstaged == .renamed
                return StashRecord.withoutTrailingSlash(file.path) == bare
                    || (isRename && file.originalPath == bare)
                    || (file.isUntracked && file.path.hasSuffix("/") && bare.hasPrefix(file.path))
            }
        }
    }

    /// The branch as git's stash messages name it (`(no branch)` when detached), and HEAD's
    /// `<short sha> <subject>`.
    func headDescription(at root: URL) async throws -> (branch: String, summary: String) {
        let branchData = try await run(["symbolic-ref", "-q", "--short", "HEAD"], cwd: root, allowedExitCodes: [1])
        let branch = String(decoding: branchData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        // `--no-show-signature`: `log.showSignature=true` would put gpg's lines into the text.
        let summary = try await run(["log", "-1", "--no-show-signature", "--format=%h %s", "HEAD"], cwd: root)
        return (
            branch.isEmpty ? "(no branch)" : branch,
            String(decoding: summary, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        )
    }
}
