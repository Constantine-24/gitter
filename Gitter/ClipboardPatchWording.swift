import Foundation
import GitCore

enum ClipboardPatchWording {
    static let copyDiff = "Copy Diff"
    static let copyHunk = "Copy Hunk"
    static let pasteDiff = "Paste Diff…"
    static let sheetTitle = "Paste Diff"
    static let applyPatch = "Apply Patch"
    static let cancel = "Cancel"
    static let repository = "Repository"
    static let branch = "Branch"
    static let files = "Files"
    static let patch = "Patch"
    static let explanation = "The patch will be applied to the working tree as unstaged changes."

    static let copiedDiff = "Copied diff to the clipboard."
    static let copiedHunk = "Copied hunk to the clipboard."
    static let applied = "Applied patch to the working tree."
    static let copyFailed = "Could not write the diff to the clipboard."
    static let noText = "The clipboard does not contain plain text."
    static let invalid = "The clipboard does not contain a supported Git diff."
    static let destinationChanged = "The destination changed since the preview opened. Choose Paste Diff… to check it again."
    static let operationInProgress = "Finish the Git operation in progress before pasting a diff."
    static let unmerged = "Resolve the unmerged files before pasting a diff."
    static let resolverOpen = "Close Resolve Conflicts before pasting a diff."
    static let noRepository = "Open a repository before pasting a diff."
    static let sheetUp = "Close the open sheet before pasting a diff."

    static func displayPath(_ path: String) -> String {
        RemoteWording.stripped(LogLine.escape(path))
    }

    static func fileAction(_ file: ClipboardPatchFile) -> String {
        switch file.kind {
        case .added: "Add"
        case .modified: "Modify"
        case .deleted: "Delete"
        }
    }

    @MainActor static func failure(_ error: Error, applying: Bool) -> Failure {
        if let refusal = error as? ClipboardPatchRefusal {
            switch refusal {
            case .invalidPatch: return Failure(message: invalid)
            case .unsafePath(let path):
                return Failure(message: "The patch names an unsupported path “\(displayPath(path))”.")
            case .affectedPathChanged(let path):
                return Failure(message: "The destination has changes in “\(displayPath(path))”.")
            case .checkoutConversion(let path):
                return Failure(message: "Git checkout settings affect “\(displayPath(path))”.")
            case .operationInProgress: return Failure(message: operationInProgress)
            case .changedSinceShown: return Failure(message: destinationChanged)
            }
        }
        let title = applying ? "Could not apply the patch." : "Could not check the patch."
        let description = RepositoryStore.describe(error)
        let detail = description.split(whereSeparator: \.isNewline).map { RemoteWording.plain(String($0)) }
            .first { !$0.isEmpty }
        return Failure(message: detail.map { "\(title) \($0)" } ?? title)
    }

    struct Failure: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }
}
