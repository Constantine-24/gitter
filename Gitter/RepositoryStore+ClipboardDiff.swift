import AppKit
import Foundation
import GitCore

extension RepositoryStore {
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
        guard canCopyDiff(file), let text = file.clipboardPatch(hunkID: hunkID) else { return }
        guard Clipboard.copy(text, to: pasteboard) else {
            showStickyError(ClipboardPatchWording.copyFailed)
            return
        }
        showNotice(hunkID == nil ? ClipboardPatchWording.copiedDiff : ClipboardPatchWording.copiedHunk)
    }

    var pasteDiffBlockedReason: String? {
        if activeSheet != nil { return ClipboardPatchWording.sheetUp }
        return clipboardPatchApplyBlockedReason
    }

    var clipboardPatchApplyBlockedReason: String? {
        guard root != nil, snapshot != nil, !isClosed else { return ClipboardPatchWording.noRepository }
        if let reason = changeRunningBlockedReason { return reason }
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
            if activeSheet == nil { activeSheet = .clipboardPatch(plan, destination: destination) }
        })
    }

    func confirmClipboardPatch(_ plan: ClipboardPatchPlan) {
        guard case .clipboardPatch(let shown, let destination) = activeSheet,
            shown == plan, destination == root, clipboardPatchApplyBlockedReason == nil
        else { return }
        activeSheet = nil
        mutate({ backend, root in
            do {
                try await backend.applyClipboardPatch(plan, at: root)
            } catch {
                throw ClipboardPatchWording.failure(error, applying: true)
            }
        }, onSuccess: { [self] in
            showNotice(ClipboardPatchWording.applied)
        })
    }
}
