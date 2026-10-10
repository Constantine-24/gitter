import GitCore
import SwiftUI

/// The "keep a local branch" boxes of Prune <remote>… and Remove… (fix round 1, I7: one view for
/// both sheets), and of Remove Worktree… and Remove All Missing… (B3 Task 5): the heading, Keep All / Keep None with how many are kept, and a row per holder —
/// a box beside the suggested name, with the name's problem under it — capped at `maxRows` rows
/// and scrolling, so a sheet with two dozen holders keeps its title and buttons on screen
/// (Ruling 12). The line under the list counts the ticked names with a problem, so a row scrolled
/// out of view never leaves the sheet's button off with no reason on screen.
///
/// The sheet owns the state — the boxes, the names, the problems and the `keeping` they were
/// checked for (`checked`) — because its button waits on it; this view draws it and edits the
/// boxes and names.
struct KeepBranchList: View {
    let holders: [RefTip]
    /// The defaults have been read: until then Keep All / Keep None are off.
    let loaded: Bool
    @Binding var ticked: [String: Bool]
    @Binding var names: [String: String]
    /// Ref → what is wrong with its name, for the `keeping` in `checked`.
    let problems: [String: String]
    let checked: [String: String]?
    var maxRows = 4
    /// The line above the boxes, and each box's label for its holder: B2's for remote-tracking
    /// refs; a worktree removal (B3) passes its own, its holders being worktree paths.
    var heading = RemoteAdminWording.keepHeading
    var label: (String) -> String = RemoteAdminWording.keepLabel
    /// The name field's label for the harness (`harnessField`), the field showing none.
    var nameLabel: (String) -> String = RemoteAdminWording.keepNameLabel

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(heading)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            controls
            ScrollView {
                Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 6) {
                    ForEach(holders, id: \.ref) { tip in row(tip) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: listHeight)
            if let summary = RemoteAdminWording.keepProblemsSummary(problemCount) {
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    /// What the sheet's button hands over: ticked holder ref → trimmed name.
    static func keeping(holders: [RefTip], ticked: [String: Bool], names: [String: String]) -> [String: String] {
        var result: [String: String] = [:]
        for tip in holders where ticked[tip.ref] == true {
            result[tip.ref] = (names[tip.ref] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        return result
    }

    private var keeping: [String: String] {
        Self.keeping(holders: holders, ticked: ticked, names: names)
    }

    /// A keep row is a toggle beside a text field; a row with a name problem has one more line.
    private var listHeight: CGFloat {
        let rows = CGFloat(min(holders.count, maxRows)) * 30
        let shownProblems = holders.prefix(maxRows).filter { visibleProblem($0) != nil }.count
        return rows + CGFloat(shownProblems) * 18
    }

    private var problemCount: Int { holders.filter { visibleProblem($0) != nil }.count }

    /// A problem is shown only for a ticked row, and only once the check is for what is on screen.
    private func visibleProblem(_ tip: RefTip) -> String? {
        guard ticked[tip.ref] == true, checked == keeping else { return nil }
        return problems[tip.ref]
    }

    /// Keep All / Keep None, and how many are kept.
    private var controls: some View {
        let refs = holders.map(\.ref)
        let offers = RemoteAdminWording.keepAllOffers(refs, ticked: ticked)
        return HStack(spacing: 8) {
            Text(RemoteAdminWording.keepCount(refs, ticked: ticked))
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer()
            // Each box is set and the names are checked again, as a click on each would.
            let keepAll: @MainActor () -> Void = { ticked = RemoteAdminWording.ticking(refs, all: true) }
            let keepNone: @MainActor () -> Void = { ticked = RemoteAdminWording.ticking(refs, all: false) }
            Button(RemoteAdminWording.keepAllTitle, action: keepAll)
                .harnessButton(RemoteAdminWording.keepAllTitle, action: keepAll)
                .disabled(!loaded || !offers.all)
            Button(RemoteAdminWording.keepNoneTitle, action: keepNone)
                .harnessButton(RemoteAdminWording.keepNoneTitle, action: keepNone)
                .disabled(!loaded || !offers.none)
        }
        .controlSize(.small)
    }

    @ViewBuilder
    private func row(_ tip: RefTip) -> some View {
        let isOn = Binding(get: { ticked[tip.ref] ?? false }, set: { ticked[tip.ref] = $0 })
        let name = Binding(get: { names[tip.ref] ?? "" }, set: { names[tip.ref] = $0 })
        GridRow {
            Toggle(label(tip.ref), isOn: isOn)
                .harnessToggle(label(tip.ref), isOn: isOn)
            TextField("", text: name)
                .textFieldStyle(.roundedBorder)
                .frame(width: 200)
                .harnessField(nameLabel(tip.ref), text: name)
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
}

/// Refs, each with the full id a compare-and-delete names and a notice repeats afterwards —
/// capped at `maxRows` rows, scrolling (Prune <remote>… and Remove…).
struct RefIDList: View {
    let refs: [RefTip]
    var maxRows = 4

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(refs, id: \.ref) { tip in
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
        .frame(height: CGFloat(min(max(refs.count, 1), maxRows)) * 20)
    }
}
