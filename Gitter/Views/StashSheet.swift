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
                .harnessField("Message", text: $message)

            if !selectedPaths.isEmpty {
                Picker(selection: $onlySelected) {
                    Text(StashWording.allChanges).tag(false)
                    Text(StashWording.selectedFiles(selectedPaths.count)).tag(true)
                } label: {
                    EmptyView()
                }
                .pickerStyle(.radioGroup)
                .harnessPicker(
                    "Stash", selection: $onlySelected,
                    options: [
                        (label: StashWording.allChanges, value: false),
                        (label: StashWording.selectedFiles(selectedPaths.count), value: true),
                    ])
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
                    .harnessToggle(StashWording.includeUntracked, isOn: $includeUntracked)
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
                let cancel: @MainActor () -> Void = { store.activeSheet = nil }
                let stashChanges: @MainActor () -> Void = { stash() }
                Button("Cancel", action: cancel)
                    .harnessButton("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(StashWording.stashButton, action: stashChanges)
                    .harnessButton(StashWording.stashButton, action: stashChanges)
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
