import Foundation

public enum ChangeKind: Sendable, Hashable {
    case modified, added, deleted, renamed, copied, typeChanged, unmerged, untracked, ignored
    case unknown(Character)

    /// Maps a porcelain XY character. '.' returns nil.
    public static func from(porcelain c: Character) -> ChangeKind? {
        // M->modified, A->added, D->deleted, R->renamed, C->copied, T->typeChanged, U->unmerged, '?'->untracked, '!'->ignored, '.'->nil, else unknown(c)
        switch c {
        case "M":
            return .modified
        case "A":
            return .added
        case "D":
            return .deleted
        case "R":
            return .renamed
        case "C":
            return .copied
        case "T":
            return .typeChanged
        case "U":
            return .unmerged
        case "?":
            return .untracked
        case "!":
            return .ignored
        case ".":
            return nil
        default:
            return .unknown(c)
        }
    }
}

public struct FileStatus: Sendable, Hashable, Identifiable {
    public let path: String
    public let originalPath: String?     // for renames/copies
    public let staged: ChangeKind?       // index side (X). nil when unchanged.
    public let unstaged: ChangeKind?     // worktree side (Y). nil when unchanged.

    public var id: String { path }
    public var isUntracked: Bool { unstaged == .untracked }

    public init(path: String, originalPath: String?, staged: ChangeKind?, unstaged: ChangeKind?) {
        self.path = path
        self.originalPath = originalPath
        self.staged = staged
        self.unstaged = unstaged
    }
}

public struct WorkingCopyStatus: Sendable, Hashable {
    public let headSha: String?          // nil in an empty repo ("(initial)")
    public let branch: String?           // nil when detached ("(detached)")
    public let upstream: String?
    public let ahead: Int
    public let behind: Int
    public let files: [FileStatus]

    public init(headSha: String?, branch: String?, upstream: String?, ahead: Int, behind: Int, files: [FileStatus]) {
        self.headSha = headSha
        self.branch = branch
        self.upstream = upstream
        self.ahead = ahead
        self.behind = behind
        self.files = files
    }

    public static let empty = WorkingCopyStatus(headSha: nil, branch: nil, upstream: nil, ahead: 0, behind: 0, files: [])
}
