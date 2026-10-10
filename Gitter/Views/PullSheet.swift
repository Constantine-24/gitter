import GitCore
import SwiftUI

/// A pull whose fetch found both sides with commits of their own: Merge or Rebase.
///
/// Rebase rewrites the user's commits, so neither answer is one keystroke away: Cancel holds
/// `.defaultAction` (Return leaves both branches alone), Escape closes, and the confirming
/// button — titled after the choice — carries no shortcut. The remembered choice is
/// preselected, and Merge when nothing is remembered: it is the answer that rewrites nothing.
///
/// The counts are the store's, read on the tracking **after** the pull's fetch. What confirming
/// checks is in `confirmPull`: the branch must still track the upstream this sheet names, and
/// a busy mutation slot is refused with the sheet left up. The live line below only says the
/// same thing before the click.
struct PullSheet: View {
    let ahead: Int
    let behind: Int
    let upstream: String

    @Environment(RepositoryStore.self) private var store
    /// What the user has picked here, or nil while the sheet still shows the remembered mode —
    /// the same arrangement as `MergeSheet`, so cancelling leaves the remembered mode alone
    /// (the store records it only after the merge or rebase has run).
    @State private var chosen: PullMode?

    private var mode: PullMode { chosen ?? store.rememberedPullMode }

    private var branchName: String { store.currentBranchRef?.name ?? store.headLabel }

    /// Why this sheet no longer describes the repository, or nil — re-read from the store's
    /// snapshot, which the watcher keeps current while the sheet is up.
    private var staleReason: String? {
        guard let branch = store.currentBranchRef, branch.upstream == upstream else {
            return RemoteWording.pullSheetNoLongerApplies(upstream)
        }
        guard branch.tracking == .counts(ahead: ahead, behind: behind) else {
            return RemoteWording.pullSheetCountsChanged(branch.tracking)
        }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RemoteWording.pullSheetTitle(upstream))
                .font(.headline)

            Text(
                RemoteWording.pullSheetSummary(
                    branch: branchName, upstream: upstream, ahead: ahead, behind: behind)
            )
            .font(.callout)
            .fixedSize(horizontal: false, vertical: true)

            Picker(selection: Binding(get: { mode }, set: { chosen = $0 })) {
                option(.merge, RemoteWording.mergeExplanation(ahead: ahead, behind: behind))
                option(.rebase, RemoteWording.rebaseExplanation(ahead: ahead))
            } label: {
                EmptyView()
            }
            .pickerStyle(.radioGroup)

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
                // No shortcut: Return belongs to Cancel, and a rebase rewrites commits.
                let act: @MainActor () -> Void = { confirm() }
                Button(RemoteWording.pullModeTitle(mode), action: act)
                    .harnessButton(RemoteWording.pullModeTitle(mode), action: act)
                    .disabled(store.sheetBusyReason != nil)
                let cancel: @MainActor () -> Void = { store.activeSheet = nil }
                Button("Cancel", action: cancel)
                    .harnessButton("Cancel", action: cancel)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 500)
        // Escape: Cancel already holds `.defaultAction`, and a button carries only one.
        .onExitCommand { store.activeSheet = nil }
    }

    /// One radio option: its title with its own explanation under it, so each answer carries
    /// its own sentence rather than the sheet explaining only the selected one.
    private func option(_ mode: PullMode, _ explanation: String) -> some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(RemoteWording.pullModeTitle(mode))
            Text(explanation)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .tag(mode)
    }

    private func confirm() {
        guard store.sheetBusyReason == nil else { return }
        // `confirmPull` reads this very sheet for the upstream and clears it itself.
        store.confirmPull(mode)
    }
}
