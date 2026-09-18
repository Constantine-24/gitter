import Foundation

public enum FileDiffKind: Sendable, Hashable { case modified, added, deleted, renamed, copied }
public enum DiffLineKind: Sendable, Hashable { case context, added, removed, noNewline }

public struct DiffLine: Sendable, Hashable, Identifiable {
    public let id: Int                   // index within the whole FileDiff, assigned by the parser
    public let kind: DiffLineKind
    public let oldNumber: Int?
    public let newNumber: Int?
    public let text: String              // without the leading +/-/space

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

    public var displayPath: String { newPath ?? oldPath ?? "" }
    public var id: String { (oldPath ?? "") + "→" + (newPath ?? "") }

    public init(oldPath: String?, newPath: String?, kind: FileDiffKind, isBinary: Bool, hunks: [Hunk]) {
        self.oldPath = oldPath
        self.newPath = newPath
        self.kind = kind
        self.isBinary = isBinary
        self.hunks = hunks
    }
}
