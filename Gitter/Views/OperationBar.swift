import GitCore
import SwiftUI

/// The strip above the working-copy file list while an operation is in progress: where it
/// stopped and what to do next (`ContinueWording.bar`), **Skip This Commit…** and **Continue**
/// for a rebase, cherry-pick or revert, and the abort button for all six.
///
/// The sentence has its own row, never cut (also its tooltip), and the buttons a row of their own
/// under it: beside three buttons a long branch name or subject was cut mid-word at the default
/// window size (fix round 1). A disabled button keeps its reason as the tooltip; Continue's reason
/// is also written under the sentence when it is about the repository ("Resolve the conflicts in
/// 2 files first: …") rather than a sheet or a running change. Skip and the abort ask before they
/// do anything (their ellipsis); Continue asks first only when the stop needs it, and then carries
/// one too.
struct OperationBar: View {
    let operation: RepositoryOperation

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        let sentence = store.operationBarSentence
        VStack(alignment: .leading, spacing: 4) {
            Text(sentence)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .help(sentence)
            if let old = store.staleSequence {
                // Ruling 29: git's own Continue, Skip and Abort would act on an older range's list.
                VStack(alignment: .leading, spacing: 2) {
                    Label(ContinueWording.staleWarning(operation, old), systemImage: "exclamationmark.triangle.fill")
                        .font(.callout)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                    Text(ContinueWording.staleWayForward(operation, old))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                    CopyCommandButton(command: ContinueWording.reapplyCommand(old))
                }
            } else if let line = store.continueReasonLine {
                Text(line)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
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
                // Not while another git write is running (this one throws work away, and the sheet
                // it opens would describe a repository mid-change), nor over a stale list.
                let abort = store.abortState
                Button(operation.abortButtonTitle) { store.requestAbort() }
                    .font(.callout)
                    .disabled(abort != .enabled, help: abort.reason)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
    }
}

/// The bar's place while git keeps a halted cherry-pick or revert range (`HaltedSequence`): no
/// operation is detected, `git status` says one is in progress, and a later `--continue` would
/// leave a commit out. It stays for as long as `sequencer/` does, and names the commits not
/// applied and the safe way on (`ContinueWording.haltedWayForward`, measured). There is no button:
/// the way on is `--quit`, which Gitter never runs.
struct HaltedSequenceBar: View {
    let halted: HaltedSequence

    var body: some View {
        // A committed stop (Ruling 30) is waiting, not stranded: no warning colour.
        let waiting = halted.committed != nil
        VStack(alignment: .leading, spacing: 4) {
            Label(
                ContinueWording.halted(halted),
                systemImage: waiting ? "arrow.right.circle" : "exclamationmark.triangle.fill"
            )
            .font(.callout)
            .foregroundStyle(waiting ? Color.secondary : Color.orange)
            .fixedSize(horizontal: false, vertical: true)
            Text(ContinueWording.haltedWayForward(halted))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            CopyCommandButton(command: ContinueWording.reapplyCommand(halted))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
    }
}

/// Copies the command that applies a list's commits again (full shas) — to be copied before
/// the step that removes `sequencer/`, and this bar with it. Nothing when there is no command.
struct CopyCommandButton: View {
    let command: String?

    var body: some View {
        if let command {
            Button(ContinueWording.copyCommand) { Clipboard.copy(command) }
                .font(.caption)
                .help(command)
        }
    }
}
