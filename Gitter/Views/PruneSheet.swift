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
        var result: [String: String] = [:]
        for tip in holders where ticked[tip.ref] == true {
            result[tip.ref] = (names[tip.ref] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
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
            refList

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
                Text(RemoteAdminWording.keepHeading)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                keepControls
                // Capped and scrolling, like the two lists above (Ruling 12): with two dozen
                // holders an uncapped list pushed the title and both buttons off the window.
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
                Button(RemoteAdminWording.pruneButton, role: .destructive) { confirm() }
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

    /// The refs, each with the full id the delete compares and the notice names afterwards.
    private var refList: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(plan.refs, id: \.ref) { tip in
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
        .frame(height: CGFloat(min(max(plan.refs.count, 1), Self.maxRows)) * 20)
    }

    /// Rows each list shows before it scrolls: with the header, every section and both buttons
    /// on screen at the default window size (Ruling 12, measured with 24 holders).
    static let maxRows = 4

    /// A keep row is a toggle beside a text field; a row with a name problem has one more line.
    private var keepListHeight: CGFloat {
        let rows = CGFloat(min(holders.count, Self.maxRows)) * 30
        let shownProblems = holders.prefix(Self.maxRows).filter { visibleProblem($0) != nil }.count
        return rows + CGFloat(shownProblems) * 18
    }

    /// The ticked names with a problem, for the line under the list: a row scrolled out of view
    /// must not leave Prune off with no reason on screen.
    private var problemCount: Int { holders.filter { visibleProblem($0) != nil }.count }

    private func visibleProblem(_ tip: RefTip) -> String? {
        guard ticked[tip.ref] == true, checked == keeping else { return nil }
        return problems[tip.ref]
    }

    /// Keep All / Keep None, and how many are kept.
    private var keepControls: some View {
        let refs = holders.map(\.ref)
        let offers = RemoteAdminWording.keepAllOffers(refs, ticked: ticked)
        return HStack(spacing: 8) {
            Text(RemoteAdminWording.keepCount(refs, ticked: ticked))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Each box is set and the names are checked again, as a click on each would.
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
