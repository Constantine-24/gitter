import Foundation
import GitCore

/// Which modal the store wants on screen. One value for all of them, held by the store rather
/// than by a view, so a menu item, a toolbar button and a debug hook all open the same sheet.
///
/// `Hashable` so it can be its own `Identifiable` id: two sheets that describe the same
/// question are the same sheet, and SwiftUI re-presents only when the question changes.
enum BranchSheet: Identifiable, Hashable {
    /// `startPoint` is what the new branch starts from — nil means "wherever HEAD is", which is
    /// git's own default and the only start point that needs no revision on the command line.
    /// `startLabel` is what to show for it, since HEAD's label ("detached at 1a2b3c4") is not a
    /// revision and a revision ("origin/main") is not always what the user clicked.
    case newBranch(startPoint: String?, startLabel: String)
    case rename(String)
    case merge(String)
    /// `git branch -d` refused and changed nothing; these are the numbers it refused over.
    case deleteUnmerged(name: String, uniqueCommits: Int, tip: String)
    case abort(RepositoryOperation)
    /// HEAD is detached and holds `unreferencedCommits` commits that no branch, tag or
    /// remote-tracking ref can reach. `then` is the action that was asked for and has NOT run.
    case leaveDetached(unreferencedCommits: Int, headSha: String, then: PendingBranchAction)
    /// A pull found both sides with commits of their own — counted on the tracking read
    /// **after** its fetch — and asks Merge or Rebase. `upstream` is git's short spelling
    /// (`origin/main`); the answer is refused if the branch no longer tracks it.
    case pullDiverged(ahead: Int, behind: Int, upstream: String)
    /// The current branch has no push remote and there is more than one remote to choose from.
    case publish(branch: String)
    /// What a force push would take off `remoteRef` on `remote`: the remote-tracking ref's
    /// **full** sha read right after a fetch, which `confirmForcePush` hands to git as the
    /// lease, the first 20 commits it would discard and how many there are in all — counted
    /// against `localTip`, the **full** sha of `branch` read at the same moment, which is what
    /// the push sends (the refspec's source side), so the sheet and the push are about the
    /// same two commits whatever the branch does meanwhile.
    case forcePush(
        branch: String, localTip: String, remote: String, remoteRef: String, remoteTip: String,
        discarded: [Commit], total: Int)
    /// Delete `branch` on `remote`, at the **full** `tip` read right after a fetch — the lease
    /// — with `onlyThere` commits held by no branch, tag or other remote-tracking ref.
    case deleteRemoteBranch(remote: String, branch: String, tip: String, onlyThere: Int)
    /// Stash Changes…: `selectedPaths` is what "Selected files" would stash — the working copy's
    /// selected file (and a rename's original path) when the sheet opened; empty offers only
    /// "All changes".
    case stash(selectedPaths: [String])
    /// Drop Stash…, about this entry: its sha, and the position it had when the sheet opened,
    /// which `confirmDropStash` hands to GitCore's verified drop as it is.
    case dropStash(Stash)
    /// A discard's confirmation: the requests with what the sheet shows (`expected`), which
    /// `confirmDiscard` hands to GitCore as they are.
    case discard(DiscardSheetModel)
    /// A resolving write GitCore refused because the file holds bytes git did not write
    /// (`ConflictError.wouldReplaceEdits`): the snapshot the resolver showed and what was asked,
    /// which `confirmReplaceHandEdited` runs again with the bytes filed first.
    case replaceHandEdited(ConflictSnapshot, PendingResolution)
    /// Mark Resolved found conflict markers left (`ConflictError.leftoverMarkers`). The count
    /// can be high (a content line that is exactly a marker), so the sheet does not show it.
    case markResolved(ConflictSnapshot, markers: Int)
    /// Reopen Conflict… on a resolved file: `hash` is the file's worktree hash when the sheet
    /// opened (nil = no file), which `confirmReopen` hands to GitCore as what it must still be;
    /// `comesBack` is what `restore --merge` will write (`GitConflictBackend.reopenedFile`) and
    /// `sides` the operation's side names, both read as the sheet opened.
    case reopen(path: String, hash: String?, comesBack: ReopenedFile, sides: SideLabels)
    /// Continue at a rebase stop whose resolution equals HEAD (M 30): the commit would be left
    /// out — unless other files are staged (Ruling 20), which it then keeps under its own title
    /// and author. `otherStaged` is exactly what `confirmContinueEmpty` acknowledges to GitCore.
    case continueEmpty(CommitRef, otherStaged: [String])
    /// Continue with staged files that are not the stopped commit's (Ruling 16): they would be
    /// committed with it. `paths` is exactly what `confirmContinueOthers` acknowledges.
    case continueOthers(RepositoryOperation, CommitRef?, paths: [String])
    /// Skip This Commit…: the stopped commit (its sha is what `confirmSkip` hands to GitCore,
    /// which refuses if the operation moved on) and the paths that go back to HEAD, read when
    /// the sheet opened.
    case skip(RepositoryOperation, CommitRef, paths: [String])
    /// Stage All during an operation (M 22): the files it would add that are not the
    /// operation's own — every file it would add when `known` is false (the operation's paths
    /// could not be read).
    case stageAll(RepositoryOperation, sweep: [String], known: Bool)
    /// Cherry-Pick / Revert N Commits…: the plan GitCore made (`historyPlan`), which
    /// `confirmHistoryAction` hands back to `run` as it is — GitCore makes it again and refuses
    /// on any difference, so what the sheet shows is what runs.
    case historyAction(HistoryPlan)
    /// Rebase onto…: the plan GitCore made (`rebasePlan`), handed back to `rebase(_:at:)` as it
    /// is, with the same promise.
    case rebaseOnto(RebasePlan)
    /// New Tag… on the commit `sha` (a full object id, which `confirmNewTag` hands to GitCore
    /// as the target).
    case newTag(sha: String)
    /// Delete Tag…: the tag as the list showed it — `objectID` is what GitCore's
    /// compare-and-delete names, so a tag that moved under the sheet is refused — the remotes
    /// this session saw holding that very tag (`RemoteTagsSeen`, Ruling 2), and the remotes set
    /// to fetch no tags (`remotesFetchingNoTags`), for the sheet's "the next fetch brings it
    /// back" line.
    case deleteTag(Tag, comesBackFrom: [String], noTagsFrom: [String])
    /// Delete from <remote>…: `id` is the tag's **unpeeled** id on `remote`, read on the lane as
    /// the sheet opened (`remoteTagID`) — the lease `confirmDeleteRemoteTag` hands to git. Nil
    /// when the remote has no such tag: the sheet then says so and offers nothing.
    case deleteRemoteTag(name: String, remote: String, id: String?)
    /// Prune <remote>…: GitCore's plan (`prunePlan`, read on the lane) — the refs with the ids
    /// the compare-and-deletes name, and what deleting them strands — which `confirmPrune`
    /// hands back to `prune` as it is.
    case prune(PrunePlan)
    /// Clean Up Gone Branches…: every local branch whose upstream is gone, as `goneBranches`
    /// read it — tips and unique-commit counts are what `confirmCleanUp` deletes against.
    case cleanUpGone([GoneBranch])
    /// Set / Change Upstream… of `branch`, which tracks `current` (git's short spelling) or
    /// nothing.
    case upstream(branch: String, current: String?)
    /// Add Remote…: a form; GitCore checks the name and the URL again as it writes.
    case addRemote
    /// Edit URL… of `remote`: its URLs as the configuration writes them (`remoteURLs`, read as
    /// the sheet opened), which `confirmEditURL` compares again before it writes.
    case editRemoteURL(RemoteURLs, remote: String)
    /// Rename… of this remote.
    case renameRemote(String)
    /// Remove…: GitCore's `removalImpact`, read as the sheet opened — the refs with the ids the
    /// notice names, what deleting them strands, the branches it changes — which
    /// `confirmRemoveRemote` hands back to `removeRemote` as it is, to be compared again, whole.
    case removeRemote(RemovalImpact)

