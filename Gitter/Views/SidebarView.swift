import GitCore
import SwiftUI

/// Repository outline: the working copy, local branches, worktrees, stashes, remotes and tags.
///
/// Selecting a branch or tag selects the commit it points at in the commit list. Right-clicking
/// one opens its menu (see `SidebarMenus.swift`), and double-clicking does the obvious thing for
/// the kind of ref it is: a local branch is switched to, a remote branch is checked out as a
/// local tracking branch, and a tag does nothing at all — detaching HEAD should be deliberate.
///
/// The filter field (B3, `.searchable` on this column, ⌘F) narrows local branches, remote
/// branches and tags (`SidebarFilter.rows`); Working Copy, Worktrees and Stashes are not
/// filtered. While it narrows anything, every remote's group is expanded — the user's own
/// expansion is kept here and comes back when the filter is cleared — a section left empty says
/// "No matches", and VoiceOver announces how many refs match.
struct SidebarView: View {
    @Environment(RepositoryStore.self) private var store

    /// The remotes whose group the user expanded, by name. Kept while filtering, which only
    /// overrides what is shown (`SidebarFilter.isExpanded`).
    @State private var expandedRemotes: Set<String> = []
    /// The same for the "Other" group, which is no remote's.
    @State private var otherExpanded = false

    private var refs: RefCollection { store.snapshot?.refs ?? .empty }

    var body: some View {
        let rows = SidebarFilter.rows(refs, deletedTags: store.deletedTags.receipts, query: store.sidebarFilter)
        List {
            Section("Working Copy") {
                Button {
                    store.select(.workingCopy)
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

            if rows.showsBranches {
                Section("Branches") {
                    ForEach(rows.localBranches) { branch in
                        branchRow(branch, showCheck: true)
                            .contextMenu { LocalBranchMenu(branch: branch.name) }
                            // Double-click switches, which is what a branch row in every other
                            // Git client does. `simultaneousGesture` rather than
                            // `onTapGesture(count: 2)`: the latter swallows the row's own
                            // single click, and selecting the branch's commit on one click is
                            // the behaviour this list already had.
                            .simultaneousGesture(
                                TapGesture(count: 2).onEnded {
                                    store.switchTo(branch: branch.name)
                                })
                    }
                    if rows.branchesHaveNoMatches { noMatches }
                }
            }

            WorktreesSection()

            StashesSection()

            // The groups come from the configured remotes, not from splitting a branch name on
            // "/": a remote nothing has been fetched from still gets a (empty) group of its
            // own, and a remote whose name contains a slash keeps its branches.
            if rows.showsRemotes {
                Section("Remotes") {
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
                    if rows.remotesHaveNoMatches { noMatches }
                }
            }

            if rows.showsTags {
                Section("Tags") {
                    ForEach(rows.tags) { tag in
                        Button {
                            store.select(.commit(tag.sha))
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
                            store.select(.commit(receipt.target))
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
                    if rows.tagsHaveNoMatches { noMatches }
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

    private var noMatches: some View {
        Text(SidebarFilter.noMatches)
            .foregroundStyle(.secondary)
    }

    /// A remote group's expansion: forced open while filtering, the user's own otherwise. A
    /// click while filtering changes nothing, so their choice is what the cleared filter shows.
    private func expansion(of remote: String) -> Binding<Bool> {
        Binding(
            get: { SidebarFilter.isExpanded(stored: expandedRemotes.contains(remote), query: store.sidebarFilter) },
            set: { expanded in
                guard !SidebarFilter.isFiltering(store.sidebarFilter) else { return }
                if expanded { expandedRemotes.insert(remote) } else { expandedRemotes.remove(remote) }
            })
    }

    private var otherExpansion: Binding<Bool> {
        Binding(
            get: { SidebarFilter.isExpanded(stored: otherExpanded, query: store.sidebarFilter) },
            set: { expanded in
                guard !SidebarFilter.isFiltering(store.sidebarFilter) else { return }
                otherExpanded = expanded
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
    private func branchRow(_ branch: Branch, showCheck: Bool) -> some View {
        Button {
            store.select(.commit(branch.sha))
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(branch.name)
                        .fontWeight(branch.isHead ? .bold : .regular)
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
