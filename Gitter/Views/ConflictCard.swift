import GitCore
import SwiftUI

/// What the diff pane shows for a conflicted file (spec, "Entering and leaving"): its name, what
/// each side did and how many conflicts it has, and **Resolve Conflicts…**, which opens focus
/// mode on it — as Return and a double-click on its row do. Selecting the file never takes over
/// the window by itself, so arrowing through the list only shows this card.
struct ConflictCard: View {
    @Environment(RepositoryStore.self) private var store

    var body: some View {
        if let path = store.selectedPath,
            let file = store.snapshot?.status.files.first(where: { $0.path == path })?.conflict
        {
            card(file)
        } else {
            ProgressView()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func card(_ file: ConflictedFile) -> some View {
        let sides = store.conflictSides
        // The count once the read has landed; a whole-file kind has none.
        let document = store.selectedConflict
        let count = document.flatMap(ResolverShell.conflictCount(of:))
        return VStack(spacing: 12) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 32))
                .foregroundStyle(ResolverColor.accent)
                .accessibilityHidden(true)
            Text((file.path as NSString).lastPathComponent)
                .font(.title3.weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(file.path)
            Text(ConflictWording.card(kind: ConflictWording.kind(file, sides: sides), count: count))
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            Button(ConflictWording.resolveConflictsButton) { store.openResolver(at: file.path) }
                .controlSize(.large)
                .help(ConflictWording.resolveConflictsHelp)
        }
        .padding(24)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor))
    }
}
