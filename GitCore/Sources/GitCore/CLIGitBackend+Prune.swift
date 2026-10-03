import Foundation

/// Prune and gone branches (B2 Task 1). See `GitRemoteAdminBackend` for the contract; this file
/// is about how each vector is spelled, what is refused before git runs, and how git's answers
/// are read.
///
/// Every vector is pinned in `ForceFlagScannerTests.allowsThePruneVectorsThisMilestoneNeeds`,
/// and the bindings are named as they are there (`remote`, `rest`, `expected`, `name`, `id`):
/// the contract is the text. Two of them are exceptions the scanner grants by exact shape — the
/// dry-run listing is the only `fetch --prune` (`denyTableExceptionShapes`), and the delete is
/// `update-ref`'s remote-tracking compare-and-delete (`allowedShapes`).
///
/// **Measured for this task (git 2.54, `LC_ALL=C`, local bare remotes, scratch repositories):**
/// - The listing's porcelain line is `- <old> 0000… refs/remotes/<r>/<b>`, on stdout, exit 0;
///   a symbolic `refs/remotes/<r>/HEAD` left dangling is a stderr notice and is never listed.
/// - `rev-list --count --not --branches --tags --exclude=<r>/<b>… --remotes <ids…> --not
///   --end-of-options <refs…>` gives the same union as the spec's `<refs…> --not …` spelling (2
///   on R5's fixture) while keeping `--branches`/`--tags` in one array literal that begins with
///   `rev-list` — the scanner reads `--tags` (and `--all`) in a fragment as `push`'s and
///   `fetch`'s — and lets the refs follow `--end-of-options`.
/// - `git worktree list --porcelain -z` gives every worktree's HEAD as a `HEAD <id>` field; a
///   commit held by another worktree's detached HEAD, or by a stash entry, is held (count 0).
/// - `update-ref --no-deref -d --end-of-options <ref> <id>` deletes a packed ref; on a moved one
///   it is `error: cannot lock ref '…': is at <x> but expected <y>`, exit 1, nothing changed.
/// - `branch --no-track --end-of-options <name> <id>` creates the branch with no `branch.<name>.*`
///   even under `branch.autoSetupMerge=always`; an existing name is `fatal: a branch named '…'
///   already exists`, exit 128.
/// - `for-each-ref` with `%(upstream:track)` and `%(worktreepath)` reads the same with another
///   process holding `config.lock` (Ruling 2).
extension CLIGitBackend: GitRemoteAdminBackend {

    // MARK: - The list

    public func prunePlan(_ remote: String, at root: URL) async throws -> PrunePlan {
        try requireRemoteName(remote)
        guard try await configuredRemoteNames(at: root).contains(remote) else {
            throw RemoteAdminRefusal.noSuchRemote(remote)
        }
        // A mirror remote's `+refs/*:refs/*` lists local branches as prunable (R3); the filter to
        // `refs/remotes/` below would hide them, but a remote whose fetch writes outside
        // `refs/remotes/` is refused outright, as fetch refuses it.
        if let refspec = try await unsafeFetchRefspec(of: remote, at: root) {
            throw RemoteAdminRefusal.unsafeRefspec(refspec)
        }

        // The one `fetch --prune` in GitCore: `--dry-run` deletes nothing (R2), and
        // `--no-prune-tags` keeps `fetch.pruneTags` / `remote.<r>.pruneTags` from listing local
        // tags that were never on the server (R8). Streamed, so a cancelled lane task kills it.
        let listed: ProcessRunner.StreamedResult
        do {
            listed = try await runStreaming(["fetch", "--prune", "--no-prune-tags", "--dry-run", "--porcelain", "--no-progress", "--end-of-options", remote], cwd: root, progress: { _ in })
        } catch GitError.commandFailed(let code, let stderr) {
            throw diagnosed(exitCode: code, stderr: stderr)
        }
        let refs = Self.prunedRemoteTrackingRefs(porcelain: listed.stdout)
        return PrunePlan(remote: remote, refs: refs, stranded: try await stranded(by: refs.map(\.ref), at: root))
    }

