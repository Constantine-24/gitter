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

            if !refs.remoteNames.isEmpty {
                Section("Remotes") {
                    ForEach(refs.remoteNames, id: \.self) { remote in
                        DisclosureGroup(remote) {
                            ForEach(refs.remoteBranches.filter { $0.name.hasPrefix(remote + "/") }) { branch in
                                branchRow(branch, showCheck: false)
                                    .contextMenu { RemoteBranchMenu(branch: branch.name) }
                                    .simultaneousGesture(
                                        TapGesture(count: 2).onEnded {
                                            store.track(remoteBranch: branch.name)
                                        })
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
