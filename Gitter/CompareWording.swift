import Foundation
import GitCore

/// Every sentence comparing two branches puts on screen (B3): the menus' items and reasons, the
/// compare bar, the list's rows and groups, the changes header with its merge-base wording, the
/// "moved since this comparison" line, the refusals and the Compare Branches… sheet. Pure, so
/// `CompareWordingTests` and `CompareMenuTests` pin each one.
///
/// A comparison is one state (`Comparison`): everything here is said from its two ids, its
/// counts, its lists and its merge bases, never from the names as they are now — except
/// `staleness`, whose whole point is to say that the names have moved on.
///
/// Branch names are somebody else's text and go through `RemoteWording.plain`.
enum CompareWording {

    // MARK: - Names

    /// A full ref as the user knows it: `main`, `origin/main`.
    static func name(_ ref: String) -> String {
        for prefix in ["refs/heads/", "refs/remotes/"] where ref.hasPrefix(prefix) {
            return RemoteWording.plain(String(ref.dropFirst(prefix.count)))
        }
        return RemoteWording.plain(ref)
    }

    static func quoted(_ ref: String) -> String {
        "\"\(name(ref))\""
    }

    private static func short(_ id: String) -> String {
        String(id.prefix(7))
    }

    private static func commits(_ n: Int) -> String {
        n == 1 ? "1 commit" : "\(n) commits"
    }

    // MARK: - Menus

    static let compareBranchesTitle = "Compare Branches…"
    static let copyCommitIDTitle = "Copy Commit ID"

    /// `Compare with "main"` — the branch HEAD is on, quoted as the spec writes it.
    static func compareWithTitle(current: String?) -> String {
        guard let current else { return "Compare with Current Branch" }
        return "Compare with \"\(RemoteWording.plain(current))\""
    }

    /// Why "Compare with <current>" is off on the row of `ref` (a full ref), or nil. The current
    /// branch's own row gives Switch's sentence, so the menu says it once.
    static func compareWithBlocked(
        _ ref: String, current: String?, currentHasCommits: Bool, isDetached: Bool
    ) -> String? {
        if isDetached { return "HEAD is detached, so there is no current branch to compare with." }
        guard let current else { return "There is no current branch to compare with." }
        guard currentHasCommits else {
            return "\"\(RemoteWording.plain(current))\" has no commits yet, so there is nothing to compare it with."
        }
        if ref == "refs/heads/" + current { return RepositoryStore.currentBranchReason }
        return nil
    }

    /// Why Compare Branches… is off, or nil: it needs two branches, local or remote.
    static func compareBranchesBlocked(branchCount: Int) -> String? {
        switch branchCount {
        case 0: "This repository has no branches to compare yet."
        case 1: "Comparing needs two branches, and this repository has only one."
        default: nil
        }
    }

    // MARK: - The bar

    /// `main ⇄ feature`.
    static func barTitle(_ c: Comparison) -> String {
        "\(name(c.a.ref)) ⇄ \(name(c.b.ref))"
    }

    static func barHelp(_ c: Comparison) -> String {
        "Comparing \(name(c.a.ref)) (\(short(c.a.id))) with \(name(c.b.ref)) (\(short(c.b.id))): "
            + "the commits only on each side, and the changes \(name(c.b.ref)) brings."
    }

    static let swapTitle = "Swap"

    static func swapHelp(_ c: Comparison) -> String {
        "Compare the other way round: the changes \(name(c.a.ref)) brings to \(name(c.b.ref))."
    }

    static let doneTitle = "Done"
    static let doneHelp = "Leave the comparison and go back to the history (Esc)."
    static let refreshTitle = "Refresh"
    static let refreshHelp = "Compare the two branches again, as they are now."

    // MARK: - After a refresh

    /// Which of a comparison's refs no longer point where it read them, in the snapshot just
    /// loaded: `moved` holds every such ref, `deleted` the ones that are gone. A first.
    struct Staleness: Hashable {
        let moved: [String]
        let deleted: [String]

        var isCurrent: Bool { moved.isEmpty }
        /// Refresh reads both branches again — unless one is gone, which leaves only Done.
        var offersRefresh: Bool { deleted.isEmpty && !moved.isEmpty }
        /// Swap reads them again the other way round, so it needs both too.
        var offersSwap: Bool { deleted.isEmpty }
    }

    /// The comparison's two tips against `refs`: a local branch looked up among the local
    /// branches, a remote one among the remote branches, by its name without the namespace.
    static func staleness(_ c: Comparison, refs: RefCollection) -> Staleness {
        var moved: [String] = []
        var deleted: [String] = []
        for tip in [c.a, c.b] {
            let now = currentTip(tip.ref, refs: refs)
            if now == nil { deleted.append(tip.ref) }
            if now != tip.id { moved.append(tip.ref) }
        }
        return Staleness(moved: moved, deleted: deleted)
    }

    private static func currentTip(_ ref: String, refs: RefCollection) -> String? {
        if ref.hasPrefix("refs/heads/") {
            let branch = String(ref.dropFirst("refs/heads/".count))
            return refs.localBranches.first { $0.name == branch }?.sha
        }
        if ref.hasPrefix("refs/remotes/") {
            let branch = String(ref.dropFirst("refs/remotes/".count))
            return refs.remoteBranches.first { $0.name == branch }?.sha
        }
        return nil
    }

    /// "feature has moved since this comparison." — or been deleted, which is said instead.
    static func staleLine(_ s: Staleness) -> String? {
        if !s.deleted.isEmpty {
            return s.deleted.count == 1
                ? "\(name(s.deleted[0])) has been deleted since this comparison."
                : "\(names(s.deleted)) have been deleted since this comparison."
        }
        guard !s.moved.isEmpty else { return nil }
        return s.moved.count == 1
            ? "\(name(s.moved[0])) has moved since this comparison."
            : "\(names(s.moved)) have moved since this comparison."
    }

