import GitCore
import SwiftUI

/// Stage All during an operation (spec, "Discard, Stage All and Commit during an operation";
/// M 22): the files it would add that are not part of the operation, which its commit would
/// then take in. Unmerged paths are never staged (GitCore), so they are not listed.
///
/// Confirming reads again and asks once more if a file not named here would be staged. Cancel
/// holds `.defaultAction`, Escape closes, Stage All has no shortcut.
struct StageAllSheet: View {
    let operation: RepositoryOperation
    let sweep: [String]
    let known: Bool

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ContinueWording.stageAllQuestion(operation))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            Text(ContinueWording.stageAllBody(operation, count: sweep.count, known: known))
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            PathList(paths: sweep)

            if let busy = store.sheetBusyReason {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                let act: @MainActor () -> Void = { store.confirmStageAll() }
                Button(ContinueWording.stageAllConfirm, action: act)
                    .harnessButton(ContinueWording.stageAllConfirm, action: act)
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
