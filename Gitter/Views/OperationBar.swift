import GitCore
import SwiftUI

/// The strip above the working-copy file list while an operation is in progress: where it
/// stopped and what to do next (`ContinueWording.bar`), **Skip This Commit…** and **Continue**
/// for a rebase, cherry-pick or revert, and the abort button for all six.
///
/// A disabled button keeps its reason as the tooltip; Continue's reason is also written under the
/// bar when it is about the repository ("Resolve the conflicts in 2 files first: …") rather than
/// a sheet or a running change. Skip and the abort ask before they do anything (their ellipsis);
/// Continue asks first only when the stop needs it, and then carries one too.
struct OperationBar: View {
    let operation: RepositoryOperation

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(store.operationBarSentence)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 8)
                if OperationBarState.isContinuable(operation) {
                    let skip = store.skipState
                    Button(ContinueWording.skipButton) { store.requestSkip() }
                        .font(.callout)
                        .disabled(skip != .enabled, help: skip.reason ?? ContinueWording.skipHelp(operation))
                    let proceed = store.continueState
                    Button(store.continueTitle) { store.continueOperation() }
                        .font(.callout)
                        .disabled(proceed != .enabled, help: proceed.reason ?? ContinueWording.continueHelp(operation))
                }
                Button(operation.abortButtonTitle) { store.requestAbort() }
                    .font(.callout)
                    // Not while another git write is running: this one throws work away, and the
                    // sheet it opens would describe a repository mid-change.
                    .disabled(store.isMutating)
            }
            if let line = store.continueReasonLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}
