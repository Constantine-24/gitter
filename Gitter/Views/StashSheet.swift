import SwiftUI

/// Stash Changes…: a message, whether untracked files go too, and — when a working-copy file
/// was selected — whether to stash only that. Stashing is not a loss (the entry can be seen and
/// brought back), so Stash is the default button.
struct StashSheet: View {
    /// What "Selected files" stashes; empty offers only "All changes".
    let selectedPaths: [String]

    @Environment(RepositoryStore.self) private var store
    @State private var message = ""
    @State private var includeUntracked = false
    @State private var onlySelected = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(StashWording.sheetTitle)
                .font(.headline)

            TextField(StashWording.messagePlaceholder, text: $message)
                .textFieldStyle(.roundedBorder)

            if !selectedPaths.isEmpty {
                Picker(selection: $onlySelected) {
                    Text(StashWording.allChanges).tag(false)
                    Text(StashWording.selectedFiles(selectedPaths.count)).tag(true)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.radioGroup)
            }

            if onlySelected {
                Text(StashWording.names(selectedPaths))
                    .font(.caption.monospaced())
                    .fixedSize(horizontal: false, vertical: true)
                Text(StashWording.selectedUntrackedNote)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                Toggle(StashWording.includeUntracked, isOn: $includeUntracked)
                if includeUntracked {
                    Text(StashWording.includeUntrackedNote)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let busy = store.sheetBusyReason {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(StashWording.stashButton) { stash() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(store.sheetBusyReason != nil)
            }
        }
        .padding(20)
        .frame(width: 420)
    }

    private func stash() {
        guard store.sheetBusyReason == nil else { return }
        // `confirmStash` reads this sheet for the paths and closes it itself.
        store.confirmStash(
            message: message, includeUntracked: includeUntracked,
            onlySelected: onlySelected && !selectedPaths.isEmpty)
    }
}
