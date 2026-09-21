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
        }
    }
}
