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

    let backend: any GitBackend
    private let gitPath: String

    private var watcher: RepositoryWatcher?
    private var refreshTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var isRefreshing = false
    private var needsAnotherRefresh = false

    private static let lastRepositoryPathKey = "lastRepositoryPath"

    init(backend: any GitBackend = CLIGitBackend(), gitPath: String = "/usr/bin/git") {
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
        isRefreshing = false
        needsAnotherRefresh = false

        // Reset all repository-derived state so nothing from the previous repository lingers
        // on screen (or gets raced against) while the new repository's first snapshot loads.
        snapshot = nil
        detailFiles = []
        diff = []
        selection = .workingCopy
        selectedPath = nil
        lastError = nil

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

    func refresh() async {
        guard let root else { return }

        if isRefreshing {
            needsAnotherRefresh = true
            return
        }
        isRefreshing = true
        isLoading = true
        defer {
            isLoading = false
            isRefreshing = false
            if needsAnotherRefresh {
                needsAnotherRefresh = false
                Task { await self.refresh() }
            }
        }

        do {
            let newSnapshot = try await backend.snapshot(at: root)
            // The repository may have been switched (via `open`) while this snapshot was in
            // flight; a snapshot for the old root must never overwrite state for the new one.
            guard self.root == root else { return }
            snapshot = newSnapshot
            lastError = nil

            // Keep a commit selection even when the commit isn't in the loaded window (the
            // log is capped): the row simply isn't highlighted. Only an empty repository has
            // no commit the selection could ever refer to. A changed root is handled by
            // `open()`, which resets the selection itself.
            if newSnapshot.commits.isEmpty {
                selection = .workingCopy
            }
        } catch {
            guard self.root == root else { return }
            lastError = Self.describe(error)
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

            guard !Task.isCancelled, self.selection == capturedSelection else { return }

            if let loadError {
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
                  self.selection == capturedSelection,
                  self.selectedPath == capturedPath
            else { return }

            if let loadError {
                self.lastError = Self.describe(loadError)
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