    /// The `-` (pruned) lines of a `fetch --porcelain` under `refs/remotes/`, in git's order:
    /// `<flag> <old> <new> <ref>` (R2). A line whose old id is not a full, non-zero id is left
    /// out — a compare-and-delete could not be made on it, and what is not listed is not deleted.
    static func prunedRemoteTrackingRefs(porcelain data: Data) -> [RefTip] {
        GitLines.split(data).compactMap { line in
            guard line.hasPrefix("- ") else { return nil }
            let fields = line.dropFirst(2).split(separator: " ", omittingEmptySubsequences: false)
            guard fields.count == 3, fields[2].hasPrefix("refs/remotes/"),
                isFullNonZeroObjectName(String(fields[0]))
            else { return nil }
            return RefTip(ref: String(fields[2]), id: String(fields[0]))
        }
    }

    /// Every configured remote's name — one with no URL included, which `git remote -v` prints
    /// as a name-only line (measured: `nourl\t`) and `RemoteParser` leaves out.
    private func configuredRemoteNames(at root: URL) async throws -> Set<String> {
        let data = try await run(["remote", "-v"], cwd: root)
        return Set(GitLines.split(data).compactMap { line in
            let name = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? ""
            return name.isEmpty ? nil : name
        })
    }

    // MARK: - Stranded commits

    public func stranded(by refs: [String], at root: URL) async throws -> StrandedCommits {
        for ref in refs { try requireRemoteTrackingRef(ref) }
        var unique: [String] = []
        for ref in refs where !unique.contains(ref) { unique.append(ref) }
        guard !unique.isEmpty else { return .none }

        // Every holder `--branches --tags --remotes` leaves out (R5): each worktree's HEAD and
        // each stash entry, by id.
        let heldElsewhere = try await worktreeHeadsAndStashEntries(at: root)
        // Short names in the `--remotes` namespace (a full name excludes nothing there, R5), and
        // every symbolic remote-tracking ref (`origin/HEAD` would otherwise hold its target).
        let excludes = unique.map { String($0.dropFirst(Self.remoteTrackingPrefix.count)) }
            + (try await symbolicRemoteRefs(at: root))

        var arguments = ["rev-list", "--count", "--not", "--branches", "--tags"]
        Self.completeStrandedVector(&arguments, excluding: excludes, heldElsewhere: heldElsewhere, from: unique)
        let count = try await revListCount(arguments, at: root)
        guard count > 0 else { return .none }

        var listing = ["rev-list", "--max-count=\(StrandedCommits.displayLimit)", "--format=%H%x00%s", "--no-commit-header", "--not", "--branches", "--tags"]
        Self.completeStrandedVector(&listing, excluding: excludes, heldElsewhere: heldElsewhere, from: unique)
        let commits = GitLines.split(try await run(listing, cwd: root)).compactMap { line -> CommitRef? in
            let fields = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, Self.isFullNonZeroObjectName(String(fields[0])) else { return nil }
            return CommitRef(sha: String(fields[0]), subject: String(fields[1]))
        }

        // A holder reaches at least one of them: the same question, asked of one ref, with every
        // ref of the set still excluded.
        var holders: [String] = []
        for ref in unique {
            var one = ["rev-list", "--count", "--not", "--branches", "--tags"]
            Self.completeStrandedVector(&one, excluding: excludes, heldElsewhere: heldElsewhere, from: [ref])
            if try await revListCount(one, at: root) > 0 { holders.append(ref) }
        }
        return StrandedCommits(count: count, commits: commits, holders: holders)
    }

    /// The rest of a stranded vector after `["rev-list", <mode>, "--not", "--branches",
    /// "--tags"]`: each `--exclude=` before the `--remotes` it applies to, the other holders' ids
    /// (still negative), then `--not` again and the refs being asked about, after
    /// `--end-of-options` — which `rev-list` accepts here because no option follows it.
    private static func completeStrandedVector(
        _ arguments: inout [String], excluding excludes: [String], heldElsewhere: [String], from refs: [String]
    ) {
        for pattern in excludes { arguments.append("--exclude=" + pattern) }
        arguments.append("--remotes")
        arguments += heldElsewhere
        arguments.append("--not")
        arguments.append("--end-of-options")
        arguments += refs
    }

    /// Every worktree's HEAD (this one's included) and every stash entry, as full ids. A HEAD
    /// that is unborn has no id and holds nothing.
    private func worktreeHeadsAndStashEntries(at root: URL) async throws -> [String] {
        let data = try await run(["worktree", "list", "--porcelain", "-z"], cwd: root)
        var ids: [String] = []
        for field in data.split(separator: 0, omittingEmptySubsequences: true) {
            let text = String(decoding: field, as: UTF8.self)
            guard text.hasPrefix("HEAD ") else { continue }
            let id = String(text.dropFirst("HEAD ".count))
            if Self.isFullNonZeroObjectName(id), !ids.contains(id) { ids.append(id) }
        }
        for entry in try await stashes(at: root) where Self.isFullNonZeroObjectName(entry.sha) {
            if !ids.contains(entry.sha) { ids.append(entry.sha) }
        }
        return ids
    }

