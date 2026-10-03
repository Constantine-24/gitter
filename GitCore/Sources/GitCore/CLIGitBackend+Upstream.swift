import Foundation

/// Fast-forward a branch that is not checked out, and set or unset a branch's upstream (B2
/// Task 2). See `GitRemoteAdminBackend` for the contract; this file is about how each vector is
/// spelled, what is refused before git runs, and how git's answers are read.
///
/// Every vector is pinned in `ForceFlagScannerTests.allowsTheUpstreamVectorsThisMilestoneNeeds`,
/// and the bindings are named as they are there (`message`, `name`, `new`, `old`, `rest`,
/// `branch`, `worktree`, `key`, `ref`): the contract is the text. Three are shapes the scanner
/// grants whole — `update-ref`'s `refs/heads/` compare-and-set (`allowedShapes`) and `branch`'s
/// two upstream vectors (`denyTableExceptionShapes`).
///
/// **Measured for this task (git 2.54, `LC_ALL=C`, local bare remotes, scratch repositories):**
/// - `update-ref --no-deref -m <msg> --end-of-options refs/heads/<b> <new> <old>` moves a plain
///   branch exactly as without `--no-deref`, reflog message `<msg>`. On a symbolic branch
///   (`refs/heads/alias` → `refs/heads/main`) it turned the alias into a plain branch at `<new>`
///   and left `main` alone; **without** `--no-deref` it moves `main` — the checked-out branch, past
///   every worktree check made on the alias's name. A symbolic branch is refused up front, and
///   `--no-deref` stays as the second wall.
/// - Lost race: `fatal: update_ref failed for ref 'refs/heads/<b>': cannot lock ref '…': is at
///   <x> but expected <old>`, exit 128; a deleted branch: `… unable to resolve reference …`, exit
///   128; a `reference-transaction` hook exiting 1 in `preparing`: `fatal: in 'preparing' phase,
///   update aborted by the reference-transaction hook`, exit 128. The branch is unchanged in all
///   three.
/// - A branch being **rebased** in another worktree (HEAD detached, `rebase-merge/head-name` =
///   `refs/heads/<b>`) has an empty `%(worktreepath)`, and `git branch -f <b>` refuses it
///   ("cannot force update the branch '<b>' used by worktree at '…'"): git counts it as checked
///   out, and so does this file — and a bisect started from it (`BISECT_START` = `<b>`) the same.
/// - `branch --set-upstream-to=<full ref> --end-of-options <b>` (R17, R24): its refusals are
///   `fatal: the requested upstream branch '<ref>' does not exist`, `fatal: cannot set up
///   tracking information; starting point '<ref>' is not a branch` and `fatal: not tracking:
///   ambiguous information for ref '<ref>'`, each exit 128 with nothing written; a symbolic
///   `refs/remotes/<r>/HEAD` is followed (it tracked `origin/main`), so it is refused up front.
///   Under `branch.autoSetupRebase=always` a `branch.<b>.rebase=false` the user had became the
///   one value `true`.
/// - `branch --unset-upstream --end-of-options <b>` on a branch with none: `fatal: branch '<b>'
///   has no upstream information`, exit 128.
extension CLIGitBackend {

    // MARK: - Fast-forward

