import SwiftUI

/// Before one of Gitter's own actions writes over or removes files whose drafts have changes, or
/// Done drops read-only drafts with changes (`BranchSheet.discardDrafts`, Task 7): "Discard your
/// changes to <file>?", Cancel / Discard Changes — or, for Done over several files, the close
/// question with Discard and Close.
///
/// Cancel holds `.defaultAction`, Escape closes, the destructive button has no shortcut — the
/// shape of every sheet that can lose work.
struct DiscardDraftsSheet: View {
    let question: DraftQuestion

    @Environment(RepositoryStore.self) private var store

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(ConflictWording.draftQuestionTitle(question))
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                let title = ConflictWording.draftQuestionButton(question)
                let act: @MainActor () -> Void = { store.confirmDiscardDrafts(question) }
                Button(title, role: .destructive, action: act)
                    .harnessButton(title, action: act)
                    .foregroundStyle(.red)
                let cancel: @MainActor () -> Void = { store.cancelDiscardDrafts() }
                Button(ConflictWording.cancel, action: cancel)
                    .harnessButton(ConflictWording.cancel, action: cancel)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onExitCommand { store.cancelDiscardDrafts() }
    }
}