    var id: Self { self }

    /// Whether `other` is the same question as this one, with possibly different numbers: the
    /// same case about the same branch or remote branch. A lane that ends with a question may
    /// replace an open sheet only when it is this — a fresher copy of itself.
    func asksTheSameQuestion(as other: BranchSheet) -> Bool {
        switch (self, other) {
        case (.pullDiverged(_, _, let a), .pullDiverged(_, _, let b)): a == b
        case (.publish(let a), .publish(let b)): a == b
        case (
            .forcePush(let a, _, let r, let ra, _, _, _), .forcePush(let b, _, let s, let rb, _, _, _)
        ):
            // All three: the same branch force-pushed to another remote, or to another ref on
            // the same remote, is a different question about different commits.
            a == b && r == s && ra == rb
        case (.deleteRemoteBranch(let r, let a, _, _), .deleteRemoteBranch(let s, let b, _, _)):
            r == s && a == b
        case (.deleteRemoteTag(let a, let r, _), .deleteRemoteTag(let b, let s, _)):
            a == b && r == s
        case (.prune(let a), .prune(let b)): a.remote == b.remote
        default: false
        }
    }
}

/// An action that was asked for while HEAD was detached over unreferenced commits, and is
/// waiting for the user to say whether those commits may be left behind.
///
/// It is the whole action, not a flag: nothing has run when the sheet goes up, so confirming has
/// to be able to run it from scratch. Only actions that move HEAD *away* are ever parked here —
/// a merge advances HEAD and strands nothing, and `switch -c <new>` from HEAD leaves the commits
/// on the new branch, so neither needs asking.
enum PendingBranchAction: Hashable {
    case switchTo(String)
    case track(String)
    case detach(String)
    case merge(String, MergeMode)
    case createAndSwitch(name: String, startPoint: String?)
    /// A pull's merge step: `merge` of the upstream in `mode`, which records the **pull** mode
    /// rather than the merge sheet's — a fast-forward pull was no choice at all, and must not
    /// change what the merge sheet comes up on. Never parked behind the detached-HEAD
    /// confirmation (a pull needs a branch), and like a merge it only moves HEAD forward.
    case pull(upstream: String, mode: MergeMode)
    /// Cherry-pick or revert of these commits (full object ids, as selected): never parked
    /// behind the detached-HEAD confirmation — both only add commits on top of HEAD. Here for
    /// Stash and Continue, whose `retry` plans it again and puts its sheet back up.
    case history(HistoryAction, [String])
    /// Rebase onto `target` (a full object id or a branch's full ref name), for Stash and
    /// Continue like `.history`. A detached HEAD stays detached, so nothing is left behind.
    case rebaseOnto(String)

