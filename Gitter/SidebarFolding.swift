import Foundation

/// Which sidebar sections, branch folders and remote groups the user has folded or unfolded in
/// one repository (N1). Kept per repository root in the window's defaults, as one JSON value per
/// root path under `defaultsKey`; written only when the user folds or unfolds, never by opening.
struct SidebarFolding: Codable, Hashable, Sendable {
    var foldedSections: Set<SidebarSection> = []
    /// Branch folders (`SidebarLayout.Folder.prefix`) the user has opened.
    var expandedFolders: Set<String> = []
    /// Remote groups (`Remote.name`) the user has opened.
    var expandedRemotes: Set<String> = []
    /// The "Other" group of remote branches that belong to no configured remote.
    var otherExpanded = false

    static let defaultsKey = "sidebarFolding"

    /// The saved state of the repository at `root`, or the default when there is none or it
    /// cannot be read. Reads only.
    static func load(from defaults: UserDefaults, root: URL) -> SidebarFolding {
        let all = defaults.dictionary(forKey: defaultsKey) as? [String: Data]
        guard let data = all?[key(for: root)],
            let folding = try? JSONDecoder().decode(SidebarFolding.self, from: data)
        else { return SidebarFolding() }
        return folding
    }

    /// Saves `folding` for `root`, leaving every other repository's entry as it is.
    static func save(_ folding: SidebarFolding, to defaults: UserDefaults, root: URL) {
        guard let data = try? JSONEncoder().encode(folding) else { return }
        var all = (defaults.dictionary(forKey: defaultsKey) as? [String: Data]) ?? [:]
        all[key(for: root)] = data
        defaults.set(all, forKey: defaultsKey)
    }

    /// The root's path, standardized with its links followed: one repository opened through two
    /// paths shares one entry.
    static func key(for root: URL) -> String {
        RepositoryStore.realPath(root.standardizedFileURL.path)
    }
}
