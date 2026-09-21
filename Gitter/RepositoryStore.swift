import AppKit
import Foundation
import GitCore
import Observation

/// What is shown in the detail pane: the working copy, or a specific commit.
enum Selection: Hashable {
    case workingCopy
    case commit(String)
}

@Observable @MainActor
final class RepositoryStore {
    private(set) var root: URL?
    private(set) var snapshot: RepoSnapshot?
    private(set) var isLoading = false
    private(set) var lastError: String?
    private(set) var gitMissing = false
    var selection: Selection = .workingCopy
    var selectedPath: String?
    private(set) var detailFiles: [FileStatus] = []
    private(set) var diff: [FileDiff] = []
    /// Which side the loaded `diff` came from. `stagedView` flips the instant the user picks a
    /// row, while the matching `git diff` is still running, so for the time in between the two
    /// disagree. Anything that has to describe the diff actually on screen — the hunk buttons'
    /// labels, the direction their patch is applied in — reads this instead of `stagedView`.
    private(set) var diffIsStaged = false
    var stagedView = false {
        didSet {
            guard stagedView != oldValue else { return }
            guard selection == .workingCopy, selectedPath != nil else { return }
            loadDiff()
        }
    }

    /// True while a stage/unstage/commit is running; mutations are serialized behind it and
    /// the UI disables its controls. Claimed and released through `beginMutation()` /
    /// `finishMutation(generation:failure:)`, kept in this file so their write to it stays
    /// `private(set)`.
    private(set) var isMutating = false

    /// The commit message being written. Stored properties cannot live in an extension, so it
    /// is declared here even though everything that drives it is in `RepositoryStore+Staging`.
    let draft = CommitDraft()

    /// Which confirmation or form is on screen. The one piece of store state views are meant to
    /// write: a `.sheet(item:)` binding puts nil back on dismissal. Opening one still goes
    /// through `+BranchSheets`, so the store decides which question gets asked.
    var activeSheet: BranchSheet?

    /// A short, non-error message about something that just succeeded ("Fast-forwarded to
    /// feature."). Unlike `lastError` it is never sticky and clears itself after a few seconds.
    private(set) var notice: String?

    /// The auto-clear for `notice`. Bookkeeping only; views must not touch it.
    // internal (not private): used by +Branches.swift's `showNotice(_:)`
    var noticeTask: Task<Void, Never>?

    /// Bumped by every `open()`. Anything loaded or run asynchronously captures it and drops
    /// its result if it no longer matches: comparing `root` is not enough, because reopening
    /// the *same* repository mid-flight leaves the root equal while everything on screen has
    /// been reset.
    private(set) var generation = 0

    /// True while `lastError` holds a message a mutation put there. Such a message outlives
    /// the reloads the mutation itself provokes; see `loadSnapshot()`.
    // Direct writes stay in this file; see `clearSticky()` / `clearErrorUnlessSticky()` below.
    private var errorIsSticky = false

    /// Everything the store can ask git to do: reads, index and commit writes, and branch,
    /// checkout and merge writes. Three protocols so a fake can implement any one on its own.
    typealias Backend = any GitBackend & GitWorkingCopyBackend & GitBranchBackend

    let backend: Backend
    // internal (not private): used by +Opening.swift's `checkGitAvailability()`
    let gitPath: String

    private var watcher: RepositoryWatcher?
    // internal (not private), bookkeeping only, views must not touch this: used by +Refresh.swift
    var refreshTask: Task<Void, Never>?
    // internal (not private), bookkeeping only, views must not touch this: used by +Detail.swift
    var detailTask: Task<Void, Never>?
    // internal (not private), bookkeeping only, views must not touch this: used by +Detail.swift
    var diffTask: Task<Void, Never>?
    /// The most recently scheduled snapshot load; new ones chain behind it. See `refresh()`.
    // internal (not private), bookkeeping only, views must not touch this: used by +Refresh.swift
    var lastRefresh: Task<Void, Never>?
    /// True while a chained load exists that has not begun reading git yet.
    // internal (not private), bookkeeping only, views must not touch this: used by +Refresh.swift
    var refreshIsQueued = false

    // internal (not private): used by RepositoryStore+Opening.swift's `reopenLastRepository()`
    static let lastRepositoryPathKey = "lastRepositoryPath"

    init(
        backend: Backend = CLIGitBackend(),
        gitPath: String = "/usr/bin/git"
    ) {
        self.backend = backend
        self.gitPath = gitPath
    }

    // MARK: - Opening

