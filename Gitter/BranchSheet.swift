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

    var id: Self { self }
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

    /// Whether leaving a detached HEAD for this action could strand commits.
    var canStrandCommits: Bool {
        switch self {
        case .switchTo, .track, .detach: true
        // A merge only ever moves HEAD forward, so whatever HEAD reaches now it still reaches.
        case .merge: false
        // `switch -c <new>` with no start point creates the branch where HEAD already is, which
        // is the *cure* for a detached HEAD, not a way to lose it. With a start point it moves
        // HEAD somewhere else like any switch.
        case .createAndSwitch(_, let startPoint): startPoint != nil
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
