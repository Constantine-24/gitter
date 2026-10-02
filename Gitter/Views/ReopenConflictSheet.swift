import GitCore
import SwiftUI

/// Reopen Conflict…: `restore --merge` puts git's conflict back over the resolution, so the
/// resolution — index entry and file — is filed in the Stashes list first, always
/// (`Reopened by Gitter: <path>`). The sheet says both before anything runs.
///
/// The hash the sheet opened with goes to GitCore, which refuses (`.changedSinceShown`) when the
/// file changed while this was up. Cancel holds `.defaultAction`, Escape closes, the destructive
/// button has no shortcut.
struct ReopenConflictSheet: View {
    let path: String
    /// What `restore --merge` will write: markers for text, the ours side's bytes for a binary,
    /// its mode for a mode-only add (`GitConflictBackend.reopenedFile`).
    let comesBack: ReopenedFile
    let sides: SideLabels

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ConflictWording.reopenTitle(path))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(ConflictWording.reopenBody(path, comesBack, sides))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text(ConflictWording.reopenDestination(path))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let busy = store.sheetBusyReason {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button(ConflictWording.reopenButton, role: .destructive) { store.confirmReopen(path) }
                    .foregroundStyle(.red)
                    .disabled(store.sheetBusyReason != nil)
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onExitCommand { store.activeSheet = nil }
    }
}
