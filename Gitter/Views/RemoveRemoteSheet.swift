import GitCore
import SwiftUI

/// Remove… of a remote: everything `RemovalImpact` says the removal deletes, strands and changes
/// — every remote-tracking ref it deletes with the id it holds (the only way back, R7); the
/// commits only they hold, counted once (R5); a "keep a local branch" box for each ref holding
/// some, as the prune sheet has; the branches left with no upstream and the ones whose push
/// silently goes elsewhere (R23); and the refs git leaves behind.
///
/// The button hands this very impact to `confirmRemoveRemote`, which GitCore compares again,
/// whole, before it creates a kept branch or runs git (`.impactChanged`). Cancel holds
/// `.defaultAction`, Escape closes, and Remove carries the destructive role and no shortcut.
/// Long lists scroll inside a capped height, so the title and both buttons stay on screen at the
/// default window size (carried note 8).
struct RemoveRemoteSheet: View {
    let impact: RemovalImpact

    @Environment(RepositoryStore.self) private var store
    /// Ref → whether its box is ticked; filled once the defaults are read.
    @State private var ticked: [String: Bool] = [:]
    /// Ref → the branch name typed (or suggested).
    @State private var names: [String: String] = [:]
    /// Ref → what is wrong with its name, for the `keeping` last checked.
    @State private var problems: [String: String] = [:]
    /// The `keeping` the problems above were checked for; Remove waits for it to be current.
    @State private var checked: [String: String]?
    @State private var loaded = false

    private var holders: [RefTip] {
        impact.stranded.holders.compactMap { ref in impact.refs.first { $0.ref == ref } }
    }

    /// What `confirmRemoveRemote` is handed: ticked ref → trimmed name.
    private var keeping: [String: String] {
        KeepBranchList.keeping(holders: holders, ticked: ticked, names: names)
    }

    private var blocked: Bool {
        !loaded || checked != keeping || keeping.keys.contains { problems[$0] != nil }
            || store.sheetBusyReason != nil
    }

    /// The sentences about what else changes: no upstream, push elsewhere, left behind.
    private var changes: [String] {
        [RemoteAdminWording.removeUpstreams(impact)].compactMap { $0 }
            + RemoteAdminWording.removePushRedirects(impact)
            + [RemoteAdminWording.removeLeftBehind(impact)].compactMap { $0 }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(RemoteAdminWording.removeRemoteSheetTitle(impact.remote))
                .font(.headline)

            Text(RemoteAdminWording.removeIntro(impact))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if !impact.refs.isEmpty {
                RefIDList(refs: impact.refs, maxRows: Self.maxRows)
                Text(RemoteAdminWording.stranded(impact.stranded))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                if impact.stranded.count > 0 {
                    CommitRefList(commits: impact.stranded.commits, maxRows: Self.maxRows)
                    if let more = RemoteAdminWording.strandedMore(impact.stranded) {
                        Text(more)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if !holders.isEmpty {
                KeepBranchList(
                    holders: holders, loaded: loaded, ticked: $ticked, names: $names, problems: problems,
                    checked: checked, maxRows: Self.maxRows)
            }

            if !changes.isEmpty {
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(changes, id: \.self) { line in
                            Text(line)
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: changesHeight)
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
                Button(RemoteAdminWording.removeButton, role: .destructive, action: act)
                    .harnessButton(RemoteAdminWording.removeButton, action: act)
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
            let defaults = await store.removeKeepDefaults(impact)
            names = defaults.names
            ticked = Dictionary(uniqueKeysWithValues: holders.map { ($0.ref, defaults.ticked.contains($0.ref)) })
            loaded = true
        }
        // Every change to a box or a name checks the ticked names again (git's own check and two
        // alike); Remove waits until the check is for what is on screen.
        .task(id: loaded ? keeping : nil) {
            guard loaded else { return }
            let asked = keeping
            let found = await store.keepNameProblems(asked)
            guard !Task.isCancelled else { return }
            problems = found
            checked = asked
        }
    }

    /// Rows each list shows before it scrolls, as in the prune sheet (Ruling 12).
    static let maxRows = 4

    /// The "what else changes" sentences, by an estimate of their wrapped lines (about ninety
    /// characters to a line at this width), at most six lines before they scroll.
    private var changesHeight: CGFloat {
        let lines = changes.reduce(0) { $0 + $1.count / 88 + 1 }
        return CGFloat(min(lines, 6)) * 17 + CGFloat(max(changes.count - 1, 0)) * 4
    }

    private func confirm() {
        guard !blocked else { return }
        // `confirmRemoveRemote` reads this very sheet for the impact and clears it itself.
        store.confirmRemoveRemote(impact, keeping: keeping)
    }
}
