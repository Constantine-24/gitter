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

    public var displayPath: String { newPath ?? oldPath ?? "" }
    public var id: String { (oldPath ?? "") + "→" + (newPath ?? "") }

    public init(
        oldPath: String?, newPath: String?, kind: FileDiffKind, isBinary: Bool, hunks: [Hunk],
        oldBlob: String? = nil, newBlob: String? = nil
    ) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.kind = kind
        self.isBinary = isBinary
        self.hunks = hunks
        self.oldBlob = oldBlob
        self.newBlob = newBlob
    }
}
