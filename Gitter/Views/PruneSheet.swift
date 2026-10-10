import GitCore
import SwiftUI

/// Prune <remote>…: the remote-tracking refs the server no longer has, each with the id the
/// compare-and-delete names; the commits only they hold, counted once (R5), up to twenty listed;
/// and a "keep a local branch" box for each ref that holds some — ticked for those whose commits
/// no other ticked ref already keeps (carried note 2), with a suggested name checked live.
///
/// The button hands this very plan to `confirmPrune`, which GitCore compares again before it
/// deletes anything. Cancel holds `.defaultAction`, Escape closes, and Prune carries the
/// destructive role and no shortcut.
struct PruneSheet: View {
    let plan: PrunePlan

    @Environment(RepositoryStore.self) private var store
    /// Ref → whether its box is ticked; filled once the defaults are read.
    @State private var ticked: [String: Bool] = [:]
    /// Ref → the branch name typed (or suggested).
    @State private var names: [String: String] = [:]
    /// Ref → what is wrong with its name, for the `keeping` last checked.
    @State private var problems: [String: String] = [:]
    /// The `keeping` the problems above were checked for; Prune waits for it to be current.
    @State private var checked: [String: String]?
    @State private var headTarget: String?
    @State private var loaded = false

    private var holders: [RefTip] {
        plan.stranded.holders.compactMap { ref in plan.refs.first { $0.ref == ref } }
    }

    /// What `confirmPrune` is handed: ticked ref → trimmed name.
    private var keeping: [String: String] {
        KeepBranchList.keeping(holders: holders, ticked: ticked, names: names)
    }

    /// Refs whose tip on screen is not the one the list read: the prune will leave them alone.
    private var changed: Int {
        plan.refs.filter { tip in
            store.remoteBranches.first { $0.name == RemoteAdminWording.shortRef(tip.ref) }?.sha != tip.id
        }.count
    }

    private var blocked: Bool {
        !loaded || checked != keeping || keeping.keys.contains { problems[$0] != nil }
            || store.sheetBusyReason != nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(RemoteAdminWording.pruneSheetTitle(plan.remote))
                .font(.headline)

            Text(RemoteAdminWording.pruneSheetIntro(plan))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            RefIDList(refs: plan.refs, maxRows: Self.maxRows)

            Text(RemoteAdminWording.stranded(plan.stranded))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            if plan.stranded.count > 0 {
                CommitRefList(commits: plan.stranded.commits, maxRows: Self.maxRows)
                if let more = RemoteAdminWording.strandedMore(plan.stranded) {
                    Text(more)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !holders.isEmpty {
                // Capped and scrolling, like the two lists above (Ruling 12): with two dozen
                // holders an uncapped list pushed the title and both buttons off the window.
                KeepBranchList(
                    holders: holders, loaded: loaded, ticked: $ticked, names: $names, problems: problems,
                    checked: checked, maxRows: Self.maxRows)
            }

            ForEach(warnings, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let busy = store.sheetBusyReason {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // No keyboard shortcut on the destructive half: Return belongs to Cancel.
                let act: @MainActor () -> Void = { confirm() }
                Button(RemoteAdminWording.pruneButton, role: .destructive, action: act)
                    .harnessButton(RemoteAdminWording.pruneButton, action: act)
                    // The role alone draws an ordinary grey button in a macOS sheet.
                    .foregroundStyle(.red)
                    .disabled(blocked)
                let cancel: @MainActor () -> Void = { store.activeSheet = nil }
                Button("Cancel", action: cancel)
                    .harnessButton("Cancel", action: cancel)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onExitCommand { store.activeSheet = nil }
        .task {
            let defaults = await store.pruneKeepDefaults(plan)
            names = defaults.names
            ticked = Dictionary(uniqueKeysWithValues: holders.map { ($0.ref, defaults.ticked.contains($0.ref)) })
            headTarget = await store.remoteHEADTarget(plan.remote)
            loaded = true
        }
        // Every change to a box or a name checks the ticked names again (git's own check and
        // two alike); Prune waits until the check is for what is on screen.
        .task(id: loaded ? keeping : nil) {
            guard loaded else { return }
            let asked = keeping
            let found = await store.keepNameProblems(asked)
            guard !Task.isCancelled else { return }
            problems = found
            checked = asked
        }
    }

    /// Rows each list shows before it scrolls: with the header, every section and both buttons
    /// on screen at the default window size (Ruling 12, measured with 24 holders).
    static let maxRows = 4

    private var warnings: [String] {
        var lines: [String] = []
        if let headTarget, RemoteAdminWording.prunesHEADTarget(target: headTarget, refs: plan.refs) {
            lines.append(RemoteAdminWording.danglingHEAD(remote: plan.remote, target: headTarget))
        }
        if changed > 0 { lines.append(RemoteAdminWording.pruneSheetStale(changed: changed)) }
        return lines
    }

    private func confirm() {
        guard !blocked else { return }
        // `confirmPrune` reads this very sheet for the plan and clears it itself.
        store.confirmPrune(plan, keeping: keeping)
    }
}
