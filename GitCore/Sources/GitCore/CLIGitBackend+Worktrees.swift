import Foundation

/// Worktrees (B3 Task 2). See `GitWorktreeBackend` for the contract; this file is about how each
/// vector is spelled, what is refused before git runs, and how git's answers are read. Every
/// vector here is pinned whole in `ForceFlagScannerTests.worktreeContract`, and `worktree`'s three
/// are the subcommand's only shapes.
///
/// **Measured for this task (git 2.54, `LC_ALL=C`, scratch repositories):**
/// - `ls-files -v -z` tags each index entry: `H` cached, `S` skip-worktree, `M` unmerged, and the
///   same letter in **lower case** when the entry is also assume-unchanged (`h`, and `s` for both
///   bits). Paths are raw after `-z` (a space, `ünï`). An assume-unchanged file deleted from disk
///   shows nothing in `status` either. Run in a linked worktree's folder, it reads that
///   worktree's own index.
/// - The nested-repository walk (`FileManager`'s enumerator, `.git` entries, not descending into
///   one): 20 000 entries in 0.07–0.11 s, 80 000 in 0.28–0.31 s (about 250 000 a second, APFS);
///   `status --ignored=matching` lists a 20 000-entry `node_modules/` as one entry in 9 ms. The
///   plan's 20 000-entry cap binds long before its 2 s.
/// - A worktree whose `.git` file is gone but whose folder is there is `prunable`, and `worktree
///   remove` refuses it (`validation failed, cannot remove working tree`, exit 128) and deletes
///   nothing. A locked worktree whose folder is gone has no `prunable` line (R25).
/// - A bare main repository's HEAD branch is not a checkout: `worktree add` checks it out
///   (exit 0), though `%(worktreepath)` prints the bare repository's path for it until then.
extension CLIGitBackend: GitWorktreeBackend {

    // MARK: - The list

    public func worktrees(at root: URL) async throws -> [Worktree] {
        let listed = try await listedWorktrees(at: root)
        let held = try await worktreeAdministrativeDirectories(at: root).compactMap { admin in
            Self.branchHeldByOperation(in: admin.directory).map { (path: admin.path, branch: $0) }
        }
        return listed.map { worktree in
            worktree.with(operationBranch: held.first { Self.samePath($0.path, worktree.path) }?.branch)
        }
    }

    /// `list` alone, parsed (R13): what every read-back compares with.
    private func listedWorktrees(at root: URL) async throws -> [Worktree] {
        let data = try await run(["worktree", "list", "--porcelain", "-z"], cwd: root)
        return WorktreeListParser.parse(data)
    }

    /// The branch a rebase or a bisect holds in the worktree whose administrative directory is
    /// `directory`, as `worktreeUsing` reads it (R14): `rebase-merge/head-name`, then
    /// `rebase-apply/head-name` unless that is an `am` (`rebase-apply/applying`), then
    /// `BISECT_START` — a branch's short name, or an id when the bisect began detached.
    static func branchHeldByOperation(in directory: URL) -> String? {
        let file = { (name: String) in Self.contents(of: directory.appendingPathComponent(name)) }
        if let ref = file("rebase-merge/head-name"), ref.hasPrefix("refs/heads/") { return ref }
        let applying = FileManager.default.fileExists(atPath: directory.appendingPathComponent("rebase-apply/applying").path)
        if !applying, let ref = file("rebase-apply/head-name"), ref.hasPrefix("refs/heads/") { return ref }
        if let start = file("BISECT_START"), !start.isEmpty, !isFullObjectID(start) { return "refs/heads/" + start }
        return nil
    }

    // MARK: - Changes

    public func worktreeChanges(_ worktree: Worktree, at root: URL) async throws -> WorktreeChanges {
        let folder = try Self.existingFolder(of: worktree)
        let data = try await run(["status", "--porcelain=v2", "-z", "--untracked-files=normal"], cwd: folder)
        return Self.statusEntries(data).changes
    }

