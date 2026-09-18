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

    private var watcher: RepositoryWatcher?
    private var refreshTask: Task<Void, Never>?
    private var detailTask: Task<Void, Never>?
    private var diffTask: Task<Void, Never>?
    private var isRefreshing = false
    private var needsAnotherRefresh = false

    private static let lastRepositoryPathKey = "lastRepositoryPath"

    init(backend: any GitBackend = CLIGitBackend()) {
        self.backend = backend
    }

    // MARK: - Opening

    func open(_ url: URL) {
        let standardized = url.standardizedFileURL
        let gitPath = standardized.appending(path: ".git")
        guard FileManager.default.fileExists(atPath: gitPath.path) else {
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

            if case .commit(let sha) = selection, !newSnapshot.commits.contains(where: { $0.sha == sha }) {
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
                self.lastError = Self.describe(loadError)
                self.detailFiles = []
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
            }
        }
        return error.localizedDescription
    }
}
