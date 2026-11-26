import AppKit
import Foundation
import GitCore

extension RepositoryStore {
    /// Stores share the system pasteboard, so a newer command supersedes an older one even
    /// when it came from a different window and does not have its result yet.
    private static var latestCopyByPasteboard: [NSPasteboard.Name: UUID] = [:]

    /// A path-specific Git diff can report a rename as an addition. The status for the
    /// source of the loaded diff still shows the rename, copy, or type change.
    func diffStatusAllowsClipboardCopy(path: String, staged: Bool) -> Bool {
        let status: FileStatus?
        let kind: ChangeKind?
        switch selection {
        case .workingCopy:
            status = snapshot?.status.files.first { $0.path == path }
            kind = staged ? status?.staged : status?.unstaged
        case .commit, .comparisonChanges:
            status = detailFiles.first { $0.path == path }
            kind = status?.staged
        case .stash, .historyEnd:
            return true
        }
        guard status?.isSubmodule != true else { return false }
        switch kind {
        case .renamed, .copied, .typeChanged, .unmerged: return false
        default: return true
        }
    }

    func canCopyDiff(_ file: FileDiff) -> Bool {
        displayedDiffAllowsClipboardCopy && file.canCopyClipboardPatch
    }

    /// Exports the diff passed by the header's button, including the side and content on screen.
    func copyDiff(_ file: FileDiff, hunkID: Hunk.ID? = nil, to pasteboard: NSPasteboard = .general) {
        guard displayedDiffAllowsClipboardCopy, let text = file.clipboardPatch(hunkID: hunkID) else { return }
        guard Clipboard.copy(text, to: pasteboard) else {
            showStickyError(ClipboardPatchWording.copyFailed)
            return
        }
        showNotice(hunkID == nil ? ClipboardPatchWording.copiedDiff : ClipboardPatchWording.copiedHunk)
    }

    var canCopyAllChanges: Bool { copyAllChangesSource != nil }

    private var copyAllChangesSource: ClipboardDiffSource? {
        guard root != nil, snapshot != nil, activeSheet == nil, resolverFocus == nil,
            !isClosed, !isHidden, !isTerminating
        else { return nil }
        if registry === AppModel.windows, QuitFlow.isUnderWay { return nil }

        switch selection {
        case .workingCopy: return isMutating ? nil : .workingCopy
        case .commit(let sha): return .commit(sha)
        case .stash(let sha): return stashes.first(where: { $0.sha == sha }).map(ClipboardDiffSource.stash)
        case .comparisonChanges:
            guard let comparison, !comparison.mergeBases.isEmpty else { return nil }
            return .comparison(comparison)
        case .historyEnd: return nil
        }
    }

    func requestCopyAllChanges(to pasteboard: NSPasteboard = .general) {
        guard let root, let source = copyAllChangesSource else { return }
        cancelCopyAllChanges()
        let capturedGeneration = generation
        let clipboardChange = pasteboard.changeCount
        let pasteboardName = pasteboard.name
        let request = UUID()
        Self.latestCopyByPasteboard[pasteboardName] = request
        copyAllChangesTask = Task { [weak self, backend] in
            defer {
                if Self.latestCopyByPasteboard[pasteboardName] == request {
                    Self.latestCopyByPasteboard[pasteboardName] = nil
                }
                if !Task.isCancelled { self?.copyAllChangesTask = nil }
            }
            let result: Result<ClipboardDiffExport?, Error>
            do {
                try Task.checkCancellation()
                result = .success(try await backend.copyAllChanges(source, at: root))
            } catch {
                result = .failure(error)
            }
            // Selection changes cancel this task, including a move away and back. The
            // pasteboard count also covers ordinary copy commands and other applications.
            guard let self, !Task.isCancelled, generation == capturedGeneration,
                canCopyAllChanges, Self.latestCopyByPasteboard[pasteboardName] == request,
                pasteboard.changeCount == clipboardChange
            else { return }

            switch result {
            case .success(.some(let patch)):
                if Clipboard.copy(patch.text, to: pasteboard) {
                    clearCopyAllChangesError()
                    showNotice(ClipboardPatchWording.copiedChanges(in: patch.fileCount))
                } else {
                    showCopyAllChangesError(ClipboardPatchWording.copyFailed)
                }
            case .success(nil):
                clearCopyAllChangesError()
                showNotice(ClipboardPatchWording.noChangesToCopy)
            case .failure(let error):
                showCopyAllChangesError(ClipboardPatchWording.copyAllChangesFailure(error))
            }
        }
    }

    func cancelCopyAllChanges() {
        copyAllChangesTask?.cancel()
        copyAllChangesTask = nil
    }

    var pasteDiffBlockedReason: String? {
        if activeSheet != nil { return ClipboardPatchWording.sheetUp }
        return clipboardPatchApplyBlockedReason
    }

    var clipboardPatchApplyBlockedReason: String? {
        guard root != nil, snapshot != nil, !isClosed else { return ClipboardPatchWording.noRepository }
        if let reason = changeRunningBlockedReason { return reason }
        if QuitFlow.isUnderWay, registry === AppModel.windows { return ClipboardPatchWording.quitPending }
        if resolverFocus != nil { return ClipboardPatchWording.resolverOpen }
        if operationInProgress != nil || haltedSequence != nil { return ClipboardPatchWording.operationInProgress }
        if hasUnmergedFiles { return ClipboardPatchWording.unmerged }
        return nil
    }

    func requestPasteDiff(from pasteboard: NSPasteboard = .general) {
        guard pasteDiffBlockedReason == nil else { return }
        guard let text = pasteboard.string(forType: .string) else {
            showStickyError(ClipboardPatchWording.noText)
            return
        }
        mutate(result: { backend, root in
            do {
                let plan = try await backend.planClipboardPatch(text, at: root)
                return (plan, root)
            } catch {
                throw ClipboardPatchWording.failure(error, applying: false)
            }
        }, onSuccess: { [self] result in
            let (plan, destination) = result
            guard activeSheet == nil else {
                showStickyError(ClipboardPatchWording.previewInterrupted)
                return
            }
            activeSheet = .clipboardPatch(ClipboardPatchPreview(plan: plan, destination: destination))
        })
    }

    func cancelClipboardPatch(_ id: ClipboardPatchPreview.ID) {
        guard case .clipboardPatch(let shown) = activeSheet, shown.id == id else { return }
        activeSheet = nil
    }

    func confirmClipboardPatch(_ id: ClipboardPatchPreview.ID) {
        guard case .clipboardPatch(let shown) = activeSheet,
            shown.id == id, shown.destination == root, clipboardPatchApplyBlockedReason == nil
        else { return }
        activeSheet = nil
        mutate({ backend, root in
            do {
                try await backend.applyClipboardPatch(shown.plan, at: root)
            } catch {
                throw ClipboardPatchWording.failure(error, applying: true)
            }
        }, applyingClipboardPatch: true, onSuccess: { [self] in
            showNotice(ClipboardPatchWording.applied)
        })
    }
}