    func open(_ url: URL) {
        // Once git itself is confirmed missing, no repository can be opened. Keep the banner
        // up instead of letting a reopen quietly clear it — and if the user dismissed it since,
        // put it back so "Open Repository…" doesn't silently do nothing.
        guard !gitMissing else {
            lastError = Self.gitMissingMessage(at: gitPath)
            // Sticky, like a mutation's own message: a repository may already be open, and its
            // watcher-driven reload succeeds and would clear this a fraction of a second later.
            errorIsSticky = true
            return
        }

        let standardized = url.standardizedFileURL
        let dotGit = standardized.appending(path: ".git")
        guard FileManager.default.fileExists(atPath: dotGit.path) else {
            lastError = "Not a Git repository: \(standardized.path)"
            errorIsSticky = true
            return
        }

        watcher?.stop()
        watcher = nil

        refreshTask?.cancel()
        detailTask?.cancel()
        diffTask?.cancel()
        // `lastRefresh` is deliberately left in place: a load still in flight for the old root
        // writes nothing (it re-checks `root` before it lands), and keeping the chain intact
        // keeps this repository's first load from overlapping it.

        // Reset all repository-derived state so nothing from the previous repository lingers
        // on screen (or gets raced against) while the new repository's first snapshot loads.
        snapshot = nil
        detailFiles = []
        setDiff([], staged: stagedView)
        selection = .workingCopy
        selectedPath = nil
        lastError = nil
        errorIsSticky = false
        // A question asked about the previous repository ("delete this unmerged branch?") must
        // never be answered against this one, and its notice is about a repository nobody is
        // looking at any more.
        activeSheet = nil
        dismissNotice()
        // A half-written message belongs to the repository it was written for, and a mutation
        // in flight can only be for the old one.
        draft.reset()
        // Released here and not left to the mutation itself: the generation below makes its
        // `finishMutation` stale, and a stale one returns early — so without this the flag
        // would stay set for the new repository and every button would stay disabled.
        isMutating = false
        // Everything in flight for the previous repository — including a reopen of this very
        // path — is now stale and will drop its result.
        generation += 1

        root = standardized
        UserDefaults.standard.set(standardized.path, forKey: Self.lastRepositoryPathKey)
        NSDocumentController.shared.noteNewRecentDocumentURL(standardized)

        watcher = RepositoryWatcher(path: standardized.path) { [weak self] in
            self?.scheduleRefresh()
        }

        Task { await refresh() }
    }

    // MARK: - Selection

    func select(_ newSelection: Selection) {
        selection = newSelection
        setDiff([], staged: stagedView)
        loadDetail()
    }

    func selectPath(_ path: String?) {
        selectedPath = path
        loadDiff()
    }

    // MARK: - State mutators for other files
    // Narrow setters for `private(set)` state whose writer lives in another file. Each pairs
    // with exactly the caller(s) named below; nothing else should call these.

    /// internal (not private(set) write): used by +Opening.swift's `checkGitAvailability()`
    func setGitMissing(_ value: Bool) {
        gitMissing = value
    }

    /// internal (not private(set) write): used by +Refresh.swift
    func setSnapshot(_ newSnapshot: RepoSnapshot?) {
        snapshot = newSnapshot
        // Here rather than in `+Refresh` because this is the one place the snapshot is written,
        // and "an operation has begun" is only ever learned from a new one. See
        // `reconcileAmendWithOperation` for why a ticked Amend cannot be left ticked.
        reconcileAmendWithOperation()
    }

    /// internal (not private(set) write): used by +Refresh.swift
    func setLoading(_ value: Bool) {
        isLoading = value
    }

    /// internal (not private(set) write): used by +Detail.swift
    func setDetailFiles(_ files: [FileStatus]) {
        detailFiles = files
    }

    /// internal (not private(set) write): used by +Branches.swift's `showNotice(_:)`/
    /// `dismissNotice()`, which own the auto-clear timing.
    func setNotice(_ message: String?) {
        notice = message
    }

    /// internal (not private(set) write): used by +Refresh.swift, +Detail.swift, +Errors.swift
    /// and +Opening.swift
    func setError(_ message: String?) {
        lastError = message
    }

    /// Clears `errorIsSticky` without touching `lastError`: what the original, unsplit code
    /// wrote as a bare `errorIsSticky = false` next to a `lastError` write it made its own way.
    /// internal (not private(set) write): used by +Refresh.swift, +Detail.swift, +Errors.swift
    func clearSticky() {
        errorIsSticky = false
    }

    /// The `if !errorIsSticky { lastError = nil }` a successful snapshot load does; the read has
    /// to move here too since `errorIsSticky` is only readable from this file.
    /// internal (not private(set) write): used by +Refresh.swift's `loadSnapshot()`
    func clearErrorUnlessSticky() {
        if !errorIsSticky {
            lastError = nil
        }
    }

    // MARK: - Mutation bookkeeping

    /// Claims the store for one git write, returning the generation to hand back to
    /// `finishMutation`, or nil when it cannot be claimed: no repository, or a mutation is
    /// already running (mutations are serialized, which is also what disables the buttons).
    ///
    /// This pair exists so the setters of `isMutating` and `lastError` can stay private while
    /// the staging API lives in another file, where `private(set)` would not reach.
    // internal (not private): used by +Staging.swift's `mutate()`
    func beginMutation() -> Int? {
        guard root != nil, !isMutating else { return nil }
        isMutating = true
        // A new attempt supersedes the last one's message: it has been read or ignored by
        // now, and nothing should keep protecting it from the reloads that follow.
        if errorIsSticky {
            lastError = nil
            errorIsSticky = false
        }
        // Same for a success notice, which would otherwise sit next to this attempt's banner
        // claiming the previous action worked — true, but read as if it were about this one.
        dismissNotice()
        return generation
    }

    /// Releases the claim `beginMutation()` made, showing `failure` in the banner if there was
    /// one. A stale generation means `open()` has already reset everything this would write.
    /// internal (not private): used by +Staging.swift's `mutate()`; kept next to `beginMutation`.
    func finishMutation(generation: Int, failure: Error?) {
        guard self.generation == generation else { return }
        if let failure {
            lastError = Self.describe(failure)
            // Protected from the reloads this mutation set off — its own, and the
            // watcher-driven one that git's writes inside `.git` trigger in parallel.
            errorIsSticky = true
        }
        isMutating = false
    }

    /// The one place `diff` is written, so `diffIsStaged` can never drift from it.
    /// internal (not private): used by +Detail.swift's `loadDiff()`; kept here since it writes
    /// `diff`/`diffIsStaged` and both stay `private(set)`.
    func setDiff(_ newDiff: [FileDiff], staged: Bool) {
        diff = newDiff
        diffIsStaged = staged
    }
}
