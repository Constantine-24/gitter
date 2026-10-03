import Foundation

/// Cherry-pick and revert of selected commits (B1 Task 1). See `GitHistoryBackend` for the
/// contract; this file is about how the plan is read and how the run is read back. The rebase
/// half — `rebasePlan(onto:at:)` and `rebase(_:at:)` — is in `CLIGitBackend+Rebase.swift`
/// beside the vector it shares with the pull flow.
///
/// **Measured for this task (git 2.54, `LC_ALL=C`, scratch repositories):**
/// - git's topological order breaks ties by the order it is given: commits of two unrelated
///   branches with equal dates came out `Y1 Y2 X1 X2` for one argv order and `X1 X2 Y1 Y2` for
///   another. The plan passes the selection sorted, so it is a function of the selected set.
/// - `rev-list` refuses `--not` after `--end-of-options` ("option '--not' must come before
///   non-option arguments"); `^<sha>` there is a revision, and works.
/// - `--empty=drop` reports each drop on **stderr**, with the full object id:
///   `dropping <sha> <subject> -- patch contents already upstream`.
/// - A range refused at its **first** commit (an untracked file in the way, exit 128) leaves
///   `sequencer/` behind with HEAD unchanged — the same halted state as a refusal later on.
/// - With such a `sequencer/` left, a new range is refused ("cherry-pick is already in
///   progress") while a single pick or revert goes ahead and leaves the stale list (Ruling 29).
/// - A `prepare-commit-msg` hook exiting 1: "error: 'prepare-commit-msg' hook failed" /
///   "fatal: cherry-pick failed" (or "revert failed"), exit 128. A pick keeps `CHERRY_PICK_HEAD`
///   (abortable); a single revert is left staged with `MERGE_MSG` and no `REVERT_HEAD` — B10's
///   signing state; two reverts keep `sequencer/` with no `REVERT_HEAD`.
/// - A revert range whose second commit is already undone: exit 1, the first committed,
///   `sequencer/` with no `REVERT_HEAD` — a halted range.
/// - After an already-undone single revert, a terminal `git commit` (no `-m`) takes the stray
///   `MERGE_MSG` as its message; Gitter's own `commit -F` ignores it and git then deletes it.
extension CLIGitBackend: GitHistoryBackend {

    // MARK: - Plan

    public func historyPlan(_ action: HistoryAction, shas: [String], at root: URL) async throws -> HistoryPlan {
        // Full object ids only (`isFullObjectID`, the commit list's): a short id could be read
        // as a ref spelled like it (B17), and a full one always wins over a name.
        for sha in shas where !Self.isFullObjectID(sha) { throw BranchOperationError.invalidName(sha) }
        var seen = Set<String>()
        let selection = shas.filter { seen.insert($0).inserted }

        try await refuseHistoryOperationInProgress(at: root)
        let head = try await headSHA(at: root)
        guard !head.isEmpty else { throw HistoryRefusal.unbornHead }
        guard !selection.isEmpty else { throw HistoryRefusal.nothingToApply }
        let headRef = try await symbolicHead(at: root)

        let selected = try await selectedCommits(selection, at: root)
        let merges = selection.compactMap { selected[$0] }.filter { $0.parents > 1 }.map(\.ref)
        if !merges.isEmpty { throw HistoryRefusal.mergeCommits(merges) }

        let plan: HistoryPlan
        switch action {
        case .cherryPick: plan = try await pickPlan(selection, selected, head: head, headRef: headRef, at: root)
        case .revert: plan = try await revertPlan(selection, selected, head: head, headRef: headRef, at: root)
        }
        // Last, after every refusal Stash and Continue could not help with: stashing first and
        // then being refused over a merge commit would move the user's work for nothing.
        let changed = try await trackedChanges(at: root)
        if !changed.isEmpty { throw HistoryRefusal.trackedChanges(changed) }
        return plan
    }

