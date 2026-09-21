import SwiftUI

/// The second half of a delete: `git branch -d` has already run, refused, and changed nothing,
/// and these are the numbers it refused over.
///
/// One of the four actions in this milestone that can lose work, so the sheet is built around
/// saying what would be lost and making the safe answer the easy one: Cancel is the default
/// button (Return leaves the branch alone), "Delete Anyway" carries the destructive role and no
/// shortcut, and the tip sha is selectable so the branch can be put back afterwards.
///
/// It does **not** clear `activeSheet` before confirming: `confirmForceDelete` reads this very
/// sheet — the name it warned about *and the tip it showed* — and clears it itself. The name
/// match is what keeps a force-delete from being reachable without the warning it answers; the
/// tip is what keeps it from answering a warning that has since gone out of date, since
/// `forceDeleteBranch` refuses unless `refs/heads/<name>` still resolves to it. Neither check
/// lives here: a sheet cannot promise anything about a ref it read some time ago.
struct DeleteBranchSheet: View {
    let name: String
    /// From `commitsOnlyOn`: commits reachable from this branch and from no other ref. It can
    /// legitimately be **0** — `-d` compares against HEAD or the branch's upstream, so a branch
    /// merged into some *other* branch is refused while nothing on it is actually at risk.
    let uniqueCommits: Int
    /// The full sha the branch points at, captured before anything was deleted.
    let tip: String

    @Environment(RepositoryStore.self) private var store

    /// What `git branch -d` compared this branch against, in words, for the 0 case — the one
    /// case where the refusal needs explaining rather than the loss. The same phrase the merge
    /// sheet and the sidebar menu use, from the store.
    private var head: String { store.headPhrase }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Delete \"\(name)\"?")
                .font(.headline)

            Text("Git refused a plain delete: \"\(name)\" is not fully merged. Nothing has been deleted.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            consequence
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                Text("Its tip is kept by git, so you can bring the branch back with:")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                // Selectable and monospaced: this line is the whole reason the sha is on
                // screen, and it is worth nothing if it cannot be copied.
                Text("git branch \(name) \(tip)")
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // No keyboard shortcut on the destructive half, on purpose: Return belongs to
                // Cancel here, and nothing that loses commits should be one keystroke away.
                Button("Delete Anyway", role: .destructive) { confirm() }
                    // The role alone draws an ordinary grey button in a macOS sheet (shot
                    // taken before this line), and this is the button that loses commits.
                    .foregroundStyle(.red)
                    .disabled(store.isMutating)
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
        // Escape, which `.keyboardShortcut(.cancelAction)` would normally carry — but that
        // shortcut is not free here: Cancel already holds `.defaultAction`, and a button can
        // have only one. Escape must still close the warning.
        .onExitCommand { store.activeSheet = nil }
    }

    /// What deleting would actually cost, in the singular, the plural, and the zero — where
    /// "0 commits exist only on this branch" is true and means the refusal is about git's
    /// narrower rule rather than about work at risk.
    @ViewBuilder
    private var consequence: some View {
        switch uniqueCommits {
        case 0:
            Text(
                "No commits exist only on \"\(name)\" — every commit on it is reachable from "
                    + "another branch, tag or remote. Git refuses anyway, because it compares "
                    + "against \(head) or the branch's own upstream, and neither has it.")
        case 1:
            Text(
                "1 commit exists only on \"\(name)\". Deleting it leaves that commit on no "
                    + "branch, tag or remote: only the reflog would still reach it.")
        default:
            Text(
                "\(uniqueCommits) commits exist only on \"\(name)\". Deleting it leaves those "
                    + "commits on no branch, tag or remote: only the reflog would still reach "
                    + "them.")
        }
    }

    private func confirm() {
        guard !store.isMutating else { return }
        // `activeSheet` is deliberately left alone — see this type's doc comment.
        store.confirmForceDelete(name)
    }
}
