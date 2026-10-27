import AppKit
import Foundation
import GitCore

/// What the store knows about the repository's worktrees (B3 Task 3), read after every snapshot
/// (`RepositoryStore.readWorktreeState`) and written when that read lands (final review, I2).
struct WorktreeState: Hashable, Sendable {
    /// `worktree list --porcelain -z`, the main worktree first (R13).
    var worktrees: [Worktree] = []
    /// Path → changes, for the linked worktrees read: those whose folder is there, at most
    /// `changesLimit` of them, in list order.
    var changes: [String: WorktreeChanges] = [:]
    /// Paths whose changes could not be read: "changes unknown" on the row, never a failed
    /// refresh (carried note 3).
    var unknownChanges: Set<String> = []
    /// Path → which operation holds the worktree's `operationBranches`, where it could be read.
    var operations: [String: WorktreeOperationKind] = [:]
    /// This window's worktree, as `list` printed its path — matched by real path, since `list`
    /// prints `/private/var/…` for a root opened as `/var/…` (R23, R28). Nil when not listed.
    var openPath: String?

    /// How many linked worktrees' changes are read with each refresh, in parallel.
    static let changesLimit = 20
}

/// When the worktree state is read (B3 final review, I2): in its own task, after the snapshot has
/// landed, never awaited by it — up to 20 `status` runs in other worktrees took 1.5–2.3 s on a
/// 60 000-file repository with 8 of them, and every stage, commit and reload waited for that. The
/// state before stays on screen until the new one arrives.
///
/// One read at a time. A request while one runs is kept, and runs once that one lands: the
/// watcher reloads every 300 ms at most, and cancelling the read in flight each time would starve
/// it. A read is written only for the generation it was started under, and `open()` resets the
/// schedule, so a read for the repository being left is never written (its task is cancelled).
struct WorktreeReadSchedule: Hashable, Sendable {
    struct Outcome: Hashable, Sendable {
        /// Write the state that was read.
        let write: Bool
        /// Then start another read: one was asked for while this one ran.
        let again: Bool
    }

    /// The generation the read in flight was started under; nil when none is.
    private var inFlight: Int?
    /// Another read was asked for while this one ran.
    private var pending = false

    var isReading: Bool { inFlight != nil }

    /// A read is wanted under `generation`: true when it starts now; false when one is running,
    /// which is then followed by one more.
    mutating func request(generation: Int) -> Bool {
        guard inFlight == nil else {
            pending = true
            return false
        }
        inFlight = generation
        pending = false
        return true
    }

    /// The read started under `generation` came back while the store is at `current`.
    mutating func finish(generation: Int, current: Int) -> Outcome {
        guard inFlight == generation, generation == current else { return Outcome(write: false, again: false) }
        inFlight = nil
        defer { pending = false }
        return Outcome(write: true, again: pending)
    }

    /// `open()`: nothing in flight is this repository's.
    mutating func reset() {
        inFlight = nil
        pending = false
    }
}

extension WorktreeOperationKind {
    /// The operation in the worktree at `worktreePath`, read from its own git directory as
    /// GitCore's `branchesHeld(in:)` reads the branches: `rebase-merge` or `rebase-apply` is a
    /// rebase, `BISECT_START` a bisect. Nil when neither is there, or the worktree's `.git` cannot
    /// be followed (its folder is gone): the wording then says "a rebase or bisect".
    static func read(worktreePath: String) -> WorktreeOperationKind? {
        guard let directories = RepositoryDirectories.resolve(root: URL(fileURLWithPath: worktreePath)) else {
            return nil
        }
        let git = directories.gitDirectory
        func exists(_ name: String) -> Bool {
            FileManager.default.fileExists(atPath: git.appendingPathComponent(name).path)
        }
        if exists("rebase-merge") || exists("rebase-apply") { return .rebase }
        if exists("BISECT_START") { return .bisect }
        return nil
    }
}

