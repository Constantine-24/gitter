import GitCore
import SwiftUI

/// Clean Up Gone Branches…: every local branch whose upstream is gone (R9), with whether
/// deleting it loses anything. Merged rows come ticked; a row with commits only on it comes
/// unticked, and ticking it shows A1's unmerged warning; a branch checked out in a worktree
/// cannot be ticked — git refuses to delete it there (R10).
///
/// The button hands the ticked rows, as read, to `confirmCleanUp`, which deletes each only at
/// the tip shown and only while it strands no more than its row said. Cancel holds
/// `.defaultAction`, Escape closes, and the delete carries the destructive role and no shortcut.
struct GoneBranchesSheet: View {
    let branches: [GoneBranch]

    @Environment(RepositoryStore.self) private var store
    @State private var ticked: Set<String>

    init(branches: [GoneBranch]) {
        self.branches = branches
        _ticked = State(initialValue: Set(branches.filter(RemoteAdminWording.defaultTicked).map(\.name)))
    }

    private var chosen: [GoneBranch] { branches.filter { ticked.contains($0.name) } }

    /// A row whose branch moved or went since the list was read.
    private var changed: Bool {
        branches.contains { gone in store.localBranches.first { $0.name == gone.name }?.sha != gone.tip }
    }

    private var busy: String? { store.isMutating ? RemoteWording.mutationBusy : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RemoteAdminWording.cleanUpSheetTitle)
                .font(.headline)

            Text(RemoteAdminWording.cleanUpIntro(branches.count))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(branches, id: \.name) { gone in row(gone) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(height: listHeight)

            ForEach([changed ? RemoteAdminWording.cleanUpSheetChanged : nil, busy].compactMap { $0 }, id: \.self) {
                line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(line == busy ? AnyShapeStyle(.secondary) : AnyShapeStyle(.orange))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                let delete: @MainActor () -> Void = { confirm() }
                let cancel: @MainActor () -> Void = { store.activeSheet = nil }
                // No keyboard shortcut on the destructive half: Return belongs to Cancel.
                Button(RemoteAdminWording.cleanUpButton(chosen.count), role: .destructive, action: delete)
                    .harnessButton(RemoteAdminWording.cleanUpButton(chosen.count), action: delete)
                    .foregroundStyle(.red)
                    .disabled(chosen.isEmpty || busy != nil)
                Button("Cancel", action: cancel)
                    .harnessButton("Cancel", action: cancel)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onExitCommand { store.activeSheet = nil }
    }

    /// Room for every row and its extra lines (where it is checked out — a path that can wrap —
    /// and the warning a ticked unmerged row shows), up to a cap past which the list scrolls.
    private var listHeight: CGFloat {
        let rows = branches.reduce(CGFloat(0)) { total, gone in
            var height: CGFloat = 40
            if gone.checkedOutAt != nil { height += 34 }
            if ticked.contains(gone.name), RemoteAdminWording.unmergedWarning(gone) != nil { height += 34 }
            return total + height
        }
        return min(rows, 340)
    }

    private func row(_ gone: GoneBranch) -> some View {
        let isOn = Binding(
            get: { ticked.contains(gone.name) },
            set: { on in if on { ticked.insert(gone.name) } else { ticked.remove(gone.name) } })
        return Toggle(isOn: isOn) {
            VStack(alignment: .leading, spacing: 2) {
                Text(gone.name)
                    .font(.callout)
                Text(RemoteAdminWording.goneRowDetail(gone))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let location = RemoteAdminWording.checkedOut(gone) {
                    Text(location)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if ticked.contains(gone.name), let warning = RemoteAdminWording.unmergedWarning(gone) {
                    Text(warning)
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .harnessToggle(gone.name, isOn: isOn)
        .disabled(gone.checkedOutAt != nil)
    }

    private func confirm() {
        guard !chosen.isEmpty, busy == nil else { return }
        // `confirmCleanUp` reads this very sheet and clears it itself.
        store.confirmCleanUp(chosen)
    }
}
