import Foundation

/// Moves an untracked item somewhere the user can get it back from, and puts it back.
///
/// Gitter never deletes an untracked file: git has no copy of one, so the Trash is the copy.
/// The URL `trash` returns must be kept — the Trash renames an item whose name is taken
/// (`reg.txt 15-18-28-335.txt`, M 15), so the original name cannot find it again.
public protocol Trasher: Sendable {
    /// Moves the item at `url` — a file, a symlink (the link, not its target) or a whole
    /// directory — out of the worktree, and returns where it went.
    func trash(_ url: URL) throws -> URL
    /// Moves `trashed` back to `original`. Never overwrites: fails if `original` exists again.
    func restore(_ trashed: URL, to original: URL) throws
}

/// The user's Trash, through `FileManager.trashItem` (M 15).
public struct FileManagerTrasher: Trasher {
    public init() {}

    public func trash(_ url: URL) throws -> URL {
        var resulting: NSURL?
        try FileManager.default.trashItem(at: url, resultingItemURL: &resulting)
        // `trashItem` succeeded, so the item is in the Trash; without its URL it cannot be put
        // back by Gitter, which the caller must hear rather than a guess at the name.
        guard let trashed = resulting as URL? else {
            throw CocoaError(.fileNoSuchFile, userInfo: [
                NSLocalizedDescriptionKey:
                    "\(url.lastPathComponent) was moved to the Trash, but the Trash did not say where.",
            ])
        }
        return trashed
    }

    /// `moveItem` never replaces an existing item: onto a path that exists again it fails with
    /// Cocoa error 516 (`NSFileWriteFileExistsError`) and moves nothing (M 15). A parent
    /// directory that is gone is made again first, which overwrites nothing.
    public func restore(_ trashed: URL, to original: URL) throws {
        try FileManager.default.createDirectory(
            at: original.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: trashed, to: original)
    }
}
