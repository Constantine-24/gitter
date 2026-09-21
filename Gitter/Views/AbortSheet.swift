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
            Text(operation.abortQuestion)
                .font(.headline)

            Text(operation.abortDiscards)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text(operation.abortKeeps)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            Text(operation.abortHistory(rewindsCommits: store.abortRewindsCommits))
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
    /// listing forty. Eight rows is where it stops growing and starts scrolling — which is why
    /// the heading carries the count: past the eighth row the list is clipped, and a user who
    /// does not scroll would otherwise have no way to tell six files from sixty.
    @ViewBuilder
    private var fileList: some View {
        if files.isEmpty {
            Text(operation.abortRevertsNothing)
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

    /// The count is in the heading, not implied by the rows: the box stops growing at eight, so
    /// a longer list is clipped, and "These 14 files" is the only thing on the sheet that says
    /// how much is below the fold.
    private var listHeading: String {
        let clause =
            files.count == 1
            ? "This file goes back to its committed state"
            : "These \(files.count) files go back to their committed state"
        return store.abortAlsoDiscardsUnstagedEdits
            ? clause + ", staged edits and unstaged alike:"
            : clause + ":"
    }

    private func confirm() {
        guard !store.isMutating else { return }
        // `confirmAbort` closes the sheet itself, before anything runs.
        store.confirmAbort(operation)
    }
}
