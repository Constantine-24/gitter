import GitCore
import SwiftUI

/// Skip This Commit…: the commit, what goes with it (every path it changed goes back to HEAD,
/// resolutions included, M 32), and where the copy goes first (`Skipped by Gitter: …`, filed by
/// GitCore before `--skip` runs).
///
/// The sha goes to GitCore, which refuses when the operation stopped somewhere else since. Cancel
/// holds `.defaultAction`, Escape closes, the destructive button has no shortcut.
struct SkipSheet: View {
    let operation: RepositoryOperation
    let current: CommitRef
    let paths: [String]

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ContinueWording.skipQuestion(current))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(ContinueWording.skipBody(operation))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)

            Text(ContinueWording.skipFiles(paths))
                .font(.callout)
                .foregroundStyle(paths.isEmpty ? .secondary : .primary)
                .fixedSize(horizontal: false, vertical: true)
            if !paths.isEmpty { PathList(paths: paths) }

            if let destination = ContinueWording.skipDestination(current, paths: paths) {
                Text(destination)
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
                let act: @MainActor () -> Void = { store.confirmSkip(stoppedAt: current.sha) }
                Button(ContinueWording.skipConfirm, role: .destructive, action: act)
                    .harnessButton(ContinueWording.skipConfirm, action: act)
                    // The role alone draws an ordinary grey button in a macOS sheet.
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
