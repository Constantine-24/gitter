import Foundation

/// Two branches compared (milestone B3): each tip read to an object id **once**, and every
/// count, list and merge base taken from those ids, so a branch that moves while the
/// comparison is read cannot mix two states into one answer (R11, R12). Keep it, and ask for
/// the changes with it: `GitCompareBackend.comparisonFiles` and `comparisonDiff` read from
/// `mergeBases.first` and `b.id`, never from the names.
public struct Comparison: Sendable, Hashable {
    /// The first branch and the second, each a full `refs/heads/…` or `refs/remotes/…` name
    /// with the commit id it held when it was read (`^{commit}`-peeled).
    public let a: RefTip, b: RefTip
    /// How many commits are reachable from one tip and not the other —
    /// `rev-list --count --left-right <a>...<b>`, exact however many there are (R1, R4).
    public let onlyA: Int, onlyB: Int
    /// Those commits, newest first as `git log` orders them, at most `listLimit` each. A merge
    /// is listed on the side it was made on, together with the commits it brought (R3).
    public let commitsOnlyA: [Commit], commitsOnlyB: [Commit]
    /// Every merge base of the two ids, as `merge-base --all` prints them: empty when the
    /// branches share no history (R7), more than one after criss-cross merges (R8), when the
    /// changes are read against the first — the one `git diff A...B` uses too.
    public let mergeBases: [String]

    /// The most commits listed on each side. The counts are not capped.
    public static let listLimit = 500

    public init(
        a: RefTip, b: RefTip, onlyA: Int, onlyB: Int, commitsOnlyA: [Commit], commitsOnlyB: [Commit],
        mergeBases: [String]
    ) {
        self.a = a
        self.b = b
        self.onlyA = onlyA
        self.onlyB = onlyB
        self.commitsOnlyA = commitsOnlyA
        self.commitsOnlyB = commitsOnlyB
        self.mergeBases = mergeBases
    }
}

/// Why a comparison was not read. Every case is decided before git is asked anything that could
/// mislead, and names the ref it is about.
public enum CompareRefusal: Error, Sendable, Hashable {
    /// Not a full `refs/heads/<name>` or `refs/remotes/<name>` ref — a short name (which a tag
    /// or another branch can shadow, R10), a tag, `HEAD`, or revision syntax (`~`, `^`, `..`,
    /// `:`, `@{`). Refused before git runs.
    case notABranch(String)
    /// No such ref: `rev-parse --verify --quiet` exited 1 (R11).
    case missing(String)
    /// The same ref on both sides. Refused before git runs.
    case sameRef
    /// The changes were asked of a comparison whose branches share no history (R7). Refused
    /// before git runs.
    case noMergeBase
}