    /// The worktree's folder, or an error for one that has none — never a status read somewhere
    /// else, or "clean".
    private static func existingFolder(of worktree: Worktree) throws -> URL {
        guard !worktree.isBare, isDirectory(worktree.path) else {
            throw GitError.commandFailed(exitCode: -1, stderr: "no worktree folder at \(worktree.path)")
        }
        return URL(fileURLWithPath: worktree.path, isDirectory: true)
    }

    /// `status --porcelain=v2 -z` records counted (R15): `1` and `2` by their two sides (a `2`
    /// record's original path is the next field), `u` as conflicted, `?` as untracked; the paths
    /// of `!` (ignored) records, in git's order.
    static func statusEntries(_ data: Data) -> (changes: WorktreeChanges, ignored: [String]) {
        var staged = 0, unstaged = 0, untracked = 0, conflicted = 0
        var ignored: [String] = []
        var skipNext = false
        for field in data.split(separator: 0, omittingEmptySubsequences: true) {
            if skipNext {
                skipNext = false
                continue
            }
            let record = Array(field)
            guard record.count >= 2, record[1] == UInt8(ascii: " ") else { continue }
            switch record[0] {
            case UInt8(ascii: "1"), UInt8(ascii: "2"):
                guard record.count >= 4 else { continue }
                if record[2] != UInt8(ascii: ".") { staged += 1 }
                if record[3] != UInt8(ascii: ".") { unstaged += 1 }
                skipNext = record[0] == UInt8(ascii: "2")
            case UInt8(ascii: "u"): conflicted += 1
            case UInt8(ascii: "?"): untracked += 1
            case UInt8(ascii: "!"): ignored.append(String(decoding: record.dropFirst(2), as: UTF8.self))
            default: continue
            }
        }
        return (WorktreeChanges(staged: staged, unstaged: unstaged, untracked: untracked, conflicted: conflicted), ignored)
    }

    // MARK: - The removal check

    public func removalCheck(_ worktree: Worktree, at root: URL) async throws -> WorktreeRemoval {
        try await removalCheck(worktree, at: root, walkLimit: .standard)
    }

    /// `removalCheck`, with the walk's cap a parameter so a test can lower it.
    func removalCheck(_ worktree: Worktree, at root: URL, walkLimit: WorktreeWalkLimit) async throws -> WorktreeRemoval {
        let all = try await worktrees(at: root)
        guard let current = all.first(where: { $0.path == worktree.path }) else {
            throw WorktreeRemovalPartial.changedSinceShown
        }
        let isOpenHere = Self.samePath(current.path, root.path)
        if current.isMain {
            return WorktreeRemoval(
                worktree: current, changes: nil, ignored: .none, stranded: .none,
                refusals: isOpenHere ? [.isMain, .isOpenHere] : [.isMain])
        }
        var refusals: [WorktreeRemovalRefusal] = []
        if isOpenHere { refusals.append(.isOpenHere) }
        if let lock = current.lock { refusals.append(.locked(reason: lock.reason)) }
        let stranded = try await strandedByRemoving(current, among: all, at: root)

        // No folder: nothing in it to lose, and nothing to read. A locked worktree whose folder
        // is gone is not `prunable` (R25), so the folder itself is asked.
        guard !current.isMissing, Self.isDirectory(current.path) else {
            return WorktreeRemoval(worktree: current, changes: nil, ignored: .none, stranded: stranded, refusals: refusals)
        }
        let folder = URL(fileURLWithPath: current.path, isDirectory: true)
        let state = try await stateDirectory(of: folder)
        guard let gitDirectory = state else {
            refusals.append(.unreadable(folder.path))
            return WorktreeRemoval(worktree: current, changes: nil, ignored: .none, stranded: stranded, refusals: refusals)
        }
        if let operation = Self.operationRefusal(in: gitDirectory) { refusals.append(operation) }

        let data = try await run(["status", "--porcelain=v2", "-z", "--untracked-files=normal", "--ignored=matching"], cwd: folder)
        let status = Self.statusEntries(data)
        if !status.changes.isClean { refusals.append(.changes(status.changes)) }
        refusals += try await hiddenEdits(in: folder)
        refusals += Self.nestedRepositories(in: folder, ignored: status.ignored, limit: walkLimit)
        return WorktreeRemoval(
            worktree: current, changes: status.changes, ignored: Self.ignoredSummary(status.ignored),
            stranded: stranded, refusals: refusals)
    }

