import GitCore
import SwiftUI

/// Repository outline: the working copy, local branches, remotes and tags.
///
/// Selecting a branch or tag selects the commit it points at in the commit list. Right-clicking
/// one opens its menu (see `SidebarMenus.swift`), and double-clicking does the obvious thing for
/// the kind of ref it is: a local branch is switched to, a remote branch is checked out as a
/// local tracking branch, and a tag does nothing at all — detaching HEAD should be deliberate.
struct SidebarView: View {
    @Environment(RepositoryStore.self) private var store

    private var refs: RefCollection { store.snapshot?.refs ?? .empty }

    var body: some View {
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

            if !refs.localBranches.isEmpty {
                Section("Branches") {
                    ForEach(refs.localBranches) { branch in
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
                }
            }

            // The groups come from the configured remotes, not from splitting a branch name on
            // "/": a remote nothing has been fetched from still gets a (empty) group of its
            // own, and a remote whose name contains a slash keeps its branches.
            if !refs.remotes.isEmpty || !refs.branchesWithoutRemote.isEmpty {
                Section("Remotes") {
                    ForEach(refs.remotes) { remote in
                        DisclosureGroup {
                            ForEach(refs.branches(of: remote)) { branch in
                                remoteBranchRow(branch)
                            }
                        } label: {
                            // On the label only, so a right-click on one of the remote's
                            // branches still gets that branch's menu.
                            Text(remote.name)
                                .contextMenu { RemoteMenu(remote: remote) }
                        }
                    }
                    // Refs under `refs/remotes/` that no configured remote claims — left over
                    // from a removed remote, or written by hand. They are shown rather than
                    // dropped: the commits they hold may be reachable from nowhere else.
                    if !refs.branchesWithoutRemote.isEmpty {
                        DisclosureGroup("Other") {
                            ForEach(refs.branchesWithoutRemote) { branch in
                                remoteBranchRow(branch)
                            }
                        }
                    }
                }
            }

            if !refs.tags.isEmpty {
                Section("Tags") {
                    ForEach(refs.tags) { tag in
                        Button {
                            store.select(.commit(tag.sha))
                        } label: {
                            Label(tag.name, systemImage: "tag")
                        }
                        .buttonStyle(.plain)
                        .contextMenu { TagMenu(tag: tag.name) }
                        // No double-click action on purpose: checking out a tag detaches HEAD,
                        // and the design asks for that to be deliberate.
                    }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle(store.root?.lastPathComponent ?? "Gitter")
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
