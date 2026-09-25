import SwiftUI

/// The confirmation for deleting a branch on a remote: the second action in this milestone that
/// can take commits off the server.
///
/// It names the tip in full — the lease `confirmDeleteRemoteBranch` hands to git, so a branch
/// that moved on the server while this was up is refused there — and says whether any of its
/// commits are held by nothing else this clone can see (`commitsOnlyOnRemoteBranch`). Never
/// "unreachable": that count does not consult the stash, notes, a detached HEAD, another
/// worktree or the reflog.
///
/// Cancel holds `.defaultAction`, Escape closes, and "Delete on "<remote>"" carries the
/// destructive role and no shortcut.
struct DeleteRemoteBranchSheet: View {
    let remote: String
    let branch: String
    let tip: String
    let onlyThere: Int

    @Environment(RepositoryStore.self) private var store

    private var trackingName: String { "\(remote)/\(branch)" }

    /// Why this sheet no longer describes the repository, or nil: the remote-tracking ref has
    /// moved or gone since the tip was read — a fetch saw the server somewhere else.
    private var staleReason: String? {
        let now = store.remoteBranches.first { $0.name == trackingName }?.sha
        guard now != tip else { return nil }
        return RemoteWording.deleteRemoteSheetStale(trackingName, isGone: now == nil)
    }

    private var busyReason: String? {
        if let activity = store.remoteActivity { return RemoteWording.laneBusy(activity) }
        if store.isMutating { return RemoteWording.mutationBusy }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RemoteWording.deleteRemoteTitle(branch: branch, remote: remote))
                .font(.headline)

            Text(RemoteWording.deleteRemoteBody(branch: branch, remote: remote))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text(RemoteWording.onlyThere(onlyThere))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(RemoteWording.deleteRemoteTipLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(tip)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                Text(RemoteWording.deleteRemoteRecreate)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ForEach([staleReason, busyReason].compactMap { $0 }, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // No keyboard shortcut on the destructive half: Return belongs to Cancel.
                Button(RemoteWording.deleteOnRemoteButton(remote), role: .destructive) {
                    confirm()
                }
                    // The role alone draws an ordinary grey button in a macOS sheet.
                    .foregroundStyle(.red)
                    .disabled(busyReason != nil)
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onExitCommand { store.activeSheet = nil }
    }

    private func confirm() {
        guard busyReason == nil else { return }
        // `confirmDeleteRemoteBranch` reads this very sheet for the tip and clears it itself.
        store.confirmDeleteRemoteBranch()
    }
}
