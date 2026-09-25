import GitCore
import SwiftUI

/// One of the three network items in the toolbar — Fetch, Pull `↓n`, Push `↑n` (or "Publish",
/// "Re-publish") — each drawn by its own `ToolbarItem` so the toolbar can lay them out and
/// overflow them like any other item.
///
/// **While the network lane is busy, the item that started it becomes the activity:** a
/// spinner, git's latest progress line and a stop button. The other two stay where they are,
/// disabled, with the store's "Wait for … to finish" in their tooltips — the toolbar never
/// rearranges itself under the pointer, and the progress line has a fixed width so a counter
/// ticking from 9% to 10% does not nudge its neighbours.
///
/// Every reason comes from the store (`fetchBlockedReason` and its two siblings) through
/// `disabled(_:help:)`, the only way a disabled control keeps its tooltip.
struct RemoteToolbarItem: View {
    enum Action {
        case fetch, pull, push
    }

    let action: Action

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if let activity = store.remoteActivity, Self.owner(of: activity.kind) == action {
            RemoteActivityItem(activity: activity)
        } else {
            button
        }
    }

    /// The item that shows a lane's progress and stop button. Every kind has one, so the stop
    /// button is always somewhere: a force push and a deletion on the remote are writes to the
    /// server, like a push, so they show on Push; the automatic fetch shows on Fetch.
    static func owner(of kind: RemoteActivity.Kind) -> Action {
        switch kind {
        case .fetch, .autoFetch: .fetch
        case .pull: .pull
        case .push, .publish, .forcePush, .deleteRemoteBranch: .push
        }
    }

    private var button: some View {
        Button(action: perform) {
            Label {
                Text(title).monospacedDigit()
            } icon: {
                icon
            }
            .labelStyle(.titleAndIcon)
        }
        .accessibilityLabel(accessibilityTitle)
        .disabled(blockedReason != nil, help: blockedReason ?? help)
    }

    private func perform() {
        switch action {
        case .fetch: store.fetch()
        case .pull: store.pull()
        case .push: store.push()
        }
    }

    private var blockedReason: String? {
        switch action {
        case .fetch: store.fetchBlockedReason
        case .pull: store.pullBlockedReason
        case .push: store.pushBlockedReason
        }
    }

    // MARK: - What it says

    private var tracking: Tracking { store.currentTracking }
    private var tracksLocalBranch: Bool { store.currentBranchRef?.tracksLocalBranch ?? false }

    /// "Pull ↓2" when behind; "Push ↑1" when ahead. The Push count is only drawn beside "Push":
    /// a branch that publishes has no push remote, so an ahead count — which is against its
    /// upstream, possibly a local branch — says nothing about what a publish would send.
    private var title: String {
        switch action {
        case .fetch:
            return "Fetch"
        case .pull:
            guard case .counts(_, let behind) = tracking, behind > 0 else { return "Pull" }
            return "Pull \(tracksLocalBranch ? "⇣" : "↓")\(behind)"
        case .push:
            let title = store.pushButtonTitle
            guard title == "Push", !tracksLocalBranch, case .counts(let ahead, _) = tracking,
                ahead > 0
            else { return title }
            return "\(title) ↑\(ahead)"
        }
    }

    /// The title in words, since "↓2" is read out as "down arrow 2".
    private var accessibilityTitle: String {
        switch action {
        case .fetch: return "Fetch"
        case .pull:
            guard case .counts(_, let behind) = tracking, behind > 0 else { return "Pull" }
            return "Pull, \(behind) behind"
        case .push:
            let title = store.pushButtonTitle
            guard title == "Push", !tracksLocalBranch, case .counts(let ahead, _) = tracking,
                ahead > 0
            else { return title }
            return "\(title), \(ahead) ahead"
        }
    }

    private var help: String {
        switch action {
        case .fetch:
            store.lastAutoFetchFailure.map(RemoteWording.autoFetchFailedHelp)
                ?? RemoteWording.fetchHelp
        case .pull: RemoteWording.pullHelp(store.currentBranchRef)
        case .push:
            RemoteWording.pushHelp(title: store.pushButtonTitle, branch: store.currentBranchRef)
        }
    }

    @ViewBuilder
    private var icon: some View {
        switch action {
        case .fetch:
            Image(systemName: "arrow.triangle.2.circlepath")
                // A failed *automatic* fetch is quiet — being offline is normal — so it gets a
                // dimmed mark and a tooltip, never a banner.
                .overlay(alignment: .bottomTrailing) {
                    if store.lastAutoFetchFailure != nil {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 7, weight: .bold))
                            .foregroundStyle(.secondary)
                            .offset(x: 4, y: 3)
                            .accessibilityLabel("The last automatic fetch failed")
                    }
                }
        case .pull: Image(systemName: "arrow.down")
        case .push: Image(systemName: "arrow.up")
        }
    }
}

/// The active network item: spinner, git's latest progress line, and Stop.
///
/// The line is `RemoteActivity.progress`, which the store has already made plain (no escapes,
/// credentials redacted, one capped line); until git prints one — and for the whole of a
/// deletion, which prints none — it says what is running.
private struct RemoteActivityItem: View {
    let activity: RemoteActivity

    @Environment(RepositoryStore.self) private var store

    /// Wide enough for a whole "Receiving objects:  44% (4/9), 67.98 KiB | 18.00 KiB/s" —
    /// measured: at 220 points the middle truncation ate the percentage, the one number worth
    /// reading — and fixed, so the toolbar does not move as the counter redraws.
    static let progressWidth: CGFloat = 330

    private var line: String {
        activity.progress ?? RemoteWording.inProgressTitle(activity)
    }

    var body: some View {
        HStack(spacing: 6) {
            ProgressView()
                .controlSize(.small)
            Text(line)
                .font(.callout)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
                .frame(width: Self.progressWidth, alignment: .leading)
                .help(line)
                .accessibilityLabel("\(RemoteWording.inProgressTitle(activity)) \(activity.progress ?? "")")
            Button {
                store.cancelRemoteActivity()
            } label: {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop \(RemoteWording.describe(activity))")
            .accessibilityLabel("Stop \(RemoteWording.describe(activity))")
        }
        .padding(.horizontal, 6)
        .accessibilityElement(children: .contain)
    }
}
