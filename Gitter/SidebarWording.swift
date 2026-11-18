import Foundation

/// The sidebar's sections, in the order they are drawn. The raw value is what is saved per
/// repository when the user folds one.
enum SidebarSection: String, Codable, CaseIterable, Sendable {
    case recent, branches, worktrees, stashes, remotes, tags
}

/// The sentences the sidebar's navigation adds (N1), pinned by GitterTests.
enum SidebarWording {
    static let recent = "Recent"

    /// Each section's header title.
    static func title(_ section: SidebarSection) -> String {
        switch section {
        case .recent: recent
        case .branches: "Branches"
        case .worktrees: WorktreeWording.sectionTitle
        case .stashes: "Stashes"
        case .remotes: "Remotes"
        case .tags: "Tags"
        }
    }

    static func showAllStashes(_ n: Int) -> String { "Show All \(n) Stashes" }

    static let showFewerStashes = "Show Fewer Stashes"

    /// What VoiceOver reads for a branch folder.
    static func folderAccessibility(_ prefix: String, count: Int) -> String {
        "Branch folder \(prefix), \(count) \(count == 1 ? "branch" : "branches")"
    }

    /// The count a folded section's header shows. Recent shows none: it is a shortcut, not a total.
    static func foldedCount(_ section: SidebarSection, count: Int) -> String? {
        section == .recent ? nil : "\(count)"
    }
}
