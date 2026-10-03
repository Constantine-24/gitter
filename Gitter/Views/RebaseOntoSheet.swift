import GitCore
import SwiftUI

/// Rebase … onto …: the plan GitCore made — the commits replayed, the merges flattened, the
/// commits skipped as already applied, and a warning when some of what is rewritten is already on
/// a remote.
///
/// The button hands this very plan to `confirmRebaseOnto`, which GitCore makes again and refuses
/// on any difference (a moved target, a fetch that changed the pushed count). Rewriting history
/// is the destructive kind: red, no shortcut; Cancel holds `.defaultAction`.
struct RebaseOntoSheet: View {
    let plan: RebasePlan

    @Environment(RepositoryStore.self) private var store
    /// How many commits the target has that HEAD lacks — only asked when nothing is replayed,
    /// where it tells "already contains" from a fast-forward. Shown, never acted on.
    @State private var incoming: Int?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(HistoryWording.rebaseTitle(plan))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(HistoryWording.rebaseSummary(plan, incoming: incoming))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if !plan.replayed.isEmpty { CommitRefList(commits: plan.replayed) }

            ForEach(
                [HistoryWording.flattened(plan.flattenedMerges), HistoryWording.skipped(plan.skippedAsApplied, plan)]
                    .compactMap { $0 },
                id: \.self
            ) { line in
                Text(line)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let pushed = HistoryWording.alreadyPushed(plan.alreadyPushed) {
                Label(pushed, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(HistoryWording.rebaseOnStop(plan))
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
                Button(HistoryWording.rebaseButton, role: .destructive) { store.confirmRebaseOnto(plan) }
                    // The role alone draws an ordinary grey button in a macOS sheet.
                    .foregroundStyle(.red)
                    .disabled(store.sheetBusyReason != nil)
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onExitCommand { store.activeSheet = nil }
        .task {
            // Cancelled with the sheet; a repository swap closes it (`open()` clears
            // `activeSheet`). Counted against the plan's own commits, not the names.
            guard plan.replayed.isEmpty, plan.flattenedMerges == 0, plan.skippedAsApplied == 0,
                plan.head != plan.target
            else { return }
            incoming = await store.commitsOnlyIn(plan.target, notIn: plan.head)
        }
    }
}
