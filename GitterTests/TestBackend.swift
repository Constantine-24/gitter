import Foundation
import GitCoreTestSupport
import Synchronization
import Testing

// `@testable` for `pop(_:at:beforeDrop:)`, GitCore's one seam inside a backend call (B1.2).
// `Testing.Tag` is in scope here too, so GitCore's is written `GitCore.Tag` (B1.3).
@testable import GitCore

/// The store's backend for a test: all 104 requirements of the twelve protocols forwarded to a
/// real `CLIGitBackend` on the test's scratch repository, with any one call open to the test
/// (E3 Task 3, spec Design §2). A test can, around a call:
/// - `hook` it: run code before or after every such call, and throw to make the call throw;
/// - `fail` it: the next such call throws the given error without running git;
/// - `hold` it: the next such call parks before it reaches git until the test releases it;
/// - replace it, through a typed replacement added when a test needs one (`replacePop`);
/// - read `calls`, every call made so far, in order.
///
/// A call is keyed by `Call`, one case per requirement whose raw value is the method's
/// `#function` spelling (plan correction 2): a misspelt key does not compile, and `around`
/// records an issue when a forwarder hands it a key other than its own
/// (`TestBackendTests.everyForwarderPassesTheKeySpelledLikeItself` reads the forwarders too).
///
/// What a forwarder does, in order (`around`): log the call; run its `.before` hooks; throw a
/// pending `fail`; park on a pending `hold`; run git (or the replacement); run its `.after`
/// hooks. A hook that throws ends the call there with that error; an `.after` hook's error
/// replaces the call's result, git having run.
///
/// Not covered (B1.4): the static `CLIGitBackend.isGitAvailable(at:)` and the store's own file
/// reads (`.git`, worktree markers, folder state), which see the scratch repository's real files.
///
/// The keys and the forwarders were generated from the protocols (the milestone's
/// `probe-kit/gentb.py`, `genfwd.py`'s parse of B1.3 emitting both) and are one shape each:
/// `try await around(.key) { try await real.method(…) }`; `pop` alone was edited, for `replacePop`.
final class TestBackend: GitBackend, GitWorkingCopyBackend, GitBranchBackend, GitRemoteBackend,
    GitStashBackend, GitConflictBackend, GitOperationBackend, GitHistoryBackend, GitTagBackend,
    GitRemoteAdminBackend, GitCompareBackend, GitWorktreeBackend, Sendable
{
    /// One case per protocol requirement (104); the raw value is the method's `#function`
    /// spelling. The overloads' cases carry what tells them apart: `stageAllExpecting`,
    /// `discardExpectationTracked` / `discardExpectationUntracked`, `commitByID` (`GitBackend`'s
    /// one-commit read, beside `GitWorkingCopyBackend`'s `commit`), and `rebaseOnto`
    /// (`GitRemoteBackend`) / `rebaseWithPlan` (`GitHistoryBackend`).
    enum Call: String, CaseIterable, Sendable {
        // GitBackend
        case snapshot = "snapshot(at:historyDepth:)"
        case historyRow = "historyRow(of:at:)"
        case commitByID = "commit(_:at:)"
        case workingCopyDiff = "workingCopyDiff(at:path:staged:)"
        case commitFiles = "commitFiles(at:sha:)"
        case commitDiff = "commitDiff(at:sha:path:)"

        // GitWorkingCopyBackend
        case stage = "stage(paths:at:)"
        case unstage = "unstage(paths:at:)"
        case stageAll = "stageAll(at:)"
        case stageAllPaths = "stageAllPaths(at:)"
        case stageAllExpecting = "stageAll(expecting:at:)"
        case unstageAll = "unstageAll(at:)"
        case applyToIndex = "applyToIndex(patch:reverse:at:)"
        case commit = "commit(message:amend:allTracked:at:)"
        case headMessage = "headMessage(at:)"
        case discardExpectationTracked = "discardExpectation(tracked:includingStaged:at:)"
        case discardExpectationUntracked = "discardExpectation(untracked:at:)"
        case discard = "discard(_:trasher:at:)"
        case undoDiscard = "undoDiscard(_:trasher:at:)"

        // GitBranchBackend
        case validateBranchName = "validateBranchName(_:at:)"
        case createBranch = "createBranch(_:startPoint:switchTo:at:)"
        case switchTo = "switchTo(branch:at:)"
        case checkoutDetached = "checkoutDetached(_:at:)"
        case trackRemoteBranch = "trackRemoteBranch(_:at:)"
        case renameBranch = "renameBranch(_:to:at:)"
        case deleteBranch = "deleteBranch(_:at:)"
        case forceDeleteBranch = "forceDeleteBranch(_:expectedTip:at:)"
        case commitsOnlyOn = "commitsOnlyOn(branch:at:)"
        case commitCount = "commitCount(in:notIn:at:)"
        case unreferencedCommits = "unreferencedCommits(at:)"
        case merge = "merge(_:mode:at:)"
        case abort = "abort(_:at:)"

        // GitRemoteBackend
        case fetch = "fetch(remote:at:progress:)"
        case push = "push(_:to:remoteRef:setUpstream:at:progress:)"
        case forcePush = "forcePush(_:to:remoteRef:expectedRemoteTip:expectedLocalTip:at:progress:)"
        case deleteRemoteBranch = "deleteRemoteBranch(_:on:expectedTip:at:)"
        case rebaseOnto = "rebase(onto:at:)"
        case commits = "commits(in:notIn:limit:at:)"
        case commitsOnlyOnRemoteBranch = "commitsOnlyOnRemoteBranch(_:at:)"

        // GitStashBackend
        case stashes = "stashes(at:)"
        case stashDiff = "stashDiff(_:at:)"
        case stashContents = "stashContents(_:at:)"
        case stashAll = "stashAll(message:includeUntracked:at:)"
        case stashPaths = "stashPaths(_:message:at:)"
        case apply = "apply(_:at:)"
        case pop = "pop(_:at:)"
        case drop = "drop(_:at:)"

        // GitConflictBackend
        case conflictDocument = "conflictDocument(for:at:)"
        case resolve = "resolve(_:choices:recordIfEdited:at:)"
        case take = "take(_:_:recordIfEdited:at:)"
        case delete = "delete(_:recordIfEdited:at:)"
        case keep = "keep(_:recordIfEdited:at:)"
        case leftoverMarkers = "leftoverMarkers(in:at:)"
        case markResolved = "markResolved(_:allowingMarkers:at:)"
        case canReopen = "canReopen(_:at:)"
        case reopen = "reopen(_:expectingWorktreeHash:at:)"
        case reopenedFile = "reopenedFile(_:at:)"

        // GitOperationBackend
        case operationProgress = "operationProgress(at:)"
        case pendingMessage = "pendingMessage(at:)"
        case operationPaths = "operationPaths(at:)"
        case continueReadiness = "continueReadiness(at:)"
        case continueOperation = "continueOperation(_:message:acknowledgingOtherStaged:at:)"
        case skipReadiness = "skipReadiness(at:)"
        case skip = "skip(_:stoppedAt:at:)"
        case haltedSequence = "haltedSequence(at:)"
        case staleSequence = "staleSequence(at:)"
        case commitsAbortRemoves = "commitsAbortRemoves(at:)"

        // GitHistoryBackend
        case historyPlan = "historyPlan(_:shas:at:)"
        case run = "run(_:at:)"
        case rebasePlan = "rebasePlan(onto:at:)"
        case rebaseWithPlan = "rebase(_:at:)"

        // GitTagBackend
        case tagNameProblem = "tagNameProblem(_:at:)"
        case createTag = "createTag(_:at:message:at:)"
        case deleteTag = "deleteTag(_:at:)"
        case restoreTag = "restoreTag(_:at:)"
        case remoteTagID = "remoteTagID(_:on:at:)"
        case pushTag = "pushTag(_:to:at:)"
        case deleteRemoteTag = "deleteRemoteTag(_:on:expecting:at:)"
        case remotesFetchingNoTags = "remotesFetchingNoTags(at:)"

        // GitRemoteAdminBackend
        case prunePlan = "prunePlan(_:at:)"
        case stranded = "stranded(by:at:)"
        case prune = "prune(_:keeping:at:)"
        case keepBranchNameProblem = "keepBranchNameProblem(_:at:)"
        case goneBranches = "goneBranches(at:)"
        case remoteHEADTarget = "remoteHEADTarget(of:at:)"
        case branchConfigKeys = "branchConfigKeys(of:at:)"
        case fastForward = "fastForward(_:expecting:at:)"
        case setUpstream = "setUpstream(of:to:at:)"
        case unsetUpstream = "unsetUpstream(of:at:)"
        case remoteNameProblem = "remoteNameProblem(_:at:)"
        case remoteURLs = "remoteURLs(_:at:)"
        case addRemote = "addRemote(_:url:at:)"
        case setURLs = "setURLs(of:fetch:push:at:)"
        case renameRemote = "renameRemote(_:to:at:)"
        case removalImpact = "removalImpact(of:at:)"
        case removeRemote = "removeRemote(_:keeping:at:)"

        // GitCompareBackend
        case compare = "compare(_:_:at:)"
        case comparisonFiles = "comparisonFiles(_:at:)"
        case comparisonDiff = "comparisonDiff(_:path:at:)"

        // GitWorktreeBackend
        case worktrees = "worktrees(at:)"
        case worktreeChanges = "worktreeChanges(_:at:)"
        case removalCheck = "removalCheck(_:at:)"
        case addWorktree = "addWorktree(path:branch:at:)"
        case removeWorktree = "removeWorktree(_:keeping:at:)"
    }

    enum When: Sendable { case before, after }

    let real: CLIGitBackend

    private struct Hook: Sendable {
        let when: When
        let action: @Sendable () async throws -> Void
    }

    private struct State: Sendable {
        var calls: [Call] = []
        var hooks: [Call: [Hook]] = [:]
        /// Errors for the next calls, first in first out, per call.
        var failures: [Call: [any Error & Sendable]] = [:]
        /// Holds no call has reached yet, first in first out, per call.
        var holds: [Call: [StuckCall]] = [:]
        /// Holds a call has taken and not yet got past, by serial.
        var parked: [Int: StuckCall] = [:]
        var lastParked = 0
        var pop: (@Sendable (Stash, URL, CLIGitBackend) async throws -> StashApplyOutcome)?
    }

    private let state = Mutex(State())

    init(real: CLIGitBackend = CLIGitBackend()) {
        precondition(TestGitEnvironment.isolated)
        self.real = real
    }

    // MARK: - What a test does

    /// Runs `action` before or after every `call` (it may throw: the call then throws that error).
    /// Hooks of one call and side run in the order they were added.
    func hook(_ call: Call, _ when: When = .before, _ action: @escaping @Sendable () async throws -> Void) {
        state.withLock { $0.hooks[call, default: []].append(Hook(when: when, action: action)) }
    }

    /// Holds the next `call` before it reaches git until the returned gate is released; `waiting`
    /// turns true once the call is parked. Release only once `waiting` is true: a release before
    /// the call parks finds nothing to resume (`releaseAll()` does not have that limit).
    /// Releasing at teardown is the test's to do, and so is waiting for what it lets run: declare
    /// `defer { await releaseAndSettle([backend], [store]) }` after the repository's `defer`, or a
    /// test that fails before its own release leaves the call parked, or racing the removal.
    func hold(_ call: Call) -> StuckCall {
        let gate = StuckCall()
        state.withLock { $0.holds[call, default: []].append(gate) }
        return gate
    }

    /// Makes the next `call` throw `error` without running git.
    func fail(_ call: Call, with error: any Error & Sendable) {
        state.withLock { $0.failures[call, default: []].append(error) }
    }

    /// Replaces `pop(_:at:)`: `body` gets the stash, the root and the real backend, whose
    /// internal `pop(_:at:beforeDrop:)` lets it act between the apply and the drop. The call is
    /// still logged, hooked, failed and held as any other.
    func replacePop(_ body: @escaping @Sendable (Stash, URL, CLIGitBackend) async throws -> StashApplyOutcome) {
        state.withLock { $0.pop = body }
    }

    /// The calls made so far, in order.
    var calls: [Call] { state.withLock { $0.calls } }

    /// Releases every hold still parked and drops every hold no call has reached yet (call from
    /// the test's cleanup; RF4). A call that has taken its hold but not yet parked on it would
    /// park after a single release and stay, so each taken hold is released again until its
    /// call has got past it.
    func releaseAll() {
        let parked = state.withLock { state in
            state.holds = [:]
            return state.parked
        }
        for (serial, gate) in parked {
            gate.release()
            Task { [weak self] in
                while self?.isParked(serial) == true {
                    gate.release()
                    try? await Task.sleep(for: .milliseconds(10))
                }
            }
        }
    }

    private func isParked(_ serial: Int) -> Bool {
        state.withLock { $0.parked[serial] != nil }
    }

    // MARK: - Around every call

    /// What every forwarder runs `body` (git, or a replacement) inside; see the type's
    /// documentation for the order. `function` is the forwarder's own `#function`, and a `call`
    /// spelled otherwise is recorded as an issue (the call goes on). Internal, not private, for
    /// that check's control.
    func around<Value>(
        _ call: Call, function: String = #function, _ body: () async throws -> Value
    ) async throws -> Value {
        if call.rawValue != function {
            Issue.record("TestBackend: \(function) is keyed as \(call.rawValue)")
        }
        let hooks = state.withLock { state in
            state.calls.append(call)
            return state.hooks[call] ?? []
        }
        for hook in hooks where hook.when == .before { try await hook.action() }
        let failure = state.withLock { state -> (any Error & Sendable)? in
            guard var pending = state.failures[call], !pending.isEmpty else { return nil }
            let first = pending.removeFirst()
            state.failures[call] = pending
            return first
        }
        if let failure { throw failure }
        let hold = state.withLock { state -> (serial: Int, gate: StuckCall)? in
            guard var pending = state.holds[call], !pending.isEmpty else { return nil }
            let gate = pending.removeFirst()
            state.holds[call] = pending
            state.lastParked += 1
            state.parked[state.lastParked] = gate
            return (state.lastParked, gate)
        }
        if let hold {
            await hold.gate.wait()
            _ = state.withLock { $0.parked.removeValue(forKey: hold.serial) }
        }
        let value = try await body()
        for hook in hooks where hook.when == .after { try await hook.action() }
        return value
    }

    // MARK: - The forwarders

    // MARK: - GitBackend

    func snapshot(at root: URL, historyDepth: Int) async throws -> RepoSnapshot {
        try await around(.snapshot) { try await real.snapshot(at: root, historyDepth: historyDepth) }
    }
    func historyRow(of sha: String, at root: URL) async throws -> Int? {
        try await around(.historyRow) { try await real.historyRow(of: sha, at: root) }
    }
    func commit(_ sha: String, at root: URL) async throws -> Commit? {
        try await around(.commitByID) { try await real.commit(sha, at: root) }
    }
    func workingCopyDiff(at root: URL, path: String, staged: Bool) async throws -> [FileDiff] {
        try await around(.workingCopyDiff) { try await real.workingCopyDiff(at: root, path: path, staged: staged) }
    }
    func commitFiles(at root: URL, sha: String) async throws -> [FileStatus] {
        try await around(.commitFiles) { try await real.commitFiles(at: root, sha: sha) }
    }
    func commitDiff(at root: URL, sha: String, path: String?) async throws -> [FileDiff] {
        try await around(.commitDiff) { try await real.commitDiff(at: root, sha: sha, path: path) }
    }

    // MARK: - GitWorkingCopyBackend

    func stage(paths: [String], at root: URL) async throws {
        try await around(.stage) { try await real.stage(paths: paths, at: root) }
    }
    func unstage(paths: [String], at root: URL) async throws {
        try await around(.unstage) { try await real.unstage(paths: paths, at: root) }
    }
    func stageAll(at root: URL) async throws {
        try await around(.stageAll) { try await real.stageAll(at: root) }
    }
    func stageAllPaths(at root: URL) async throws -> [String] {
        try await around(.stageAllPaths) { try await real.stageAllPaths(at: root) }
    }
    func stageAll(expecting expected: [String], at root: URL) async throws {
        try await around(.stageAllExpecting) { try await real.stageAll(expecting: expected, at: root) }
    }
    func unstageAll(at root: URL) async throws {
        try await around(.unstageAll) { try await real.unstageAll(at: root) }
    }
    func applyToIndex(patch: Patch, reverse: Bool, at root: URL) async throws {
        try await around(.applyToIndex) { try await real.applyToIndex(patch: patch, reverse: reverse, at: root) }
    }
    func commit(message: String, amend: Bool, allTracked: Bool, at root: URL) async throws -> String {
        try await around(.commit) {
            try await real.commit(message: message, amend: amend, allTracked: allTracked, at: root)
        }
    }
    func headMessage(at root: URL) async throws -> String {
        try await around(.headMessage) { try await real.headMessage(at: root) }
    }
    func discardExpectation(tracked paths: [String], includingStaged: Bool, at root: URL) async throws -> DiscardExpectation {
        try await around(.discardExpectationTracked) {
            try await real.discardExpectation(tracked: paths, includingStaged: includingStaged, at: root)
        }
    }
    func discardExpectation(untracked paths: [String], at root: URL) async throws -> DiscardExpectation {
        try await around(.discardExpectationUntracked) { try await real.discardExpectation(untracked: paths, at: root) }
    }
    func discard(_ request: DiscardRequest, trasher: any Trasher, at root: URL) async throws -> DiscardReceipt {
        try await around(.discard) { try await real.discard(request, trasher: trasher, at: root) }
    }
    func undoDiscard(_ receipt: DiscardReceipt, trasher: any Trasher, at root: URL) async throws -> UndoDiscardOutcome {
        try await around(.undoDiscard) { try await real.undoDiscard(receipt, trasher: trasher, at: root) }
    }

    // MARK: - GitBranchBackend

    func validateBranchName(_ name: String, at root: URL) async throws -> Bool {
        try await around(.validateBranchName) { try await real.validateBranchName(name, at: root) }
    }
    func createBranch(_ name: String, startPoint: String?, switchTo: Bool, at root: URL) async throws {
        try await around(.createBranch) {
            try await real.createBranch(name, startPoint: startPoint, switchTo: switchTo, at: root)
        }
    }
    func switchTo(branch: String, at root: URL) async throws {
        try await around(.switchTo) { try await real.switchTo(branch: branch, at: root) }
    }
    func checkoutDetached(_ revision: String, at root: URL) async throws {
        try await around(.checkoutDetached) { try await real.checkoutDetached(revision, at: root) }
    }
    func trackRemoteBranch(_ remoteBranch: String, at root: URL) async throws {
        try await around(.trackRemoteBranch) { try await real.trackRemoteBranch(remoteBranch, at: root) }
    }
    func renameBranch(_ old: String, to new: String, at root: URL) async throws {
        try await around(.renameBranch) { try await real.renameBranch(old, to: new, at: root) }
    }
    func deleteBranch(_ name: String, at root: URL) async throws -> BranchDeletion {
        try await around(.deleteBranch) { try await real.deleteBranch(name, at: root) }
    }
    func forceDeleteBranch(_ name: String, expectedTip: String, at root: URL) async throws {
        try await around(.forceDeleteBranch) {
            try await real.forceDeleteBranch(name, expectedTip: expectedTip, at: root)
        }
    }
    func commitsOnlyOn(branch: String, at root: URL) async throws -> Int {
        try await around(.commitsOnlyOn) { try await real.commitsOnlyOn(branch: branch, at: root) }
    }
    func commitCount(in branch: String, notIn base: String, at root: URL) async throws -> Int {
        try await around(.commitCount) { try await real.commitCount(in: branch, notIn: base, at: root) }
    }
    func unreferencedCommits(at root: URL) async throws -> UnreferencedCommits {
        try await around(.unreferencedCommits) { try await real.unreferencedCommits(at: root) }
    }
    func merge(_ branch: String, mode: MergeMode, at root: URL) async throws -> MergeOutcome {
        try await around(.merge) { try await real.merge(branch, mode: mode, at: root) }
    }
    func abort(_ operation: RepositoryOperation, at root: URL) async throws {
        try await around(.abort) { try await real.abort(operation, at: root) }
    }

    // MARK: - GitRemoteBackend

    func fetch(remote: String?, at root: URL, progress: @escaping @Sendable (String) -> Void) async throws {
        try await around(.fetch) { try await real.fetch(remote: remote, at: root, progress: progress) }
    }
    func push(_ branch: String, to remote: String, remoteRef: String, setUpstream: Bool, at root: URL, progress: @escaping @Sendable (String) -> Void) async throws -> PushResult {
        try await around(.push) {
            try await real.push(branch, to: remote, remoteRef: remoteRef, setUpstream: setUpstream, at: root, progress: progress)
        }
    }
    func forcePush(_ branch: String, to remote: String, remoteRef: String, expectedRemoteTip: String, expectedLocalTip: String, at root: URL, progress: @escaping @Sendable (String) -> Void) async throws -> PushResult {
        try await around(.forcePush) {
            try await real.forcePush(branch, to: remote, remoteRef: remoteRef, expectedRemoteTip: expectedRemoteTip, expectedLocalTip: expectedLocalTip, at: root, progress: progress)
        }
    }
    func deleteRemoteBranch(_ branch: String, on remote: String, expectedTip: String, at root: URL) async throws -> PushResult {
        try await around(.deleteRemoteBranch) {
            try await real.deleteRemoteBranch(branch, on: remote, expectedTip: expectedTip, at: root)
        }
    }
    func rebase(onto upstream: String, at root: URL) async throws -> RebaseOutcome {
        try await around(.rebaseOnto) { try await real.rebase(onto: upstream, at: root) }
    }
    func commits(in revision: String, notIn base: String, limit: Int, at root: URL) async throws -> [Commit] {
        try await around(.commits) { try await real.commits(in: revision, notIn: base, limit: limit, at: root) }
    }
    func commitsOnlyOnRemoteBranch(_ remoteBranch: String, at root: URL) async throws -> Int {
        try await around(.commitsOnlyOnRemoteBranch) {
            try await real.commitsOnlyOnRemoteBranch(remoteBranch, at: root)
        }
    }

    // MARK: - GitStashBackend

    func stashes(at root: URL) async throws -> [Stash] {
        try await around(.stashes) { try await real.stashes(at: root) }
    }
    func stashDiff(_ stash: Stash, at root: URL) async throws -> [FileDiff] {
        try await around(.stashDiff) { try await real.stashDiff(stash, at: root) }
    }
    func stashContents(_ stash: Stash, at root: URL) async throws -> StashContents {
        try await around(.stashContents) { try await real.stashContents(stash, at: root) }
    }
    func stashAll(message: String?, includeUntracked: Bool, at root: URL) async throws -> StashPushOutcome {
        try await around(.stashAll) {
            try await real.stashAll(message: message, includeUntracked: includeUntracked, at: root)
        }
    }
    func stashPaths(_ paths: [String], message: String, at root: URL) async throws -> StashPushOutcome {
        try await around(.stashPaths) { try await real.stashPaths(paths, message: message, at: root) }
    }
    func apply(_ stash: Stash, at root: URL) async throws -> StashApplyOutcome {
        try await around(.apply) { try await real.apply(stash, at: root) }
    }
    func pop(_ stash: Stash, at root: URL) async throws -> StashApplyOutcome {
        try await around(.pop) {
            if let replacement = state.withLock({ $0.pop }) { return try await replacement(stash, root, real) }
            return try await real.pop(stash, at: root)
        }
    }
    func drop(_ stash: Stash, at root: URL) async throws {
        try await around(.drop) { try await real.drop(stash, at: root) }
    }

    // MARK: - GitConflictBackend

    func conflictDocument(for file: ConflictedFile, at root: URL) async throws -> ConflictDocument {
        try await around(.conflictDocument) { try await real.conflictDocument(for: file, at: root) }
    }
    func resolve(_ snapshot: ConflictSnapshot, choices: [BlockChoice], recordIfEdited: Bool, at root: URL) async throws -> ConflictReceipt {
        try await around(.resolve) {
            try await real.resolve(snapshot, choices: choices, recordIfEdited: recordIfEdited, at: root)
        }
    }
    func take(_ side: ConflictSide, _ snapshot: ConflictSnapshot, recordIfEdited: Bool, at root: URL) async throws -> ConflictReceipt {
        try await around(.take) { try await real.take(side, snapshot, recordIfEdited: recordIfEdited, at: root) }
    }
    func delete(_ snapshot: ConflictSnapshot, recordIfEdited: Bool, at root: URL) async throws -> ConflictReceipt {
        try await around(.delete) { try await real.delete(snapshot, recordIfEdited: recordIfEdited, at: root) }
    }
    func keep(_ snapshot: ConflictSnapshot, recordIfEdited: Bool, at root: URL) async throws -> ConflictReceipt {
        try await around(.keep) { try await real.keep(snapshot, recordIfEdited: recordIfEdited, at: root) }
    }
    func leftoverMarkers(in path: String, at root: URL) async throws -> Int {
        try await around(.leftoverMarkers) { try await real.leftoverMarkers(in: path, at: root) }
    }
    func markResolved(_ snapshot: ConflictSnapshot, allowingMarkers: Bool, at root: URL) async throws {
        try await around(.markResolved) {
            try await real.markResolved(snapshot, allowingMarkers: allowingMarkers, at: root)
        }
    }
    func canReopen(_ path: String, at root: URL) async throws -> Bool {
        try await around(.canReopen) { try await real.canReopen(path, at: root) }
    }
    func reopen(_ path: String, expectingWorktreeHash: String?, at root: URL) async throws -> ConflictReceipt {
        try await around(.reopen) {
            try await real.reopen(path, expectingWorktreeHash: expectingWorktreeHash, at: root)
        }
    }
    func reopenedFile(_ path: String, at root: URL) async throws -> ReopenedFile? {
        try await around(.reopenedFile) { try await real.reopenedFile(path, at: root) }
    }

    // MARK: - GitOperationBackend

    func operationProgress(at root: URL) async throws -> OperationProgress? {
        try await around(.operationProgress) { try await real.operationProgress(at: root) }
    }
    func pendingMessage(at root: URL) async throws -> PendingMessage? {
        try await around(.pendingMessage) { try await real.pendingMessage(at: root) }
    }
    func operationPaths(at root: URL) async throws -> [String]? {
        try await around(.operationPaths) { try await real.operationPaths(at: root) }
    }
    func continueReadiness(at root: URL) async throws -> ContinueReadiness {
        try await around(.continueReadiness) { try await real.continueReadiness(at: root) }
    }
    func continueOperation(_ expected: RepositoryOperation, message: String?, acknowledgingOtherStaged: [String], at root: URL) async throws -> ContinueOutcome {
        try await around(.continueOperation) {
            try await real.continueOperation(expected, message: message, acknowledgingOtherStaged: acknowledgingOtherStaged, at: root)
        }
    }
    func skipReadiness(at root: URL) async throws -> SkipReadiness {
        try await around(.skipReadiness) { try await real.skipReadiness(at: root) }
    }
    func skip(_ expected: RepositoryOperation, stoppedAt sha: String, at root: URL) async throws -> SkipOutcome {
        try await around(.skip) { try await real.skip(expected, stoppedAt: sha, at: root) }
    }
    func haltedSequence(at root: URL) async throws -> HaltedSequence? {
        try await around(.haltedSequence) { try await real.haltedSequence(at: root) }
    }
    func staleSequence(at root: URL) async throws -> HaltedSequence? {
        try await around(.staleSequence) { try await real.staleSequence(at: root) }
    }
    func commitsAbortRemoves(at root: URL) async throws -> [CommitRef] {
        try await around(.commitsAbortRemoves) { try await real.commitsAbortRemoves(at: root) }
    }

    // MARK: - GitHistoryBackend

    func historyPlan(_ action: HistoryAction, shas: [String], at root: URL) async throws -> HistoryPlan {
        try await around(.historyPlan) { try await real.historyPlan(action, shas: shas, at: root) }
    }
    func run(_ plan: HistoryPlan, at root: URL) async throws -> HistoryOutcome {
        try await around(.run) { try await real.run(plan, at: root) }
    }
    func rebasePlan(onto target: String, at root: URL) async throws -> RebasePlan {
        try await around(.rebasePlan) { try await real.rebasePlan(onto: target, at: root) }
    }
    func rebase(_ plan: RebasePlan, at root: URL) async throws -> RebaseOutcome {
        try await around(.rebaseWithPlan) { try await real.rebase(plan, at: root) }
    }

    // MARK: - GitTagBackend

    func tagNameProblem(_ name: String, at root: URL) async throws -> TagNameProblem? {
        try await around(.tagNameProblem) { try await real.tagNameProblem(name, at: root) }
    }
    func createTag(_ name: String, at sha: String, message: String?, at root: URL) async throws {
        try await around(.createTag) { try await real.createTag(name, at: sha, message: message, at: root) }
    }
    func deleteTag(_ tag: GitCore.Tag, at root: URL) async throws -> TagReceipt {
        try await around(.deleteTag) { try await real.deleteTag(tag, at: root) }
    }
    func restoreTag(_ receipt: TagReceipt, at root: URL) async throws {
        try await around(.restoreTag) { try await real.restoreTag(receipt, at: root) }
    }
    func remoteTagID(_ name: String, on remote: String, at root: URL) async throws -> String? {
        try await around(.remoteTagID) { try await real.remoteTagID(name, on: remote, at: root) }
    }
    func pushTag(_ name: String, to remote: String, at root: URL) async throws -> TagPushOutcome {
        try await around(.pushTag) { try await real.pushTag(name, to: remote, at: root) }
    }
    func deleteRemoteTag(_ name: String, on remote: String, expecting id: String, at root: URL) async throws {
        try await around(.deleteRemoteTag) { try await real.deleteRemoteTag(name, on: remote, expecting: id, at: root) }
    }
    func remotesFetchingNoTags(at root: URL) async throws -> [String] {
        try await around(.remotesFetchingNoTags) { try await real.remotesFetchingNoTags(at: root) }
    }

    // MARK: - GitRemoteAdminBackend

    func prunePlan(_ remote: String, at root: URL) async throws -> PrunePlan {
        try await around(.prunePlan) { try await real.prunePlan(remote, at: root) }
    }
    func stranded(by refs: [String], at root: URL) async throws -> StrandedCommits {
        try await around(.stranded) { try await real.stranded(by: refs, at: root) }
    }
    func prune(_ plan: PrunePlan, keeping: [String: String], at root: URL) async throws -> PruneResult {
        try await around(.prune) { try await real.prune(plan, keeping: keeping, at: root) }
    }
    func keepBranchNameProblem(_ name: String, at root: URL) async throws -> RemoteAdminRefusal? {
        try await around(.keepBranchNameProblem) { try await real.keepBranchNameProblem(name, at: root) }
    }
    func goneBranches(at root: URL) async throws -> [GoneBranch] {
        try await around(.goneBranches) { try await real.goneBranches(at: root) }
    }
    func remoteHEADTarget(of remote: String, at root: URL) async throws -> String? {
        try await around(.remoteHEADTarget) { try await real.remoteHEADTarget(of: remote, at: root) }
    }
    func branchConfigKeys(of branch: String, at root: URL) async throws -> [String] {
        try await around(.branchConfigKeys) { try await real.branchConfigKeys(of: branch, at: root) }
    }
    func fastForward(_ branch: String, expecting tip: String, at root: URL) async throws -> FastForwardOutcome {
        try await around(.fastForward) { try await real.fastForward(branch, expecting: tip, at: root) }
    }
    func setUpstream(of branch: String, to ref: String, at root: URL) async throws -> SetUpstreamResult {
        try await around(.setUpstream) { try await real.setUpstream(of: branch, to: ref, at: root) }
    }
    func unsetUpstream(of branch: String, at root: URL) async throws {
        try await around(.unsetUpstream) { try await real.unsetUpstream(of: branch, at: root) }
    }
    func remoteNameProblem(_ name: String, at root: URL) async throws -> RemoteNameProblem? {
        try await around(.remoteNameProblem) { try await real.remoteNameProblem(name, at: root) }
    }
    func remoteURLs(_ remote: String, at root: URL) async throws -> RemoteURLs {
        try await around(.remoteURLs) { try await real.remoteURLs(remote, at: root) }
    }
    func addRemote(_ name: String, url: String, at root: URL) async throws {
        try await around(.addRemote) { try await real.addRemote(name, url: url, at: root) }
    }
    func setURLs(of remote: String, fetch: String, push: PushURLChange, at root: URL) async throws {
        try await around(.setURLs) { try await real.setURLs(of: remote, fetch: fetch, push: push, at: root) }
    }
    func renameRemote(_ old: String, to new: String, at root: URL) async throws {
        try await around(.renameRemote) { try await real.renameRemote(old, to: new, at: root) }
    }
    func removalImpact(of remote: String, at root: URL) async throws -> RemovalImpact {
        try await around(.removalImpact) { try await real.removalImpact(of: remote, at: root) }
    }
    func removeRemote(_ impact: RemovalImpact, keeping: [String: String], at root: URL) async throws {
        try await around(.removeRemote) { try await real.removeRemote(impact, keeping: keeping, at: root) }
    }

    // MARK: - GitCompareBackend

    func compare(_ a: String, _ b: String, at root: URL) async throws -> Comparison {
        try await around(.compare) { try await real.compare(a, b, at: root) }
    }
    func comparisonFiles(_ c: Comparison, at root: URL) async throws -> [FileStatus] {
        try await around(.comparisonFiles) { try await real.comparisonFiles(c, at: root) }
    }
    func comparisonDiff(_ c: Comparison, path: String?, at root: URL) async throws -> [FileDiff] {
        try await around(.comparisonDiff) { try await real.comparisonDiff(c, path: path, at: root) }
    }

    // MARK: - GitWorktreeBackend

    func worktrees(at root: URL) async throws -> [Worktree] {
        try await around(.worktrees) { try await real.worktrees(at: root) }
    }
    func worktreeChanges(_ worktree: Worktree, at root: URL) async throws -> WorktreeChanges {
        try await around(.worktreeChanges) { try await real.worktreeChanges(worktree, at: root) }
    }
    func removalCheck(_ worktree: Worktree, at root: URL) async throws -> WorktreeRemoval {
        try await around(.removalCheck) { try await real.removalCheck(worktree, at: root) }
    }
    func addWorktree(path: String, branch: String, at root: URL) async throws -> AddWorktreeResult {
        try await around(.addWorktree) { try await real.addWorktree(path: path, branch: branch, at: root) }
    }
    func removeWorktree(_ removal: WorktreeRemoval, keeping: [String: String], at root: URL) async throws -> [String] {
        try await around(.removeWorktree) { try await real.removeWorktree(removal, keeping: keeping, at: root) }
    }
}

/// A value a hook or a replacement writes and the test reads, behind one `Mutex`: a checked
/// `Sendable` box for the `@Sendable` closures `TestBackend` takes.
final class Recorded<Value: Sendable>: Sendable {
    private let box: Mutex<Value>

    init(_ value: Value) { box = Mutex(value) }

    var value: Value { box.withLock { $0 } }

    func set(_ value: Value) { box.withLock { $0 = value } }

    func update(_ change: (inout Value) -> Void) { box.withLock { change(&$0) } }

    /// Sets `value` and returns what it replaced.
    func exchange(_ value: Value) -> Value {
        box.withLock { current in
            let old = current
            current = value
            return old
        }
    }
}
