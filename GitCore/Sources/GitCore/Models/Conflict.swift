import Foundation

/// What each side did to a conflicted path, read from porcelain v2's `u XY` record (M 1).
///
/// XY alone decides which index stages exist: `UU` 1 2 3 · `AA` 2 3 · `DU` 1 3 · `UD` 1 2 ·
/// `AU` 2 · `UA` 3 · `DD` 1. A rename/delete is `UD` at the new name; a rename/rename is three
/// records, `DD` at the source and `AU`/`UA` at each side's name.
public enum ConflictKind: Sendable, Hashable {
    case bothModified, bothAdded, deletedByUs, deletedByThem, addedByUs, addedByThem, bothDeleted

    /// The porcelain v2 XY field → kind; nil for anything git does not write.
    static func from(xy: Substring) -> ConflictKind? {
        switch xy {
        case "UU": return .bothModified
        case "AA": return .bothAdded
        case "DU": return .deletedByUs
        case "UD": return .deletedByThem
        case "AU": return .addedByUs
        case "UA": return .addedByThem
        case "DD": return .bothDeleted
        default: return nil
        }
    }
}

/// One index stage of a conflicted path: its mode (`100644`, `100755`, `120000`, `160000`) and
/// its full object id.
public struct ConflictStage: Sendable, Hashable {
    public let mode: String
    public let blob: String

    public init(mode: String, blob: String) {
        self.mode = mode
        self.blob = blob
    }
}

/// A path with conflict stages, as the `u` record shows it: stage 1 (`base`), 2 (`ours`) and 3
/// (`theirs`), each nil when the kind has none.
///
/// Binary, symlink and mode conflicts leave no markers in the worktree (M 1), so this record —
/// not the file's text — is what says a path is conflicted.
public struct ConflictedFile: Sendable, Hashable {
    public let path: String
    public let kind: ConflictKind
    public let base: ConflictStage?, ours: ConflictStage?, theirs: ConflictStage?

    public init(
        path: String, kind: ConflictKind, base: ConflictStage?, ours: ConflictStage?,
        theirs: ConflictStage?
    ) {
        self.path = path
        self.kind = kind
        self.base = base
        self.ours = ours
        self.theirs = theirs
    }

    private var stages: [ConflictStage] { [base, ours, theirs].compactMap { $0 } }

    /// Any stage is a gitlink (`160000`).
    public var isSubmodule: Bool { stages.contains { $0.mode == "160000" } }

    /// Any stage is a symlink (`120000`).
    public var isSymlink: Bool { stages.contains { $0.mode == "120000" } }

    /// Both sides added the same bytes with different modes: not its own XY, only `AA` with
    /// equal ids and unequal modes (M 1). Comparing ids alone would call the sides identical.
    public var isModeOnly: Bool {
        guard kind == .bothAdded, let ours, let theirs else { return false }
        return ours.blob == theirs.blob && ours.mode != theirs.mode
    }
}

/// A side of a conflict: stage 2 or stage 3. In a rebase stage 2 is the upstream and stage 3
/// the user's own commit (M 6), so the words shown for each are the app's business.
public enum ConflictSide: Sendable, Hashable { case ours, theirs }

/// What the user chose for one block.
public enum BlockChoice: Sendable, Hashable { case ours, theirs, oursThenTheirs, theirsThenOurs }

/// One conflict block, in the worktree form of the parse rebuild: every byte as `cat-file
/// --filters` gave it, line endings included. `base` is nil only when the text had no base
/// section; an empty base section (an add/add) is empty data.
public struct ConflictBlock: Sendable, Hashable {
    public let ours: Data
    public let base: Data?
    public let theirs: Data

    public init(ours: Data, base: Data?, theirs: Data) {
        self.ours = ours
        self.base = base
        self.theirs = theirs
    }
}