    /// Whether leaving a detached HEAD for this action could strand commits.
    ///
    /// `sha` is the commit HEAD is really on, when it has been read. Passing nil answers the
    /// cheaper question — "could this ever need asking about?" — which is what decides whether to
    /// spend a `rev-list` on finding out; the answer is then re-taken with the sha in hand, and
    /// only a `true` there opens the confirmation.
    func canStrandCommits(leavingHeadAt sha: String? = nil) -> Bool {
        switch self {
        case .switchTo, .track, .detach: true
        // A merge only ever moves HEAD forward, so whatever HEAD reaches now it still reaches.
        case .merge, .pull: false
        // Never run through `perform`: they plan, ask and run on their own path, and neither
        // moves HEAD away from what it holds — a pick or revert adds commits on top, a rebase
        // of a detached HEAD leaves it detached (the old tip in ORIG_HEAD and the reflog).
        case .history, .rebaseOnto: false
        // `switch -c <new>` with no start point creates the branch where HEAD already is, which
        // is the *cure* for a detached HEAD, not a way to lose it. With a start point it moves
        // HEAD somewhere else like any switch — **unless** that start point is the very commit
        // HEAD is on, spelled out in full. That is what the warning's own "Create Branch Here…"
        // passes, and a branch created there holds exactly what the detached HEAD held, so
        // warning about it again would be asking the user to confirm the cure. Compared as
        // strings against git's own 40-character output: a start point that is anything else —
        // a name, an abbreviation, a sha HEAD has since left — is not proof of anything and
        // still asks.
        case .createAndSwitch(_, let startPoint): startPoint != nil && startPoint != sha
        }
    }

    /// The action in words, for the confirmation's button and its explanation.
    var summary: String {
        switch self {
        case .switchTo(let branch): "switch to \"\(branch)\""
        case .track(let remote): "check out \"\(remote)\" as a local branch"
        case .detach(let revision): "check out \(revision)"
        case .merge(let branch, _): "merge \"\(branch)\""
        case .createAndSwitch(let name, _): "create \"\(name)\" and switch to it"
        case .pull(let upstream, _): "pull from \"\(upstream)\""
        case .history(let action, let shas): HistoryWording.attempt(action, count: shas.count)
        case .rebaseOnto(let target): HistoryWording.rebaseAttempt(target)
        }
    }
}

/// Why a branch name typed into the New Branch or Rename sheet cannot be used. Nil is a good
/// name; `nil` from the validator never means "could not tell".
enum BranchNameProblem: Hashable {
    case empty
    case invalid
    case exists

    /// Shown under the field. `.empty` is not an error the user made yet, so it reads as a
    /// prompt rather than a complaint.
    var message: String {
        switch self {
        case .empty: "Enter a branch name."
        case .invalid: "That is not a valid branch name."
        case .exists: "A branch with that name already exists."
        }
    }
}
