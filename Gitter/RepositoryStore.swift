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
    var stagedView = false

    let backend: any GitBackend

    private var watcher: RepositoryWatcher?
    private var refreshTask: Task<Void, Never>?
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
            snapshot = newSnapshot
            lastError = nil

            if case .commit(let sha) = selection, !newSnapshot.commits.contains(where: { $0.sha == sha }) {
                selection = .workingCopy
            }
        } catch {
            lastError = Self.describe(error)
        }

        await reloadDetail()
    }

    // MARK: - Selection

    func select(_ newSelection: Selection) {
        selection = newSelection
        diff = []
        Task { await reloadDetail() }
    }

    func selectPath(_ path: String?) {
        selectedPath = path
        Task { await reloadDiff() }
    }

    // MARK: - Detail loading

    private func reloadDetail() async {
        guard let root, let snapshot else {
            detailFiles = []
            diff = []
            return
        }

        switch selection {
        case .workingCopy:
            detailFiles = snapshot.status.files
        case .commit(let sha):
            do {
                detailFiles = try await backend.commitFiles(at: root, sha: sha)
            } catch {
                lastError = Self.describe(error)
                detailFiles = []
            }
        }

        if let selectedPath, !detailFiles.contains(where: { $0.path == selectedPath }) {
            self.selectedPath = nil
        }

        await reloadDiff()
    }

    private func reloadDiff() async {
        guard let root, let selectedPath else {
            diff = []
            return
        }

        do {
            switch selection {
            case .workingCopy:
                diff = try await backend.workingCopyDiff(at: root, path: selectedPath, staged: stagedView)
            case .commit(let sha):
                diff = try await backend.commitDiff(at: root, sha: sha, path: selectedPath)
            }
        } catch {
            lastError = Self.describe(error)
            diff = []
        }
    }

    // MARK: - Errors

    private static func describe(_ error: Error) -> String {
        if let gitError = error as? GitError {
            switch gitError {
            case .commandFailed(_, let stderr):
                return stderr
            case .launchFailed(let path):
                return "Failed to launch: \(path)"
            }
        }
        return error.localizedDescription
    }
}
