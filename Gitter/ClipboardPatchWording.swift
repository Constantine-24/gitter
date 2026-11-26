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
    static let previewInterrupted = "Close the open sheet and choose Paste Diff… again."
    static let openWhileApplying = "Wait for the clipboard patch to finish applying before replacing this repository."
    static let quitWhileApplying = "Wait for the clipboard patch to finish applying before quitting Gitter."
    static let quitPending = "Wait for the quit request to finish before pasting a diff."

    static func displayName(_ name: String) -> String {
        LogLine.escape(name).unicodeScalars.map { scalar in
            let properties = scalar.properties
            let needsEscape = switch properties.generalCategory {
            case .format, .nonspacingMark, .enclosingMark: true
            default: properties.isDefaultIgnorableCodePoint
            }
            return needsEscape ? "\\u{\(String(scalar.value, radix: 16, uppercase: true))}" : String(scalar)
        }.joined()
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
                return Failure(message: "The patch names an unsupported path “\(displayName(path))”.")
            case .affectedPathChanged(let path):
                return Failure(message:
                    "The destination path “\(displayName(path))” is missing, changed, or already occupied. "
                        + "Choose Paste Diff… to check it again.")
            case .unsupportedFileMetadata(let path):
                return Failure(message: "Applying the patch would change the permissions or filesystem metadata of “\(displayName(path))”.")
            case .checkoutConversion(let path):
                return Failure(message: "Git checkout settings affect “\(displayName(path))”.")
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
