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
/// - `rev-list --count --not --exclude=<alias>… --branches --exclude=refs/tags/<alias>…
///   --glob=refs/tags --exclude=<r>/<b>… --remotes <HEAD ids…> --not --end-of-options <refs…>`
///   gives the same union as the spec's `<refs…> --not …` spelling (2 on R5's fixture), every
///   selector after its own excludes; `--glob=refs/tags` lists nested tags as `--tags` does and,
///   unlike `--tags`, can be appended (the scanner reads `--tags` in a fragment as `push`'s).
///   An exclude before `--glob` is a full name (a short one excluded nothing); before
///   `--branches`/`--remotes` a short one (fix round 1).
/// - `git worktree list --porcelain -z` gives every worktree's HEAD as a `HEAD <id>` field; a
///   commit held by another worktree's detached HEAD is held (count 0). A stash entry is not a
///   holder (fix round 1, I1).
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
    /// as a name-only line (measured: `nourl\t`) and `RemoteParser` leaves out. Internal since
    /// Task 2: Set Upstream asks which remotes map a ref.
    func configuredRemoteNames(at root: URL) async throws -> Set<String> {
        let data = try await run(["remote", "-v"], cwd: root)
        return Set(GitLines.split(data).compactMap { line in
            let name = line.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false).first
                .map(String.init) ?? ""
            return name.isEmpty ? nil : name
        })
    }

    // MARK: - Stranded commits

    public func stranded(by refs: [String], at root: URL) async throws -> StrandedCommits {
        let unique = try Self.uniqueRemoteTrackingRefs(refs, check: requireRemoteTrackingRef)
        guard !unique.isEmpty else { return .none }
        let holders = try await StrandedHolders.read(for: unique, by: self, at: root)

        let count = try await strandedCount(of: unique, holders, at: root)
        guard count > 0 else { return .none }
        let commits = try await strandedCommits(of: unique, holders, at: root)

        // A holder reaches at least one of them: the same question, asked of one ref, with every
        // ref of the set still excluded.
        var reaching: [String] = []
        for ref in unique where try await strandedCount(of: [ref], holders, at: root) > 0 {
            reaching.append(ref)
        }
        return StrandedCommits(count: count, commits: commits, holders: reaching)
    }

    /// `refs`, each checked, without repeats, in order.
    private static func uniqueRemoteTrackingRefs(
        _ refs: [String], check: (String) throws -> Void
    ) throws -> [String] {
        var unique: [String] = []
        for ref in refs {
            try check(ref)
            if !unique.contains(ref) { unique.append(ref) }
        }
        return unique
    }

    /// What a stranded count excludes from the refs that hold commits, and what it adds.
    ///
    /// - **Symbolic refs hold nothing of their own** — delete the ref one names and it dangles —
    ///   but `--branches`, `--tags` and `--remotes` resolve each to its target's commit, so one
    ///   naming a pruned ref made the union 0 (R5 for `refs/remotes/<r>/HEAD`; fix round 1, Minor
    ///   3, measured for `refs/heads/alias` and `refs/tags/alias`). Every symref is excluded, by
    ///   the spelling each selector reads: short before `--branches` and `--remotes`, **full**
    ///   before `--glob=refs/tags` (measured: a short one there excludes nothing). A symref whose
    ///   target is an ordinary ref loses nothing by it — the target is listed itself.
    /// - **Every worktree's HEAD** (this one's included), by id: `--branches --tags --remotes`
    ///   leave a detached HEAD out (R5). An unborn HEAD has no id and holds nothing.
    /// - **Not the stash** (fix round 1, I1, Ruling 5): a stash entry is not a place a commit is
    ///   kept — `GitBranchBackend.commitsOnlyOn`'s rule — and a later drop would lose it.
    struct StrandedHolders {
        let branchSymrefs: [String]
        let tagSymrefs: [String]
        let remoteExcludes: [String]
        let heads: [String]

        static func read(for refs: [String], by backend: CLIGitBackend, at root: URL) async throws -> StrandedHolders {
            let local = try await backend.symbolicBranchAndTagRefs(at: root)
            // The refs being asked about are excluded from `--remotes` too, in its short spelling
            // (a full name excludes nothing there, R5).
            let remote = refs.map { String($0.dropFirst(remoteTrackingPrefix.count)) }
                + (try await backend.symbolicRemoteRefs(at: root))
            return StrandedHolders(
                branchSymrefs: local.branches, tagSymrefs: local.tags, remoteExcludes: remote,
                heads: try await backend.worktreeHeads(at: root))
        }

        /// The rest of a stranded vector after `["rev-list", <mode…>, "--not"]`: each selector
        /// after its `--exclude=`s (an exclude applies to the next selector only), the HEADs
        /// (still negative), then `--not` again and the refs asked about, after
        /// `--end-of-options` — which `rev-list` accepts here because no option follows it.
        /// `--glob=refs/tags` is `--tags` (nested tags included, measured) spelled so that it can
        /// be appended: the scanner reads a `--tags` outside a classified literal as `push`'s.
        func complete(_ arguments: inout [String], asking refs: [String]) {
            for name in branchSymrefs { arguments.append("--exclude=" + name) }
            arguments.append("--branches")
            for name in tagSymrefs { arguments.append("--exclude=" + name) }
            arguments.append("--glob=refs/tags")
            for name in remoteExcludes { arguments.append("--exclude=" + name) }
            arguments.append("--remotes")
            arguments += heads
            arguments.append("--not")
            arguments.append("--end-of-options")
            arguments += refs
        }
    }

    /// One `rev-list --count`: how many commits only `refs` hold.
    private func strandedCount(of refs: [String], _ holders: StrandedHolders, at root: URL) async throws -> Int {
        var arguments = ["rev-list", "--count", "--not"]
        holders.complete(&arguments, asking: refs)
        return try await revListCount(arguments, at: root)
    }

    /// The newest `StrandedCommits.displayLimit` of them.
    private func strandedCommits(of refs: [String], _ holders: StrandedHolders, at root: URL) async throws -> [CommitRef] {
        var listing = ["rev-list", "--max-count=\(StrandedCommits.displayLimit)", "--format=%H%x00%s", "--no-commit-header", "--not"]
        holders.complete(&listing, asking: refs)
        return GitLines.split(try await run(listing, cwd: root)).compactMap { line -> CommitRef? in
            let fields = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, Self.isFullNonZeroObjectName(String(fields[0])) else { return nil }
            return CommitRef(sha: String(fields[0]), subject: String(fields[1]))
        }
    }

    /// Every worktree's HEAD, as full ids.
    func worktreeHeads(at root: URL) async throws -> [String] {
        let data = try await run(["worktree", "list", "--porcelain", "-z"], cwd: root)
        var ids: [String] = []
        for field in data.split(separator: 0, omittingEmptySubsequences: true) {
            let text = String(decoding: field, as: UTF8.self)
            guard text.hasPrefix("HEAD ") else { continue }
            let id = String(text.dropFirst("HEAD ".count))
            if Self.isFullNonZeroObjectName(id), !ids.contains(id) { ids.append(id) }
        }
        return ids
    }

    /// Every symbolic ref under `refs/heads/` (short, as `--branches` reads an exclude) and under
    /// `refs/tags/` (full, as `--glob=refs/tags` reads one). A dangling one is not listed by
    /// `for-each-ref`, and holds nothing.
    func symbolicBranchAndTagRefs(at root: URL) async throws -> (branches: [String], tags: [String]) {
        let data = try await run(["for-each-ref", "--format=%(refname)%00%(symref)", "--end-of-options", "refs/heads", "refs/tags"], cwd: root)
        var branches: [String] = []
        var tags: [String] = []
        for line in GitLines.split(data) {
            let fields = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, !fields[1].isEmpty else { continue }
            if fields[0].hasPrefix("refs/heads/") {
                branches.append(String(fields[0].dropFirst("refs/heads/".count)))
            } else if fields[0].hasPrefix("refs/tags/") {
                tags.append(String(fields[0]))
            }
        }
        return (branches, tags)
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
        try await refuseUnlessStrandedIsWhatTheSheetShowed(plan, at: root)

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
            do {
                try await createKeptBranch(branch.name, at: branch.tip.id, in: root)
            } catch {
                // Nothing created yet: a plain failure, and the repository is as it was. Otherwise
                // the branches already created stay, and the error says which (fix round 1, I2).
                guard !keptBranches.isEmpty else { throw error }
                throw RemoteAdminPartial.keptBranchesThenStopped(
                    kept: keptBranches, failedName: branch.name, gitsWords: Self.words(of: error))
            }
            keptBranches.append(branch.name)
        }

        // 4. One compare-and-delete per ref; every ref is tried, until a cancellation.
        var deleted: [RefTip] = []
        var skippedMoved: [RefTip] = []
        var failed: [RefFailure] = []
        var outcomeUnknown: [RefTip] = []
        var notTried: [RefTip] = []
        for (index, tip) in plan.refs.enumerated() {
            // Cancelled between two deletes: the rest are exactly where they were.
            if Task.isCancelled {
                notTried = Array(plan.refs[index...])
                break
            }
            let rest = String(tip.ref.dropFirst(Self.remoteTrackingPrefix.count))
            let expected = tip.id
            let result: ProcessRunner.StreamedResult
            do {
                // `--no-deref`: a symbolic ref is deleted itself, never followed onto its target.
                result = try await runWithEnvironment(["update-ref", "--no-deref", "-d", "--end-of-options", "refs/remotes/\(rest)", "\(expected)"], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
            } catch is CancellationError {
                // git was stopped part-way (or never started — the runner cannot say which), so
                // whether this ref is gone is not known (fix round 1, Minor 1).
                outcomeUnknown.append(tip)
                notTried = Array(plan.refs[(index + 1)...])
                break
            } catch {
                // It could not be started (a launch failure): nothing ran.
                failed.append(RefFailure(tip: tip, gitsWords: Self.words(of: error)))
                continue
            }
            if result.exitCode == 0 {
                deleted.append(tip)
                continue
            }
            // git refused, and a refused compare-and-delete changes nothing: the ref either moved
            // (or went) since the list, or git refused for a reason of its own.
            let words = RemoteFailureParser.gitsOwnWords(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
            if let now = try? await currentID(of: tip.ref, at: root), now != expected {
                skippedMoved.append(tip)
            } else {
                failed.append(RefFailure(tip: tip, gitsWords: words))
            }
        }
        return PruneResult(
            deleted: deleted, skippedMoved: skippedMoved, keptBranches: keptBranches, failed: failed,
            outcomeUnknown: outcomeUnknown, notTried: notTried)
    }

    /// `.strandedGrew` unless deleting the refs that still hold their listed ids would strand
    /// only commits the sheet showed (fix round 1, Minor 2). The count alone is not enough: one
    /// commit losing its holder while another gains one keeps it equal and strands a commit
    /// nobody was shown. So when the sheet listed every stranded commit (`count ≤ displayLimit`),
    /// the commits now stranded must be among them; past that only the count can be compared.
    private func refuseUnlessStrandedIsWhatTheSheetShowed(_ plan: PrunePlan, at root: URL) async throws {
        let tips = try await remoteTrackingTips(at: root)
        let stillListed = plan.refs.filter { tips[$0.ref] == $0.id }.map(\.ref)
        guard !stillListed.isEmpty else { return }
        let holders = try await StrandedHolders.read(for: stillListed, by: self, at: root)
        let count = try await strandedCount(of: stillListed, holders, at: root)
        guard count <= plan.stranded.count else { throw RemoteAdminRefusal.strandedGrew }
        guard count > 0, plan.stranded.count <= StrandedCommits.displayLimit else { return }
        let shown = Set(plan.stranded.commits.map(\.sha))
        let now = try await strandedCommits(of: stillListed, holders, at: root)
        guard now.allSatisfy({ shown.contains($0.sha) }) else { throw RemoteAdminRefusal.strandedGrew }
    }

    /// An error in words for a notice: git's own (redacted) for a git failure.
    private static func words(of error: Error) -> String {
        if case GitError.commandFailed(_, let stderr) = error { return RemoteFailureParser.gitsOwnWords(stderr) }
        return String(describing: error)
    }

    /// What `ref` holds now, or "" when it does not exist. Internal since Task 2: a refused
    /// fast-forward asks the same of its branch.
    func currentID(of ref: String, at root: URL) async throws -> String {
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
