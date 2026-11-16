import Foundation
import GitCore
import GitterSyntax

/// The diff's syntax colours (syntax colours Task 3): read after the diff is on screen, never
/// before it, and published only while that same diff is still the one shown.
extension RepositoryStore {

    /// Reads the sources of `diffs` (just set by `loadDiff`), colours them off the main actor and
    /// publishes `diffSyntax`. The blob sides are read through the backend, the worktree side
    /// from disk; both with `SyntaxHighlighter.maxBytes` as the limit. A failed read leaves that
    /// side plain, with no banner. The result is dropped when the task was cancelled (`setDiff`
    /// cancels it with every new diff, `open()` and `close()` too) or when the generation,
    /// selection, path, side or comparison it was read for changed meanwhile, as `loadDiff`'s is.
    // internal (not private): used by +Detail.swift's `loadDiff()`
    func loadDiffSyntax(
        for diffs: [FileDiff], root: URL, selection: Selection, path: String, staged: Bool,
        generation: Int, comparison: Comparison?
    ) {
        diffSyntaxTask?.cancel()
        let jobs = diffs.compactMap { diff -> (diff: FileDiff, old: DiffSyntax.Source, new: DiffSyntax.Source)? in
            let sides = DiffSyntax.sourceSides(for: diff, selection: selection, staged: staged)
            return sides == (.none, .none) ? nil : (diff, sides.old, sides.new)
        }
        guard !jobs.isEmpty else {
            diffSyntaxTask = nil
            return
        }
        let backend = backend

        diffSyntaxTask = Task {
            var colours: [FileDiff.ID: [DiffLine.ID: [SyntaxToken]]] = [:]
            for job in jobs {
                // Off the main actor, as every backend call is.
                let oldBlob = await Self.blobBytes(job.old, backend: backend, root: root)
                let newBlob = await Self.blobBytes(job.new, backend: backend, root: root)
                guard !Task.isCancelled else { return }
                let lines = await Task.detached(priority: .userInitiated) {
                    let new: Data? =
                        if case .worktree(let path) = job.new {
                            DiffSyntax.worktreeBytes(
                                at: root.appending(path: path), limit: SyntaxHighlighter.maxBytes)
                        } else {
                            newBlob
                        }
                    return DiffSyntax.colours(for: job.diff, old: oldBlob, new: new)
                }.value
                if !lines.isEmpty { colours[job.diff.id] = lines }
            }

            guard !Task.isCancelled,
                self.generation == generation,
                self.selection == selection,
                self.selectedPath == path,
                self.diffIsStaged == staged,
                self.comparison == comparison || selection != .comparisonChanges
            else { return }
            self.setDiffSyntax(colours)
        }
    }

    /// A blob side's bytes, or nil: another kind of side, over the limit, or a read that failed.
    private static func blobBytes(_ source: DiffSyntax.Source, backend: Backend, root: URL) async -> Data? {
        guard case .blob(let id) = source else { return nil }
        return try? await backend.blobBytes(id, at: root, limit: SyntaxHighlighter.maxBytes)
    }
}