    private static let remoteTrackingPrefix = "refs/remotes/"

    /// Refuses a name that is not a full remote-tracking ref, before git runs. It is written into
    /// a `rev-list` as a revision and into an `--exclude=` pattern, so on top of the prefix:
    /// no revision syntax (`requireRefNameOrObjectName` — `a..b` is a range), no glob character
    /// (a pattern would exclude refs nobody named), no whitespace or backslash. git's own
    /// ref-name rules forbid every one of these, so no real ref is refused.
    func requireRemoteTrackingRef(_ ref: String) throws {
        let prefix = Self.remoteTrackingPrefix
        guard ref.hasPrefix(prefix), ref.count > prefix.count, !ref.hasSuffix("/"),
            !ref.contains(where: { "*?[\\".contains($0) || $0.isWhitespace })
        else {
            throw BranchOperationError.invalidName(ref)
        }
        try requireRefNameOrObjectName(ref)
    }

    // MARK: - The prune

    public func prune(_ plan: PrunePlan, keeping: [String: String], at root: URL) async throws -> PruneResult {
        // 1. Before any process. An empty or all-zero expected value makes `update-ref -d` delete
        // unconditionally (R6), and a short one is resolved by git, not compared.
        for tip in plan.refs {
            guard Self.isFullNonZeroObjectName(tip.id) else { throw RemoteAdminRefusal.invalidObjectID }
            try requireRemoteTrackingRef(tip.ref)
        }
        let listed = Set(plan.refs.map(\.ref))
        for ref in keeping.keys where !listed.contains(ref) { throw BranchOperationError.invalidName(ref) }

        // 2. What deleting the refs that still hold their listed ids would strand now. A ref that
        // moved or is gone will not be deleted, so it is a holder like any other.
        let tips = try await remoteTrackingTips(at: root)
        let stillListed = plan.refs.filter { tips[$0.ref] == $0.id }.map(\.ref)
        guard try await stranded(by: stillListed, at: root).count <= plan.stranded.count else {
            throw RemoteAdminRefusal.strandedGrew
        }

        // 3. Every kept branch's name, then every kept branch, at the id the sheet showed —
        // all before the first delete.
        let kept = plan.refs.compactMap { tip in keeping[tip.ref].map { (tip: tip, name: $0) } }
        var names = Set<String>()
        for branch in kept {
            if let problem = try await keepBranchNameProblem(branch.name, at: root) { throw problem }
            guard names.insert(branch.name.lowercased()).inserted else {
                throw RemoteAdminRefusal.branchExists(branch.name)
            }
        }
        var keptBranches: [String] = []
        for branch in kept {
            try await createKeptBranch(branch.name, at: branch.tip.id, in: root)
            keptBranches.append(branch.name)
        }

        // 4. One compare-and-delete per ref; every ref is tried.
        var deleted: [RefTip] = []
        var skippedMoved: [RefTip] = []
        var failed: [RefFailure] = []
        for tip in plan.refs {
            do {
                switch try await deleteRemoteTrackingRef(tip, at: root) {
                case nil: deleted.append(tip)
                case .some(let words?): failed.append(RefFailure(tip: tip, gitsWords: words))
                case .some(nil): skippedMoved.append(tip)
                }
            } catch {
                // A launch failure or a cancellation: not known to be deleted, and the refs after
                // it are still tried (each fails the same way at once if the task is cancelled).
                failed.append(RefFailure(tip: tip, gitsWords: String(describing: error)))
            }
        }
        return PruneResult(deleted: deleted, skippedMoved: skippedMoved, keptBranches: keptBranches, failed: failed)
    }

