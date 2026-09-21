import GitCore
import SwiftUI

/// "Abort Merge…" / "Undo Squash…" from the operation note: the second of the four actions in
/// this milestone that can lose work, so the sheet's whole job is to say what goes and what
/// stays.
///
/// Every sentence here comes from the kept/lost table in `GitBranchBackend.abort` — one test per
/// cell, on real repositories, asserting byte-for-byte — and the table is not the same for all
/// six operations, which is why the prose is chosen per operation rather than written once:
///
/// - `rebase --abort` resets **hard**, so it takes unstaged edits too (`abortAlsoDiscardsUnstagedEdits`).
/// - `am --abort` rewinds the branch past the patches it already committed (`abortRewindsCommits`).
/// - undoing a squash resets the whole index, including anything staged *before* the squash if
///   the squash was started outside Gitter — the one cell where work a user never associated
///   with this operation is destroyed.
///
/// The file list is not decoration. The `.squash` precondition rests on `SQUASH_MSG` alone, a
/// plain file that can outlive the squash it belonged to (see `CLIGitBackend+Abort.swift`), so a
/// user whose staged work is not the squash's work has nothing but these paths to see that by.
/// It is the mitigation GitCore explicitly could not make for itself.
///
/// Cancel is the default button, the destructive half carries no keyboard shortcut, and Escape
/// closes — the same shape as `DeleteBranchSheet`, for the same reason.
struct AbortSheet: View {
    /// The operation the note offered to end. What actually runs is decided again by the
    /// backend, against the repository, when this is confirmed.
    let operation: RepositoryOperation

    @Environment(RepositoryStore.self) private var store

    /// The files this abort would put back to their committed state, read live: the repository
    /// can change while the sheet is up, and a list captured when it opened would be the one
    /// thing here that is not about what is on disk now.
    private var files: [FileStatus] { store.filesRevertedByAbort }

    /// Why this sheet no longer describes the repository, or nil. A terminal can commit the
    /// merge, or finish the rebase, while this is on screen; the abort would then be refused by
    /// the backend ("The repository changed; nothing was aborted."), and saying so before the
    /// click is better than after it.
    private var staleReason: String? {
        guard store.operationInProgress != operation else { return nil }
        guard let actual = store.operationInProgress else {
            return "Nothing is in progress any more — there is nothing to end."
        }
        return "\(actual.noun) is in progress now, not \(operation.noun.lowercased()). "
            + "Close this and look again."
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.question(operation))
                .font(.headline)

            Text(Self.discarded(operation))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text(Self.kept(operation))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(history)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            fileList

            if let staleReason {
                Text(staleReason)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // No keyboard shortcut on the destructive half: Return belongs to Cancel, and
                // nothing that throws away work should be one keystroke away.
                Button(operation.abortActionName, role: .destructive) { confirm() }
                    // The role alone draws an ordinary grey button in a macOS sheet.
                    .foregroundStyle(.red)
                    .disabled(store.isMutating)
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        // Escape: `.keyboardShortcut(.cancelAction)` is not free here, since Cancel already
        // holds `.defaultAction` and a button can carry only one.
        .onExitCommand { store.activeSheet = nil }
    }

    // MARK: - The files

    /// The exact paths about to be put back, with git's own status letter against each.
    ///
    /// A fixed height computed from the row count rather than a bare `ScrollView`: a scroll view
    /// takes every point it is offered, which would leave a sheet listing one file as tall as one
    /// listing forty. Twenty rows is where it stops growing and starts scrolling.
    @ViewBuilder
    private var fileList: some View {
        if files.isEmpty {
            Text(Self.nothingToRevert(operation))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } else {
            VStack(alignment: .leading, spacing: 4) {
                Text(listHeading)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(files) { file in
                            HStack(spacing: 6) {
                                ChangeBadge(kind: file.staged ?? file.unstaged)
                                Text(file.path)
                                    .font(.callout)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: min(CGFloat(files.count), 8) * 20)
            }
        }
    }

    private var listHeading: String {
        store.abortAlsoDiscardsUnstagedEdits
            ? "These files go back to their committed state, staged edits and unstaged alike:"
            : "These files go back to their committed state:"
    }

    /// What happens to commits, which is the half of the table a file list cannot show.
    private var history: String {
        if store.abortRewindsCommits {
            return "The patches already applied leave the branch: nothing but the reflog will "
                + "reach those commits afterwards."
        }
        switch operation {
        case .squash: return "No commit is created or removed."
        case .rebase:
            // Not "\"<branch>\" goes back…", which the design's draft wording had: git detaches
            // HEAD for the duration of a rebase (verified — `status --porcelain=v2` reports
            // `# branch.head (detached)`), so there is no branch name on screen to quote.
            return "Your branch goes back to the commit it was on before the rebase."
        case .merge, .cherryPick, .revert, .applyingPatches:
            return "Your branch and history go back to exactly where they were."
        }
    }

    private func confirm() {
        guard !store.isMutating else { return }
        // `confirmAbort` closes the sheet itself, before anything runs.
        store.confirmAbort(operation)
    }

    // MARK: - The five wordings

    private static func question(_ operation: RepositoryOperation) -> String {
        switch operation {
        case .merge: "Abort the merge?"
        case .cherryPick: "Abort the cherry-pick?"
        case .revert: "Abort the revert?"
        case .rebase: "Abort the rebase?"
        case .applyingPatches: "Stop applying patches?"
        case .squash: "Undo the pending squash?"
        }
    }

    private static func discarded(_ operation: RepositoryOperation) -> String {
        switch operation {
        case .merge, .cherryPick, .revert:
            let it = operation.noun.lowercased()
            return "Aborting discards the \(it)'s changes, every conflict resolution — including "
                + "the ones you already staged — and anything else you staged since the \(it) "
                + "began."
        case .rebase:
            return "Aborting discards everything the rebase has replayed, every conflict "
                + "resolution, anything you staged since it began — and any uncommitted edits "
                + "you have made since the rebase started, anywhere in the working copy."
        case .applyingPatches:
            return "Stopping discards every conflict resolution and anything you staged since it "
                + "began, and removes the patches that were already applied."
        case .squash:
            return "Undoing discards everything currently staged — the squashed changes, any "
                + "conflict resolutions, and anything else in the index, including work you "
                + "staged before the squash if the squash was started outside Gitter. The "
                + "prepared \"Squashed commit of the following:\" message goes too."
        }
    }

    private static func kept(_ operation: RepositoryOperation) -> String {
        switch operation {
        case .merge, .cherryPick, .revert:
            return "Kept: uncommitted edits you had before, edits you have made since to files "
                + "the \(operation.noun.lowercased()) did not touch, and all untracked files."
        case .applyingPatches:
            return "Kept: uncommitted edits you had before, edits you have made since to files "
                + "the patches did not touch, and all untracked files."
        case .rebase:
            return "Kept: untracked files, and nothing else — `git rebase --abort` restores the "
                + "working copy completely."
        case .squash:
            return "Kept: unstaged edits and all untracked files."
        }
    }

    /// The empty list. It is a real state, not a sign that something went wrong: a squash whose
    /// net diff was empty stages nothing at all, and removing `SQUASH_MSG` is then the entire job.
    private static func nothingToRevert(_ operation: RepositoryOperation) -> String {
        switch operation {
        case .squash:
            "Nothing is staged, so no file in your working copy changes — the pending squash and "
                + "its prepared message are all that go."
        case .merge, .cherryPick, .revert, .rebase, .applyingPatches:
            "No tracked file is staged or conflicted, so no file in your working copy changes."
        }
    }
}
