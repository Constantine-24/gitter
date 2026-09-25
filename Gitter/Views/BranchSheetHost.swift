import SwiftUI

/// The one place a `BranchSheet` becomes a view. `MainWindow` presents it; the store decides
/// which question is on screen.
///
/// The switch is exhaustive on purpose: every question the store can ask has a view here, and
/// three of the six are confirmations for the actions that can lose work.
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
            AbortSheet(operation: operation)
        case .leaveDetached(let unreferencedCommits, let headSha, let action):
            LeaveDetachedSheet(
                unreferencedCommits: unreferencedCommits, headSha: headSha, action: action)
        // Placeholders until Task 10 draws the four remote sheets. They can only be cancelled:
        // none of them offers the confirming button, so nothing on the server can be changed
        // from a sheet that does not yet say what it would change.
        case .pullDiverged(let ahead, let behind, let upstream):
            PlaceholderSheet(
                title: "Pull from \"\(upstream)\"",
                lines: ["\(ahead) of yours, \(behind) of theirs."])
        case .publish(let branch):
            PlaceholderSheet(title: "Publish \"\(branch)\"", lines: ["Choose a remote."])
        case .forcePush(let branch, _, let remote, _, let remoteTip, _, let total):
            PlaceholderSheet(
                title: "Force push \"\(branch)\" to \"\(remote)\"",
                lines: ["Remote tip \(remoteTip)", "\(total) commits would be discarded."])
        case .deleteRemoteBranch(let remote, let branch, let tip, let onlyThere):
            PlaceholderSheet(
                title: "Delete \"\(branch)\" on \"\(remote)\"",
                lines: ["Tip \(tip)", "\(onlyThere) held by no branch, tag or other remote."])
        }
    }
}

/// A stand-in for a sheet whose real view is not written yet: its facts, and Cancel.
private struct PlaceholderSheet: View {
    @Environment(RepositoryStore.self) private var store
    let title: String
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.headline)
            ForEach(lines, id: \.self) { line in
                Text(line).font(.callout.monospaced()).textSelection(.enabled)
            }
            HStack {
                Spacer()
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(minWidth: 420)
    }
}
