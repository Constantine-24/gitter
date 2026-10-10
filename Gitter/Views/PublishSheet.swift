import GitCore
import SwiftUI

/// Where to publish a branch that has no push remote. The toolbar opens it when there is more
/// than one remote to choose from (with a single remote `push()` publishes straight away); a
/// branch's own "Publish <b>…" (B2 Task 4) always opens it, and with one remote it names that
/// remote instead of offering a one-item choice.
///
/// Publishing loses nothing — a remote that already has a branch of this name only takes it as
/// a fast-forward — but it does write to a server, so it follows the other remote sheets:
/// Cancel holds `.defaultAction`, Escape closes, and "Publish" has no shortcut.
struct PublishSheet: View {
    let branch: String

    @Environment(RepositoryStore.self) private var store
    /// The remote picked here, or nil while the sheet still shows the default.
    @State private var chosen: String?

    /// Only remotes with a URL to push to (fix round 1, I1).
    private var remotes: [Remote] { (store.snapshot?.refs.remotes ?? []).filter(\.canPush) }

    /// "origin" when it is configured, else git's first remote (git lists them alphabetically).
    ///
    /// "origin" because it is git's own implicit default remote — the one a bare `git push` of
    /// an upstreamless branch falls back to (the design's push-target table, row m) — so it is
    /// where the user's own terminal would have sent this branch.
    ///
    /// The branch's upstream cannot be the guide, although it would be the natural first
    /// choice: this sheet only opens for a branch `PushTarget` calls `.unpublished`, meaning it
    /// has no `pushRemote`, and a branch whose upstream is on a remote always has one — git
    /// reports the upstream's remote as the push remote when nothing overrides it. The other
    /// case, an upstream that is another *local* branch, has no remote at all
    /// (`upstreamRemote` is nil there). So there is never an upstream remote to prefer here.
    private var defaultRemote: String? {
        if remotes.contains(where: { $0.name == "origin" }) { return "origin" }
        return remotes.first?.name
    }

    /// The choice, if it is still a configured remote.
    private var remote: String? {
        let pick = chosen ?? defaultRemote
        return remotes.contains { $0.name == pick } ? pick : defaultRemote
    }

    /// The branch is gone, or has a push remote now: `confirmPublish` would refuse.
    private var staleReason: String? {
        guard let ref = store.localBranches.first(where: { $0.name == branch }),
            PushTarget.resolve(ref, remotes: store.snapshot?.refs.remotes ?? []) == .unpublished
        else { return RemoteWording.publishSheetNoLongerApplies(branch) }
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
                            // The address as git would use it for a push, its credential
                            // taken out by the URL's structure (final review I1).
                            if let caption = RemoteWording.publishRemoteCaption(remote) {
                                Text(caption)
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
                Text(RemoteWording.publishWillTrack(remote: remote, branch: branch, checkedOut: branch == store.currentBranch))
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

            ForEach(
                [staleReason, store.sheetBusyReason].compactMap { $0 }, id: \.self
            ) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // No shortcut: Return belongs to Cancel.
                let act: @MainActor () -> Void = { confirm() }
                Button("Publish", action: act)
                    .harnessButton("Publish", action: act)
                    .disabled(remote == nil || store.sheetBusyReason != nil)
                let cancel: @MainActor () -> Void = { store.activeSheet = nil }
                Button("Cancel", action: cancel)
                    .harnessButton("Cancel", action: cancel)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        .onExitCommand { store.activeSheet = nil }
    }

    private func confirm() {
        guard let remote, store.sheetBusyReason == nil else { return }
        // `confirmPublish` checks this sheet's branch is still unpublished and clears it itself.
        store.confirmPublish(to: remote)
    }
}