/// The worktree reading (B3 Task 3): the Worktrees section's rows and marks, the branches
/// another worktree holds, Open Worktree, Reveal in Finder and Copy Path, the window title of a
/// linked worktree and the history's "worktree:" pill. Every sentence is `WorktreeWording`'s.
///
/// Nothing here writes to the repository: Open Worktree switches this window to another folder
/// through `open(_:)`, which adds it to Open Recent. Add Worktree… and Remove Worktree… are
/// Task 5's.
extension RepositoryStore {

    // MARK: - The list

    var worktrees: [Worktree] { worktreeState.worktrees }

    /// Path → changes, linked worktrees only, at most `WorktreeState.changesLimit`.
    var worktreeChanges: [String: WorktreeChanges] { worktreeState.changes }

    func isOpenHere(_ worktree: Worktree) -> Bool {
        worktreeState.openPath == worktree.path
    }

    func changesReading(_ worktree: Worktree) -> WorktreeChangesReading {
        if let changes = worktreeState.changes[worktree.path] { return .read(changes) }
        return worktreeState.unknownChanges.contains(worktree.path) ? .unknown : .notRead
    }

    func marks(_ worktree: Worktree) -> [WorktreeMark] {
        WorktreeWording.marks(
            worktree, isOpenHere: isOpenHere(worktree), changes: changesReading(worktree),
            operation: worktreeState.operations[worktree.path])
    }

    // MARK: - This window

    /// This window has a linked worktree open: from the list once it is read, from the
    /// repository's own `.git` file before.
    var isLinkedWorktree: Bool {
        if let open = worktrees.first(where: isOpenHere) { return !open.isMain }
        return directories?.isLinkedWorktree ?? false
    }

    /// The main worktree's folder name, for a linked worktree's title: the list's first record,
    /// or, before it is read, the folder the common git directory is in (`main/.git` → "main";
    /// a bare `x.git` is its own).
    var mainWorktreeName: String? {
        if let main = worktrees.first(where: \.isMain) { return WorktreeWording.folderName(main.path) }
        guard let common = directories?.commonDirectory else { return nil }
        let folder = common.lastPathComponent == ".git" ? common.deletingLastPathComponent() : common
        return WorktreeWording.folderName(folder.path)
    }

    /// "wt-feat (worktree of main)" for a linked worktree, the folder name otherwise.
    var windowTitle: String {
        guard let root else { return "Gitter" }
        return WorktreeWording.windowTitle(
            folder: WorktreeWording.folderName(root.path), mainFolder: isLinkedWorktree ? mainWorktreeName : nil)
    }

    /// Other worktrees' detached HEADs by commit, for the history's pill.
    var detachedWorktreeHeads: [String: [Worktree]] {
        WorktreeWording.detachedHeads(worktrees, openPath: worktreeState.openPath)
    }

    // MARK: - Branches another worktree holds

    /// The worktree holding the local branch `name`, or nil.
    func worktreeHolder(of name: String) -> BranchHolder? {
        guard let branch = localBranch(name) else { return nil }
        return WorktreeWording.holder(
            of: branch, worktrees: worktrees, openPath: worktreeState.openPath, operations: worktreeState.operations)
    }

    /// Why Switch, Delete and Fast-Forward of `name` are off because another worktree holds it.
    func worktreeHeldReason(_ name: String) -> String? {
        worktreeHolder(of: name).map { WorktreeWording.heldReason(name, by: $0) }
    }

    // MARK: - The row's menu

    func openWorktreeBlockedReason(_ worktree: Worktree) -> String? {
        WorktreeWording.openBlocked(worktree, isOpenHere: isOpenHere(worktree))
    }

    /// Open Worktree, a double-click on the row, the add notice's Open: this window switches to
    /// it — unless another window already shows it, which comes to the front instead (Ruling 11:
    /// two stores on one worktree would be two watchers and two write lanes on one index). Routed
    /// through the store's registry (`.worktreeHere`); a store made outside one opens it itself.
    /// Nil, with the reason in the banner, when it cannot be opened.
    @discardableResult
    func openWorktree(_ worktree: Worktree) -> OpenRoute? {
        if let reason = openWorktreeBlockedReason(worktree) {
            showStickyError(reason)
            return nil
        }
        let url = URL(fileURLWithPath: worktree.path)
        guard let registry else {
            open(url)
            return .useFront(self)
        }
        return registry.open(url, kind: .worktreeHere, front: self)
    }

