import Foundation
import GitCore

/// The sidebar's state that is more than a filter (N1): the branch activity Recent is built from,
/// and which sections, folders and remote groups are folded, per repository.
extension RepositoryStore {
    /// Recent: the current branch, then the HEAD reflog's switches, then tip dates.
    var recentBranches: [Branch] {
        SidebarLayout.recent(localBranches, activity: branchActivity)
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
