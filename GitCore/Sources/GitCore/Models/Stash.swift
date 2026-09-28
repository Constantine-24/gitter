import Foundation

/// Whose entry a stash is: one the user made, or the record Gitter filed before a discard.
public enum StashKind: Sendable, Hashable {
    case user, discarded
}

/// One entry of `git stash list`.
///
/// An entry is identified by its `sha`. Its `index` is only a position (`stash@{index}`), and
/// positions shift whenever an entry above it is dropped — by Gitter, by a terminal, or by
/// another linked worktree, which shares the one `refs/stash` (M 17). Anything that acts on an
/// entry checks that `stash@{index}` still names `sha` first.
public struct Stash: Sendable, Hashable, Identifiable {
    /// The prefix of every record Gitter files before it discards something.
    public static let discardPrefix = "Discarded by Gitter: "

    public let sha: String
    /// The position: this entry is `stash@{index}`.
    public let index: Int
    /// The reflog message (`%gs`): `On <branch>: <message>`, `WIP on <branch>: <sha> <subject>`,
    /// or exactly the `-m` text of a `stash store`. git flattens a newline in it to a space.
    public let reflogSubject: String
    /// `%P`: the commit the entry was made on, the index commit, and a third, holding the
    /// untracked files, when the entry has any.
    public let parents: [String]
    /// When the entry was made (`%ct`).
    public let date: Date

    public init(sha: String, index: Int, reflogSubject: String, parents: [String], date: Date) {
        self.sha = sha
        self.index = index
        self.reflogSubject = reflogSubject
        self.parents = parents
        self.date = date
    }

    public var id: String { sha }

    public var kind: StashKind {
        reflogSubject.hasPrefix(Self.discardPrefix) ? .discarded : .user
    }

    public var hasUntrackedPart: Bool { parents.count == 3 }

    /// The branch the entry was made on, from `On <branch>: ` or `WIP on <branch>: `. Nil for a
    /// detached HEAD (`(no branch)`) and for an entry filed by `stash store` with a message of
    /// its own. A branch name cannot contain `: ` (nor a space), so the first one ends it.
    public var branch: String? {
        guard let (branch, _) = splitPrefix(), branch != Self.detached else { return nil }
        return branch
    }

    /// The subject without its `On <branch>: ` / `WIP on <branch>: ` prefix; the whole subject
    /// when there is none (a stored entry, such as Gitter's discard record).
    public var message: String {
        splitPrefix()?.message ?? reflogSubject
    }

    private static let detached = "(no branch)"

    private func splitPrefix() -> (branch: String, message: String)? {
        for prefix in ["On ", "WIP on "] where reflogSubject.hasPrefix(prefix) {
            let rest = reflogSubject.dropFirst(prefix.count)
            guard let colon = rest.range(of: ": ") else { continue }
            let branch = String(rest[rest.startIndex..<colon.lowerBound])
            guard !branch.isEmpty, branch == Self.detached || !branch.contains(" ") else { continue }
            return (branch, String(rest[colon.upperBound...]))
        }
        return nil
    }
}
