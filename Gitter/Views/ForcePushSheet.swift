import GitCore
import SwiftUI

/// The confirmation for a force push: one of the two actions in this milestone that can take
/// commits off the server, so the sheet names exactly which ones.
///
/// Both shas are shown in full because both are what git receives: `localTip` is the refspec's
/// source — the commit that is pushed, whatever the branch points at by the time the button is
/// pressed — and `remoteTip` is the lease, so a server branch that moved while this was up is
/// refused by the server itself (`[rejected] (stale info)`). The list is the commits the second
/// has and the first lacks, counted against the sha rather than the branch name, capped at 20
/// by the store with the total beside it.
///
/// Cancel holds `.defaultAction` (Return pushes nothing), Escape closes, and "Force Push"
/// carries the destructive role and no shortcut.
struct ForcePushSheet: View {
    let branch: String
    let localTip: String
    let remote: String
    let remoteRef: String
    let remoteTip: String
    let discarded: [Commit]
    let total: Int

    @Environment(RepositoryStore.self) private var store

    /// The branch's name on the server: the remote ref without `refs/heads/`.
    private var remoteName: String {
        remoteRef.hasPrefix("refs/heads/")
            ? String(remoteRef.dropFirst("refs/heads/".count)) : remoteRef
    }

    /// `origin/main` — the remote-tracking ref the lease was read from.
    private var trackingName: String { "\(remote)/\(remoteName)" }

    /// Why this sheet no longer describes the repository, or nil. A courtesy: `confirmForcePush`
    /// refuses a moved branch itself, and the server refuses a moved remote branch.
    private var staleReasons: [String] {
        var reasons: [String] = []
        if store.localBranches.first(where: { $0.name == branch })?.sha != localTip
            || store.currentBranch != branch
        {
            reasons.append(RemoteWording.forcePushSheetBranchMoved(branch))
        }
        if store.remoteBranches.first(where: { $0.name == trackingName })?.sha != remoteTip {
            reasons.append(RemoteWording.forcePushSheetRemoteMoved(trackingName))
        }
        return reasons
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RemoteWording.forcePushTitle(branch: branch, remote: remote, remoteRef: remoteRef))
                .font(.headline)

            Text(RemoteWording.forcePushWarning(total: total, remoteBranch: trackingName))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            sha(RemoteWording.forcePushLocalTipLabel(branch), localTip)
            sha(RemoteWording.forcePushRemoteTipLabel(trackingName), remoteTip)

            commitList

            ForEach(
                staleReasons + [store.sheetBusyReason].compactMap { $0 }, id: \.self
            ) { line in
                Text(line)
                    .font(.caption)
                    // A stale line warns about the destructive button; tinted so it does not
                    // read like the grey busy line that may sit under it.
                    .foregroundStyle(
                        staleReasons.contains(line)
                            ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // No keyboard shortcut on the destructive half: Return belongs to Cancel.
                let act: @MainActor () -> Void = { confirm() }
                Button("Force Push", role: .destructive, action: act)
                    .harnessButton("Force Push", action: act)
                    // The role alone draws an ordinary grey button in a macOS sheet.
                    .foregroundStyle(.red)
                    .disabled(store.sheetBusyReason != nil)
                let cancel: @MainActor () -> Void = { store.activeSheet = nil }
                Button("Cancel", action: cancel)
                    .harnessButton("Cancel", action: cancel)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 540)
        .onExitCommand { store.activeSheet = nil }
    }

    /// A labelled sha, in full, monospaced and selectable: it is what git receives, and the
    /// replaced one is the way back.
    private func sha(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.caption.monospaced())
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    /// Subject, short sha and author of each discarded commit, in a box that grows to eight
    /// rows and then scrolls — with the total in the heading and "and N more" under the box, so
    /// neither the clipping nor the store's cap of 20 can hide how much goes.
    private var commitList: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(RemoteWording.forcePushListHeading(total: total, remote: remote))
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(discarded) { commit in
                        HStack(spacing: 8) {
                            Text(commit.shortSha)
                                .font(.callout.monospaced())
                                .foregroundStyle(.secondary)
                            // Fetched from somebody else: made plain, so a bidi override or a control
                            // character in a subject cannot rearrange the warning.
                            Text(RemoteWording.plain(commit.summary))
                                .font(.callout)
                                .lineLimit(1)
                                .truncationMode(.tail)
                            Spacer(minLength: 8)
                            Text(RemoteWording.plain(commit.authorName))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .textSelection(.enabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: CGFloat(min(max(discarded.count, 1), 8)) * 20)
            if total > discarded.count {
                Text(RemoteWording.andMore(total - discarded.count))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func confirm() {
        guard store.sheetBusyReason == nil else { return }
        // `confirmForcePush` reads this very sheet for both shas and clears it itself.
        store.confirmForcePush()
    }
}
