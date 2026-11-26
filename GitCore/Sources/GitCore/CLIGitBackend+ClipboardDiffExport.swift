import Foundation

extension CLIGitBackend {
    public func copyAllChanges(_ source: ClipboardDiffSource, at root: URL) async throws -> ClipboardDiffExport? {
        let root = root.resolvingSymlinksInPath().standardizedFileURL
        let data: Data
        switch source {
        case .workingCopy:
            data = try await workingCopyClipboardDiff(at: root)
        case .commit(let sha):
            data = try await clipboardTreeDiff([sha], at: root)
        case .stash(let stash):
            data = try await clipboardStashDiff(stash, at: root)
        case .comparison(let comparison):
            guard let base = comparison.mergeBases.first else { throw CompareRefusal.noMergeBase }
            data = try await clipboardTreeDiff([base, comparison.b.id], at: root)
        }
        try Task.checkCancellation()
        guard !data.isEmpty else { return nil }

        let files = DiffParser.parse(data, quotingInvalidPaths: true)
        let unsupported = files.filter { !$0.canCopyClipboardPatch }.flatMap { [$0.oldPath, $0.newPath].compactMap { $0 } }
        if !unsupported.isEmpty { throw ClipboardDiffExportRefusal.unsupported(unsupported) }
        guard let text = String(data: data, encoding: .utf8), !files.isEmpty,
            text.utf8.elementsEqual(files.compactMap { $0.clipboardPatch() }.joined().utf8)
        else { throw ClipboardPatchRefusal.invalidPatch }

        let fileCount = try await validateClipboardExport(text, at: root)
        return ClipboardDiffExport(text: text, fileCount: fileCount)
    }

    private func clipboardTreeDiff(
        _ revisions: [String], at root: URL, environment: [String: String] = ProcessInfo.processInfo.environment
    ) async throws -> Data {
        guard revisions.allSatisfy(Self.isFullObjectID) else { throw ClipboardDiffExportRefusal.sourceChanged }
        // Even a tree diff can consult the checkout's attributes and start a file monitor.
        var pinned = Self.withConfig("core.fsmonitor", "false", over: environment)
        pinned = Self.withConfig("core.quotePath", "true", over: pinned)
        pinned["GIT_NO_LAZY_FETCH"] = "1"
        return try await runWithEnvironment(
            ["diff-tree", "--root", "--diff-merges=first-parent", "--no-commit-id", "-p", "-r", "-M", "-l0",
             "--no-color", "--no-ext-diff", "--no-textconv", "--ignore-submodules=none", "--submodule=short",
             "--src-prefix=a/", "--dst-prefix=b/", "--output-indicator-new=+", "--output-indicator-old=-",
             "--output-indicator-context= ", "--full-index", "-U3", "--end-of-options"] + revisions + ["--"],
            cwd: root, extra: pinned).stdout
    }

    private func clipboardStashDiff(_ stash: Stash, at root: URL) async throws -> Data {
        guard Self.isFullObjectID(stash.sha), let base = stash.parents.first,
            Self.isFullObjectID(base)
        else { throw ClipboardDiffExportRefusal.sourceChanged }
        guard stash.hasUntrackedPart else { return try await clipboardTreeDiff([base, stash.sha], at: root) }
        let untracked = stash.parents[2]
        guard Self.isFullObjectID(untracked) else { throw ClipboardDiffExportRefusal.sourceChanged }
        // A staged deletion followed by an untracked recreation can put the same path in
        // both saved trees. Diff the overlay once, including when it equals the base.
        return try await StashRecord.withClipboardStashTree(
            stash.sha, untracked: untracked, backend: self, at: root
        ) { combined, index in
            try await clipboardTreeDiff([base, combined], at: root, environment: index)
        }
    }
}
