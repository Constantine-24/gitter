import Foundation
import GitCore

/// The sidebar's filter (B3): the field at the top of the sidebar (⌘F) narrows local branches,
/// remote branches and tags as you type. Working Copy, Stashes and Worktrees are not filtered.
///
/// The rule is `matches`: case- and diacritic-insensitive substring matching, where every
/// whitespace-separated word of the query must match. A remote branch also matches as
/// `<remote>/<name>`, so "origin/fe" finds `origin/feature` and "origin" every branch of
/// `origin`. `rows` applies it to the refs on screen, and is what the sidebar draws: a remote's
/// group only when one of its branches matches, "No matches" in a section left empty, and the
/// count VoiceOver announces. Pure: the query is the store's `sidebarFilter`, which the
/// `.searchable` field binds and `open(_:)` clears (B3 Ruling 2).
enum SidebarFilter {

    // MARK: - The rule

    /// The query's words: split at any run of whitespace or newlines, blanks dropped.
    static func words(_ query: String) -> [Substring] {
        query.split(whereSeparator: { $0.isWhitespace || $0.isNewline })
    }

    /// Whether the query narrows anything: a blank one is no filter at all.
    static func isFiltering(_ query: String) -> Bool {
        !words(query).isEmpty
    }

    /// Whether a ref named `name` stays in the sidebar for `query`. For a remote-tracking branch
    /// `name` is the part after `<remote>/` and `remote` the remote's name, and every word is
    /// matched against `<remote>/<name>` — which holds `<name>`, so the branch's own name matches
    /// too. A blank query matches everything.
    static func matches(_ name: String, remote: String?, query: String) -> Bool {
        let candidate = remote.map { "\($0)/\(name)" } ?? name
        return words(query).allSatisfy { word in
            candidate.range(of: word, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) != nil
        }
    }

    /// A remote's group is expanded while the filter narrows anything, whatever the user left it
    /// as: what matched must be seen. `stored` — the user's own choice — is never written over,
    /// so it is what shows again once the filter is cleared.
    static func isExpanded(stored: Bool, query: String) -> Bool {
        isFiltering(query) || stored
    }

    // MARK: - What the sidebar draws

    /// A configured remote and the branches of it the sidebar shows.
    struct RemoteGroup: Hashable {
        let remote: Remote
        let branches: [Branch]
    }

    /// The refs sections of the sidebar after the filter. A section is drawn (`shows…`) exactly
    /// when it was before the filter existed — when it has anything to filter — and says "No
    /// matches" (`…HaveNoMatches`) when the filter left nothing in it.
    struct Rows: Hashable {
        let localBranches: [Branch]
        let remoteGroups: [RemoteGroup]
        /// Remote-tracking branches no configured remote claims (the "Other" group).
        let otherBranches: [Branch]
        let tags: [Tag]
        let deletedTags: [TagReceipt]
        let isFiltering: Bool
        let showsBranches: Bool
        let showsRemotes: Bool
        let showsTags: Bool

        var branchesHaveNoMatches: Bool { isFiltering && showsBranches && localBranches.isEmpty }
        var remotesHaveNoMatches: Bool {
            isFiltering && showsRemotes && remoteGroups.isEmpty && otherBranches.isEmpty
        }
        var tagsHaveNoMatches: Bool { isFiltering && showsTags && tags.isEmpty && deletedTags.isEmpty }

        /// Every ref row left: what VoiceOver announces.
        var matchCount: Int {
            localBranches.count + remoteGroups.reduce(0) { $0 + $1.branches.count } + otherBranches.count
                + tags.count + deletedTags.count
        }
    }

    static func rows(_ refs: RefCollection, deletedTags: [TagReceipt], query: String) -> Rows {
        let filtering = isFiltering(query)
        let groups = refs.remotes.compactMap { remote -> RemoteGroup? in
            let branches = refs.branches(of: remote).filter {
                matches(String($0.name.dropFirst(remote.name.count + 1)), remote: remote.name, query: query)
            }
            // Unfiltered, every configured remote keeps its group, empty or not.
            return filtering && branches.isEmpty ? nil : RemoteGroup(remote: remote, branches: branches)
        }
        return Rows(
            localBranches: refs.localBranches.filter { matches($0.name, remote: nil, query: query) },
            remoteGroups: groups,
            otherBranches: refs.branchesWithoutRemote.filter { matches($0.name, remote: nil, query: query) },
            tags: refs.tags.filter { matches($0.name, remote: nil, query: query) },
            deletedTags: deletedTags.filter { matches($0.name, remote: nil, query: query) },
            isFiltering: filtering,
            showsBranches: !refs.localBranches.isEmpty,
            showsRemotes: !refs.remotes.isEmpty || !refs.branchesWithoutRemote.isEmpty,
            showsTags: !refs.tags.isEmpty || !deletedTags.isEmpty)
    }

    // MARK: - Words

    /// The field's placeholder.
    static let prompt = "Filter"

    /// A section the filter left empty.
    static let noMatches = "No matches"

    /// What VoiceOver announces as the matches change.
    static func announcement(matches: Int) -> String {
        switch matches {
        case 0: noMatches
        case 1: "1 match"
        default: "\(matches) matches"
        }
    }
}
