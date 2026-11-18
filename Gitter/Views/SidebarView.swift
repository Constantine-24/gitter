import GitCore
import SwiftUI

/// Repository outline: the working copy, the recent branches, local branches in prefix folders,
/// worktrees, stashes, remotes and tags.
///
/// Selecting a branch or tag selects the commit it points at in the commit list. Any row's click
/// ends compare mode first (B3, `selectFromSidebar`). Right-clicking
/// one opens its menu (see `SidebarMenus.swift`), and double-clicking does the obvious thing for
/// the kind of ref it is: a local branch is switched to, a remote branch is checked out as a
/// local tracking branch, and a tag does nothing at all — detaching HEAD should be deliberate.
///
/// N1: Recent (`SidebarLayout.recent`, at most five, the current branch first) sits above
/// Branches, whose branches sharing a first path segment are grouped in folders
/// (`SidebarLayout.tree`) that start folded. A branch in Recent and the same branch in its folder
/// are one row view (`localBranchRow`) — same menu, same double-click — under distinct ids
/// (`recent:<name>`, `branch:<name>`, `folder:<prefix>`), so the list never merges them. Every
/// section but Working Copy folds from its header, which then shows a count (except Recent); the
/// folding, each folder's and each remote group's expansion are the store's (`sidebarFolding`),
/// kept per repository and written only by a click (`setSection`, `setFolder`, `setRemote`).
///
/// The filter field (B3, `.searchable` on this column, ⌘F) narrows local branches, remote
/// branches, tags and stashes (`SidebarFilter.rows`); Working Copy and Worktrees are not
/// filtered. While it narrows anything, Recent is hidden and every section, folder and remote
/// group is shown open — the user's own folding is kept by the store and comes back when the
/// filter is cleared, and a disclosure click meanwhile changes nothing — a section left empty
/// says "No matches", and VoiceOver announces how many rows match.
struct SidebarView: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let rows = store.sidebarRows
        List {
            Section("Working Copy") {
                Button {
                    store.selectFromSidebar(.workingCopy)
                } label: {
                    HStack {
                        Label("Working Copy", systemImage: "pencil.and.list.clipboard")
                        Spacer()
                        let count = store.snapshot?.status.files.count ?? 0
                        if count > 0 {
                            Text("\(count)")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                .buttonStyle(.plain)
            }

            if store.sidebarShowsRecent {
                Section(isExpanded: SidebarSectionHeader.expansion(.recent, store: store)) {
                    ForEach(store.recentBranches) { branch in
                        localBranchRow(branch, title: branch.name)
                            .id("recent:" + branch.name)
                    }
                } header: {
                    SidebarSectionHeader(section: .recent)
                }
            }

            if rows.showsBranches {
                // From the filtered branches: while filtering, a folder holds (and counts) its
                // matches only.
                let tree = SidebarLayout.tree(rows.localBranches)
                Section(isExpanded: SidebarSectionHeader.expansion(.branches, store: store)) {
                    ForEach(tree.folders, id: \.prefix) { folder in
                        DisclosureGroup(isExpanded: folderExpansion(folder.prefix)) {
                            ForEach(folder.branches) { branch in
                                localBranchRow(branch, title: SidebarLayout.leafName(branch.name, in: folder.prefix))
                                    .id("branch:" + branch.name)
                            }
                        } label: {
                            BranchFolderLabel(prefix: folder.prefix, count: folder.branches.count)
                        }
                        .id("folder:" + folder.prefix)
                    }
                    ForEach(tree.plain) { branch in
                        localBranchRow(branch, title: branch.name)
                            .id("branch:" + branch.name)
                    }
                    if rows.branchesHaveNoMatches { SidebarNoMatchesRow() }
                } header: {
                    SidebarSectionHeader(section: .branches)
                }
            }

            WorktreesSection()

            StashesSection(rows: rows)

            // The groups come from the configured remotes, not from splitting a branch name on
            // "/": a remote nothing has been fetched from still gets a (empty) group of its
            // own, and a remote whose name contains a slash keeps its branches.
            if rows.showsRemotes {
                Section(isExpanded: SidebarSectionHeader.expansion(.remotes, store: store)) {
                    ForEach(rows.remoteGroups, id: \.remote) { group in
                        DisclosureGroup(isExpanded: expansion(of: group.remote.name)) {
                            ForEach(group.branches) { branch in
                                remoteBranchRow(branch)
                            }
                        } label: {
                            // On the label only, so a right-click on one of the remote's
                            // branches still gets that branch's menu.
                            RemoteRowLabel(remote: group.remote)
                                .contextMenu { RemoteMenu(remote: group.remote) }
                        }
                    }
                    // Refs under `refs/remotes/` that no configured remote claims — left over
                    // from a removed remote, or written by hand. They are shown rather than
                    // dropped: the commits they hold may be reachable from nowhere else.
                    if !rows.otherBranches.isEmpty {
                        DisclosureGroup("Other", isExpanded: otherExpansion) {
                            ForEach(rows.otherBranches) { branch in
                                remoteBranchRow(branch)
                            }
                        }
                    }
                    if rows.remotesHaveNoMatches { SidebarNoMatchesRow() }
                } header: {
                    SidebarSectionHeader(section: .remotes)
                }
            }

            if rows.showsTags {
                Section(isExpanded: SidebarSectionHeader.expansion(.tags, store: store)) {
                    ForEach(rows.tags) { tag in
                        Button {
                            store.selectFromSidebar(.commit(tag.sha))
                        } label: {
                            // Filled for an annotated tag, outlined for a lightweight one; the
                            // tooltip says which, who tagged it, when, and its message.
                            Label(tag.name, systemImage: TagWording.rowIcon(tag))
                        }
                        .buttonStyle(.plain)
                        .help(TagWording.rowHelp(tag))
                        .accessibilityLabel(TagWording.rowAccessibility(tag))
                        .contextMenu { TagMenu(tag: tag) }
                        // No double-click action on purpose: checking out a tag detaches HEAD,
                        // and the design asks for that to be deliberate.
                    }
                    // The tags deleted while this repository is open, dimmed, each with its
                    // Restore Tag: the way back once the delete notice is gone (another notice
                    // took the slot, or ×). Here rather than in a menu because a row is seen
                    // without looking for it, and it outlives every tag being deleted — the
                    // section stays while any is.
                    ForEach(rows.deletedTags, id: \.self) { receipt in
                        Button {
                            store.selectFromSidebar(.commit(receipt.target))
                        } label: {
                            Label(receipt.name, systemImage: TagWording.deletedRowIcon)
                                .strikethrough()
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help(TagWording.deletedRowHelp(receipt))
                        .accessibilityLabel(TagWording.deletedRowAccessibility(receipt))
                        .contextMenu {
                            Button(TagWording.restoreMenuTitle) { store.restoreTags([receipt]) }
                        }
                    }
                    if rows.tagsHaveNoMatches { SidebarNoMatchesRow() }
                } header: {
                    SidebarSectionHeader(section: .tags)
                }
            }
        }
        .listStyle(.sidebar)
        // The count as it changes while filtering — typing, or a refresh bringing refs in.
        .onChange(of: rows.isFiltering ? rows.matchCount : nil) { _, count in
            guard let count else { return }
            AccessibilityNotification.Announcement(SidebarFilter.announcement(matches: count)).post()
        }
    }

    /// A branch folder's expansion: folded until the user opens it, open while filtering. The
    /// store ignores a click while filtering, so the user's choice is what the cleared filter shows.
    private func folderExpansion(_ prefix: String) -> Binding<Bool> {
        Binding(
            get: { store.sidebarShowsFolder(prefix) },
            set: { store.setFolder(prefix, expanded: $0) })
    }

    /// A remote group's expansion: forced open while filtering, the user's own otherwise, kept
    /// per repository by the store (which ignores a click while filtering).
    private func expansion(of remote: String) -> Binding<Bool> {
        Binding(
            get: { store.sidebarShowsRemote(remote) },
            set: { store.setRemote(remote, expanded: $0) })
    }

    private var otherExpansion: Binding<Bool> {
        Binding(
            get: { store.sidebarShowsOther },
            set: { store.setOtherExpanded($0) })
    }

    /// A local branch's row wherever it is listed — Recent, a folder or a plain row — with the
    /// same menu and the same double-click, so the shortcut never behaves differently. `title` is
    /// what the row reads: the full name, or the name inside its folder.
    private func localBranchRow(_ branch: Branch, title: String) -> some View {
        branchRow(branch, showCheck: true, title: title)
            .contextMenu { LocalBranchMenu(branch: branch.name) }
            // Double-click switches, which is what a branch row in every other Git client does.
            // `simultaneousGesture` rather than `onTapGesture(count: 2)`: the latter swallows
            // the row's own single click, and selecting the branch's commit on one click is the
            // behaviour this list already had.
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    store.switchTo(branch: branch.name)
                })
    }

    @ViewBuilder
    private func remoteBranchRow(_ branch: Branch) -> some View {
        branchRow(branch, showCheck: false)
            .contextMenu { RemoteBranchMenu(branch: branch.name) }
            .simultaneousGesture(
                TapGesture(count: 2).onEnded {
                    store.track(remoteBranch: branch.name)
                })
    }

    @ViewBuilder
    private func branchRow(_ branch: Branch, showCheck: Bool, title: String? = nil) -> some View {
        Button {
            store.selectFromSidebar(.commit(branch.sha))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    // In a folder the row reads the rest of the name; VoiceOver and the tooltip
                    // still give the whole of it.
                    Text(title ?? branch.name)
                        .fontWeight(branch.isHead ? .bold : .regular)
                        .accessibilityLabel(branch.name)
                    if let upstream = branch.upstream {
                        Text(upstream)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)
                // Checked out in another worktree, or held by a rebase or bisect there (B3): its
                // Switch, Delete and Fast-Forward are off with this same sentence.
                if showCheck, let holder = store.worktreeHolder(of: branch.name) {
                    let reason = WorktreeWording.heldReason(branch.name, by: holder)
                    Image(systemName: WorktreeWording.holderSymbol(holder))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(reason)
                        .accessibilityLabel(reason)
                }
                // Local branches only: a remote-tracking branch has no upstream of its own, so
                // its tracking is always `.none` and the badge would draw nothing anyway.
                if showCheck {
                    TrackingBadge(
                        tracking: branch.tracking, tracksLocalBranch: branch.tracksLocalBranch,
                        upstream: branch.upstream
                    )
                    .font(.caption)
                }
                if showCheck && branch.isHead {
                    Image(systemName: "checkmark")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.tint)
                }
            }
        }
        .buttonStyle(.plain)
        .helpIfPresent((title ?? branch.name) == branch.name ? nil : branch.name)
    }
}