    /// Open in New Window (E2 Task 4): routed as an open (`.worktreeNewWindow`) through
    /// `registry` — the app's, `AppModel.windows` — so it gets a window of its own, or the window
    /// already showing it comes to the front; this window keeps its repository. Nil, with the
    /// reason in the banner, when it cannot be opened.
    @discardableResult
    func openWorktreeInNewWindow(_ worktree: Worktree, in registry: WindowRegistry) -> OpenRoute? {
        if let reason = WorktreeWording.openInNewWindowBlocked(worktree) {
            showStickyError(reason)
            return nil
        }
        return registry.open(URL(fileURLWithPath: worktree.path), kind: .worktreeNewWindow, front: self)
    }

    func revealWorktree(_ worktree: Worktree) {
        if let reason = WorktreeWording.revealBlocked(worktree) {
            showStickyError(reason)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
    }

    // MARK: - Reading

    /// Reads the worktree state for the snapshot that has just landed, in its own task off the
    /// main actor, and writes it when it arrives (`WorktreeReadSchedule`); the state before stays
    /// until then. Called by `loadSnapshot()` after the snapshot is written.
    func scheduleWorktreeStateRead() {
        guard let root else { return }
        let generation = self.generation
        guard worktreeReadSchedule.request(generation: generation) else { return }
        let backend = self.backend
        worktreeReadTask = Task { [weak self] in
            let state = await Self.readWorktreeState(backend: backend, root: root)
            guard let self else { return }
            let outcome = self.worktreeReadSchedule.finish(generation: generation, current: self.generation)
            guard outcome.write, !Task.isCancelled else { return }
            self.worktreeReadTask = nil
            self.setWorktreeState(state)
            if outcome.again { self.scheduleWorktreeStateRead() }
        }
    }

    /// Whether a worktree state read is running (the harness waits for it before a step).
    var isReadingWorktreeState: Bool { worktreeReadSchedule.isReading }

    /// The worktree state for `root`, read off the main actor after each snapshot: the list, then
    /// — in parallel — the changes of at most `WorktreeState.changesLimit` linked worktrees whose
    /// folder is there, and the operation holding any worktree's branches. A list that cannot be
    /// read is an empty state (no section, no marks) and a changes read that fails is "changes
    /// unknown": neither fails the refresh (carried note 3).
    nonisolated static func readWorktreeState(backend: Backend, root: URL) async -> WorktreeState {
        guard let listed = try? await backend.worktrees(at: root) else { return WorktreeState() }
        let rootPath = realPath(root.path)
        var state = WorktreeState(worktrees: listed)
        state.openPath = listed.first { realPath($0.path) == rootPath }?.path
        let toRead = listed.filter { !$0.isMain && !$0.isMissing && !$0.isBare }.prefix(WorktreeState.changesLimit)
        let read = await withTaskGroup(of: (String, WorktreeChanges?).self) { group in
            for worktree in toRead {
                group.addTask { (worktree.path, try? await backend.worktreeChanges(worktree, at: root)) }
            }
            var results: [(String, WorktreeChanges?)] = []
            for await result in group { results.append(result) }
            return results
        }
        for (path, changes) in read {
            if let changes { state.changes[path] = changes } else { state.unknownChanges.insert(path) }
        }
        for worktree in listed where !worktree.operationBranches.isEmpty {
            state.operations[worktree.path] = WorktreeOperationKind.read(worktreePath: worktree.path)
        }
        return state
    }

    /// `path` with its links followed as `realpath(3)` follows them — `/var` is `/private/var`,
    /// as git prints it — or as it is when it cannot be resolved.
    nonisolated private static func realPath(_ path: String) -> String {
        guard let resolved = realpath(path, nil) else { return path }
        defer { free(resolved) }
        return String(cString: resolved)
    }
}

/// What Add Worktree checks out (B3 Task 5, Ruling 3): an existing local branch by its short
/// name, or a branch it creates first — at a start point's id (for a commit, `start.ref` is the
/// id itself), or at a remote branch's id, then set to track it.
enum AddWorktreeChoice: Hashable {
    case existing(String)
    case newBranch(name: String, start: RefTip)
    case tracking(name: String, remote: RefTip)

