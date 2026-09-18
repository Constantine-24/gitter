import GitCore
import SwiftUI

/// Repository outline: the working copy, local branches, remotes and tags.
/// Selecting a branch or tag selects the commit it points at in the commit list.
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
                    }
                }
            }

            if !refs.remoteNames.isEmpty {
                Section("Remotes") {
                    ForEach(refs.remoteNames, id: \.self) { remote in
                        DisclosureGroup(remote) {
                            ForEach(refs.remoteBranches.filter { $0.name.hasPrefix(remote + "/") }) { branch in
                                branchRow(branch, showCheck: false)
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
