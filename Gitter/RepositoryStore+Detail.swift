import Foundation
import GitCore

/// Loading the detail pane: the file list for the current selection (a stash entry's is its
/// `stashContents`), and the diff for the currently selected path within it.
extension RepositoryStore {

    // MARK: - Detail loading

    /// Cancels any in-flight detail load and starts a fresh one for the current
    /// `root`/`selection`. Only the most recently started task is allowed to write
    /// `detailFiles`/`selectedPath`/`lastError`: every earlier one is cancelled, and this one
    /// re-checks that `selection` hasn't changed again before it lands.
    // internal (not private): used by RepositoryStore.swift's `select()` and by
    // RepositoryStore+Refresh.swift's `loadSnapshot()`
    func loadDetail() {
        detailTask?.cancel()

        guard let root, snapshot != nil else {
            setDetailFiles([])
            loadDiff()
            return
        }

        let capturedSelection = selection
        let capturedGeneration = generation

        detailTask = Task {
            var files: [FileStatus] = []
            var contents: StashContents?
            var stashGone = false
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
            case .stash(let sha):
                // By sha, from the snapshot just loaded: its position is whatever the list says now.
                if let stash = self.stashes.first(where: { $0.sha == sha }) {
                    do {
                        contents = try await self.backend.stashContents(stash, at: root)
                    } catch {
                        loadError = error
                    }
                } else {
                    stashGone = true
                }
            }

            guard !Task.isCancelled,
                self.generation == capturedGeneration,
                self.selection == capturedSelection
            else { return }

            if stashGone {
                // Popped or dropped — here or in a terminal. The pop's or drop's own notice says
                // what happened; the pane goes back to the working copy, where a pop's changes are.
                self.selection = .workingCopy
                self.setStashContents(nil)
                self.loadDetail()
                return
            }

            if let loadError {
                self.clearSticky()
                switch capturedSelection {
                case .commit:
                    // The selected commit no longer exists (e.g. its branch was rebased or
                    // force-pushed away). Fall back to the working copy instead of leaving the
                    // detail pane stuck on a dead selection; the working copy reload never calls
                    // `commitFiles`, so this cannot loop.
                    self.selection = .workingCopy
                    self.setError("That commit is no longer in the repository.")
                    self.loadDetail()
                    return
                case .stash:
                    // The entry is listed but could not be read: say why, and leave the pane.
                    self.selection = .workingCopy
                    self.setStashContents(nil)
                    self.setError(Self.describe(loadError))
                    self.loadDetail()
                    return
                case .workingCopy:
                    // Unreachable today (the working-copy branch above never throws); kept so
                    // this switch stays exhaustive if that ever changes.
                    self.setError(Self.describe(loadError))
                    self.setDetailFiles([])
                }
            } else {
                self.setDetailFiles(files)
                if case .stash = capturedSelection { self.setStashContents(contents) }
            }

            let paths: Set<String> =
                if case .stash = capturedSelection {
                    Set((self.stashContents?.all ?? []).map(\.displayPath))
                } else {
                    Set(self.detailFiles.map(\.path))
                }
            if let selectedPath = self.selectedPath, !paths.contains(selectedPath) {
                self.selectedPath = nil
            }

            self.loadDiff()
        }
    }

    // internal (not private): used by RepositoryStore.swift's `stagedView` didSet and
    // `selectPath()`
    func loadDiff() {
        diffTask?.cancel()

        guard let root, let selectedPath else {
            setDiff([], staged: stagedView)
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
                case .stash:
                    // Already read with the entry's files: both parts, so a path in each shows
                    // both. Read-only — `canPartiallyStage` is false off the working copy.
                    result = (self.stashContents?.all ?? []).filter { $0.displayPath == capturedPath }
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
                self.setError(Self.describe(loadError))
                self.clearSticky()
                self.setDiff([], staged: capturedStagedView)
            } else {
                self.setDiff(result, staged: capturedStagedView)
            }
        }
    }
}
