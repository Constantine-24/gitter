import GitCore
import SwiftUI

/// Where to publish a branch that has no push remote, when there is more than one remote to
/// choose from. With a single remote `push()` publishes straight away and this never opens; if
/// it is ever shown with one, it names that remote instead of offering a one-item choice.
///
/// Publishing loses nothing — a remote that already has a branch of this name only takes it as
/// a fast-forward — but it does write to a server, so it follows the other remote sheets:
/// Cancel holds `.defaultAction`, Escape closes, and "Publish" has no shortcut.
struct PublishSheet: View {
    let branch: String

    @Environment(RepositoryStore.self) private var store
    /// The remote picked here, or nil while the sheet still shows the default.
    @State private var chosen: String?

    private var remotes: [Remote] { store.snapshot?.refs.remotes ?? [] }

    /// The upstream's remote when the branch has one (a branch tracking a local branch, or one
    /// published before and since unset, still says where it belongs), else the first remote.
    private var defaultRemote: String? {
        let upstreamRemote = store.localBranches.first { $0.name == branch }?.upstreamRemote
        if let upstreamRemote, remotes.contains(where: { $0.name == upstreamRemote }) {
            return upstreamRemote
        }
        return remotes.first?.name
    }

    /// The choice, if it is still a configured remote.
    private var remote: String? {
        let pick = chosen ?? defaultRemote
        return remotes.contains { $0.name == pick } ? pick : defaultRemote
    }

    private var staleReason: String? {
        store.currentBranch == branch ? nil : RemoteWording.publishSheetNoLongerApplies(branch)
    }

    private var busyReason: String? {
        if let activity = store.remoteActivity { return RemoteWording.laneBusy(activity) }
        if store.isMutating { return RemoteWording.mutationBusy }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RemoteWording.publishSheetTitle(branch))
                .font(.headline)

            if remotes.count > 1 {
                Text(RemoteWording.publishTo(branch, remote: nil))
                    .font(.callout)
                Picker(selection: Binding(get: { remote ?? "" }, set: { chosen = $0 })) {
                    ForEach(remotes) { remote in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(remote.name)
                            // The address as git would use it for a push, made plain like
                            // every other string that can carry a credential.
                            if let url = remote.pushURL ?? remote.fetchURL {
                                Text(RemoteWording.plain(url))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                        }
                        .tag(remote.name)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.radioGroup)
            } else if let remote {
                Text(RemoteWording.publishTo(branch, remote: remote))
                    .font(.callout)
            }

            if let remote {
                Text(RemoteWording.publishWillTrack(remote: remote, branch: branch))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if store.remoteBranches.contains(where: { $0.name == "\(remote)/\(branch)" }) {
                    Text(RemoteWording.publishOntoExisting(remote: remote, branch: branch))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ForEach([staleReason, busyReason].compactMap { $0 }, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // No shortcut: Return belongs to Cancel.
                Button("Publish") { confirm() }
                    .disabled(remote == nil || busyReason != nil)
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onExitCommand { store.activeSheet = nil }
    }

    private func confirm() {
        guard let remote, busyReason == nil else { return }
        // `confirmPublish` checks this sheet's branch against HEAD and clears it itself.
        store.confirmPublish(to: remote)
    }
}