/// A sidebar section's header: its title, and once folded, the count of what it holds
/// (`SidebarWording.foldedCount`; none for Recent).
struct SidebarSectionHeader: View {
    let section: SidebarSection

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        HStack(spacing: 6) {
            Text(SidebarWording.title(section))
            if !store.sidebarShows(section), let count = store.sidebarFoldedCount(section) {
                Text(count)
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// The section's disclosure: shown open while filtering, the user's folding otherwise. A
    /// click writes through `setSection`, which ignores it while filtering.
    @MainActor
    static func expansion(_ section: SidebarSection, store: RepositoryStore) -> Binding<Bool> {
        Binding(
            get: { store.sidebarShows(section) },
            set: { store.setSection(section, folded: !$0) })
    }
}

/// "No matches", in a section the filter left empty: Branches, Stashes, Remotes and Tags.
struct SidebarNoMatchesRow: View {
    var body: some View {
        Text(SidebarFilter.noMatches)
            .foregroundStyle(.secondary)
    }
}

/// A branch folder's row: the prefix and how many branches it holds (its matches, while
/// filtering), read by VoiceOver as one sentence.
struct BranchFolderLabel: View {
    let prefix: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "folder")
                .foregroundStyle(.secondary)
            Text(prefix)
            Spacer(minLength: 4)
            Text("\(count)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(SidebarWording.folderAccessibility(prefix, count: count))
    }
}

/// A remote's name in the sidebar. A remote git cannot fetch from — no URL at all, or only a push
/// URL — is listed so it can be given one (carried note 3): it is marked beside its name, and its
/// tooltip points at Edit URL….
struct RemoteRowLabel: View {
    let remote: Remote

    var body: some View {
        if let badge = RemoteAdminWording.remoteBadge(remote) {
            HStack(spacing: 6) {
                Text(remote.name)
                Text(badge)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .help(RemoteAdminWording.remoteHelp(remote) ?? "")
            .accessibilityElement(children: .combine)
        } else {
            Text(remote.name)
        }
    }
}
