import Foundation

public enum FileDiffKind: Sendable, Hashable { case modified, added, deleted, renamed, copied }
public enum DiffLineKind: Sendable, Hashable { case context, added, removed, noNewline }

public struct DiffLine: Sendable, Hashable, Identifiable {
    public let id: Int                   // index within the whole FileDiff, assigned by the parser
    public let kind: DiffLineKind
    public let oldNumber: Int?
    public let newNumber: Int?
    /// Without the leading +/-/space, and otherwise byte for byte: a CRLF line keeps its `\r`,
    /// because `PatchBuilder` builds patches from this text and must give every byte back.
    public let text: String

    /// `text` as the diff view shows it: one trailing `\r` (a CRLF line ending) dropped, for
    /// display only.
    public var displayText: String {
        guard text.unicodeScalars.last == "\r" else { return text }
        return String(text.unicodeScalars.dropLast())
    }

    public init(id: Int, kind: DiffLineKind, oldNumber: Int?, newNumber: Int?, text: String) {
        self.id = id
        self.kind = kind
        self.oldNumber = oldNumber
        self.newNumber = newNumber
        self.text = text
    }
}

public struct Hunk: Sendable, Hashable, Identifiable {
    public let header: String            // full "@@ -a,b +c,d @@ ctx" line
    public let oldStart: Int, oldCount: Int, newStart: Int, newCount: Int
    public let lines: [DiffLine]

    public var id: String { header }

    public init(header: String, oldStart: Int, oldCount: Int, newStart: Int, newCount: Int, lines: [DiffLine]) {
        self.header = header
        self.oldStart = oldStart
        self.oldCount = oldCount
        self.newStart = newStart
        self.newCount = newCount
        self.lines = lines
    }
}

public struct FileDiff: Sendable, Hashable, Identifiable {
    public let oldPath: String?          // nil for added
    public let newPath: String?          // nil for deleted
    public let kind: FileDiffKind
    public let isBinary: Bool
    public let hunks: [Hunk]
    /// The object ids on the diff's `index <old>..<new>` line: full with `--full-index`,
    /// all zeros for a side that does not exist (a new or deleted file), nil when the diff had
    /// no such line (a pure rename, a mode-only change). For a working-copy diff the index
    /// side is what `applyToIndex` checks the index against before it applies a patch — see
    /// `Patch.oldBlob`.
    public let oldBlob: String?
    public let newBlob: String?
    /// Whether every byte of this file's part of the diff was valid UTF-8. `DiffLine.text` is a
    /// `String`, so a byte that is not (a Latin-1 `é`) arrives as U+FFFD, and a patch built from
    /// it would write `EF BF BD` back. `PatchBuilder` builds no patch for such a diff; the file
    /// can still be staged, unstaged or discarded whole, which git does from the bytes.
    public let isValidUTF8: Bool

    // The original Git section, retained by DiffParser for eligible UTF-8 text changes.
    var clipboardPatchText: String? = nil

    /// Whether the loaded file diff can be copied as a unified patch.
    public var canCopyClipboardPatch: Bool { clipboardPatchText != nil }

    /// The loaded file patch, or a forward patch for one hunk against the original file.
    public func clipboardPatch(hunkID: Hunk.ID? = nil) -> String? {
        guard let clipboardPatchText else { return nil }
        guard let hunkID else { return clipboardPatchText }

        switch kind {
        case .modified:
            return PatchBuilder.patch(
                file: self, hunkIDs: [hunkID], lineIDs: nil, direction: .stage)?.text
        case .added, .deleted:
            // Keep Git's mode and /dev/null headers so the hunk creates or removes the file.
            return hunks.count == 1 && hunks[0].id == hunkID ? clipboardPatchText : nil
        case .renamed, .copied:
            return nil
        }
    }

    public var displayPath: String { newPath ?? oldPath ?? "" }
    public var id: String { (oldPath ?? "") + "→" + (newPath ?? "") }

    // Comparing snapshots for discard and syntax uses the parsed change. Git can vary the
    // original section's spelling, such as omitting the space marker on a blank context line.
    public static func == (lhs: FileDiff, rhs: FileDiff) -> Bool {
        lhs.oldPath == rhs.oldPath && lhs.newPath == rhs.newPath
            && lhs.kind == rhs.kind && lhs.isBinary == rhs.isBinary && lhs.hunks == rhs.hunks
            && lhs.oldBlob == rhs.oldBlob && lhs.newBlob == rhs.newBlob
            && lhs.isValidUTF8 == rhs.isValidUTF8
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(oldPath)
        hasher.combine(newPath)
        hasher.combine(kind)
        hasher.combine(isBinary)
        hasher.combine(hunks)
        hasher.combine(oldBlob)
        hasher.combine(newBlob)
        hasher.combine(isValidUTF8)
    }

    public init(
        oldPath: String?, newPath: String?, kind: FileDiffKind, isBinary: Bool, hunks: [Hunk],
        oldBlob: String? = nil, newBlob: String? = nil, isValidUTF8: Bool = true
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.kind = kind
        self.isBinary = isBinary
        self.hunks = hunks
        self.oldBlob = oldBlob
        self.newBlob = newBlob
        self.isValidUTF8 = isValidUTF8
    }
}