    /// The local branch the worktree is for.
    var branch: String {
        switch self {
        case .existing(let name), .newBranch(let name, _), .tracking(let name, _): name
        }
    }

    /// Whether a branch is created before the worktree is added.
    var createsBranch: Bool {
        if case .existing = self { false } else { true }
    }
}

/// Add Worktree… and Remove Worktree… (B3 Task 5). Both write through `mutate` — local work,
/// never the network lane — and run git off the main actor. Every sentence is
/// `WorktreeWording`'s.
///
/// - **Add** checks out only the branch the user chose (promise 3): an existing local branch
///   no worktree holds, or one it creates first as a separate step — `createBranch` from an id,
///   then, for a remote branch, B2's `setUpstream`, which reads its write back — and then
///   GitCore's `addWorktree`, which verifies the branch right before git and reads `list` back
///   whatever git's exit code (R19). Each partial state is said, and the notice offers Open.
/// - **Remove** shows what Gitter's own check found (`removalCheck`, off the main actor, with a
///   progress state and cancelled when the sheet closes) and hands exactly that to GitCore,
///   which makes the check again before it creates a kept branch or runs git (promise 2, RF1).
extension RepositoryStore {

    // MARK: - Add Worktree

    var addWorktreeBlockedReason: String? {
        root == nil ? RemoteWording.noRepository : changeRunningBlockedReason
    }

    /// "New Worktree for <b>…": off for this window's branch and one another worktree holds.
    func newWorktreeBlockedReason(_ name: String) -> String? {
        WorktreeWording.newWorktreeBlocked(name, isCurrent: name == currentBranch, heldReason: worktreeHeldReason(name))
            ?? changeRunningBlockedReason
    }

    /// Opens the Add Worktree sheet, preset to the local branch `branch` when given.
    func requestAddWorktree(branch: String?) {
        if let reason = addWorktreeBlockedReason ?? branch.flatMap(newWorktreeBlockedReason) {
            showStickyError(reason)
            return
        }
        activeSheet = .addWorktree(branch: branch)
    }

    /// Existing branch's choices: no worktree has them checked out, no rebase or bisect holds
    /// them.
    var freeWorktreeBranches: [String] {
        WorktreeWording.freeBranches(localBranches, current: currentBranch, worktrees: worktrees)
    }

    /// New branch's start points: a detached HEAD's commit (by its id), then every local and
    /// remote branch at the id the snapshot read.
    var worktreeStartPoints: [RefTip] {
        var tips: [RefTip] = []
        if currentBranch == nil, let head = headSha, !head.isEmpty { tips.append(RefTip(ref: head, id: head)) }
        tips += localBranches.filter { !$0.sha.isEmpty }.map { RefTip(ref: "refs/heads/" + $0.name, id: $0.sha) }
        return tips + worktreeRemoteTips
    }

    /// Remote branch's choices, at the id the snapshot read.
    var worktreeRemoteTips: [RefTip] {
        remoteBranches.filter { !$0.sha.isEmpty }.map { RefTip(ref: "refs/remotes/" + $0.name, id: $0.sha) }
    }

    /// The local name a tracking branch is offered for `tip`: the remote branch's own name.
    func trackingName(for tip: RefTip) -> String {
        let short = WorktreeWording.startLabel(tip)
        let owner = remoteBranches.first { "refs/remotes/" + $0.name == tip.ref }.flatMap { snapshot?.refs.remote(of: $0)?.name }
        return WorktreeWording.trackingName(short, remote: owner)
    }