    /// Oldest first by topology: a real walk from the selection down to HEAD, filtered to the
    /// selection (B2). A selected commit HEAD already reaches is not in the walk — that is the
    /// "already in HEAD" answer, `merge-base --is-ancestor` for all of them in one process.
    private func pickPlan(
        _ selection: [String], _ selected: [String: SelectedCommit], head: String, headRef: String, at root: URL
    ) async throws -> HistoryPlan {
        let sorted = selection.sorted()
        let data = try await run(["rev-list", "--topo-order", "--reverse", "--end-of-options"] + sorted + ["^" + head], cwd: root)
        let wanted = Set(selection)
        let order = GitLines.split(data).filter(wanted.contains)
        let ordered = Set(order)
        let commits = order.compactMap { selected[$0]?.ref }
        let leftOut = selection.filter { !ordered.contains($0) }.compactMap { selected[$0]?.ref }
        guard !commits.isEmpty else { throw HistoryRefusal.nothingToApply }
        var mayDrop: [CommitRef] = []
        for commit in commits where try await isAlreadyUpstream(commit.sha, of: head, at: root) {
            mayDrop.append(commit)
        }
        return HistoryPlan(
            action: .cherryPick, head: head, commits: commits, leftOut: leftOut, mayDrop: mayDrop, headRef: headRef)
    }

    /// Newest first by the same topology (B8), of commits HEAD contains — any other is refused
    /// `.notOnBranch` (fix round 1: reverting a commit of another branch applies the inverse of a
    /// change this one never had, and git's "nothing to commit" then read as "already
    /// reverted"). The walk is bounded below by the selection's
    /// common ancestors' parents (`merge-base --octopus`, exit 1 when there is none) — every
    /// selected commit descends from each of them, so nothing between two selected commits is
    /// cut — rather than walking all history.
    private func revertPlan(
        _ selection: [String], _ selected: [String: SelectedCommit], head: String, headRef: String, at root: URL
    ) async throws -> HistoryPlan {
        let sorted = selection.sorted()
        // Selected commits HEAD does not reach, in one walk.
        let outside = Set(
            GitLines.split(try await run(["rev-list", "--end-of-options"] + sorted + ["^" + head], cwd: root)))
        let foreign = selection.filter(outside.contains).compactMap { selected[$0]?.ref }
        if !foreign.isEmpty { throw HistoryRefusal.notOnBranch(foreign) }
        let bases = GitLines.split(
            try await run(["merge-base", "--octopus", "--end-of-options"] + sorted, cwd: root, allowedExitCodes: [1]))
        let bound = bases.filter(Self.isFullObjectID).map { "^\($0)^@" }
        let wanted = Set(selection)
        var commits: [CommitRef] = []
        // The unbounded walk is the fallback, never needed in theory: it always reaches every
        // selected commit.
        for exclusions in [bound, []] {
            let data = try await run(["rev-list", "--topo-order", "--end-of-options"] + sorted + exclusions, cwd: root)
            commits = GitLines.split(data).filter(wanted.contains).compactMap { selected[$0]?.ref }
            if commits.count == selection.count { break }
        }
        return HistoryPlan(action: .revert, head: head, commits: commits, headRef: headRef)
    }

    /// Whether `sha`'s change is already on HEAD's side as a patch-identical commit:
    /// `rev-list --cherry-mark --right-only --no-merges HEAD...<sha>` marks it `=` (B4).
    private func isAlreadyUpstream(_ sha: String, of head: String, at root: URL) async throws -> Bool {
        let data = try await run(
            ["rev-list", "--cherry-mark", "--right-only", "--no-merges", "--end-of-options", "\(head)...\(sha)"], cwd: root)
        return GitLines.split(data).contains("=" + sha)
    }

    struct SelectedCommit {
        let ref: CommitRef
        let parents: Int
    }

