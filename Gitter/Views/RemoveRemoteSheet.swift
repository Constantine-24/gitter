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
        var result: [String: String] = [:]
        for tip in holders where ticked[tip.ref] == true {
            result[tip.ref] = (names[tip.ref] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
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
                refList
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
                Text(RemoteAdminWording.keepHeading)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                keepControls
                ScrollView {
                    Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                        ForEach(holders, id: \.ref) { tip in keepRow(tip) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: keepListHeight)
                if let summary = RemoteAdminWording.keepProblemsSummary(problemCount) {
                    Text(summary)
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
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
                Button(RemoteAdminWording.removeButton, role: .destructive) { confirm() }
                    // The role alone draws an ordinary grey button in a macOS sheet.
                    .foregroundStyle(.red)
                    .disabled(blocked)
                Button("Cancel") { store.activeSheet = nil }
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
            var found: [String: String] = [:]
            for (ref, name) in asked {
                let duplicate = asked.contains { $0.key != ref && $0.value.lowercased() == name.lowercased() }
                if let problem = await store.keepNameProblem(name, duplicate: duplicate) { found[ref] = problem }
            }
            guard !Task.isCancelled else { return }
            problems = found
            checked = asked
        }
    }

    /// The refs, each with the full id the notice names afterwards.
    private var refList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(impact.refs, id: \.ref) { tip in
                    HStack(spacing: 8) {
                        Text(RemoteAdminWording.shortRef(tip.ref))
                            .font(.callout)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(tip.id)
                            .font(.caption.monospaced())
                            .foregroundStyle(.secondary)
                    }
                    .textSelection(.enabled)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(height: CGFloat(min(max(impact.refs.count, 1), Self.maxRows)) * 20)
    }

    /// Rows each list shows before it scrolls, as in the prune sheet (Ruling 12).
    static let maxRows = 4

    private var keepListHeight: CGFloat {
        let rows = CGFloat(min(holders.count, Self.maxRows)) * 30
        let shownProblems = holders.prefix(Self.maxRows).filter { visibleProblem($0) != nil }.count
        return rows + CGFloat(shownProblems) * 18
    }

    /// The "what else changes" sentences, by an estimate of their wrapped lines (about ninety
    /// characters to a line at this width), at most six lines before they scroll.
    private var changesHeight: CGFloat {
        let lines = changes.reduce(0) { $0 + $1.count / 88 + 1 }
        return CGFloat(min(lines, 6)) * 17 + CGFloat(max(changes.count - 1, 0)) * 4
    }

    private var problemCount: Int { holders.filter { visibleProblem($0) != nil }.count }

    private func visibleProblem(_ tip: RefTip) -> String? {
        guard ticked[tip.ref] == true, checked == keeping else { return nil }
        return problems[tip.ref]
    }

    private var keepControls: some View {
        let refs = holders.map(\.ref)
        let offers = RemoteAdminWording.keepAllOffers(refs, ticked: ticked)
        return HStack(spacing: 8) {
            Text(RemoteAdminWording.keepCount(refs, ticked: ticked))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            Button(RemoteAdminWording.keepAllTitle) { ticked = RemoteAdminWording.ticking(refs, all: true) }
                .disabled(!loaded || !offers.all)
            Button(RemoteAdminWording.keepNoneTitle) { ticked = RemoteAdminWording.ticking(refs, all: false) }
                .disabled(!loaded || !offers.none)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func keepRow(_ tip: RefTip) -> some View {
        GridRow {
            Toggle(
                RemoteAdminWording.keepLabel(tip.ref),
                isOn: Binding(get: { ticked[tip.ref] ?? false }, set: { ticked[tip.ref] = $0 }))
            TextField("", text: Binding(get: { names[tip.ref] ?? "" }, set: { names[tip.ref] = $0 }))
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .disabled(ticked[tip.ref] != true)
        }
        if let problem = visibleProblem(tip) {
            GridRow {
                Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private func confirm() {
        guard !blocked else { return }
        // `confirmRemoveRemote` reads this very sheet for the impact and clears it itself.
        store.confirmRemoveRemote(impact, keeping: keeping)
    }
}