    public func fastForward(_ branch: String, expecting tip: String, at root: URL) async throws -> FastForwardOutcome {
        // Before any process. A short or empty expected value is no compare at all (R6).
        try requireName(branch)
        guard Self.isFullNonZeroObjectName(tip) else { throw RemoteAdminRefusal.invalidObjectID }

        guard let state = try await branchState(branch, at: root) else { throw FastForwardRefusal.moved }
        // Moving an alias would move the branch it names: refused, whatever `--no-deref` does.
        guard state.symref.isEmpty else { throw BranchOperationError.invalidName(branch) }
        if let path = state.worktreePath { throw FastForwardRefusal.checkedOut(path: path) }
        if let path = try await worktreeRebasingOrBisecting(branch, at: root) {
            throw FastForwardRefusal.checkedOut(path: path)
        }
        guard state.tip == tip else { throw FastForwardRefusal.moved }
        guard !state.upstream.isEmpty, let upstreamTip = try await commitID(of: state.upstream, at: root) else {
            throw FastForwardRefusal.noUpstream
        }
        if upstreamTip == tip { return .upToDate }

        // Ancestry between two fixed ids cannot change, so this answer holds for the
        // compare-and-set below, which moves the branch only from `tip` (R15).
        guard try await isAncestor(tip, of: upstreamTip, at: root) else {
            let ahead = try await commitCount(in: tip, notIn: upstreamTip, at: root)
            let behind = try await commitCount(in: upstreamTip, notIn: tip, at: root)
            throw behind == 0 ? FastForwardRefusal.ahead(ahead) : FastForwardRefusal.diverged(ahead: ahead, behind: behind)
        }
        return try await compareAndSet(branch, from: tip, to: upstreamTip, upstreamName: state.upstreamShort, at: root)
    }

