import SwiftUI

/// The fourth action in this milestone that can lose work, and the one git itself only mentions
/// in passing: HEAD is detached over commits no branch, tag or remote-tracking ref can reach, and
/// the action the user asked for would move HEAD away from them. `git switch` does that with a
/// stderr warning nobody reading a GUI ever sees.
///
/// Nothing has run when this appears — `perform` read the count, found it non-zero and stopped —
/// so all three answers are live: leave them, keep them on a new branch, or do nothing at all.
///
/// The safe answer is the default one (Return cancels), the destructive half carries no keyboard
/// shortcut, and the sha is selectable, because a user who leaves anyway has exactly one way back
/// and it is that string.
struct LeaveDetachedSheet: View {
    /// Commits reachable from `headSha` and from nothing else, counted by git at the moment the
    /// sha was read (see `UnreferencedCommits` — the pair describes one state, and confirming is
    /// refused unless it still holds).
    let unreferencedCommits: Int
    /// The full object name HEAD is on.
    let headSha: String
    /// What was asked for and has not run.
    let action: PendingBranchAction

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title)
                .font(.headline)

            Text(consequence)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(
                    isOne
                        ? "It is the commit HEAD is on now:"
                        : "They start at the commit HEAD is on now:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Selectable and in full: an abbreviation is enough to read and not always
                // enough to type back, and typing it back is the whole recovery.
                Text(headSha)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(
                "Creating a branch here keeps \(them). It does not \(action.summary) — ask for "
                    + "that again afterwards.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Button("Create Branch Here…") { createBranch() }
                Spacer()
                // No shortcut on the half that strands commits.
                Button(isOne ? "Leave It Behind" : "Leave Them Behind", role: .destructive) {
                    leave()
                }
                    .foregroundStyle(.red)
                    .disabled(store.isMutating)
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        // Escape, which Cancel cannot also carry while it holds `.defaultAction`.
        .onExitCommand { store.activeSheet = nil }
    }

    /// One commit is the case every sentence here has to bend for, so it is asked once.
    private var isOne: Bool { unreferencedCommits == 1 }

    private var them: String { isOne ? "it" : "them" }

    private var title: String {
        isOne ? "Leave 1 commit behind?" : "Leave \(unreferencedCommits) commits behind?"
    }

    private var consequence: String {
        let they =
            isOne
            ? "1 commit is on no branch, tag or remote"
            : "\(unreferencedCommits) commits are on no branch, tag or remote"
        return "You are not on a branch, and \(they) — only this detached HEAD. If you "
            + "\(action.summary), nothing but the reflog will reach \(them)."
    }

    /// Opens the New Branch sheet at the commit this warning is about, spelled in full rather
    /// than as "HEAD": the branch must land on the commit the user was shown, not on wherever
    /// HEAD has got to by the time they finish typing a name.
    ///
    /// That start point is also what lets the new branch be switched to without this warning
    /// coming straight back — a branch created at the very commit HEAD is on strands nothing, and
    /// `PendingBranchAction.canStrandCommits(leavingHeadAt:)` knows it by comparing the two shas.
    ///
    /// The action that was parked is dropped, deliberately and visibly (the line above says so).
    /// Running it afterwards would be a switch the user never re-confirmed, and chaining it
    /// behind a sheet that can be cancelled is more machinery than an honest sentence.
    private func createBranch() {
        store.requestNewBranch(from: headSha, labelled: "detached at \(headSha.prefix(7))")
    }

    private func leave() {
        guard !store.isMutating else { return }
        // `confirmLeaveDetached` reads this very sheet for what it promised and clears it itself.
        store.confirmLeaveDetached()
    }
}
