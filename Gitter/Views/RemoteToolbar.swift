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
/// double-click interval of the activity starting (`StopClick.isDeliberate`, capped at 0.6 s); ⌘. and
/// the menu's Stop are deliberate and are not held back. The other two items stay where they
/// are, disabled, with the store's "Wait for … to finish" in their tooltips, and the progress
/// line has a fixed width so a counter ticking from 9% to 10% does not nudge its neighbours.
///
/// **The activity is drawn only once the lane has run for `ActivityReveal.delay`** (0.4 s); the
/// button is disabled at once. A lane that ends sooner — a fetch with nothing to download, as a
/// retried pull's usually is — never resizes the toolbar. Growing the item by ~240 points and
/// shrinking it again inside AppKit's own animation of the toolbar's glass groups made its layout
/// alternate by 1e-11 points on every pass, each pass re-invalidating the SwiftUI hosting view,
/// until AppKit threw "more Update Constraints in Window passes than there are views in the
/// window" (the A1 toolbar crash; `ActivityReveal`).
///
/// **The automatic fetch is the exception.** It shows on Fetch like a fetch — Stop, spinner and
/// "Fetching automatically…", never git's counters — so a user can see why the network is busy,
/// but it blocks nothing: all three buttons, Fetch's own included, stay enabled, and using one
/// stops the automatic fetch and goes ahead (`RepositoryStore.beginRemote`).
///
/// Every reason comes from the store (`fetchBlockedReason` and its two siblings) through
/// `disabled(_:help:)`, the only way a disabled control keeps its tooltip.
struct RemoteToolbarItem: View {
    enum Action {
        case fetch, pull, push
    }

    let action: Action

    @Environment(RepositoryStore.self) private var store

    /// The `startedAt` of the lane this item has waited `ActivityReveal.delay` for — view state,
    /// not the store's: it only decides when the activity is drawn.
    @State private var revealed: Date?

    var body: some View {
        let owned = store.remoteActivity.flatMap { Self.owner(of: $0.kind) == action ? $0 : nil }
        Group {
            if let activity = owned,
                ActivityReveal.shows(laneStartedAt: activity.startedAt, revealed: revealed)
            {
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
        // Restarted by every new lane, and cancelled by its end: a lane shorter than the delay
        // never reveals anything.
        .task(id: owned?.startedAt) {
            guard let started = owned?.startedAt else { return }
            try? await Task.sleep(for: ActivityReveal.delay)
            guard !Task.isCancelled else { return }
            revealed = started
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
/// The line is `RemoteWording.progressLine`: what is running ("Fetching…"), then git's latest
/// segment, which the store has already made plain (no escapes, credentials redacted, one capped
/// line) — so a `remote: Total 3 (delta 0) … done.` segment never reads as though the whole
/// action were done. Until git prints one — and for the whole of a deletion, which prints none —
/// it is just what is running, remote included. The tooltip and VoiceOver get the long form
/// (`progressHelp`), remote and all.
private struct RemoteActivityItem: View {
    let activity: RemoteActivity

    @Environment(RepositoryStore.self) private var store

    /// Fixed, so the toolbar does not move as the counter redraws, and cut at its **tail**: a
    /// middle cut ate the percentage, the one number worth reading, where a tail cut loses only
    /// the byte counts and the rate.
    ///
    /// **The width is what the default 1200-point window allows.** Measured with the `views`
    /// step (Task 9, fix round 2) at 1200 with the longest labels ("Pull ↓12", "Push ↑12"): the
    /// three network items have the toolbar from x≈670 to 1191, so the active item — Stop,
    /// spinner, this line and the item's own button — may be about 320 points with the Fetch
    /// button (fix round 1's 360-point line made it 485–506 and pushed a pull's or a push's own
    /// Stop into the overflow menu). 196 points at the subheadline size holds "Fetching…
    /// Receiving objects: 100%" plus the truncation mark (measured 187 + 8).
    static let progressWidth: CGFloat = 196

    private var line: String { RemoteWording.progressLine(activity) }

    var body: some View {
        HStack(spacing: 4) {
            Button(action: stop) {
                Image(systemName: "xmark.circle")
            }
            .buttonStyle(.borderless)
            .help("Stop \(RemoteWording.describe(activity))")
            .accessibilityLabel("Stop \(RemoteWording.describe(activity))")
            ProgressView()
                .controlSize(.small)
            Text(line)
                .font(.subheadline)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: Self.progressWidth, alignment: .leading)
                .help(RemoteWording.progressHelp(activity))
                .accessibilityLabel(RemoteWording.progressHelp(activity))
        }
        .accessibilityElement(children: .contain)
    }

    /// A click on Stop that arrives within the double-click interval of the activity starting
    /// is the tail of the click that started it, not a decision to stop; it is dropped. ⌘. and
    /// the menu go straight to `cancelRemoteActivity()` and are never held back.
    private func stop() {
        guard StopClick.isDeliberate(
            startedAt: activity.startedAt, now: .now,
            doubleClickInterval: NSEvent.doubleClickInterval)
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

/// When a network item draws its lane's activity: once that same lane has run for `delay`.
///
/// The item waits `delay` after its lane starts and then records the lane's `startedAt` as
/// `revealed`; the activity shows only while the running lane is that one. A lane shorter than
/// `delay` therefore never changes the toolbar's size, and a reveal left over from an earlier lane
/// never shows the next one early.
///
/// `delay` is longer than AppKit's animation of the toolbar's glass groups (measured at about
/// 0.3 s), so a short lane can no longer grow the item and shrink it again inside that animation —
/// the pattern behind the constraint-loop crash. It is shorter than the default double-click
/// interval (0.5 s), during which Stop ignores a click anyway (`StopClick.isDeliberate`); ⌘. and
/// the menu's Stop work from the lane's first moment.
enum ActivityReveal {
    static let delay: Duration = .milliseconds(400)

    static func shows(laneStartedAt: Date?, revealed: Date?) -> Bool {
        guard let laneStartedAt else { return false }
        return revealed == laneStartedAt
    }
}