    /// Deletes `tip.ref` only while it holds `tip.id`: nil when it did; `.some(nil)` when the ref
    /// no longer held that id (moved or gone, RF1); `.some(words)` when git refused for a reason
    /// of its own — a held lock, a `reference-transaction` hook — and the ref still holds it.
    private func deleteRemoteTrackingRef(_ tip: RefTip, at root: URL) async throws -> String?? {
        let rest = String(tip.ref.dropFirst(Self.remoteTrackingPrefix.count))
        let expected = tip.id
        // `--no-deref`: a symbolic ref is deleted itself, never followed onto the ref it names.
        let result = try await runWithEnvironment(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/remotes/\(rest)", "\(expected)"], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        guard result.exitCode != 0 else { return nil }
        guard try await currentID(of: tip.ref, at: root) == expected else { return .some(nil) }
        return .some(RemoteFailureParser.gitsOwnWords(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    /// What `ref` holds now, or "" when it does not exist.
    private func currentID(of ref: String, at root: URL) async throws -> String {
        let data = try await run(["rev-parse", "--verify", "-q", "--end-of-options", ref], cwd: root, allowedExitCodes: [1])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Every remote-tracking ref and the id it holds, in one read.
    private func remoteTrackingTips(at root: URL) async throws -> [String: String] {
        let data = try await run(["for-each-ref", "--format=%(refname)%00%(objectname)", "--end-of-options", "refs/remotes"], cwd: root)
        var tips: [String: String] = [:]
        for line in GitLines.split(data) {
            let fields = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            if fields.count == 2 { tips[String(fields[0])] = String(fields[1]) }
        }
        return tips
    }

    /// `branch --no-track`: the kept branch has no upstream whatever `branch.autoSetupMerge`
    /// says, so it never shows as "gone" itself. git's "already exists" — a branch made in a
    /// terminal since the name was checked — is `.branchExists`; anything else is git's words.
    private func createKeptBranch(_ name: String, at id: String, in root: URL) async throws {
        let result = try await runWithEnvironment(["branch", "--no-track", "--end-of-options", name, id], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        guard result.exitCode != 0 else { return }
        if result.stderr.contains("already exists") { throw RemoteAdminRefusal.branchExists(name) }
        throw GitError.commandFailed(
            exitCode: result.exitCode, stderr: result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    // MARK: - Kept branch names (Ruling 1)

    public func keepBranchNameProblem(_ name: String, at root: URL) async throws -> RemoteAdminRefusal? {
        // New Branch's own check (`check-ref-format --branch`, and the four shapes it accepts
        // while meaning something else), and a root-ref name: `MERGE_HEAD` passes
        // `check-ref-format` and then shadows git's own (B17).
        guard try await validateBranchName(name, at: root), !Self.isRootRefName(name) else {
            return .invalidBranchName(name)
        }
        // Taken, compared as the file system compares names: a local or remote-tracking branch
        // of that name or one a path level above or below it (git cannot store `a` beside `a/b`),
        // a tag, or a remote (`origin` alone resolves to `refs/remotes/origin/HEAD`).
        let folded = name.lowercased()
        let refs = try await refNames(at: root)
        let clashesWithABranch = refs.branches.contains {
            $0 == folded || $0.hasPrefix(folded + "/") || folded.hasPrefix($0 + "/")
        }
        let remotes = try await configuredRemoteNames(at: root).map { $0.lowercased() }
        if clashesWithABranch || refs.tags.contains(folded) || remotes.contains(folded) {
            return .branchExists(name)
        }
        return nil
    }

    // MARK: - Gone branches

    public func goneBranches(at root: URL) async throws -> [GoneBranch] {
        // Each record ends `%00` and git adds the newline, so records are cut at NUL + newline: a
        // worktree path can hold a newline, never a NUL (R9: `[gone]` covers remote and local
        // upstreams; a missing remote's branch has an empty upstream).
        let data = try await run(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(upstream)%00%(upstream:track)%00%(worktreepath)%00", "--end-of-options", "refs/heads"], cwd: root)
        var gone: [GoneBranch] = []
        for record in String(decoding: data, as: UTF8.self).components(separatedBy: "\u{0}\n") {
            let fields = record.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 5, fields[3] == "[gone]", fields[0].hasPrefix("refs/heads/") else { continue }
            let name = String(fields[0].dropFirst("refs/heads/".count))
            // The branch delete's own count. A name the branch backend refuses (one beginning
            // with `-`, made with `update-ref`) is a branch Gitter cannot delete either; it is
            // left out rather than failing the whole list.
            let uniqueCommits: Int
            do {
                uniqueCommits = try await commitsOnlyOn(branch: name, at: root)
            } catch is BranchOperationError {
                continue
            }
            gone.append(GoneBranch(
                name: name, tip: fields[1], upstream: fields[2], uniqueCommits: uniqueCommits,
                checkedOutAt: fields[4].isEmpty ? nil : fields[4]))
        }
        return gone
    }
}