    /// The folder the sheet starts with for `branch`: a sibling of the main worktree.
    func defaultWorktreeFolder(for branch: String) -> String {
        let main = worktrees.first(where: \.isMain)?.path ?? root?.path ?? "/"
        return WorktreeWording.defaultFolder(mainPath: main, branch: branch)
    }

    /// The folder field's live check, read off the main actor: what is at the path, and which
    /// listed worktree holds it, both sides by real path (R23, GitCore's `WorktreePaths`).
    func worktreeFolderProblem(_ text: String) async -> String? {
        let path = WorktreeWording.normalizedFolder(text)
        let listed = worktrees.map(\.path)
        return await Task.detached { Self.folderProblem(path, listed: listed) }.value
    }

    nonisolated static func folderProblem(_ path: String, listed: [String]) -> String? {
        guard path.hasPrefix("/") else { return WorktreeWording.folderProblem(path, state: .missing, insideWorktree: nil) }
        let inside = WorktreeWording.containingWorktree(
            WorktreePaths.resolved(path), in: listed.map { (path: $0, resolved: WorktreePaths.resolved($0)) })
        return WorktreeWording.folderProblem(path, state: folderState(path), insideWorktree: inside)
    }

    /// What is at `path`, not following a link (a link is not a folder git would fill).
    nonisolated static func folderState(_ path: String) -> WorktreeFolderState {
        guard let type = (try? FileManager.default.attributesOfItem(atPath: path))?[.type] as? FileAttributeType else {
            return .missing
        }
        guard type == .typeDirectory else { return .notAFolder }
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return .unreadable }
        return names.isEmpty ? .empty : .notEmpty
    }

    /// Adds the worktree the Add sheet describes — only as the answer to that sheet. A branch is
    /// created first only for a new or tracking choice (Ruling 3); a failure after that names it.
    /// The notice is sticky and offers Open; one with nothing listed is a banner.
    func confirmAddWorktree(_ choice: AddWorktreeChoice, path: String) {
        guard case .addWorktree = activeSheet else { return }
        guard !isMutating else {
            showStickyError(RemoteWording.mutationBusy)
            return
        }
        activeSheet = nil
        let path = WorktreeWording.normalizedFolder(path)
        mutate(result: { backend, root in
            try await Self.addWorktree(choice, path: path, backend: backend, root: root)
        }, onSuccess: { [self] report in
            guard let opens = report.opens else {
                showStickyError(report.text)
                return
            }
            showStickyNotice(Notice(text: report.text, actions: [.openWorktree(opens)]))
        })
    }

    private static func addWorktree(
        _ choice: AddWorktreeChoice, path: String, backend: Backend, root: URL
    ) async throws -> AddWorktreeReport {
        var upstreamProblem: String?
        switch choice {
        case .existing:
            break
        case .newBranch(let name, let start):
            try await createWorktreeBranch(name, at: start.id, backend: backend, root: root)
        case .tracking(let name, let remote):
            try await createWorktreeBranch(name, at: remote.id, backend: backend, root: root)
            do {
                _ = try await backend.setUpstream(of: name, to: remote.ref, at: root)
            } catch {
                upstreamProblem = WorktreeWording.upstreamProblem(error)
            }
        }
        let result: AddWorktreeResult
        do {
            result = try await backend.addWorktree(path: path, branch: choice.branch, at: root)
        } catch {
            throw RemoteBannerText(
                WorktreeWording.addFailure(
                    error, choice: choice, path: path, branchCreated: choice.createsBranch,
                    upstreamProblem: upstreamProblem))
        }
        return WorktreeWording.added(result, choice: choice, upstreamProblem: upstreamProblem)
    }

    /// The new branch, from an id and not switched to — the existing branch creation.
    private static func createWorktreeBranch(_ name: String, at id: String, backend: Backend, root: URL) async throws {
        do {
            try await backend.createBranch(name, startPoint: id, switchTo: false, at: root)
        } catch {
            throw RemoteBannerText(WorktreeWording.branchNotCreated(error, name: name))
        }
    }

