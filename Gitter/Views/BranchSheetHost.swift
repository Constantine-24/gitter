import SwiftUI

/// The one place a `BranchSheet` becomes a view. `MainWindow` presents it; the store decides
/// which question is on screen.
///
/// The switch is exhaustive on purpose. The two cases this milestone has not built yet — the
/// abort confirmation and the detached-HEAD warning — get a plain placeholder rather than an
/// empty view, so a hook or a menu item that opens one shows something nameable and closable
/// instead of a blank sheet with no way out.
struct BranchSheetHost: View {
    let sheet: BranchSheet

    var body: some View {
        switch sheet {
        case .newBranch(let startPoint, let startLabel):
            NewBranchSheet(startPoint: startPoint, startLabel: startLabel)
        case .rename(let branch):
            RenameBranchSheet(branch: branch)
        case .merge(let branch):
            MergeSheet(branch: branch)
        case .deleteUnmerged(let name, let uniqueCommits, let tip):
            DeleteBranchSheet(name: name, uniqueCommits: uniqueCommits, tip: tip)
        case .abort(let operation):
            PlaceholderSheet(name: "abort(\(operation))")
        case .leaveDetached(let unreferencedCommits, _, _):
            PlaceholderSheet(name: "leaveDetached(\(unreferencedCommits) commits)")
        }
    }
}

/// A sheet that is not built yet: it names itself and closes. Nothing here answers the question
/// it stands for — aborting an operation and leaving a detached HEAD are two of the four
/// actions that can lose work, and each gets its own sheet in Task 9.
struct PlaceholderSheet: View {
    let name: String

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Not built yet")
                .font(.headline)
            Text(name)
                .font(.callout.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            HStack {
                Spacer()
                Button("Close") { store.activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
            }
        }
        .padding(20)
        .frame(width: 380)
    }
}
