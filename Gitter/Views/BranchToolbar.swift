import GitCore
import SwiftUI

/// The toolbar's branch menu: what HEAD is, and the local branches to switch to.
///
/// The label is the one place the window says where HEAD is, so a detached HEAD says so in
/// words ("detached at 1a2b3c4"), in orange, and under a different glyph — three signals, since
/// colour alone is not one everybody gets.
///
/// Mid-operation the *switch* items are disabled and the reason is spelled out at the top of the
/// menu; "New Branch…" is not, because creating a branch without switching writes one ref and
/// touches neither the worktree nor the index (see `RepositoryStore.createBranch`).
struct BranchMenu: View {
    @Environment(RepositoryStore.self) private var store

    private var blockedReason: String? { store.branchSwitchingBlockedReason }

    var body: some View {
        Menu {
            // The reason, as a disabled item rather than only as a tooltip: a disabled menu
            // item shows no tooltip of its own, and "why is this grey?" should not need a hover.
            // `MenuReasons` is the sidebar menus' version of exactly this, divider and all.
            MenuReasons(reasons: [blockedReason])
            Section {
                // A picker, not a row of buttons: an inline picker in a macOS menu is what puts
                // the checkmark against the branch HEAD is on, and picking another is the
                // switch. A detached HEAD selects nothing, so no branch is ticked.
                Picker(selection: switchSelection) {
                    ForEach(store.localBranches) { branch in
                        Text(branch.name).tag(branch.name as String?)
                    }
                } label: {
                    EmptyView()
                }
                .pickerStyle(.inline)
            }
            .disabled(blockedReason != nil)

            Divider()

            // The reason beside the item, as the sidebar menus show theirs.
            if let reason = store.changeRunningBlockedReason { Text(reason) }
            Button("New Branch…") { store.requestNewBranch() }
                .disabled(store.changeRunningBlockedReason != nil)
        } label: {
            Label {
                // The badge rides in the label, so it is where the eye already is for "which
                // branch am I on" — and says nothing at all when the branch is level.
                HStack(spacing: 6) {
                    Text(store.headLabel)
                    if let branch = store.currentBranchRef {
                        TrackingBadge(
                            tracking: branch.tracking, tracksLocalBranch: branch.tracksLocalBranch,
                            upstream: branch.upstream)
                    }
                }
            } icon: {
                Image(systemName: store.isDetached ? "circle.dashed" : "arrow.triangle.branch")
            }
            // Both halves, always: a toolbar item shows its icon alone by default, and the
            // branch's *name* is the whole point of this control.
            .labelStyle(.titleAndIcon)
            .foregroundStyle(store.isDetached ? AnyShapeStyle(.orange) : AnyShapeStyle(.primary))
        }
        .menuStyle(.button)
        .fixedSize()
        // On the menu itself, which stays enabled for "New Branch…": `disabled(_:help:)` is for
        // a control that is off, and this one is not.
        .helpIfPresent(blockedReason ?? "Current branch: \(store.headLabel)")
    }

    /// Where HEAD is, for the checkmark; picking anything else switches to it.
    ///
    /// The only pick dropped here is a re-pick of the branch that is already ticked, which is
    /// not a switch at all. A pick that arrives while switching is blocked — the menu was opened
    /// before a terminal started a merge — goes to `switchTo` like any other: `perform` refuses
    /// it through `mutate`, which raises `BranchActionBlocked`'s sentence in the sticky banner.
    /// Dropping it here instead would be a click that does nothing and says nothing. The
    /// disabled section above is still the primary defence; this is what happens when it is a
    /// moment out of date.
    private var switchSelection: Binding<String?> {
        Binding(
            get: { store.currentBranch },
            set: { picked in
                guard let picked, picked != store.currentBranch else { return }
                store.switchTo(branch: picked)
            })
    }
}

/// "New Branch…", from wherever HEAD is. Available through an operation in progress: it is also
/// the way out of a detached HEAD, and the one branch action an operation does not stand in the
/// way of. Off only while a change runs (`changeRunningBlockedReason`).
struct NewBranchButton: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        Button {
            store.requestNewBranch()
        } label: {
            Label("New Branch…", systemImage: "plus")
        }
        .labelStyle(.titleAndIcon)
        .disabled(store.changeRunningBlockedReason != nil)
        .help(store.changeRunningBlockedReason ?? "Create a branch from \(store.headLabel)")
    }
}
