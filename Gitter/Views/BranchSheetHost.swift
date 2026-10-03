import SwiftUI

/// The one place a `BranchSheet` becomes a view. `MainWindow` presents it; the store decides
/// which question is on screen.
///
/// The switch is exhaustive on purpose: every question the store can ask has a view here, and
/// eleven of the twenty-two are confirmations for actions that can replace or lose work — nine
/// here (Drop Stash…, Discard…, replacing a hand-edited conflict, Reopen Conflict…, Skip This
/// Commit… and Rebase onto… among them), two on the server. Cherry-Pick / Revert N Commits…
/// only adds commits, and still asks: it says which, in which order. Mark Resolved with markers left loses nothing, and
/// still asks; so do Continue over an empty result or other staged files, and Stage All during
/// an operation, which decide what a commit holds.
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
        case .discard(let model):
            DiscardSheet(model: model)
        case .replaceHandEdited(let snapshot, let pending):
            ReplaceHandEditedSheet(snapshot: snapshot, pending: pending)
        case .markResolved(let snapshot, _):
            MarkResolvedSheet(snapshot: snapshot)
        case .reopen(let path, _, let comesBack, let sides):
            ReopenConflictSheet(path: path, comesBack: comesBack, sides: sides)
        case .continueEmpty, .continueOthers:
            ContinueEmptySheet(sheet: sheet)
        case .skip(let operation, let current, let paths):
            SkipSheet(operation: operation, current: current, paths: paths)
        case .stageAll(let operation, let sweep, let known):
            StageAllSheet(operation: operation, sweep: sweep, known: known)
        case .historyAction(let plan):
            HistoryActionSheet(plan: plan)
        case .rebaseOnto(let plan):
            RebaseOntoSheet(plan: plan)
        }
    }
}

