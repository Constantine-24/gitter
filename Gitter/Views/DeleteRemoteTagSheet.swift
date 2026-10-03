import GitCore
import SwiftUI

/// Delete from <remote>…: deleting a tag on the server, for everyone who uses that remote.
///
/// It names the tag's **unpeeled** id there in full — read on the lane as the sheet opened
/// (`remoteTagID`) and the lease `confirmDeleteRemoteTag` hands to git, so a tag that moved or
/// went on the server while this was up is refused there — and whether it is the same tag as
/// the one here, which is kept either way (B22).
///
/// With no such tag on the remote (`id` nil) it says so and offers nothing but Close.
///
/// Cancel holds `.defaultAction`, Escape closes, and "Delete on "<remote>"" carries the
/// destructive role and no shortcut.
struct DeleteRemoteTagSheet: View {
    let name: String
    let remote: String
    let id: String?

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let id {
                question(id)
            } else {
                nothingThere
            }
        }
        .padding(20)
        .frame(width: 480)
        .onExitCommand { store.activeSheet = nil }
    }

    @ViewBuilder
    private func question(_ id: String) -> some View {
        Text(TagWording.deleteRemoteTitle(name, remote: remote))
            .font(.headline)

        Text(TagWording.deleteRemoteBody(remote: remote))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

        Text(TagWording.remoteRelation(name, local: store.tag(named: name), remoteID: id))
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

        VStack(alignment: .leading, spacing: 2) {
            Text(TagWording.deleteRemoteIDLabel)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(id)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(TagWording.deleteRemoteRecreate)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        if let busy = store.sheetBusyReason {
            Text(busy)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }

        HStack {
            Spacer()
            // No keyboard shortcut on the destructive half: Return belongs to Cancel.
            Button(TagWording.deleteOnRemoteButton(remote), role: .destructive) { confirm(id) }
                // The role alone draws an ordinary grey button in a macOS sheet.
                .foregroundStyle(.red)
                .disabled(store.sheetBusyReason != nil)
            Button("Cancel") { store.activeSheet = nil }
                .keyboardShortcut(.defaultAction)
        }
    }

    @ViewBuilder
    private var nothingThere: some View {
        Text(TagWording.noRemoteTagTitle(name, remote: remote))
            .font(.headline)
        Text(TagWording.noRemoteTagBody)
            .font(.callout)
        HStack {
            Spacer()
            Button(TagWording.closeButton) { store.activeSheet = nil }
                .keyboardShortcut(.defaultAction)
        }
    }

    private func confirm(_ id: String) {
        guard store.sheetBusyReason == nil else { return }
        // `confirmDeleteRemoteTag` checks this very sheet for the lease and clears it itself.
        store.confirmDeleteRemoteTag(name, on: remote, expecting: id)
    }
}
