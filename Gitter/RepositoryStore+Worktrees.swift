import AppKit
import Foundation
import GitCore

/// What the store knows about the repository's worktrees (B3 Task 3), read with every snapshot
/// (`RepositoryStore.readWorktreeState`) and written with it.
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

    /// Open Worktree, and a double-click on the row: this window switches to it.
    func openWorktree(_ worktree: Worktree) {
        if let reason = openWorktreeBlockedReason(worktree) {
            showStickyError(reason)
            return
        }
        open(URL(fileURLWithPath: worktree.path))
    }

    func revealWorktree(_ worktree: Worktree) {
        if let reason = WorktreeWording.revealBlocked(worktree) {
            showStickyError(reason)
            return
        }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: worktree.path)])
    }

    // MARK: - Reading

    /// The worktree state for `root`, read off the main actor with each snapshot: the list, then
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
