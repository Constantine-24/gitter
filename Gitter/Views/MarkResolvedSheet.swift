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
                Button(ConflictWording.markResolvedButton, role: .destructive) {
                    store.confirmMarkResolved(snapshot)
                }
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
