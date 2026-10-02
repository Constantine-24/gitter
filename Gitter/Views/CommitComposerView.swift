import SwiftUI

/// The commit box under the working-copy file list: subject, body, the amend toggle and the
/// commit button — which is **Continue** during a rebase, cherry-pick or revert stop (spec,
/// "Commit": `commit -F` is not offered there, M 15). An empty draft is prefilled with git's
/// prepared message when an operation stops (`ComposerPrefill`); for a cherry-pick or revert a
/// note says which lines git will remove.
struct CommitComposerView: View {
    @Environment(RepositoryStore.self) private var store
    @FocusState private var focus: Field?

    private enum Field: Hashable {
        case subject
        case body
    }

    /// Git's conventional subject limit, and the point past which most tools start eliding.
    private static let subjectLimit = 50
    private static let subjectHardLimit = 72

    var body: some View {
        @Bindable var draft = store.draft

        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                TextField("Subject", text: $draft.subject)
                    .textFieldStyle(.roundedBorder)
                    .focused($focus, equals: .subject)
                    // Return in a single-line field means "on to the body", not "commit":
                    // committing is ⌘↩, which works from either field.
                    .onSubmit { focus = .body }
                Text("\(draft.subject.count)/\(Self.subjectLimit)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(counterColor(draft.subject.count))
                    .accessibilityLabel("\(draft.subject.count) of \(Self.subjectLimit) characters")
            }

            bodyEditor(draft: $draft.body)

            if let foreign = store.composerForeignDraft, let operation = store.operationInProgress {
                // Written for another commit, or before this stop: not sent until the user chooses.
                let current = store.operationProgress?.current
                HStack(spacing: 8) {
                    Label(
                        ContinueWording.foreignNote(
                            writtenFor: foreign.writtenFor, operation: operation, current: current),
                        systemImage: "exclamationmark.triangle.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 4)
                    Button(ContinueWording.useMessage(operation, current: current)) { store.useOperationMessage() }
                        .font(.caption)
                    Button(ContinueWording.keepMessage) { store.keepDraftMessage() }
                        .font(.caption)
                }
            }

            if let note = store.composerCommentNote {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if store.amendRewritesPublishedHistory {
                Label(
                    "Amending rewrites history that has already been pushed.",
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }

            HStack(spacing: 8) {
                // Deliberately not disabled while mutating: amending only edits the draft, and
                // the draft stays editable while a git write is in flight.
                //
                // It *is* disabled while an operation is in progress, which is a different
                // question: amending there rewrites the commit the operation is standing on, and
                // git goes through with it in four of the six cases (see
                // `GitWorkingCopyBackend.commit`). The tooltip names which operation and the way
                // out; the store and the backend refuse it as well, since ⌘↩ never passes
                // through this control.
                Toggle(
                    "Amend",
                    isOn: Binding(get: { store.draft.amend }, set: { store.setAmend($0) })
                )
                .disabled(
                    store.operationInProgress != nil,
                    help: store.operationInProgress?.amendBlockedHelp)
                if store.isMutating {
                    ProgressView().controlSize(.small)
                }
                Spacer()
                if let operation = store.operationInProgress, store.composerContinues {
                    // The bar's Continue, with this draft as the message where git has one.
                    let state = store.continueState
                    Button(store.continueTitle) { store.continueOperation() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(state != .enabled, help: state.reason ?? ContinueWording.continueHelp(operation))
                } else {
                    let blocked = store.composerCommitBlockedReason
                    Button(store.commitButtonTitle) { store.commit() }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(!draft.canCommit || store.isMutating || blocked != nil, help: blocked)
                }
            }
        }
        .padding(8)
    }

    private func bodyEditor(draft body: Binding<String>) -> some View {
        TextEditor(text: body)
            .font(.body)
            .focused($focus, equals: .body)
            .scrollContentBackground(.hidden)
            // Capped as well as floored: a `TextEditor` is as greedy as a `List`, and without
            // a ceiling it would take the file list's half of the pane.
            .frame(minHeight: 60, maxHeight: 96)
            .padding(.horizontal, 3)
            .padding(.vertical, 4)
            .background(Color(nsColor: .textBackgroundColor), in: .rect(cornerRadius: 5))
            .overlay {
                RoundedRectangle(cornerRadius: 5).strokeBorder(.quaternary)
            }
            .overlay(alignment: .topLeading) {
                if body.wrappedValue.isEmpty {
                    Text("Body…")
                        .foregroundStyle(.tertiary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 8)
                        .allowsHitTesting(false)
                }
            }
    }

    private func counterColor(_ count: Int) -> Color {
        switch count {
        case ...Self.subjectLimit: .secondary
        case ...Self.subjectHardLimit: .orange
        default: .red
        }
    }
}