    /// The worktree's own git directory (`rev-parse --absolute-git-dir`, run in its folder), or
    /// nil when git's top level there is not the folder itself — its `.git` gone, git found an
    /// enclosing repository instead, and nothing read there is this worktree's.
    private func stateDirectory(of folder: URL) async throws -> URL? {
        let data = try await run(["rev-parse", "--absolute-git-dir", "--show-toplevel"], cwd: folder)
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        guard lines.count >= 2, lines[0].hasPrefix("/"), Self.samePath(lines[1], folder.path) else { return nil }
        return URL(fileURLWithPath: lines[0], isDirectory: true)
    }

    /// An operation part-way through in the git directory `directory` (R20): the rebase or `am`
    /// first, as `operationInProgress` orders them, then a merge, cherry-pick, revert, bisect or
    /// a sequence between its steps. A directory that cannot be listed refuses too: unreadable
    /// is never "nothing in progress" (carried note 4).
    static func operationRefusal(in directory: URL) -> WorktreeRemovalRefusal? {
        let names: Set<String>
        do {
            names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
        } catch {
            return .unreadable(directory.path)
        }
        let operation: String?
        if names.contains("rebase-merge") {
            operation = "rebase"
        } else if names.contains("rebase-apply") {
            let applying = FileManager.default.fileExists(atPath: directory.appendingPathComponent("rebase-apply/applying").path)
            operation = applying ? "am" : "rebase"
        } else if names.contains("MERGE_HEAD") {
            operation = "merge"
        } else if names.contains("CHERRY_PICK_HEAD") {
            operation = "cherry-pick"
        } else if names.contains("REVERT_HEAD") {
            operation = "revert"
        } else if names.contains("BISECT_LOG") || names.contains("BISECT_START") {
            operation = "bisect"
        } else if names.contains("sequencer") {
            operation = "sequencer"
        } else {
            operation = nil
        }
        return operation.map { .operationInProgress($0) }
    }

    /// Edits `status` cannot see (R21): index entries `ls-files -v` tags in lower case
    /// (assume-unchanged), and skip-worktree entries (`S`, `s`) whose file is present.
    private func hiddenEdits(in folder: URL) async throws -> [WorktreeRemovalRefusal] {
        let data = try await run(["ls-files", "-v", "-z"], cwd: folder)
        var assumed: [String] = []
        var skipped: [String] = []
        for field in data.split(separator: 0, omittingEmptySubsequences: true) {
            let entry = String(decoding: field, as: UTF8.self)
            guard let tag = entry.first, entry.dropFirst().first == " " else { continue }
            let path = String(entry.dropFirst(2))
            if tag.isLowercase, !assumed.contains(path) { assumed.append(path) }
            if tag == "S" || tag == "s", Self.entryExists(folder.appendingPathComponent(path).path), !skipped.contains(path) {
                skipped.append(path)
            }
        }
        var refusals: [WorktreeRemovalRefusal] = []
        if !assumed.isEmpty { refusals.append(.assumeUnchanged(Array(assumed.prefix(WorktreeRemovalRefusal.pathLimit)))) }
        if !skipped.isEmpty { refusals.append(.skipWorktreePresent(Array(skipped.prefix(WorktreeRemovalRefusal.pathLimit)))) }
        return refusals
    }

