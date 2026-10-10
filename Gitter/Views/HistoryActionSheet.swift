import GitCore
import SwiftUI

/// Cherry-Pick / Revert N Commits…: the plan GitCore made — the commits in the order git gets
/// them, the ones left out as already on the branch, the ones that may be skipped as already
/// applied, and what happens if git stops part-way.
///
/// The button hands this very plan to `confirmHistoryAction`, which GitCore makes again and
/// refuses on any difference. Cancel holds `.defaultAction` and Escape closes; the action
/// button has no shortcut.
struct HistoryActionSheet: View {
    let plan: HistoryPlan

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(HistoryWording.sheetTitle(plan))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(HistoryWording.sheetOrder(plan))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            CommitRefList(commits: plan.commits)

            ForEach(
                [HistoryWording.leftOut(plan), HistoryWording.mayDrop(plan)].compactMap { $0 },
                id: \.self
            ) { line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(HistoryWording.onStop)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let busy = store.sheetBusyReason {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                let act: @MainActor () -> Void = { store.confirmHistoryAction(plan) }
                Button(HistoryWording.confirmButton(plan.action), action: act)
                    .harnessButton(HistoryWording.confirmButton(plan.action), action: act)
                    .disabled(store.sheetBusyReason != nil)
                let cancel: @MainActor () -> Void = { store.activeSheet = nil }
                Button("Cancel", action: cancel)
                    .harnessButton("Cancel", action: cancel)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onExitCommand { store.activeSheet = nil }
    }
}

/// The commits a history sheet names, one per row — short sha and subject — in a box that grows
/// to eight rows and then scrolls. The sheet's own sentence says how many there are.
struct CommitRefList: View {
    let commits: [CommitRef]
    /// Rows shown before the list scrolls (the prune sheet shows fewer, Ruling 12).
    var maxRows = 8

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(commits, id: \.sha) { commit in
                    HStack(spacing: 8) {
                        Text(commit.sha.prefix(7))
                            .font(.callout.monospaced())
                            .foregroundStyle(.secondary)
                        // Somebody else's text: made plain, so a bidi override or a control
                        // character in a subject cannot rearrange the list.
                        Text(RemoteWording.plain(commit.subject))
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.tail)
                        Spacer(minLength: 0)
                    }
                    .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: CGFloat(min(max(commits.count, 1), maxRows)) * 20)
    }
}
