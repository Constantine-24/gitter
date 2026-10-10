import GitCore
import SwiftUI

/// Mark Resolved found conflict markers still in the file (`ConflictError.leftoverMarkers`) and
/// staged nothing. Confirming stages the file with them (`markResolved(allowingMarkers:)`).
///
/// No count on screen: `leftoverMarkers` can over-count a content line that is exactly an
/// opening marker. Cancel holds `.defaultAction`, Escape closes, the confirming button has no
/// shortcut.
struct MarkResolvedSheet: View {
    let snapshot: ConflictSnapshot

    @Environment(RepositoryStore.self) private var store

    private var path: String { snapshot.file.path }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ConflictWording.markResolvedTitle(path))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(ConflictWording.markResolvedBody(path))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            if let busy = store.sheetBusyReason {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                let act: @MainActor () -> Void = { store.confirmMarkResolved(snapshot) }
                Button(ConflictWording.markResolvedButton, role: .destructive, action: act)
                    .harnessButton(ConflictWording.markResolvedButton, action: act)
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
