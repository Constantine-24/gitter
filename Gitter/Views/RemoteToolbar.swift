import AppKit
import GitCore
import SwiftUI

/// One of the three network items in the toolbar — Fetch, Pull `↓n`, Push `↑n` (or "Publish",
/// "Re-publish") — each drawn by its own `ToolbarItem` so the toolbar can lay them out and
/// overflow them like any other item.
///
/// **While the network lane is busy, the item that started it grows the activity to its
/// left:** `[Stop] spinner progress-line [its own button, disabled]`. The button stays exactly
/// where it was — the item keeps its trailing edge and grows leftward — so what is under the
/// pointer after a click is the same button, now disabled, and never Stop. (Task 9's review
/// reproduced the alternative: with Stop at the trailing edge it landed exactly where the
/// clicked label had been, and a double-click on Fetch cancelled the fetch it had started.)
/// Stop is at the far, leading end, and additionally ignores a click that arrives within the
/// double-click interval of the activity starting (`RemoteActivity.acceptsStopClick`); ⌘. and
/// the menu's Stop are deliberate and are not held back. The other two items stay where they
/// are, disabled, with the store's "Wait for … to finish" in their tooltips, and the progress
/// line has a fixed width so a counter ticking from 9% to 10% does not nudge its neighbours.
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
            HStack(spacing: 2) {
                RemoteActivityItem(activity: activity)
                // Disabled by the lane-busy reason like the other two, and in the same place
                // it was: a second click of a double-click lands here and does nothing.
                button
            }
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

    /// "Pull ↓2" when behind; "Push ↑1" when a push would send that many. Both counts are the
    /// store's (`pullBehindCount`, `pushAheadCount`), which decide when a count is true — never
    /// beside Publish or Re-publish, a triangular branch's Push, or a refused target.
    private var title: String {
        switch action {
        case .fetch:
            return "Fetch"
        case .pull:
            return store.pullBehindCount.map { "Pull ↓\($0)" } ?? "Pull"
        case .push:
            let title = store.pushButtonTitle
            return store.pushAheadCount.map { "\(title) ↑\($0)" } ?? title
        }
    }

    /// The title in words, since "↓2" is read out as "down arrow 2". The Fetch item's label
    /// replaces its icon's, so the quiet failure mark is said here too.
    private var accessibilityTitle: String {
        switch action {
        case .fetch:
            return store.lastAutoFetchFailure == nil
                ? "Fetch" : "Fetch, the last automatic fetch failed"
        case .pull:
            return store.pullBehindCount.map { "Pull, \($0) behind" } ?? "Pull"
        case .push:
            let title = store.pushButtonTitle
            return store.pushAheadCount.map { "\(title), \($0) ahead" } ?? title
        }
    }

    private var help: String {
        switch action {
        case .fetch:
            store.lastAutoFetchFailure.map(RemoteWording.autoFetchFailedHelp)
                ?? RemoteWording.fetchHelp
        case .pull: RemoteWording.pullHelp(store.currentBranchRef)
        case .push: store.pushHelp
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
                        // No label of its own: the button's `accessibilityTitle` replaces its
                        // icon's, so the failure is said there.
                    }
                }
        case .pull: Image(systemName: "arrow.down")
        case .push: Image(systemName: "arrow.up")
        }
    }
}

/// The active network item's own part: Stop, spinner and git's latest progress line, with
/// Stop at the leading end, as far as it can be from the button the user just clicked.
///
/// The line is `RemoteWording.progressLine`: what is running, then git's latest segment, which
/// the store has already made plain (no escapes, credentials redacted, one capped line) — so a
/// `remote: Total 3 (delta 0) … done.` segment never reads as though the whole action were done.
/// Until git prints one — and for the whole of a deletion, which prints none — it is just what
/// is running.
private struct RemoteActivityItem: View {
    let activity: RemoteActivity

    @Environment(RepositoryStore.self) private var store

    /// Fixed, so the toolbar does not move as the counter redraws. With the "Fetching — "
    /// prefix the line is cut at its **tail**: measured, at 360 points a middle cut of
    /// "Fetching — Receiving objects:  50% (3/6), 3.50 MiB | 839.00 KiB/s" ate the percentage,
    /// the one number worth reading, while a tail cut loses only the transfer rate.
    static let progressWidth: CGFloat = 360

    private var line: String { RemoteWording.progressLine(activity) }

    var body: some View {
        HStack(spacing: 6) {
            Button(action: stop) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop \(RemoteWording.describe(activity))")
            .accessibilityLabel("Stop \(RemoteWording.describe(activity))")
            ProgressView()
                .controlSize(.small)
            Text(line)
                .font(.callout)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.progressWidth, alignment: .leading)
                .help(line)
                .accessibilityLabel(line)
        }
        .padding(.leading, 6)
        .accessibilityElement(children: .contain)
    }

    /// A click on Stop that arrives within the double-click interval of the activity starting
    /// is the tail of the click that started it, not a decision to stop; it is dropped. ⌘. and
    /// the menu go straight to `cancelRemoteActivity()` and are never held back.
    private func stop() {
        guard activity.acceptsStopClick(at: .now, doubleClickInterval: NSEvent.doubleClickInterval)
        else {
            #if DEBUG
                FileHandle.standardError.write(
                    Data("BRANCH_ACTION stop click ignored: within the double-click interval\n".utf8))
            #endif
            return
        }
        store.cancelRemoteActivity()
    }
}
