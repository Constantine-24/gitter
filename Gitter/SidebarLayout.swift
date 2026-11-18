import Foundation
import GitCore

/// What the sidebar lists and in what order (N1), decided without views: the Recent section, the
/// prefix folders of Branches and the stash limit. Pure, so GitterTests pin it without a store.
enum SidebarLayout {
    static let recentLimit = 5
    static let stashLimit = 5

    // MARK: - Recent

    /// The current branch first; then the HEAD reflog's switch targets that are existing local
    /// branches, newest first; then the rest by tip date (newest first, ties by name,
    /// case-insensitively). At most `recentLimit`, no duplicates. A target that is no local
    /// branch (a sha, `HEAD~0`, a deleted or renamed name) is skipped.
    static func recent(_ local: [Branch], activity: BranchActivity) -> [Branch] {
        let byName = Dictionary(local.map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
        var seen = Set<String>()
        var result: [Branch] = []
        func add(_ branch: Branch) {
            guard result.count < recentLimit, seen.insert(branch.name).inserted else { return }
            result.append(branch)
        }
        if let head = local.first(where: \.isHead) { add(head) }
        for target in activity.switchTargets {
            if let branch = byName[target] { add(branch) }
        }
        let byTip = local.sorted { a, b in
            let da = activity.tipDates[a.name] ?? .distantPast
            let db = activity.tipDates[b.name] ?? .distantPast
            if da != db { return da > db }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
        for branch in byTip { add(branch) }
        return result
    }

    // MARK: - Folders

    struct Folder: Hashable {
        let prefix: String
        /// Sorted as given.
        let branches: [Branch]
    }

    struct Tree: Hashable {
        let folders: [Folder]
        let plain: [Branch]
    }

    /// The prefix is the first path segment; it is a folder when two or more branches share it
    /// (case-sensitively, as git does). Folders are sorted case-insensitively, then the plain rows
    /// follow in input order.
    static func tree(_ local: [Branch]) -> Tree {
        func prefix(_ branch: Branch) -> String? {
            guard let slash = branch.name.firstIndex(of: "/") else { return nil }
            return String(branch.name[..<slash])
        }
        var counts: [String: Int] = [:]
        for branch in local { if let p = prefix(branch) { counts[p, default: 0] += 1 } }
        let folderPrefixes = counts.filter { $0.value >= 2 }.keys
        let folders = folderPrefixes
            .sorted { a, b in
                let order = a.localizedCaseInsensitiveCompare(b)
                return order == .orderedSame ? a < b : order == .orderedAscending
            }
            .map { p in Folder(prefix: p, branches: local.filter { prefix($0) == p }) }
        let plain = local.filter { branch in prefix(branch).map { counts[$0, default: 0] < 2 } ?? true }
        return Tree(folders: folders, plain: plain)
    }

    /// The branch's name inside its folder: "ui/login" for "feature/ui/login" in "feature".
    static func leafName(_ name: String, in prefix: String) -> String {
        name.hasPrefix(prefix + "/") ? String(name.dropFirst(prefix.count + 1)) : name
    }

    // MARK: - Stashes

    /// The newest `stashLimit` (the list is newest first), or all when `showAll`; the selected one
    /// is appended when it falls outside. `hidden` is how many are not shown.
    static func stashes(_ all: [Stash], showAll: Bool, selected: String?) -> (rows: [Stash], hidden: Int) {
        guard !showAll, all.count > stashLimit else { return (all, 0) }
        var rows = Array(all.prefix(stashLimit))
        if let selected, let extra = all.dropFirst(stashLimit).first(where: { $0.sha == selected }) {
            rows.append(extra)
        }
        return (rows, all.count - rows.count)
    }

    /// What the Stashes section draws: its rows, how many entries are not among them, and the
    /// last row's title ("Show All 8 Stashes" / "Show Fewer Stashes"), or nil for no such row.
    struct StashList: Hashable {
        let rows: [Stash]
        /// Unfiltered: the entries past the limit. Filtering: the entries that do not match.
        let hidden: Int
        let toggle: String?
    }

    /// While filtering, every match and no toggle (`matching` is `SidebarFilter.Rows.stashes`);
    /// otherwise `stashes(_:showAll:selected:)`, with the toggle whenever there are more entries
    /// than the limit — keyed off the count, not `hidden`, so six entries with the sixth selected
    /// (all shown, none hidden) can still be folded back to five.
    static func stashList(
        _ all: [Stash], matching: [Stash], isFiltering: Bool, showAll: Bool, selected: String?
    ) -> StashList {
        if isFiltering {
            return StashList(rows: matching, hidden: all.count - matching.count, toggle: nil)
        }
        let (rows, hidden) = stashes(all, showAll: showAll, selected: selected)
        let toggle =
            all.count > stashLimit
            ? (showAll ? SidebarWording.showFewerStashes : SidebarWording.showAllStashes(all.count)) : nil
        return StashList(rows: rows, hidden: hidden, toggle: toggle)
    }

    // MARK: - Sections

    /// Recent is drawn when there is a local branch and the filter narrows nothing: while
    /// filtering, the matching branches are in Branches, and a current branch that does not
    /// match is not shown.
    static func showsRecent(localBranchCount: Int, query: String) -> Bool {
        localBranchCount > 0 && !SidebarFilter.isFiltering(query)
    }

    /// Whether a section shows its rows: the user's own folding, overridden while filtering.
    static func isExpanded(_ section: SidebarSection, folding: SidebarFolding, query: String) -> Bool {
        SidebarFilter.isExpanded(stored: !folding.foldedSections.contains(section), query: query)
    }

    /// Whether a branch folder shows its rows: folded unless the user opened it, open while
    /// filtering.
    static func isFolderExpanded(_ prefix: String, folding: SidebarFolding, query: String) -> Bool {
        SidebarFilter.isExpanded(stored: folding.expandedFolders.contains(prefix), query: query)
    }

    /// What a section's header counts, unfiltered: local branches, linked worktrees (the main one
    /// left out), stash entries, configured remotes, tags (not the dimmed deleted ones). Recent
    /// counts nothing (`SidebarWording.foldedCount` draws none for it).
    static func headerCount(_ section: SidebarSection, refs: RefCollection, stashCount: Int, worktrees: [Worktree]) -> Int {
        switch section {
        case .recent: 0
        case .branches: refs.localBranches.count
        case .worktrees: worktrees.filter { !$0.isMain }.count
        case .stashes: stashCount
        case .remotes: refs.remotes.count
        case .tags: refs.tags.count
        }
    }
}