    /// The one write: `update-ref`'s compare-and-set, under the names the scanner's contract
    /// spells. Cancelled before it starts: nothing written. Cancelled while it runs: unknown.
    private func compareAndSet(
        _ branch: String, from old: String, to new: String, upstreamName: String, at root: URL
    ) async throws -> FastForwardOutcome {
        let name = branch
        let message = "Gitter: fast-forward \(branch) to \(upstreamName)"
        try Task.checkCancellation()
        let result: ProcessRunner.StreamedResult
        do {
            result = try await runWithEnvironment(["update-ref", "--no-deref", "-m", message, "--end-of-options", "refs/heads/\(name)", "\(new)", "\(old)"], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        } catch is CancellationError {
            // git was stopped part-way, or never started — the runner cannot say which (Task 1's
            // rule for a cancelled write): never "nothing changed".
            throw RemoteAdminPartial.fastForwardOutcomeUnknown(branch: branch, from: old, to: new)
        }
        guard result.exitCode != 0 else { return .fastForwarded(from: old, to: new) }

        // A refused compare-and-set changes nothing. The branch no longer holding `old` is the
        // lost race (RF1); otherwise git refused for a reason of its own — a hook, a lock.
        let words = RemoteFailureParser.gitsOwnWords(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        if let now = try? await currentID(of: "refs/heads/\(branch)", at: root), now != old {
            throw FastForwardRefusal.moved
        }
        throw GitError.commandFailed(exitCode: result.exitCode, stderr: words)
    }

    /// What `refs/heads/<branch>` is, in one read: nil when there is no such branch.
    private struct BranchState {
        let tip: String
        let symref: String
        let upstream: String
        let upstreamShort: String
        let worktreePath: String?
    }

    private func branchState(_ branch: String, at root: URL) async throws -> BranchState? {
        // `for-each-ref` matches a pattern by whole path components (`refs/heads/keep` lists
        // `keep/sub` too) and expands globs, so only the record whose name is exactly the branch
        // counts. Records end `%00` + git's newline: a worktree path can hold a newline, never
        // a NUL (as `goneBranches` reads them).
        let data = try await run(["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)%00%(upstream)%00%(upstream:short)%00%(worktreepath)%00", "--end-of-options", "refs/heads/\(branch)"], cwd: root)
        for record in String(decoding: data, as: UTF8.self).components(separatedBy: "\u{0}\n") {
            let fields = record.split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 6, fields[0] == "refs/heads/\(branch)" else { continue }
            return BranchState(
                tip: fields[1], symref: fields[2], upstream: fields[3], upstreamShort: fields[4],
                worktreePath: fields[5].isEmpty ? nil : fields[5])
        }
        return nil
    }

    /// The commit `upstream` (a full ref name git printed) holds, or nil when it does not
    /// resolve — an upstream that is gone. Peeled, so a branch is only ever set to a commit.
    private func commitID(of upstream: String, at root: URL) async throws -> String? {
        let data = try await run(["rev-parse", "--verify", "-q", "--end-of-options", "\(upstream)^{commit}"], cwd: root, allowedExitCodes: [1])
        let id = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !id.isEmpty else { return nil }
        guard Self.isFullNonZeroObjectName(id) else {
            throw GitError.commandFailed(exitCode: -1, stderr: "unexpected rev-parse output: \(id)")
        }
        return id
    }

    /// The worktree in which `branch` is being rebased or bisected, or nil. Asked only of the
    /// worktrees whose HEAD is detached — a branch checked out anywhere else is
    /// `%(worktreepath)`'s — as git's own `is_worktree_being_rebased` / `…_bisected` ask: the
    /// worktree's `rebase-merge/head-name`, or `rebase-apply/head-name` when it is not an
    /// `am` (`rebase-apply/applying`), is `refs/heads/<branch>`; or its `BISECT_START` is the
    /// branch's short name. A worktree whose directory is gone (prunable) cannot be asked and
    /// is passed over; every other failure to ask is thrown, not read as "not in use".
    private func worktreeRebasingOrBisecting(_ branch: String, at root: URL) async throws -> String? {
        let ref = "refs/heads/\(branch)"
        for path in try await detachedWorktreePaths(at: root) {
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let worktree = URL(fileURLWithPath: path, isDirectory: true)
            let data = try await run(["rev-parse", "--path-format=absolute", "--git-path", "rebase-merge/head-name", "--git-path", "rebase-apply/head-name", "--git-path", "rebase-apply/applying", "--git-path", "BISECT_START"], cwd: worktree)
            let files = GitLines.split(data).map { URL(fileURLWithPath: $0) }
            guard files.count == 4 else {
                throw GitError.commandFailed(exitCode: -1, stderr: "unexpected rev-parse --git-path output in \(path)")
            }
            let applying = FileManager.default.fileExists(atPath: files[2].path)
            if Self.contents(of: files[0]) == ref
                || (!applying && Self.contents(of: files[1]) == ref)
                || Self.contents(of: files[3]) == branch
            {
                return path
            }
        }
        return nil
    }

    /// Every worktree whose HEAD is detached, by path (`worktree list --porcelain -z`: a record
    /// is NUL-separated fields ending in an empty one; `worktree <path>` first, `detached` for a
    /// detached HEAD).
    private func detachedWorktreePaths(at root: URL) async throws -> [String] {
        let data = try await run(["worktree", "list", "--porcelain", "-z"], cwd: root)
        var paths: [String] = []
        var path: String?
        var detached = false
        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
            let text = String(decoding: field, as: UTF8.self)
            if text.isEmpty {
                if let path, detached { paths.append(path) }
                path = nil
                detached = false
            } else if text.hasPrefix("worktree ") {
                path = String(text.dropFirst("worktree ".count))
            } else if text == "detached" {
                detached = true
            }
        }
        if let path, detached { paths.append(path) }
        return paths
    }

    // MARK: - Upstream

    public func setUpstream(of branch: String, to ref: String, at root: URL) async throws -> SetUpstreamResult {
        // Before any process: only a full remote-tracking name, never a short one a tag or a
        // local branch can shadow (R17), and never revision syntax.
        try requireName(branch)
        guard ref.hasPrefix("refs/remotes/") else { throw UpstreamRefusal.notABranch(ref) }
        try requireRemoteTrackingRef(ref)

        let expected = try await expectedUpstream(of: ref, at: root)
        switch try await remoteTrackingRefKind(ref, at: root) {
        case .missing: throw UpstreamRefusal.notFetched(ref)
        case .symbolic: throw UpstreamRefusal.notABranch(ref)
        case .plain: break
        }
        let rebaseBefore = try await configValues("branch.\(branch).rebase", at: root)

        let rest = String(ref.dropFirst("refs/remotes/".count))
        try Task.checkCancellation()
        let result: ProcessRunner.StreamedResult
        do {
            result = try await runWithEnvironment(["branch", "--set-upstream-to=refs/remotes/\(rest)", "--end-of-options", branch], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        } catch is CancellationError {
            throw RemoteAdminPartial.upstreamOutcomeUnknown(branch: branch)
        }
        guard result.exitCode == 0 else {
            if let refusal = Self.upstreamRefusal(stderr: result.stderr, ref: ref) { throw refusal }
            throw GitError.commandFailed(
                exitCode: result.exitCode,
                stderr: RemoteFailureParser.gitsOwnWords(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        // Read back, never assumed: overlapping refspecs make git write a server branch nobody
        // chose (R18). git has written by now, so a cancellation here leaves it unknown too.
        do {
            let remote = try await configValues("branch.\(branch).remote", at: root)
            let merge = try await configValues("branch.\(branch).merge", at: root)
            if remote != [expected.remote] {
                throw UpstreamRefusal.mergeMismatch(
                    expected: "\(expected.remote) \(expected.merge)",
                    written: "\(remote.joined(separator: ", ")) \(merge.joined(separator: ", "))")
            }
            if merge != [expected.merge] {
                throw UpstreamRefusal.mergeMismatch(expected: expected.merge, written: merge.joined(separator: ", "))
            }
            let rebaseAfter = try await configValues("branch.\(branch).rebase", at: root)
            let wasTrue = rebaseBefore.last.map(Self.isConfigTrue) ?? false
            return SetUpstreamResult(wroteRebase: rebaseAfter.last == "true" && !wasTrue)
        } catch is CancellationError {
            throw RemoteAdminPartial.upstreamOutcomeUnknown(branch: branch)
        }
    }

    public func unsetUpstream(of branch: String, at root: URL) async throws {
        try requireName(branch)
        try Task.checkCancellation()
        let result: ProcessRunner.StreamedResult
        do {
            result = try await runWithEnvironment(["branch", "--unset-upstream", "--end-of-options", branch], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        } catch is CancellationError {
            throw RemoteAdminPartial.upstreamOutcomeUnknown(branch: branch)
        }
        guard result.exitCode == 0 else {
            throw GitError.commandFailed(
                exitCode: result.exitCode,
                stderr: RemoteFailureParser.gitsOwnWords(result.stderr.trimmingCharacters(in: .whitespacesAndNewlines)))
        }
    }

    /// git's three measured refusals of `--set-upstream-to` (R17), or nil for anything else.
    static func upstreamRefusal(stderr: String, ref: String) -> UpstreamRefusal? {
        if stderr.contains("the requested upstream branch"), stderr.contains("does not exist") {
            return .notFetched(ref)
        }
        if stderr.contains("cannot set up tracking information"), stderr.contains("is not a branch") {
            return .notABranch(ref)
        }
        if stderr.contains("not tracking: ambiguous information for ref") { return .ambiguousNamespace(ref) }
        return nil
    }

    /// The remote and the server branch `ref` is expected to track: the one remote whose fetch
    /// refspecs map `ref`, through the most specific of them (`trackedSource`). None is the
    /// "Other" group (`.notABranch`), two are `.ambiguousNamespace` — git's own refusals, asked
    /// before git runs.
    private func expectedUpstream(of ref: String, at root: URL) async throws -> (remote: String, merge: String) {
        var found: [(remote: String, merge: String)] = []
        for remote in try await configuredRemoteNames(at: root).sorted() {
            let refspecs = try await configValues("remote.\(remote).fetch", at: root)
            if let source = Self.trackedSource(of: ref, through: refspecs) { found.append((remote, source)) }
        }
        guard let only = found.first else { throw UpstreamRefusal.notABranch(ref) }
        guard found.count == 1 else { throw UpstreamRefusal.ambiguousNamespace(ref) }
        return only
    }

    /// The server ref a fetch through `refspecs` writes into `ref`, reverse-mapped, or nil when
    /// none maps it.
    ///
    /// Parsed as git parses a refspec (`FetchRefspec`): an optional `+`, `<src>:<dst>` split at
    /// the last `:`, one `*` per side; a bare source (no destination) writes no ref. When more
    /// than one maps `ref` — overlapping refspecs (R18) — the **most specific** destination wins
    /// (the most literal characters; the first of equals): `refs/remotes/origin/x/*` over
    /// `refs/remotes/origin/*` for `origin/x/keep`, whose server branch is `keep`. git's own
    /// `--set-upstream-to` takes the first in configuration order instead, which is what the
    /// read-back catches. And as git does, a reverse-mapped source a negative refspec (`^…`)
    /// excludes means the remote maps nothing.
    static func trackedSource(of ref: String, through refspecs: [String]) -> String? {
        var best: (source: String, literal: Int)?
        var reversed: [String] = []
        var negatives: [String] = []
        for refspec in refspecs {
            if refspec.hasPrefix("^") {
                negatives.append(String(refspec.dropFirst()))
                continue
            }
            let body = refspec.hasPrefix("+") ? String(refspec.dropFirst()) : refspec
            guard let colon = body.lastIndex(of: ":") else { continue }
            let source = String(body[..<colon])
            let destination = String(body[body.index(after: colon)...])
            guard !destination.isEmpty, let mapped = reverseMapped(ref, source: source, destination: destination) else {
                continue
            }
            reversed.append(mapped)
            let literal = destination.filter { $0 != "*" }.count
            if best.map({ literal > $0.literal }) ?? true { best = (mapped, literal) }
        }
        guard let best else { return nil }
        if reversed.contains(where: { name in negatives.contains { matchesRefPattern(name, $0) } }) { return nil }
        return best.source
    }

    /// `ref` read back through one refspec's destination into its source, or nil.
    private static func reverseMapped(_ ref: String, source: String, destination: String) -> String? {
        let stars = destination.filter { $0 == "*" }.count
        guard stars == 1 else { return stars == 0 && ref == destination && !source.contains("*") ? source : nil }
        guard source.filter({ $0 == "*" }).count == 1, let star = destination.firstIndex(of: "*") else { return nil }
        let prefix = String(destination[..<star])
        let suffix = String(destination[destination.index(after: star)...])
        guard ref.count >= prefix.count + suffix.count, ref.hasPrefix(prefix), ref.hasSuffix(suffix) else { return nil }
        let captured = ref.dropFirst(prefix.count).dropLast(suffix.count)
        return source.replacingOccurrences(of: "*", with: captured)
    }

    /// Whether `name` matches a refspec side: exactly, or with its one `*` standing for any run
    /// of characters.
    private static func matchesRefPattern(_ name: String, _ pattern: String) -> Bool {
        guard let star = pattern.firstIndex(of: "*") else { return name == pattern }
        let prefix = String(pattern[..<star])
        let suffix = String(pattern[pattern.index(after: star)...])
        return name.count >= prefix.count + suffix.count && name.hasPrefix(prefix) && name.hasSuffix(suffix)
    }

    private enum RefKind { case missing, symbolic, plain }

    /// Whether `ref` exists, and whether it is a symbolic ref (`refs/remotes/<r>/HEAD`), which
    /// `--set-upstream-to` would follow to the branch it names.
    private func remoteTrackingRefKind(_ ref: String, at root: URL) async throws -> RefKind {
        let data = try await run(["for-each-ref", "--format=%(refname)%00%(symref)", "--end-of-options", ref], cwd: root)
        for line in GitLines.split(data) {
            let fields = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0] == ref else { continue }
            return fields[1].isEmpty ? .plain : .symbolic
        }
        return .missing
    }

    /// Every value of the configuration key `key`, in order; empty when it is not set (`--get-all`
    /// exits 1 then).
    private func configValues(_ key: String, at root: URL) async throws -> [String] {
        let data = try await run(["config", "--get-all", "--end-of-options", key], cwd: root, allowedExitCodes: [1])
        return GitLines.split(data)
    }

    /// git's spelling of a true boolean (`git config --type=bool`), or a key written with no
    /// value at all.
    private static func isConfigTrue(_ value: String) -> Bool {
        ["true", "yes", "on", "1", ""].contains(value.lowercased())
    }
}
