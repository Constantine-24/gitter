import Foundation

/// Fast-forward a branch that is not checked out, and set or unset a branch's upstream (B2
/// Task 2). See `GitRemoteAdminBackend` for the contract; this file is about how each vector is
/// spelled, what is refused before git runs, and how git's answers are read.
///
/// Every vector is pinned in `ForceFlagScannerTests.allowsTheUpstreamVectorsThisMilestoneNeeds`,
/// and the bindings are named as they are there (`message`, `name`, `new`, `old`, `rest`,
/// `branch`, `local`, `key`, `ref`): the contract is the text. Four are shapes the scanner
/// grants whole — `update-ref`'s `refs/heads/` compare-and-set (`allowedShapes`) and `branch`'s
/// three upstream vectors (`denyTableExceptionShapes`).
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
/// - Fix round 1: a branch a `rebase --update-refs` will move is in use too — its worktree's
///   `rebase-merge/update-refs` holds `<ref>\n<id>\n<forty zeros>\n` per ref, and `branch -f`
///   refuses it; moving it left that rebase's last step failing ("is at X but expected Y"). A
///   worktree whose directory is moved away is `prunable` in `worktree list`, its state still in
///   `.git/worktrees/<id>/` (whose `gitdir` names the old path), and `branch -f` still refuses
///   its branches — so every administrative directory is read, not only reachable worktrees.
/// - Fix round 1: `--set-upstream-to=refs/heads/<x>` writes `branch.<b>.remote=.` and
///   `.merge=refs/heads/<x>`; naming the branch itself warns "not setting branch '<b>' as its
///   own upstream" and exits 0 with nothing written. A `config.lock` held from the start makes
///   `--unset-upstream` fail with `fatal: could not unset 'branch.<b>.remote'` and write nothing.
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
        // Last, immediately before the write: the window in which a worktree can start using
        // the branch unseen (R15) is as narrow as it can be (fix round 1, M4).
        if let path = state.worktreePath { throw FastForwardRefusal.checkedOut(path: path) }
        if let path = try await worktreeUsing(branch, at: root) { throw FastForwardRefusal.checkedOut(path: path) }
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
        } catch let error where error is CancellationError || Self.wasKilledBySignal(error) {
            // git was stopped part-way, or never started — the runner cannot say which (Task 1's
            // rule for a cancelled write): never "nothing changed". A killed git likewise.
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

    /// The worktree that uses `branch` the way git counts it (`branch.c`,
    /// `prepare_checked_out_branches`), or nil: its HEAD is the branch, a rebase started from it
    /// (`rebase-merge/head-name`, or `rebase-apply/head-name` when it is not an `am`), a rebase
    /// that will move it at the end (`rebase-merge/update-refs`, fix round 1, I1), or a bisect
    /// started from it (`BISECT_START`). Asked of **every** worktree — attached or detached, and
    /// one whose directory is gone (prunable), whose state is still in its administrative
    /// directory — as git asks: the main one's is the common directory (none for a bare
    /// repository), a linked one's `<common>/worktrees/<id>/`, read straight from the files.
    /// Internal since B3 Task 2: Add Worktree refuses a branch it names.
    func worktreeUsing(_ branch: String, at root: URL) async throws -> String? {
        let ref = "refs/heads/\(branch)"
        for worktree in try await worktreeAdministrativeDirectories(at: root) {
            let held = Self.branchesHeld(in: worktree.directory)
            if held.head == ref || held.byOperation.contains(ref) {
                return worktree.path
            }
        }
        return nil
    }

    /// What one worktree's state files say it holds — **the one reader** of them (B3 Task 2 fix
    /// round 1: `worktreeUsing` and `Worktree.operationBranches` both read it): `head`, the ref its
    /// HEAD names (`ref: <ref>`; nil when detached), and `byOperation`, every ref an operation there
    /// holds, in this order — the branch a rebase started from (`rebase-merge/head-name`, or
    /// `rebase-apply/head-name` when it is not an `am`), the branch a bisect started from
    /// (`refs/heads/` + `BISECT_START`, which holds an id when the bisect began detached), then
    /// each ref a `rebase --update-refs` will move (`rebase-merge/update-refs`).
    static func branchesHeld(in directory: URL) -> (head: String?, byOperation: [String]) {
        let file = { (name: String) in Self.contents(of: directory.appendingPathComponent(name)) }
        let head = file("HEAD").flatMap { $0.hasPrefix("ref: ") ? String($0.dropFirst("ref: ".count)) : nil }
        var held: [String] = []
        let add = { (ref: String?) in if let ref, !ref.isEmpty, !held.contains(ref) { held.append(ref) } }
        add(file("rebase-merge/head-name"))
        let applying = FileManager.default.fileExists(atPath: directory.appendingPathComponent("rebase-apply/applying").path)
        if !applying { add(file("rebase-apply/head-name")) }
        add(file("BISECT_START").flatMap { $0.isEmpty ? nil : "refs/heads/" + $0 })
        for ref in refsAnUpdateRefsRebaseWillMove(file("rebase-merge/update-refs")) { add(ref) }
        return (head, held)
    }

    /// The refs a `rebase --update-refs` will move when it finishes: `rebase-merge/update-refs`
    /// holds three lines per ref — the ref, then two ids (measured: `refs/heads/s1`, its id, and
    /// forty zeros) — so the first line and every third after it.
    static func refsAnUpdateRefsRebaseWillMove(_ contents: String?) -> [String] {
        guard let contents else { return [] }
        let lines = contents.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        return stride(from: 0, to: lines.count, by: 3).map { lines[$0] }.filter { $0.hasPrefix("refs/") }
    }

    /// Every worktree's administrative directory and the path git names it by: the main
    /// worktree's (the common directory, unless the main one is bare) first, then each
    /// `<common>/worktrees/<id>/`, its path read from its `gitdir` file (`<path>/.git`, relative
    /// to the directory under `worktree.useRelativePaths`) — present for a prunable one too.
    /// Internal since B3 Task 2: `worktrees(at:)` reads each one's `operationBranch` from it.
    func worktreeAdministrativeDirectories(at root: URL) async throws -> [(directory: URL, path: String)] {
        let common = try await commonDirectory(at: root)
        var result: [(directory: URL, path: String)] = []
        if let main = try await mainWorktree(at: root), !main.bare {
            result.append((common, main.path))
        }
        let linked = common.appendingPathComponent("worktrees", isDirectory: true)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: linked.path)) ?? []
        for name in names.sorted() {
            let directory = linked.appendingPathComponent(name, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: directory.path, isDirectory: &isDirectory), isDirectory.boolValue else {
                continue
            }
            let path: String
            if let gitdir = Self.contents(of: directory.appendingPathComponent("gitdir")), !gitdir.isEmpty {
                let dotGit = gitdir.hasPrefix("/")
                    ? URL(fileURLWithPath: gitdir) : directory.appendingPathComponent(gitdir).standardizedFileURL
                path = dotGit.deletingLastPathComponent().path
            } else {
                path = directory.path
            }
            result.append((directory, path))
        }
        return result
    }

    /// `rev-parse --git-common-dir`, absolute.
    private func commonDirectory(at root: URL) async throws -> URL {
        let data = try await run(["rev-parse", "--path-format=absolute", "--git-common-dir"], cwd: root)
        let path = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
        guard path.hasPrefix("/") else {
            throw GitError.commandFailed(exitCode: -1, stderr: "unexpected rev-parse --git-common-dir output: \(path)")
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// The main worktree's path and whether it is bare: `worktree list --porcelain -z`'s first
    /// record (NUL-separated fields ending in an empty one; `worktree <path>`, `bare`).
    private func mainWorktree(at root: URL) async throws -> (path: String, bare: Bool)? {
        let data = try await run(["worktree", "list", "--porcelain", "-z"], cwd: root)
        var path: String?
        var bare = false
        for field in data.split(separator: 0, omittingEmptySubsequences: false) {
            let text = String(decoding: field, as: UTF8.self)
            if text.isEmpty { break }
            if text.hasPrefix("worktree ") { path = String(text.dropFirst("worktree ".count)) }
            if text == "bare" { bare = true }
        }
        return path.map { ($0, bare) }
    }

    // MARK: - Upstream

    public func setUpstream(of branch: String, to ref: String, at root: URL) async throws -> SetUpstreamResult {
        // Before any process: only a full name — a remote-tracking ref, or (fix round 1) a local
        // branch — never a short one a tag or a branch can shadow (R17), never revision syntax.
        try requireName(branch)
        let target: UpstreamTarget
        let expected: (remote: String, merge: String)
        if ref.hasPrefix("refs/heads/") {
            try requirePlainRef(ref, under: "refs/heads/")
            let local = String(ref.dropFirst("refs/heads/".count))
            // git only warns about this one and exits 0 with nothing written (measured).
            guard local != branch else { throw UpstreamRefusal.ownUpstream(branch) }
            target = .local(local)
            expected = (".", ref)
        } else if ref.hasPrefix("refs/remotes/") {
            try requireRemoteTrackingRef(ref)
            target = .remote(String(ref.dropFirst("refs/remotes/".count)))
            expected = try await expectedUpstream(of: ref, at: root)
        } else {
            throw UpstreamRefusal.notABranch(ref)
        }
        switch try await refKind(ref, at: root) {
        case .missing:
            if case .local(let local) = target { throw BranchOperationError.noSuchBranch(local) }
            throw UpstreamRefusal.notFetched(ref)
        case .symbolic: throw UpstreamRefusal.notABranch(ref)
        case .plain: break
        }
        let before = try await upstreamConfig(of: branch, at: root)
        let rebaseBefore = try await configValues("branch.\(branch).rebase", at: root)

        try Task.checkCancellation()
        let result: ProcessRunner.StreamedResult
        do {
            switch target {
            case .remote(let rest):
                result = try await runWithEnvironment(["branch", "--set-upstream-to=refs/remotes/\(rest)", "--end-of-options", branch], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
            case .local(let local):
                result = try await runWithEnvironment(["branch", "--set-upstream-to=refs/heads/\(local)", "--end-of-options", branch], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
            }
        } catch let error where error is CancellationError || Self.wasKilledBySignal(error) {
            throw RemoteAdminPartial.upstreamOutcomeUnknown(branch: branch)
        }
        guard result.exitCode == 0 else {
            let words = try await readBackAfterFailure(of: branch, before: before, stderr: result.stderr, at: root)
            if let refusal = Self.upstreamRefusal(stderr: result.stderr, ref: ref) { throw refusal }
            throw GitError.commandFailed(exitCode: result.exitCode, stderr: words)
        }

        // Read back, never assumed: overlapping refspecs make git write a server branch nobody
        // chose (R18). git has written by now, so a cancellation here leaves it unknown too.
        do {
            let now = try await upstreamConfig(of: branch, at: root)
            if now.remote != [expected.remote] {
                throw UpstreamRefusal.mergeMismatch(
                    expected: "\(expected.remote) \(expected.merge)",
                    written: "\(now.remote.joined(separator: ", ")) \(now.merge.joined(separator: ", "))")
            }
            if now.merge != [expected.merge] {
                throw UpstreamRefusal.mergeMismatch(expected: expected.merge, written: now.merge.joined(separator: ", "))
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
        let before = try await upstreamConfig(of: branch, at: root)
        try Task.checkCancellation()
        let result: ProcessRunner.StreamedResult
        do {
            result = try await runWithEnvironment(["branch", "--unset-upstream", "--end-of-options", branch], cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        } catch let error where error is CancellationError || Self.wasKilledBySignal(error) {
            throw RemoteAdminPartial.upstreamOutcomeUnknown(branch: branch)
        }
        guard result.exitCode == 0 else {
            let words = try await readBackAfterFailure(of: branch, before: before, stderr: result.stderr, at: root)
            throw GitError.commandFailed(exitCode: result.exitCode, stderr: words)
        }
    }

    /// Where Set Upstream points: a remote-tracking ref (the part after `refs/remotes/`) or a
    /// local branch (its short name). Each has its own whole vector in the scanner.
    private enum UpstreamTarget {
        case remote(String)
        case local(String)
    }

    /// `branch.<b>.remote` and `.merge`, every value of each.
    private func upstreamConfig(of branch: String, at root: URL) async throws -> (remote: [String], merge: [String]) {
        (try await configValues("branch.\(branch).remote", at: root), try await configValues("branch.\(branch).merge", at: root))
    }

    /// A failed set or unset is **not** assumed to have changed nothing (fix round 1, M3): git
    /// writes `branch.<b>.remote` and `.merge` one at a time, so a failure between the two
    /// leaves half. Both are read back: changed since `before` is
    /// `RemoteAdminPartial.upstreamChangedThenFailed` with what they hold now; unchanged returns
    /// git's (redacted) words for the caller's own refusal. A read-back that cannot be made
    /// leaves the outcome unknown. Measured: a `config.lock` held from the start writes nothing
    /// (`fatal: could not unset 'branch.<b>.remote'`, exit 128, both keys as they were).
    private func readBackAfterFailure(
        of branch: String, before: (remote: [String], merge: [String]), stderr: String, at root: URL
    ) async throws -> String {
        let words = RemoteFailureParser.gitsOwnWords(stderr.trimmingCharacters(in: .whitespacesAndNewlines))
        let now: (remote: [String], merge: [String])
        do {
            now = try await upstreamConfig(of: branch, at: root)
        } catch {
            throw RemoteAdminPartial.upstreamOutcomeUnknown(branch: branch)
        }
        guard now.remote == before.remote, now.merge == before.merge else {
            let joined = { (values: [String]) in values.isEmpty ? nil : values.joined(separator: ", ") }
            throw RemoteAdminPartial.upstreamChangedThenFailed(
                branch: branch, remote: joined(now.remote), merge: joined(now.merge), gitsWords: words)
        }
        return words
    }

    /// Refuses a ref that is not a plain full name under `prefix`, before git runs: it is
    /// written into an option's value and read back as a config value, so no revision syntax
    /// (`requireRefNameOrObjectName`), no glob character, no whitespace or backslash — all of
    /// which git's own ref-name rules forbid, so no real ref is refused.
    private func requirePlainRef(_ ref: String, under prefix: String) throws {
        guard ref.hasPrefix(prefix), ref.count > prefix.count, !ref.hasSuffix("/"),
            !ref.contains(where: { "*?[\\".contains($0) || $0.isWhitespace })
        else {
            throw BranchOperationError.invalidName(ref)
        }
        try requireRefNameOrObjectName(ref)
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

    /// Whether `ref` exists, and whether it is a symbolic ref (`refs/remotes/<r>/HEAD`, a
    /// branch alias), which `--set-upstream-to` would follow to the branch it names.
    private func refKind(_ ref: String, at root: URL) async throws -> RefKind {
        let data = try await run(["for-each-ref", "--format=%(refname)%00%(symref)", "--end-of-options", ref], cwd: root)
        for line in GitLines.split(data) {
            let fields = line.split(separator: "\u{0}", maxSplits: 1, omittingEmptySubsequences: false)
            guard fields.count == 2, fields[0] == ref else { continue }
            return fields[1].isEmpty ? .plain : .symbolic
        }
        return .missing
    }

    /// Every value of the configuration key `key`, in order; empty when it is not set (`--get-all`
    /// exits 1 then). Internal since Task 3: a removal reads every remote's refspecs.
    func configValues(_ key: String, at root: URL) async throws -> [String] {
        let data = try await run(["config", "--get-all", "--end-of-options", key], cwd: root, allowedExitCodes: [1])
        return GitLines.split(data)
    }

    /// git's spelling of a true boolean (`git config --type=bool`), or a key written with no
    /// value at all.
    private static func isConfigTrue(_ value: String) -> Bool {
        ["true", "yes", "on", "1", ""].contains(value.lowercased())
    }
}
