import GitCore
import SwiftUI

/// A resolving write over a conflicted file that holds bytes git did not write: GitCore refused
/// it (`ConflictError.wouldReplaceEdits`) and nothing was written. The sheet says what will be
/// kept and where, and what then happens; confirming runs the same write again with the edited
/// bytes filed in the Stashes list first (`Replaced by Gitter: <path>`).
///
/// A snapshot: the write carries the `ConflictSnapshot` the resolver showed, and GitCore refuses
/// (`.changedSinceShown`) when the file moved on while this was up. Cancel holds
/// `.defaultAction`, Escape closes, and the destructive button has no shortcut.
struct ReplaceHandEditedSheet: View {
    let snapshot: ConflictSnapshot
    let pending: PendingResolution

    @Environment(RepositoryStore.self) private var store

    private var path: String { snapshot.file.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ConflictWording.replaceTitle(path))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(ConflictWording.replaceBody(path))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text(ConflictWording.replaceDestination(path))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text(ConflictWording.replaceThen(pending, snapshot.file, store.conflictSides))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if let busy = store.sheetBusyReason {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                // No keyboard shortcut on the destructive half: Return belongs to Cancel.
                let act: @MainActor () -> Void = { store.confirmReplaceHandEdited(snapshot, pending) }
                Button(ConflictWording.replaceButton(pending, snapshot.file), role: .destructive, action: act)
                    .harnessButton(ConflictWording.replaceButton(pending, snapshot.file), action: act)
                    .foregroundStyle(.red)
                    .disabled(store.sheetBusyReason != nil)
                let cancel: @MainActor () -> Void = { store.activeSheet = nil }
                Button("Cancel", action: cancel)
                    .harnessButton("Cancel", action: cancel)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onExitCommand { store.activeSheet = nil }
    }
}
