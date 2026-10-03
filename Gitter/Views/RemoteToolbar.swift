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
/// **The activity is drawn only once the lane has run for `ActivityReveal.delay`** (0.4 s), and
/// once drawn it stays for at least that long, even after the lane ends; the button is disabled
/// at once. A lane that ends sooner, like a fetch with nothing to download, never resizes the
/// toolbar, and no lane shrinks the item within 0.4 s of growing it. Growing the item by ~240 points and
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

    /// When this item revealed its lane's activity, and for which lane: view state, not the
    /// store's, since it only decides what is drawn (`ActivityReveal`).
    @State private var revealed: ActivityReveal.Revealed?
    /// The last activity drawn, kept so it can stay on screen after its lane has ended.
    @State private var lastShown: RemoteActivity?

    private var owned: RemoteActivity? {
        store.remoteActivity.flatMap { Self.owner(of: $0.kind) == action ? $0 : nil }
    }

    private var lane: ActivityReveal.Lane? {
        store.remoteActivity.map {
            ActivityReveal.Lane(startedAt: $0.startedAt, owner: Self.owner(of: $0.kind))
        }
    }

    var body: some View {
        let step = ActivityReveal.step(lane: lane, item: action, revealed: revealed, now: .now)
        let drawn: RemoteActivity? =
            switch step.drawn {
            case .button: nil
            case .lane: owned
            case .lingering: lastShown
            }
        Group {
            if let activity = drawn {
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
        .onChange(of: owned, initial: true) { _, activity in
            if let activity { lastShown = activity }
        }
        // Run again whenever the lane or the reveal changes: it applies the step's new reveal,
        // or sleeps until the moment the step names (the delay is up, or the minimum is over).
        .task(id: TaskKey(lane: lane, revealed: revealed)) {
            let now = Date.now
            let current = ActivityReveal.step(lane: lane, item: action, revealed: revealed, now: now)
            if current.revealed != revealed {
                revealed = current.revealed
                return
            }
            guard let wakeAt = current.wakeAt else { return }
            try? await Task.sleep(for: .seconds(max(0, wakeAt.timeIntervalSince(now))))
            guard !Task.isCancelled else { return }
            revealed =
                ActivityReveal.step(lane: lane, item: action, revealed: revealed, now: .now)
                .revealed
        }
    }

    private struct TaskKey: Equatable {
        let lane: ActivityReveal.Lane?
        let revealed: ActivityReveal.Revealed?
    }

    /// The item that shows a lane's progress and stop button. Every kind has one, so the stop
    /// button is always somewhere: a force push, a deletion on the remote and a tag's push or
    /// remote delete are writes to the server, like a push, so they show on Push; the automatic
    /// fetch shows on Fetch.
    static func owner(of kind: RemoteActivity.Kind) -> Action {
        switch kind {
        // A prune lists with a fetch; a fast-forward fetches and then moves a branch, as a pull.
        case .fetch, .autoFetch, .prune: .fetch
        case .pull, .fastForward: .pull
        case .push, .publish, .forcePush, .deleteRemoteBranch, .pushTag, .deleteRemoteTag: .push
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
        // Drawn after its lane has ended (`ActivityReveal`'s minimum): nothing of its own to
        // stop, and the lane running now may be another item's.
        guard
            ActivityReveal.stopActs(
                shownLane: activity.startedAt, runningLane: store.remoteActivity?.startedAt)
        else { return }
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

/// When a network item draws its lane's activity (Stop, spinner, progress line).
///
/// What the design guarantees, by construction:
/// - **Late:** an item draws a lane's activity only once that lane has run for `delay`. A lane
///   that ends sooner never changes the toolbar's size at all.
/// - **Held:** once drawn, the activity stays for at least `delay`, even past its lane's end (the
///   last one drawn stays, and its Stop does nothing: `stopActs`). So every growth of an item is
///   followed by at least `delay` without a shrink, whatever the lane's length.
/// - **Carried over:** a new lane of the same item that starts while the activity is still drawn
///   (Fetch pressed during a revealed automatic fetch) keeps it drawn, with no shrink and regrow.
///   A lane of another item waits its own `delay`.
///
/// `delay` is longer than AppKit's animation of the toolbar's glass groups (about 0.3 s, measured
/// with a frame probe). So no item grows and shrinks again inside one animation, which is the
/// pattern that made AppKit's layout loop until it threw ("more Update Constraints in Window passes
/// than there are views in the window", A1 inserted fix 6). It is not a guarantee about two
/// *different* items changing within one animation; that is the BACKLOG's residual. It is shorter
/// than the default double-click interval (0.5 s), during which Stop ignores a click anyway
/// (`StopClick.isDeliberate`); ⌘. and the menu's Stop work from the lane's first moment.
enum ActivityReveal {
    static let delay: Duration = .milliseconds(400)
    static var delaySeconds: TimeInterval {
        let parts = delay.components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }

    /// The lane running now, and the item that shows it.
    struct Lane: Equatable {
        let startedAt: Date
        let owner: RemoteToolbarItem.Action
    }

    /// An item's reveal: the lane it is drawing (the latest, after a carry-over) and when the
    /// activity first appeared.
    struct Revealed: Equatable {
        var lane: Date
        var at: Date
    }

    enum Drawn: Equatable {
        /// Only the item's own button.
        case button
        /// The running lane's activity.
        case lane
        /// The last activity drawn, after its lane has ended, until the minimum is over.
        case lingering
    }

    /// What `item` draws at `now`, the reveal it should hold from now on, and when to look again
    /// (nil: only when the lane or the reveal changes).
    struct Step: Equatable {
        let revealed: Revealed?
        let drawn: Drawn
        let wakeAt: Date?
    }

    static func step(lane: Lane?, item: RemoteToolbarItem.Action, revealed: Revealed?, now: Date)
        -> Step
    {
        if let lane, lane.owner == item {
            if var revealed {
                // Revealed already: this lane, or a new one of the same item with no gap.
                revealed.lane = lane.startedAt
                return Step(revealed: revealed, drawn: .lane, wakeAt: nil)
            }
            let due = lane.startedAt.addingTimeInterval(delaySeconds)
            if now >= due {
                return Step(
                    revealed: Revealed(lane: lane.startedAt, at: now), drawn: .lane, wakeAt: nil)
            }
            return Step(revealed: nil, drawn: .button, wakeAt: due)
        }
        // No lane of this item: hold what was drawn until the minimum is over.
        if let revealed {
            let until = revealed.at.addingTimeInterval(delaySeconds)
            if now < until {
                return Step(revealed: revealed, drawn: .lingering, wakeAt: until)
            }
        }
        return Step(revealed: nil, drawn: .button, wakeAt: nil)
    }

    /// Whether Stop, drawn for the lane that started at `shownLane`, may stop anything: only
    /// while that lane is the one running.
    static func stopActs(shownLane: Date, runningLane: Date?) -> Bool {
        shownLane == runningLane
    }
}