extension ConflictBlock {
    /// The bytes `choice` puts in place of this block: one side's, or both in the order named.
    /// Pure; the one composition both `GitConflictBackend.resolve` and the app's preview use.
    public func composed(_ choice: BlockChoice) -> Data {
        switch choice {
        case .ours: ours
        case .theirs: theirs
        case .oursThenTheirs: ours + theirs
        case .theirsThenOurs: theirs + ours
        }
    }
}

/// A stretch of a conflicted file: text both sides agree on, or a block.
public enum ConflictSegment: Sendable, Hashable {
    case common(Data)
    case block(ConflictBlock)

    /// The file `choices` compose to — common text as it is, each block replaced by its choice —
    /// or nil unless there is exactly one choice per block. `resolve` writes exactly this, except
    /// in a block that ends the file, where it also drops the line terminator merge-file gave a
    /// side whose stage has none (Ruling 9): that needs the stage itself, which this does not read.
    public static func composed(_ segments: [ConflictSegment], choices: [BlockChoice]) -> Data? {
        let blocks = segments.count { if case .block = $0 { true } else { false } }
        guard choices.count == blocks else { return nil }
        var bytes = Data()
        var next = choices.makeIterator()
        for segment in segments {
            switch segment {
            case .common(let text): bytes.append(text)
            case .block(let block): bytes.append(block.composed(next.next()!))
            }
        }
        return bytes
    }
}

/// What the UI showed, carried into every write so it can refuse when the repository moved.
public struct ConflictSnapshot: Sendable, Hashable {
    /// The stages as the UI saw them.
    public let file: ConflictedFile
    /// SHA-256 of the worktree bytes (lowercase hex); nil when there is no file at the path.
    public let worktreeHash: String?

    public init(file: ConflictedFile, worktreeHash: String?) {
        self.file = file
        self.worktreeHash = worktreeHash
    }
}

/// How a conflicted path can be shown.
public enum ConflictPresentation: Sendable, Hashable {
    /// UU / AA with text on both sides.
    case blocks([ConflictSegment])
    /// Offered as a whole file only (M 33).
    case wholeFile(reason: WholeFileReason)
    /// A gitlink conflict: shown and explained, not resolved here.
    case submodule
}

/// Why a path is whole-file only.
public enum WholeFileReason: Sendable, Hashable {
    /// `merge-file` refused the stages: a NUL in the first 8 000 bytes (M 33).
    case binary
    /// A side is a symlink.
    case symlink
    /// Both sides added the same bytes with different modes.
    case modeOnly
    /// A side deleted the path (`DU`, `UD`, `DD`).
    case deletion
    /// Only one side has the path (`AU`, `UA`).
    case oneSided
    /// `check-attr merge` names something other than the text driver — `binary`, `unset`
    /// (`-merge`, the `binary` macro) or a driver of the user's — and git did not draw blocks
    /// `merge-file` would draw (M 33, M 3).
    case mergeAttribute(String)
    /// The parse rebuild could not be split into blocks (a filter that rewrote the marker lines).
    case unparsable
}

/// A conflicted path read for the resolver.
public struct ConflictDocument: Sendable, Hashable {
    public let snapshot: ConflictSnapshot
    public let presentation: ConflictPresentation
    /// false = the worktree is not what git wrote ("changed since the conflict"): it equals
    /// neither `AUTO_MERGE`'s entry (during an operation) nor the compare rebuild (text) nor
    /// the stage git leaves (whole file), label text removed from marker lines (M 26). See
    /// `GitConflictBackend.conflictDocument`.
    public let matchesGitsConflict: Bool
    /// The current worktree bytes (for the "changed since" view and previews).
    public let worktree: Data?

    public init(
        snapshot: ConflictSnapshot, presentation: ConflictPresentation, matchesGitsConflict: Bool,
        worktree: Data?
    ) {
        self.snapshot = snapshot
        self.presentation = presentation
        self.matchesGitsConflict = matchesGitsConflict
        self.worktree = worktree
    }
}
