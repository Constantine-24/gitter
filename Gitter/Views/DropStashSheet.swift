import GitCore
import SwiftUI

/// Drop Stash…: the one stash action that loses work, so the sheet names what goes — the
/// message, the files (and the untracked ones), and the sha.
///
/// The sheet is a snapshot of one entry: `stash` carries its sha and the position it had, and
/// Drop Stash hands exactly that to GitCore, whose verified drop refuses when `stash@{index}`
/// no longer names the sha. A live stale line says so before the click when the entry moved or
/// went while this was up.
///
/// Cancel holds `.defaultAction`, Escape closes, and Drop Stash has the destructive role and no
/// shortcut.
struct DropStashSheet: View {
    let stash: Stash

    @Environment(RepositoryStore.self) private var store
    @State private var contents: StashContents?
    @State private var loaded = false

    /// Where the entry is in the list now: nil when it is gone.
    private var positionNow: Int? {
        store.stashes.first { $0.sha == stash.sha }?.index
    }

    private var staleReason: String? {
        let now = positionNow
        guard now != stash.index else { return nil }
        return StashWording.dropSheetStale(movedTo: now)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(StashWording.dropTitle(stash))
                .font(.headline)

            Text(StashWording.dropBody)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 2) {
                Text(StashWording.dropFilesLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(filesLine)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text(StashWording.dropShaLabel)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(stash.sha)
                    .font(.caption.monospaced())
                    .textSelection(.enabled)
            }

            ForEach([staleReason, store.sheetBusyReason].compactMap { $0 }, id: \.self) { line in
                Text(line)
                    .font(.caption)
                    .foregroundStyle(
                        line == staleReason ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                // No keyboard shortcut on the destructive half: Return belongs to Cancel.
                let act: @MainActor () -> Void = { confirm() }
                Button(StashWording.dropButton, role: .destructive, action: act)
                    .harnessButton(StashWording.dropButton, action: act)
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
        .task {
            // Shown, never acted on; cancelled with the sheet.
            contents = await store.loadStashContents(stash)
            loaded = true
        }
    }

    private var filesLine: String {
        guard loaded else { return StashWording.dropReading }
        guard let contents else { return StashWording.dropUnreadable }
        return StashWording.dropFiles(
            tracked: contents.tracked.map(\.displayPath),
            untracked: contents.untracked.map(\.displayPath))
    }

    private func confirm() {
        guard store.sheetBusyReason == nil else { return }
        store.confirmDropStash(stash)
    }
}
