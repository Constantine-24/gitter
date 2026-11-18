import Foundation
import GitCore

/// The sidebar's state that is more than a filter (N1): the branch activity Recent is built from,
/// and which sections, folders and remote groups are folded, per repository.
extension RepositoryStore {
    /// Recent: the current branch, then the HEAD reflog's switches, then tip dates.
    var recentBranches: [Branch] {
        SidebarLayout.recent(localBranches, activity: branchActivity)
    }

    /// The stash the detail pane shows, which Stashes keeps on screen past its limit.
    var selectedStashSHA: String? {
        if case .stash(let sha) = selection { sha } else { nil }
    }

    /// What Stashes draws now: the rows, how many are left out, and its Show All / Show Fewer row.
    func stashList(_ rows: SidebarFilter.Rows) -> SidebarLayout.StashList {
        SidebarLayout.stashList(
            stashes, matching: rows.stashes, isFiltering: rows.isFiltering, showAll: showsAllStashes,
            selected: selectedStashSHA)
    }

    /// The count a section's header shows once folded (`SidebarLayout.headerCount`).
    func sidebarHeaderCount(_ section: SidebarSection) -> Int {
        SidebarLayout.headerCount(
            section, refs: snapshot?.refs ?? .empty, stashCount: stashes.count, worktrees: worktrees)
    }

    /// Whether `section` shows its rows now: the user's folding, or open while filtering.
    func sidebarShows(_ section: SidebarSection) -> Bool {
        SidebarLayout.isExpanded(section, folding: sidebarFolding, query: sidebarFilter)
    }

    func setSection(_ section: SidebarSection, folded: Bool) {
        changeFolding {
            if folded { $0.foldedSections.insert(section) } else { $0.foldedSections.remove(section) }
        }
    }

    func setFolder(_ prefix: String, expanded: Bool) {
        changeFolding {
            if expanded { $0.expandedFolders.insert(prefix) } else { $0.expandedFolders.remove(prefix) }
        }
    }

    func setRemote(_ name: String, expanded: Bool) {
        changeFolding {
            if expanded { $0.expandedRemotes.insert(name) } else { $0.expandedRemotes.remove(name) }
        }
    }

    func setOtherExpanded(_ expanded: Bool) {
        changeFolding { $0.otherExpanded = expanded }
    }

    /// Applies one change and saves. Ignored while the filter narrows the sidebar: a filtered
    /// sidebar shows everything it matches unfolded, so a fold then says nothing the user meant.
    /// Names that no longer exist are dropped with the write; nothing else ever writes.
    private func changeFolding(_ change: (inout SidebarFolding) -> Void) {
        guard let root, !SidebarFilter.isFiltering(sidebarFilter) else { return }
        var folding = sidebarFolding
        change(&folding)
        if let snapshot {
            let folders = Set(SidebarLayout.tree(snapshot.refs.localBranches).folders.map(\.prefix))
            folding.expandedFolders.formIntersection(folders)
            folding.expandedRemotes.formIntersection(snapshot.refs.remotes.map(\.name))
        }
        guard folding != sidebarFolding else { return }
        replaceSidebarFolding(folding)
        SidebarFolding.save(folding, to: defaults, root: root)
    }
}
