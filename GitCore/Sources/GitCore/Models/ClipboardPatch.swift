import Foundation

/// A file that the clipboard patch will add, modify or delete in the working tree.
public struct ClipboardPatchFile: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        case added, modified, deleted
    }

    public let path: String
    public let kind: Kind
    public let additions: Int
    public let deletions: Int
}

/// The patch shown for confirmation, bound to a worktree and its clean preimages.
public struct ClipboardPatchPlan: Sendable, Hashable {
    public let text: String
    public let files: [ClipboardPatchFile]
    public let headLabel: String

    let root: Directory
    let gitDirectory: Directory
    let gitCommonDirectory: Directory
    let head: String
    let symbolicHead: Data
    let preimages: [Preimage?]

    struct Directory: Sendable, Hashable {
        let url: URL
        let device: Int32
        let inode: UInt64
    }

    struct Preimage: Sendable, Hashable {
        let object: String
        let permissions: UInt16
    }
}

public enum ClipboardPatchRefusal: Error, Sendable, Hashable {
    case invalidPatch
    case unsafePath(String)
    case affectedPathChanged(String)
    case checkoutConversion(String)
    case unsupportedFileMetadata(String)
    case operationInProgress
    case changedSinceShown
}