    /// Repositories inside the ignored folders (`!` entries ending `/`): every `.git` entry — a
    /// folder, or a file naming one elsewhere — is a repository `remove` would delete (R21). The
    /// walk does not descend into a `.git`, or follow a link (`remove` deletes a link, not its
    /// target). Past `limit` it stops and refuses (`.tooLargeToCheck`), with whatever it found;
    /// a folder it cannot read refuses as `.unreadable`.
    static func nestedRepositories(in folder: URL, ignored: [String], limit: WorktreeWalkLimit) -> [WorktreeRemovalRefusal] {
        let clock = ContinuousClock()
        let start = clock.now
        let deadline = Duration.seconds(limit.seconds)
        var visited = 0
        var found: [String] = []
        for entry in ignored where entry.hasSuffix("/") {
            let base = folder.appendingPathComponent(entry, isDirectory: true)
            let failure = WalkFailure()
            guard let enumerator = FileManager.default.enumerator(
                at: base, includingPropertiesForKeys: [], options: [],
                errorHandler: { url, _ in
                    failure.url = url
                    return false
                })
            else {
                return [.unreadable(base.path)]
            }
            for case let url as URL in enumerator {
                visited += 1
                if visited > limit.entries || clock.now - start > deadline {
                    return (found.isEmpty ? [] : [.nestedRepository(Array(found.prefix(WorktreeRemovalRefusal.pathLimit)))])
                        + [.tooLargeToCheck]
                }
                guard url.lastPathComponent == ".git" else { continue }
                enumerator.skipDescendants()
                let inside = url.deletingLastPathComponent().path.dropFirst(base.path.count)
                found.append(String(entry.dropLast()) + inside)
            }
            if let url = failure.url { return [.unreadable(url.path)] }
        }
        return found.isEmpty ? [] : [.nestedRepository(Array(found.prefix(WorktreeRemovalRefusal.pathLimit)))]
    }

    /// Where the enumerator's error handler records the folder it could not read.
    private final class WalkFailure: @unchecked Sendable {
        var url: URL?
    }

    /// `status --ignored=matching`'s entries: how many, and their distinct first components.
    static func ignoredSummary(_ ignored: [String]) -> IgnoredSummary {
        var top: [String] = []
        for path in ignored {
            let name = path.firstIndex(of: "/").map { String(path[...$0]) } ?? path
            if !top.contains(name) { top.append(name) }
            if top.count == IgnoredSummary.topLevelLimit { break }
        }
        return IgnoredSummary(count: ignored.count, topLevel: top)
    }

    /// A detached worktree's own commits (R22): those its HEAD reaches and no branch, tag,
    /// remote-tracking ref or **other** worktree's HEAD does — B2's union (`StrandedHolders`, its
    /// symbolic-ref excludes included), with this HEAD left out of the holders, since `--all` and
    /// B2's `worktreeHeads` both count it. Nothing for a worktree on a branch.
    private func strandedByRemoving(_ worktree: Worktree, among all: [Worktree], at root: URL) async throws -> StrandedCommits {
        guard worktree.branch == nil, let head = worktree.head, Self.isFullNonZeroObjectName(head) else { return .none }
        var others: [String] = []
        for other in all where other.path != worktree.path {
            if let id = other.head, Self.isFullNonZeroObjectName(id), !others.contains(id) { others.append(id) }
        }
        let local = try await symbolicBranchAndTagRefs(at: root)
        let holders = StrandedHolders(
            branchSymrefs: local.branches, tagSymrefs: local.tags,
            remoteExcludes: try await symbolicRemoteRefs(at: root), heads: others)
        let count = try await strandedCount(of: [head], holders, at: root)
        guard count > 0 else { return .none }
        return StrandedCommits(
            count: count, commits: try await strandedCommits(of: [head], holders, at: root), holders: [worktree.path])
    }

    // MARK: - Add