    /// The add notice's Open: this window switches to the worktree, if it is still listed.
    /// The list is read after the add's snapshot lands (B3 final review, I2), so a click before
    /// that read is in waits for it — and any read queued behind it — before "not listed".
    func openAddedWorktree(_ path: String) {
        if let worktree = worktrees.first(where: { $0.path == path }) {
            openWorktree(worktree)
            return
        }
        guard isReadingWorktreeState else {
            showStickyError(WorktreeWording.notListedAnyMore(path))
            return
        }
        let generation = self.generation
        Task { [weak self] in
            while let self, self.generation == generation, self.isReadingWorktreeState,
                !self.worktrees.contains(where: { $0.path == path }), let reading = self.worktreeReadTask
            {
                await reading.value
            }
            guard let self, self.generation == generation else { return }
            guard let worktree = self.worktrees.first(where: { $0.path == path }) else {
                self.showStickyError(WorktreeWording.notListedAnyMore(path))
                return
            }
            self.openWorktree(worktree)
        }
    }

    // MARK: - Remove Worktree

    func removeWorktreeBlockedReason(_ worktree: Worktree) -> String? {
        WorktreeWording.removeBlocked(worktree, isOpenHere: isOpenHere(worktree)) ?? changeRunningBlockedReason
    }

    var removeAllMissingBlockedReason: String? {
        WorktreeWording.removeAllMissingBlocked(worktrees) ?? changeRunningBlockedReason
    }

    /// Opens the Remove sheet in its progress state and runs Gitter's removal check off the main
    /// actor; the sheet then shows what it found.
    func requestRemoveWorktree(_ worktree: Worktree) {
        if let reason = removeWorktreeBlockedReason(worktree) {
            showStickyError(reason)
            return
        }
        startRemovalCheck([worktree], allMissing: false)
    }

    /// Remove All Missing…: the check of every worktree whose folder is gone, then one sheet.
    func requestRemoveAllMissing() {
        if let reason = removeAllMissingBlockedReason {
            showStickyError(reason)
            return
        }
        startRemovalCheck(WorktreeWording.missing(worktrees), allMissing: true)
    }

    private func startRemovalCheck(_ targets: [Worktree], allMissing: Bool) {
        guard let root, !targets.isEmpty else { return }
        worktreeCheckTask?.cancel()
        let sheet = BranchSheet.checkingWorktreeRemoval(targets, allMissing: allMissing)
        activeSheet = sheet
        let generation = self.generation
        let backend = self.backend
        worktreeCheckTask = Task { [weak self] in
            var removals: [WorktreeRemoval] = []
            var failure: (error: Error, worktree: Worktree)?
            for target in targets {
                do {
                    removals.append(try await backend.removalCheck(target, at: root))
                } catch WorktreeRemovalPartial.changedSinceShown where allMissing {
                    // Off the list already: nothing left to remove.
                    continue
                } catch {
                    failure = (error, target)
                    break
                }
            }
            guard let self, !Task.isCancelled, self.generation == generation, self.activeSheet == sheet else { return }
            if let failure {
                guard !(failure.error is CancellationError) else { return }
                self.activeSheet = nil
                self.showStickyError(WorktreeWording.checkFailure(failure.error, worktree: failure.worktree))
                return
            }
            if !allMissing, let removal = removals.first {
                self.activeSheet = .removeWorktree(removal)
            } else if removals.isEmpty {
                self.activeSheet = nil
                self.showNotice(WorktreeWording.noneMissing)
            } else {
                self.activeSheet = .removeMissingWorktrees(removals)
            }
        }
    }

    /// The Remove sheet closed: its check, if still running, is not wanted.
    func cancelWorktreeRemovalCheck() {
        worktreeCheckTask?.cancel()
    }