    private static func names(_ refs: [String]) -> String {
        refs.map(name).joined(separator: " and ")
    }

    // MARK: - The list

    /// The row that shows the changes B brings, with how many files once they are read; nil
    /// with no merge base, when there are none to show (R7).
    static func changesRow(_ c: Comparison, fileCount: Int?) -> String? {
        guard !c.mergeBases.isEmpty else { return nil }
        let title = headerTitle(c)
        switch fileCount {
        case nil: return title
        case 0: return "\(title) (no files)"
        case 1: return "\(title) (1 file)"
        case let n?: return "\(title) (\(n) files)"
        }
    }

    /// What stands in the changes row's place with no merge base.
    static func noHistoryRow(_ c: Comparison) -> String {
        "No changes to show: \(name(c.a.ref)) and \(name(c.b.ref)) share no history"
    }

    /// `Only on feature (3)` — the count is exact however long the list.
    static func onlyOn(_ ref: String, count: Int) -> String {
        "Only on \(name(ref)) (\(count))"
    }

    /// The commits a group does not list (it stops at `Comparison.listLimit`), or nil.
    static func notListed(total: Int, listed: Int) -> String? {
        let rest = total - listed
        return rest > 0 ? "…and \(rest) more not listed" : nil
    }

    /// An empty group.
    static let noCommits = "None"

    // MARK: - The changes header

    static func headerTitle(_ c: Comparison) -> String {
        "Changes \(name(c.b.ref)) brings"
    }

    /// Where the changes are read from: the merge base, none, or the first of several — which
    /// `git diff A...B` also takes, warning only on stderr (R8).
    static func baseLine(_ c: Comparison) -> String {
        let a = name(c.a.ref)
        let b = name(c.b.ref)
        switch c.mergeBases.count {
        case 0:
            return "\(a) and \(b) share no history, so there are no changes to show."
        case 1:
            return "From their merge base \(short(c.mergeBases[0])) to \(b) at \(short(c.b.id)), "
                + "as git diff \(a)...\(b) shows."
        case let n:
            return "\(n) merge bases — showing the first, as git diff does: "
                + "from \(short(c.mergeBases[0])) to \(b) at \(short(c.b.id))."
        }
    }

    /// The two counts in words.
    static func countsLine(_ c: Comparison) -> String {
        let a = name(c.a.ref)
        let b = name(c.b.ref)
        if c.onlyA == 0 && c.onlyB == 0 { return "\(a) and \(b) are at the same commit." }
        if c.onlyB == 0 { return "\(b) has no commits \(a) lacks, so it brings no changes." }
        let other = c.onlyA == 0 ? "none" : "\(c.onlyA)"
        return "\(b) has \(commits(c.onlyB)) \(a) lacks; \(a) has \(other) \(b) lacks."
    }

    /// Commits on B that change nothing in all (R9), or nil.
    static func filesLine(_ c: Comparison, fileCount: Int?) -> String? {
        guard fileCount == 0, c.onlyB > 0, !c.mergeBases.isEmpty else { return nil }
        return "Together its commits change no files: they are empty, or what they do cancels out, as a change and its revert do."
    }

    /// The file list's empty state.
    static let noChangesTitle = "No Changes"
    static let noHistoryTitle = "No Shared History"

    // MARK: - Refusals

    /// What a failed comparison or read of its changes says, or nil for an error that is not
    /// about comparing (the store's own `describe` words it).
    static func failure(_ error: Error) -> String? {
        if let refusal = error as? CompareRefusal {
            switch refusal {
            case .notABranch(let ref):
                return "\"\(RemoteWording.plain(ref))\" is not a branch, so it cannot be compared."
            case .missing(let ref):
                return "\(name(ref)) no longer exists, so the comparison could not be read."
            case .sameRef:
                return "Choose two different branches to compare."
            case .noMergeBase:
                return "These branches share no history, so there are no changes to show."
            }
        }
        // The two-id diff's guard (Task 1): no `Comparison` can reach it with anything but full
        // ids, so this is a failure nobody expects — said as one.
        if case .invalidName? = error as? BranchOperationError {
            return "Gitter could not read the changes: an id it read was not a full commit id. Nothing was changed."
        }
        return nil
    }

    // MARK: - The Compare Branches… sheet

    static let sheetTitle = "Compare Branches"
    static let sheetExplanation =
        "See the commits only on each branch and the changes the second brings — what git diff A...B shows. "
        + "Nothing is changed."
    static let firstLabel = "Branch A"
    static let secondLabel = "Branch B — the changes it brings"
    static let compareButton = "Compare"

    /// Every branch a picker offers, as full refs — local branches, then remote ones — narrowed
    /// by `query` as the sidebar's filter narrows (`SidebarFilter.matches`).
    static func pickerOptions(_ refs: RefCollection, query: String) -> [String] {
        let locals = refs.localBranches.filter { SidebarFilter.matches($0.name, remote: nil, query: query) }
            .map { "refs/heads/" + $0.name }
        let remotes = refs.remoteBranches.filter { SidebarFilter.matches($0.name, remote: nil, query: query) }
            .map { "refs/remotes/" + $0.name }
        return locals + remotes
    }

    /// Under a picker: which branch it holds, which a filter may have scrolled out of sight.
    static func chosen(_ ref: String?) -> String {
        ref.map { "Chosen: \(name($0))" } ?? "Nothing chosen"
    }

    /// Why Compare is off, or nil.
    static func sheetBlocked(a: String?, b: String?) -> String? {
        guard let a, let b else { return "Choose a branch on each side." }
        return a == b ? "Choose two different branches." : nil
    }
}
