import GitCore
import SwiftUI

/// Take Ours / Theirs for N Files…: the files that are replaced by that side's whole file and
/// staged, which of them get a copy in the Stashes list first (edited since git wrote the
/// conflict), and which are skipped and why. Confirming takes them as the sheet read them
/// (`confirmTakeForFiles`); a file that moved on since is refused by its snapshot.
///
/// Cancel holds `.defaultAction`, Escape closes, and the confirming button has no shortcut.
struct TakeForFilesSheet: View {
    let plan: TakeForFilesPlan

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ConflictWording.takeForFilesTitle(plan))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            ForEach(ConflictWording.takeForFiles(plan, store.conflictSides), id: \.self) { line in
                Text(line)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if let busy = store.sheetBusyReason {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                let act: @MainActor () -> Void = { store.confirmTakeForFiles(plan) }
                Button(ConflictWording.takeForFilesButton(plan), role: .destructive, action: act)
                    .harnessButton(ConflictWording.takeForFilesButton(plan), action: act)
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
