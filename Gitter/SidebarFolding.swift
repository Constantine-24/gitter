import Foundation

/// Which sidebar sections, branch folders and remote groups the user has folded or unfolded in
/// one repository (N1). Kept per repository root in the store's defaults, as one JSON value per
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
        guard let data = entries(in: defaults)[key(for: root)],
            let folding = try? JSONDecoder().decode(SidebarFolding.self, from: data)
        else { return SidebarFolding() }
        return folding
    }

    /// Saves `folding` for `root`, leaving every other repository's entry as it is.
    static func save(_ folding: SidebarFolding, to defaults: UserDefaults, root: URL) {
        guard let data = try? JSONEncoder().encode(folding) else { return }
        var all = entries(in: defaults)
        all[key(for: root)] = data
        defaults.set(all, forKey: defaultsKey)
    }

    /// Every saved entry that is `Data`, one by one: a value of another type (written by hand, or
    /// by another version) is left out alone, never taking the other repositories' entries with it.
    private static func entries(in defaults: UserDefaults) -> [String: Data] {
        (defaults.dictionary(forKey: defaultsKey) ?? [:]).compactMapValues { $0 as? Data }
    }

    /// The root's path, standardized with its links followed: one repository opened through two
    /// paths shares one entry.
    static func key(for root: URL) -> String {
        RepositoryStore.realPath(root.standardizedFileURL.path)
    }
}

extension SidebarFolding {
    private enum CodingKeys: String, CodingKey {
        case foldedSections, expandedFolders, expandedRemotes, otherExpanded
    }

    /// Lenient, so an entry written by another version keeps what it can: a missing key takes its
    /// default, and a section name this version does not know is dropped rather than failing the
    /// whole entry. In an extension, so the memberwise initializer stays.
    init(from decoder: any Decoder) throws {
        self.init()
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let sections = try container.decodeIfPresent([String].self, forKey: .foldedSections) ?? []
        foldedSections = Set(sections.compactMap(SidebarSection.init(rawValue:)))
        expandedFolders = try container.decodeIfPresent(Set<String>.self, forKey: .expandedFolders) ?? []
        expandedRemotes = try container.decodeIfPresent(Set<String>.self, forKey: .expandedRemotes) ?? []
        otherExpanded = try container.decodeIfPresent(Bool.self, forKey: .otherExpanded) ?? false
    }
}