    public func addWorktree(path: String, branch: String, at root: URL) async throws -> AddWorktreeResult {
        // Before any process.
        guard path.hasPrefix("/") else { throw AddWorktreeRefusal.pathNotAbsolute(path) }
        try requireName(branch)
        try requireRefNameOrObjectName(branch)
        if Self.entryExists(path), !Self.isEmptyFolder(path) { throw AddWorktreeRefusal.pathExists(path) }

        let listed = try await listedWorktrees(at: root)
        let target = Self.resolvedPath(path)
        if listed.contains(where: { Self.isInside(target, Self.resolvedPath($0.path)) }) {
            throw AddWorktreeRefusal.pathInsideWorktree(path)
        }
        if let using = listed.first(where: { $0.branch == "refs/heads/\(branch)" }) {
            throw AddWorktreeRefusal.branchInUse(path: using.path)
        }
        if let holder = try await worktreeUsing(branch, at: root) {
            throw AddWorktreeRefusal.branchHeldByOperation(path: holder)
        }
        // Last, immediately before git: the name is a plain local branch (R17).
        guard try await isPlainLocalBranch(branch, at: root) else { throw AddWorktreeRefusal.noSuchBranch(branch) }

        let result: ProcessRunner.StreamedResult
        do {
            result = try await runWithEnvironment(["worktree", "add", "-q", "--end-of-options", path, branch], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        } catch is CancellationError {
            // git was stopped part-way, or never started. Read back outside this cancelled task:
            // a worktree that is there is reported, never "nothing happened".
            let after = try? await Task { try await self.listedWorktrees(at: root) }.value
            guard let found = after?.first(where: { Self.samePath($0.path, path) }) else { throw CancellationError() }
            return Self.added(found, branch: branch, exitCode: -1, words: "")
        }
        let words = RemoteFailureParser.gitsOwnWords(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        // Whatever the exit code (R19).
        guard let found = try await listedWorktrees(at: root).first(where: { Self.samePath($0.path, path) }) else {
            if result.exitCode != 0 { throw GitError.commandFailed(exitCode: result.exitCode, stderr: words) }
            return .unexpected(nil, gitsWords: words)
        }
        return Self.added(found, branch: branch, exitCode: result.exitCode, words: words)
    }

    /// What `list` says was added at the path.
    private static func added(_ worktree: Worktree, branch: String, exitCode: Int32, words: String) -> AddWorktreeResult {
        guard worktree.branch == "refs/heads/\(branch)" else { return .unexpected(worktree, gitsWords: words) }
        return exitCode == 0 ? .added(worktree) : .addedWithError(worktree, gitsWords: words)
    }

    /// Whether `refs/heads/<branch>` exists and is not a symbolic ref, in one read. `for-each-ref`
    /// matches a pattern by whole path components and expands globs, so only the record whose
    /// name is exactly the branch counts.
    private func isPlainLocalBranch(_ branch: String, at root: URL) async throws -> Bool {
        let data = try await run(["for-each-ref", "--format=%(refname)%00%(symref)", "--end-of-options", "refs/heads/\(branch)"], cwd: root)
        return GitLines.split(data).contains { line in
            let fields = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            return fields.count == 2 && fields[0] == "refs/heads/\(branch)" && fields[1].isEmpty
        }
    }

    // MARK: - Remove

    public func removeWorktree(_ removal: WorktreeRemoval, keeping: [String: String], at root: URL) async throws -> [String] {
        // Before any process.
        if let refusal = removal.refusals.first { throw refusal }
        for key in keeping.keys where !removal.stranded.holders.contains(key) {
            throw BranchOperationError.invalidName(key)
        }

        // The sheet's state, again, just before anything is written (RF1).
        let now = try await removalCheck(removal.worktree, at: root)
        guard now.worktree == removal.worktree, now.changes == removal.changes,
            now.ignored.count == removal.ignored.count, now.stranded.count == removal.stranded.count,
            now.refusals == removal.refusals
        else {
            throw WorktreeRemovalPartial.changedSinceShown
        }

        var kept: [String] = []
        if let name = keeping[removal.worktree.path], let head = removal.worktree.head {
            do {
                kept = try await createKeptBranches([(tip: RefTip(ref: removal.worktree.path, id: head), name: name)], at: root)
            } catch RemoteAdminPartial.keptBranchesThenStopped(let created, _, let words) {
                throw WorktreeRemovalPartial.keptBranchesThenStopped(kept: created, gitsWords: words)
            }
        }

        // The path exactly as `list` printed it (R23), and git's own refusal of an untracked file
        // put back whatever the user's `status.showUntrackedFiles` says (R21, R24).
        let path = removal.worktree.path
        let result: ProcessRunner.StreamedResult
        do {
            result = try await runWithEnvironment(["worktree", "remove", "--end-of-options", path], cwd: root, extra: Self.withConfig("status.showUntrackedFiles", "normal", over: ProcessInfo.processInfo.environment), allowedExitCodes: Self.anyExitCode)
        } catch is CancellationError {
            throw WorktreeRemovalPartial.outcomeUnknown(keptBranches: kept)
        } catch {
            // Not started at all: nothing was removed.
            guard !kept.isEmpty else { throw error }
            throw WorktreeRemovalPartial.keptBranchesThenStopped(kept: kept, gitsWords: Self.words(of: error))
        }

        // Read back, never assumed from the exit code.
        let stillListed: Bool
        do {
            stillListed = try await listedWorktrees(at: root).contains { $0.path == path }
        } catch {
            throw WorktreeRemovalPartial.outcomeUnknown(keptBranches: kept)
        }
        guard !stillListed else {
            let words = RemoteFailureParser.gitsOwnWords(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            throw WorktreeRemovalPartial.refusedByGit(gitsWords: words, keptBranches: kept)
        }
        return kept
    }

    // MARK: - Branch rows

    /// `refs` with no `checkedOutAt` naming a bare repository: `%(worktreepath)` prints a bare
    /// main repository's path for its HEAD branch, which is not a checkout (measured: `worktree
    /// add` checks that branch out). A bare repository is a folder with `HEAD` and `objects/` and
    /// no `.git`; a worktree's folder has a `.git`, and a missing one has neither.
    static func withoutBareRepositoryCheckouts(_ refs: RefCollection) -> RefCollection {
        guard refs.localBranches.contains(where: { $0.checkedOutAt.map(isBareRepository) ?? false }) else { return refs }
        let branches = refs.localBranches.map { branch in
            branch.checkedOutAt.map(isBareRepository) == true ? branch.with(checkedOutAt: nil) : branch
        }
        return RefCollection(
            localBranches: branches, remoteBranches: refs.remoteBranches, tags: refs.tags, remotes: refs.remotes)
    }

    private static func isBareRepository(_ path: String) -> Bool {
        let folder = URL(fileURLWithPath: path, isDirectory: true)
        return !entryExists(folder.appendingPathComponent(".git").path)
            && FileManager.default.fileExists(atPath: folder.appendingPathComponent("HEAD").path)
            && isDirectory(folder.appendingPathComponent("objects").path)
    }

    // MARK: - Paths (R23)

    /// The same file system object by git's rule: equal, or equal once both are resolved.
    static func samePath(_ a: String, _ b: String) -> Bool {
        a == b || resolvedPath(a) == resolvedPath(b)
    }

    /// `path` as git compares it: `..` and `.` taken out, then the deepest part that exists
    /// resolved with `realpath(3)` (`/var` → `/private/var`, links followed) and the rest put back.
    static func resolvedPath(_ path: String) -> String {
        var url = URL(fileURLWithPath: path).standardizedFileURL
        var rest: [String] = []
        while true {
            if let real = realpath(url.path, nil) {
                defer { free(real) }
                let head = String(cString: real)
                return rest.isEmpty ? head : (head == "/" ? "" : head) + "/" + rest.joined(separator: "/")
            }
            guard url.path != "/", !url.path.isEmpty else { return path }
            rest.insert(url.lastPathComponent, at: 0)
            url.deleteLastPathComponent()
        }
    }

    /// `path` is `folder` or inside it; both resolved.
    static func isInside(_ path: String, _ folder: String) -> Bool {
        path == folder || path.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// Something is at `path` — a file, a folder or a link, dangling or not (`lstat`).
    static func entryExists(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)) != nil
    }

    /// A real folder (not a link to one) with nothing in it. One that cannot be listed is not.
    static func isEmptyFolder(_ path: String) -> Bool {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType,
            type == .typeDirectory, let names = try? FileManager.default.contentsOfDirectory(atPath: path)
        else { return false }
        return names.isEmpty
    }

    static func isDirectory(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) && isDirectory.boolValue
    }
}
