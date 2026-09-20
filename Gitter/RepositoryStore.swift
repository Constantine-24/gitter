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
    // internal (not private(set)): used by RepositoryStore+Detail.swift
    var diff: [FileDiff] = []
    /// Which side the loaded `diff` came from. `stagedView` flips the instant the user picks a
    /// row, while the matching `git diff` is still running, so for the time in between the two
    /// disagree. Anything that has to describe the diff actually on screen — the hunk buttons'
    /// labels, the direction their patch is applied in — reads this instead of `stagedView`.
    // internal (not private(set)): used by RepositoryStore+Detail.swift
    var diffIsStaged = false
    var stagedView = false {
        didSet {
            guard stagedView != oldValue else { return }
            guard selection == .workingCopy, selectedPath != nil else { return }
            loadDiff()
        }
    }

    /// True while a stage/unstage/commit is running; mutations are serialized behind it and
    /// the UI disables its controls. Claimed and released through `beginMutation()` /
    /// `finishMutation(generation:failure:)`, since the staging extension is in another file.
    // internal (not private(set)): used by RepositoryStore+Errors.swift
    var isMutating = false

    /// The commit message being written. Stored properties cannot live in an extension, so it
    /// is declared here even though everything that drives it is in `RepositoryStore+Staging`.
    let draft = CommitDraft()

    /// Bumped by every `open()`. Anything loaded or run asynchronously captures it and drops
    /// its result if it no longer matches: comparing `root` is not enough, because reopening
    /// the *same* repository mid-flight leaves the root equal while everything on screen has
    /// been reset.
    private(set) var generation = 0

    /// True while `lastError` holds a message a mutation put there. Such a message outlives
    /// the reloads the mutation itself provokes; see `loadSnapshot()`.
    // internal (not private): used by RepositoryStore+Refresh.swift, +Detail.swift and +Errors.swift
    var errorIsSticky = false

    let backend: any GitBackend & GitWorkingCopyBackend
    private let gitPath: String

    private var watcher: RepositoryWatcher?
    // internal (not private): used by RepositoryStore+Refresh.swift
    var refreshTask: Task<Void, Never>?
    // internal (not private): used by RepositoryStore+Detail.swift
    var detailTask: Task<Void, Never>?
    // internal (not private): used by RepositoryStore+Detail.swift
    var diffTask: Task<Void, Never>?
    /// The most recently scheduled snapshot load; new ones chain behind it. See `refresh()`.
    // internal (not private): used by RepositoryStore+Refresh.swift
    var lastRefresh: Task<Void, Never>?
    /// True while a chained load exists that has not begun reading git yet.
    // internal (not private): used by RepositoryStore+Refresh.swift
    var refreshIsQueued = false

    private static let lastRepositoryPathKey = "lastRepositoryPath"

    init(
        backend: any GitBackend & GitWorkingCopyBackend = CLIGitBackend(),
        gitPath: String = "/usr/bin/git"
    ) {
        self.backend = backend
        self.gitPath = gitPath
    }

    // MARK: - Git availability

    /// The banner text shown while `git` can't be found. Kept in one place so
    /// `checkGitAvailability()` can recognize it as "still showing the git-missing banner"
    /// before clearing it, without duplicating the literal string.
    private static func gitMissingMessage(at gitPath: String) -> String {
        "Git was not found at \(gitPath). Install the Xcode Command Line Tools."
    }

    /// Surfaces a missing `git` as an error banner at launch, before anything tries to run a
    /// command and fails with a less helpful "failed to launch" message per request. Also
    /// re-checkable later: if git was missing and has since become available, this clears the
    /// banner (but only if it's still showing the git-missing message, not some other error).
    func checkGitAvailability() async {
        let available = await CLIGitBackend.isGitAvailable(at: gitPath)
        gitMissing = !available
        let message = Self.gitMissingMessage(at: gitPath)
        if available {
            if lastError == message {
                lastError = nil
                // `open()` made this message sticky; with it gone, nothing is being protected
                // from the next reload any more.
                errorIsSticky = false
            }
        } else {
            lastError = message
        }
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

    func reopenLastRepository() {
        guard let path = UserDefaults.standard.string(forKey: Self.lastRepositoryPathKey) else { return }
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return
        }
        open(URL(fileURLWithPath: path))
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

    /// Narrow setters for state whose `private(set)` is worth keeping even though the code that
    /// updates it lives in another file — see the file's own doc comment for why. Each pairs
    /// with exactly the callers named below; nothing else should call these.

    /// internal (not private(set) write): used by RepositoryStore+Refresh.swift
    func setSnapshot(_ newSnapshot: RepoSnapshot?) {
        snapshot = newSnapshot
    }

    /// internal (not private(set) write): used by RepositoryStore+Refresh.swift
    func setLoading(_ value: Bool) {
        isLoading = value
    }

    /// internal (not private(set) write): used by RepositoryStore+Detail.swift
    func setDetailFiles(_ files: [FileStatus]) {
        detailFiles = files
    }

    /// internal (not private(set) write): used by RepositoryStore+Refresh.swift, +Detail.swift
    /// and +Errors.swift
    func setError(_ message: String?) {
        lastError = message
    }
}