    /// Each selected commit's subject and parent count, in one `log --no-walk=unsorted`. A
    /// selected id that is not a commit (a tag object's, say) is refused by name; one that does
    /// not exist is git's own "bad object".
    private func selectedCommits(_ shas: [String], at root: URL) async throws -> [String: SelectedCommit] {
        let data = try await run(
            ["log", "--no-walk=unsorted", "--no-show-signature", "--format=%H%x00%P%x00%s", "--end-of-options"] + shas,
            cwd: root)
        var result: [String: SelectedCommit] = [:]
        for line in GitLines.split(data) {
            let fields = line.split(separator: "\0", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
            guard fields.count == 3 else { continue }
            let parents = fields[1].split(separator: " ").count
            result[fields[0]] = SelectedCommit(ref: CommitRef(sha: fields[0], subject: fields[2]), parents: parents)
        }
        if let missing = shas.first(where: { result[$0] == nil }) { throw BranchOperationError.invalidName(missing) }
        return result
    }

    // MARK: - Run

    public func run(_ plan: HistoryPlan, at root: URL) async throws -> HistoryOutcome {
        // HEAD first: a moved HEAD can make the plan refuse for a reason of its own (the
        // selection now in HEAD is `.nothingToApply`), and what the user needs to hear is that
        // HEAD moved.
        // By commit AND by name: the same commit on another branch, or detached, is not the HEAD
        // the sheet named (fix round 1).
        guard try await headSHA(at: root) == plan.head, try await symbolicHead(at: root) == plan.headRef else {
            throw HistoryRefusal.headMoved
        }
        let now = try await historyPlan(plan.action, shas: plan.commits.map(\.sha) + plan.leftOut.map(\.sha), at: root)
        guard now == plan else { throw HistoryRefusal.planChanged }

        let mergeMsg = try await gitPath("MERGE_MSG", at: root)
        let hadMergeMsg = FileManager.default.fileExists(atPath: mergeMsg.path)
        let shas = plan.commits.map(\.sha)
        // ONE complete literal per action, pinned whole by `ForceFlagScannerTests`'
        // `allowsTheHistoryVectorsThisMilestoneNeeds`. Every exit code is an answer: the
        // repository is read back afterwards.
        let result: ProcessRunner.StreamedResult
        switch plan.action {
        case .cherryPick:
            result = try await runWithEnvironment(["cherry-pick", "--empty=drop", "--end-of-options"] + shas, cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        case .revert:
            result = try await runWithEnvironment(["revert", "--no-edit", "--no-reference", "--end-of-options"] + shas, cwd: root, extra: [:], allowedExitCodes: Self.anyExitCode)
        }
        let outcome = try await outcome(of: result, plan: plan, at: root)
        // git's leftover from this run, not the user's: a terminal `git commit` would take it as
        // its message. One that was there before is left alone.
        if case .alreadyReverted = outcome, !hadMergeMsg {
            try? FileManager.default.removeItem(at: mergeMsg)
        }
        return outcome
    }

    /// What the run left, read in the order that cannot mislead: an operation, or a range git
    /// left halted, first — whatever git exited with or printed (a stopped commit's subject is
    /// echoed and can read like anything); then success; then, with HEAD where it was, git's
    /// refusals and the single revert's two states.
    private func outcome(
        of result: ProcessRunner.StreamedResult, plan: HistoryPlan, at root: URL
    ) async throws -> HistoryOutcome {
        if try await operationInProgress(at: root) != nil { return .stopped }
        let head = try await headSHA(at: root)
        if try await hasSequencer(at: root) {
            return try await refusalAtTheFirstCommit(result, plan: plan, head: head, at: root) ?? .stopped
        }
        if result.exitCode == 0 {
            let count = try await commitCount("\(plan.head)..\(head)", at: root)
            return .applied(count: count, dropped: Self.dropped(in: result.stderr, of: plan.commits))
        }
        guard head == plan.head else { return .failed(gitsWords: Self.words(result)) }
        if let sha = BranchRefusalParser.mergeWithoutMainline(stderr: result.stderr) {
            throw HistoryRefusal.mergeCommits([plan.commits.first { $0.sha == sha } ?? CommitRef(sha: sha, subject: "")])
        }
        if let refusal = BranchRefusalParser.parse(stderr: result.stderr) { throw refusal }
        if plan.action == .revert, plan.commits.count == 1 {
            if try await indexDiffersFromHead(at: root) { return .unsignedRevertLeftStaged(gitsWords: Self.words(result)) }
            if result.exitCode == 1 { return .alreadyReverted(plan.commits[0]) }
        }
        return .failed(gitsWords: Self.words(result))
    }

    /// A range git refused at its **first** commit (an untracked file in the way, measured):
    /// `sequencer/` with no pseudo-ref, HEAD and the index where the plan left them, and git's
    /// refusal on stderr. A2's halted bar would list every commit as not applied and lose git's
    /// words, so the range's own `--abort` clears it — measured: with `sequencer/head` at HEAD it
    /// rewinds to HEAD itself, keeps the untracked file, exits 0 — and git's refusal is thrown,
    /// as for a single pick (fix round 1, Ruling 6b). Nil — the halted range stays, `.stopped` —
    /// when anything is not exactly that, or the abort does not leave it so.
    private func refusalAtTheFirstCommit(
        _ result: ProcessRunner.StreamedResult, plan: HistoryPlan, head: String, at root: URL
    ) async throws -> HistoryOutcome? {
        let refusal: Error
        if let sha = BranchRefusalParser.mergeWithoutMainline(stderr: result.stderr) {
            refusal = HistoryRefusal.mergeCommits([plan.commits.first { $0.sha == sha } ?? CommitRef(sha: sha, subject: "")])
        } else if let parsed = BranchRefusalParser.parse(stderr: result.stderr) {
            refusal = parsed
        } else {
            return nil
        }
        guard result.exitCode != 0, head == plan.head,
            Self.contents(of: try await gitPath("sequencer/head", at: root)) == plan.head,
            try await indexDiffersFromHead(at: root) == false
        else { return nil }
        switch plan.action {
        case .cherryPick: _ = try await run(["cherry-pick", "--abort"], cwd: root, allowedExitCodes: Self.anyExitCode)
        case .revert: _ = try await run(["revert", "--abort"], cwd: root, allowedExitCodes: Self.anyExitCode)
        }
        guard try await hasSequencer(at: root) == false, try await headSHA(at: root) == plan.head else { return nil }
        throw refusal
    }

    /// The commits `--empty=drop` reported dropping, in plan order.
    static func dropped(in stderr: String, of commits: [CommitRef]) -> [CommitRef] {
        let named = Set(
            stderr.split(separator: "\n").compactMap { line -> String? in
                let parts = line.split(separator: " ", maxSplits: 2)
                guard parts.count >= 2, parts[0] == "dropping", line.hasSuffix(" -- patch contents already upstream")
                else { return nil }
                return String(parts[1])
            })
        return commits.filter { named.contains($0.sha) }
    }

    /// `rev-list --count` of `range` (both ends full object ids).
    func commitCount(_ range: String, at root: URL) async throws -> Int {
        Self.count(try await run(["rev-list", "--count", "--end-of-options", range], cwd: root))
    }

    /// A `rev-list --count` answer as a number.
    static func count(_ data: Data) -> Int {
        Int(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
    }

    // MARK: - Refusals shared with the rebase plan

    /// `symbolic-ref -q HEAD`: the full ref HEAD names (`refs/heads/main`), "" when detached.
    func symbolicHead(at root: URL) async throws -> String {
        let data = try await run(["symbolic-ref", "-q", "HEAD"], cwd: root, allowedExitCodes: [1])
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// `.operationInProgress` for an operation, and for a cherry-pick or revert range git left
    /// halted: `sequencer/` with no pseudo-ref, named by its todo's first command.
    func refuseHistoryOperationInProgress(at root: URL) async throws {
        if let operation = try await operationInProgress(at: root) {
            throw HistoryRefusal.operationInProgress(operation)
        }
        guard try await hasSequencer(at: root) else { return }
        let todo = Self.contents(of: try await gitPath("sequencer/todo", at: root), trimmed: false) ?? ""
        throw HistoryRefusal.operationInProgress(Self.todoEntries(todo).first?.revert == true ? .revert : .cherryPick)
    }

    /// Every tracked path with an uncommitted change, staged or not — unmerged, intent-to-add
    /// and a submodule with changes included; untracked files are not (B6).
    func trackedChanges(at root: URL) async throws -> [String] {
        try await stashStatus(at: root).files.filter { !$0.isUntracked }.map(\.path)
    }
}