    /// The keep boxes' holders: each detached worktree whose HEAD alone holds commits, by its
    /// path as listed, at its HEAD — only for removals the sheet offers (no refusals).
    static func keepHolders(_ removals: [WorktreeRemoval]) -> [RefTip] {
        removals.filter { $0.refusals.isEmpty && $0.stranded.count > 0 }.flatMap { removal in
            removal.stranded.holders.compactMap { holder in removal.worktree.head.map { RefTip(ref: holder, id: $0) } }
        }
    }

    /// The keep boxes' defaults: every holder ticked, each with its folder's name made a branch
    /// name (`suggestedKeepName`), none alike and none a branch, tag or remote has.
    func worktreeKeepDefaults(_ holders: [RefTip]) -> (names: [String: String], ticked: Set<String>) {
        let refs = snapshot?.refs
        var taken = Set(
            (refs?.localBranches.map(\.name) ?? []) + (refs?.tags.map(\.name) ?? []) + (refs?.remoteNames ?? []))
        var names: [String: String] = [:]
        for tip in holders {
            let name = WorktreeWording.suggestedKeepName(folder: URL(fileURLWithPath: tip.ref).lastPathComponent, taken: taken)
            names[tip.ref] = name
            taken.insert(name)
        }
        return (names, Set(holders.map(\.ref)))
    }

    /// Removes the worktree `removal` describes — only as the answer to the sheet that showed it,
    /// and only when it showed no refusal — creating the kept branch in `keeping` (the worktree's
    /// path → a name) first. GitCore makes the check again and refuses any difference
    /// (`changedSinceShown`) before anything is written. A partial or unknown result is a sticky
    /// banner naming the kept branches; a removal that kept one is a sticky notice.
    func confirmRemoveWorktree(_ removal: WorktreeRemoval, keeping: [String: String]) {
        guard case .removeWorktree(let shown) = activeSheet, shown == removal, removal.refusals.isEmpty else { return }
        guard !isMutating else {
            showStickyError(RemoteWording.mutationBusy)
            return
        }
        activeSheet = nil
        mutate(result: { backend, root in
            do {
                return try await backend.removeWorktree(removal, keeping: keeping, at: root)
            } catch {
                throw RemoteBannerText(WorktreeWording.removeFailure(error, removal: removal))
            }
        }, onSuccess: { [self] kept in
            let text = WorktreeWording.removed(removal, kept: kept)
            if kept.isEmpty {
                showNotice(text)
            } else {
                show(Notice(text: text, keep: true))
            }
        })
    }

    /// Remove All Missing…: each of `removals` the sheet showed, one at a time through the same
    /// `removeWorktree` (which checks each again), the refused ones left; one report naming each.
    func confirmRemoveMissingWorktrees(_ removals: [WorktreeRemoval], keeping: [String: String]) {
        guard case .removeMissingWorktrees(let shown) = activeSheet, shown == removals,
            removals.contains(where: { $0.refusals.isEmpty })
        else { return }
        guard !isMutating else {
            showStickyError(RemoteWording.mutationBusy)
            return
        }
        activeSheet = nil
        mutate(result: { backend, root in
            var report: [MissingRemoval] = []
            for removal in removals {
                if let refusal = removal.refusals.first {
                    report.append(MissingRemoval(worktree: removal.worktree, outcome: .notRemoved(WorktreeWording.refusal(refusal))))
                    continue
                }
                let mine = keeping.filter { $0.key == removal.worktree.path }
                do {
                    let kept = try await backend.removeWorktree(removal, keeping: mine, at: root)
                    report.append(MissingRemoval(worktree: removal.worktree, outcome: .removed(kept: kept)))
                } catch {
                    report.append(
                        MissingRemoval(
                            worktree: removal.worktree,
                            outcome: .notRemoved(WorktreeWording.removeFailure(error, removal: removal))))
                }
            }
            return report
        }, onSuccess: { [self] report in
            let text = WorktreeWording.removedMissing(report)
            if WorktreeWording.missingReportHasProblems(report) {
                showStickyError(text)
            } else {
                show(Notice(text: text, keep: true))
            }
        })
    }
}
