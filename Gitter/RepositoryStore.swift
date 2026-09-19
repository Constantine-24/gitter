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
    private(set) var isMutating = false

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
    private var errorIsSticky = false

    let backend: any GitBackend & GitWorkingCopyBackend
    private let gitPath: String

    private var watcher: RepositoryWatcher?
    private var refreshTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    /// The most recently scheduled snapshot load; new ones chain behind it. See `refresh()`.
    private var lastRefresh: Task<Void, Never>?
    /// True while a chained load exists that has not begun reading git yet.
    private var refreshIsQueued = false

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
            return
        }

        let standardized = url.standardizedFileURL
        let dotGit = standardized.appending(path: ".git")
        guard FileManager.default.fileExists(atPath: dotGit.path) else {
            lastError = "Not a Git repository: \(standardized.path)"
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
        diff = []
        selection = .workingCopy
        selectedPath = nil
        lastError = nil
        errorIsSticky = false
        // A half-written message belongs to the repository it was written for, and a mutation
        // in flight can only be for the old one.
        draft.reset()
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

    // MARK: - Debounced refresh

    private func scheduleRefresh() {
        refreshTask?.cancel()
        refreshTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await self?.refresh()
        }
    }

    // MARK: - Refresh

    /// Loads a fresh snapshot, returning only once a load that *started after this call* has
    /// finished. `mutate` depends on that: a load already in flight may have read git before
    /// the mutation landed, so sharing it could hand back a pre-mutation snapshot.
    ///
    /// Loads never overlap — each is chained behind the previous one. A load that is chained
    /// but has not begun reading git yet is shared by every further caller, which is the
    /// coalescing the file-system watcher needs (many events, one reload). The flip side of
    /// that chaining: nothing reachable from inside a chained load may `await refresh()`, as
    /// it would then be waiting on itself forever.
    func refresh() async {
        guard root != nil else { return }
        await chainedRefresh().value
    }

    private func chainedRefresh() -> Task<Void, Never> {
        if refreshIsQueued, let queued = lastRefresh { return queued }
        let previous = lastRefresh
        refreshIsQueued = true
        let run = Task { @MainActor [weak self] in
            await previous?.value
            guard let self else { return }
            // Reading git starts now, so anything that happens from here on is invisible to
            // this load and later callers have to chain behind it instead of sharing it.
            refreshIsQueued = false
            await loadSnapshot()
        }
        lastRefresh = run
        return run
    }

    private func loadSnapshot() async {
        guard let root else { return }
        let capturedGeneration = generation
        isLoading = true
        defer { isLoading = false }

        do {
            let newSnapshot = try await backend.snapshot(at: root)
            // The repository may have been switched (via `open`) while this snapshot was in
            // flight; a snapshot from before that must never overwrite the new state.
            guard generation == capturedGeneration else { return }
            snapshot = newSnapshot
            // A mutation's own failure outranks the reload it provokes. git writes inside
            // `.git` before it fails — a rejected commit has already written COMMIT_EDITMSG —
            // so the watcher fires and this successful snapshot would otherwise erase the
            // hook's output a fraction of a second after the user saw it.
            if !errorIsSticky {
                lastError = nil
            }

            // Keep a commit selection even when the commit isn't in the loaded window (the
            // log is capped): the row simply isn't highlighted. Only an empty repository has
            // no commit the selection could ever refer to. A changed root is handled by
            // `open()`, which resets the selection itself.
            if newSnapshot.commits.isEmpty {
                selection = .workingCopy
            }
        } catch {
            guard generation == capturedGeneration else { return }
            // A failed load is newer, real information about the repository, so it replaces
            // even a mutation's message — and stops being protected from the next reload.
            lastError = Self.describe(error)
            errorIsSticky = false
        }

        loadDetail()
    }

    // MARK: - Selection

    func select(_ newSelection: Selection) {
        selection = newSelection
        diff = []
        loadDetail()
    }

    func selectPath(_ path: String?) {
        selectedPath = path
        loadDiff()
    }

    // MARK: - Detail loading

    /// Cancels any in-flight detail load and starts a fresh one for the current
    /// `root`/`selection`. Only the most recently started task is allowed to write
    /// `detailFiles`/`selectedPath`/`lastError`: every earlier one is cancelled, and this one
    /// re-checks that `selection` hasn't changed again before it lands.
    private func loadDetail() {
        detailTask?.cancel()

        guard let root, snapshot != nil else {
            detailFiles = []
            loadDiff()
            return
        }

        let capturedSelection = selection
        let capturedGeneration = generation

        detailTask = Task {
            var files: [FileStatus] = []
            var loadError: Error?

            switch capturedSelection {
            case .workingCopy:
                files = self.snapshot?.status.files ?? []
            case .commit(let sha):
                do {
                    files = try await self.backend.commitFiles(at: root, sha: sha)
                } catch {
                    loadError = error
                }
            }

            guard !Task.isCancelled,
                self.generation == capturedGeneration,
                self.selection == capturedSelection
            else { return }

            if let loadError {
                self.errorIsSticky = false
                switch capturedSelection {
                case .commit:
                    // The selected commit no longer exists (e.g. its branch was rebased or
                    // force-pushed away). Fall back to the working copy instead of leaving the
                    // detail pane stuck on a dead selection; the working copy reload never calls
                    // `commitFiles`, so this cannot loop.
                    self.selection = .workingCopy
                    self.lastError = "That commit is no longer in the repository."
                    self.loadDetail()
                    return
                case .workingCopy:
                    // Unreachable today (the working-copy branch above never throws); kept so
                    // this switch stays exhaustive if that ever changes.
                    self.lastError = Self.describe(loadError)
                    self.detailFiles = []
                }
            } else {
                self.detailFiles = files
            }

            if let selectedPath = self.selectedPath, !self.detailFiles.contains(where: { $0.path == selectedPath }) {
                self.selectedPath = nil
            }

            self.loadDiff()
        }
    }

    private func loadDiff() {
        diffTask?.cancel()

        guard let root, let selectedPath else {
            diff = []
            return
        }

        let capturedSelection = selection
        let capturedPath = selectedPath
        let capturedStagedView = stagedView
        let capturedGeneration = generation

        diffTask = Task {
            var result: [FileDiff] = []
            var loadError: Error?

            do {
                switch capturedSelection {
                case .workingCopy:
                    result = try await self.backend.workingCopyDiff(
                        at: root, path: capturedPath, staged: capturedStagedView
                    )
                case .commit(let sha):
                    result = try await self.backend.commitDiff(at: root, sha: sha, path: capturedPath)
                }
            } catch {
                loadError = error
            }

            guard !Task.isCancelled,
                  self.generation == capturedGeneration,
                  self.selection == capturedSelection,
                  self.selectedPath == capturedPath
            else { return }

            if let loadError {
                self.lastError = Self.describe(loadError)
                self.errorIsSticky = false
                self.diff = []
            } else {
                self.diff = result
            }
        }
    }

    // MARK: - Errors

    /// Clears the currently displayed error (the banner's dismiss button).
    func dismissError() {
        lastError = nil
        errorIsSticky = false
    }

    // MARK: - Mutation bookkeeping

    /// Claims the store for one git write, returning the generation to hand back to
    /// `finishMutation`, or nil when it cannot be claimed: no repository, or a mutation is
    /// already running (mutations are serialized, which is also what disables the buttons).
    ///
    /// This pair exists so the setters of `isMutating` and `lastError` can stay private while
    /// the staging API lives in another file, where `private(set)` would not reach.
    func beginMutation() -> Int? {
        guard root != nil, !isMutating else { return nil }
        isMutating = true
        // A new attempt supersedes the last one's message: it has been read or ignored by
        // now, and nothing should keep protecting it from the reloads that follow.
        if errorIsSticky {
            lastError = nil
            errorIsSticky = false
        }
        return generation
    }

    /// Releases the claim `beginMutation()` made, showing `failure` in the banner if there was
    /// one. A stale generation means `open()` has already reset everything this would write.
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

    private static func describe(_ error: Error) -> String {
        if let gitError = error as? GitError {
            switch gitError {
            case .commandFailed(let exitCode, let stderr):
                let trimmed = stderr.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? "git exited with code \(exitCode)" : stderr
            case .launchFailed(let path):
                return "Failed to launch: \(path)"
            case .emptyCommitMessage:
                return "Enter a commit message."
            }
        }
        return error.localizedDescription
    }
}
