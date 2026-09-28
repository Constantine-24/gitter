import SwiftUI

/// The one place a `BranchSheet` becomes a view. `MainWindow` presents it; the store decides
/// which question is on screen.
///
/// The switch is exhaustive on purpose: every question the store can ask has a view here, and
/// six of the twelve are confirmations for actions that can lose work — four here (Drop Stash…
/// among them), two on the server.
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
        case .pullDiverged(let ahead, let behind, let upstream):
            PullSheet(ahead: ahead, behind: behind, upstream: upstream)
        case .publish(let branch):
            PublishSheet(branch: branch)
        case .forcePush(
            let branch, let localTip, let remote, let remoteRef, let remoteTip, let discarded,
            let total):
            ForcePushSheet(
                branch: branch, localTip: localTip, remote: remote, remoteRef: remoteRef,
                remoteTip: remoteTip, discarded: discarded, total: total)
        case .deleteRemoteBranch(let remote, let branch, let tip, let onlyThere):
            DeleteRemoteBranchSheet(remote: remote, branch: branch, tip: tip, onlyThere: onlyThere)
        case .stash(let selectedPaths):
            StashSheet(selectedPaths: selectedPaths)
        case .dropStash(let stash):
            DropStashSheet(stash: stash)
        }
    }
}

