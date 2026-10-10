import GitCore
import Observation
import SwiftUI

/// New Tag… on a commit: a name, annotated or lightweight, and for an annotated tag its message.
///
/// The name is checked by GitCore as it is typed (`validateNewTagName`), and Create Tag stays
/// off until a verdict has come back **for the text in the field** (`TagNameValidator`) — the
/// same rule as the New Branch form. `createTag` checks it once more holding the slot, so a
/// name taken in a terminal meanwhile is still refused, and a name git itself refuses (one under
/// a dangling symbolic ref) comes back in git's words.
///
/// A form like New Branch rather than a confirmation: making a tag loses nothing (Delete Tag
/// takes it away again), so Create Tag answers Return from the name field, and Escape cancels.
/// The message is stored exactly as written — `#` lines kept — and never signed.
struct NewTagSheet: View {
    let sha: String

    @Environment(RepositoryStore.self) private var store
    @State private var name = ""
    @State private var annotated = true
    @State private var message = ""
    @State private var validator = TagNameValidator()
    @FocusState private var nameFocused: Bool

    private var hasMessage: Bool {
        !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var canCreate: Bool {
        !store.isMutating && validator.isReady(for: name) && (!annotated || hasMessage)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(TagWording.newTagSheetTitle)
                .font(.headline)

            Text(TagWording.newTagOn(sha, subject: store.commitSubject(sha)))
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.tail)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Name:")
                    TextField("Tag name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .accessibilityLabel("Tag name")
                }
                if let line = validator.message(for: name) {
                    Text(line)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Picker("Kind:", selection: $annotated) {
                    Text(TagWording.kindTitle(annotated: true)).tag(true)
                    Text(TagWording.kindTitle(annotated: false)).tag(false)
                }
                .pickerStyle(.segmented)
                .fixedSize()
                Text(TagWording.kindExplanation(annotated: annotated))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if annotated {
                VStack(alignment: .leading, spacing: 4) {
                    Text(TagWording.messageLabel)
                    TextEditor(text: $message)
                        .font(.body)
                        .frame(height: 72)
                        .scrollContentBackground(.hidden)
                        .padding(4)
                        .background(.background, in: RoundedRectangle(cornerRadius: 5))
                        .overlay(
                            RoundedRectangle(cornerRadius: 5).strokeBorder(.separator))
                        .accessibilityLabel("Tag message")
                    if !hasMessage {
                        Text(TagWording.messageNeeded)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if store.isMutating {
                Text(RemoteWording.mutationBusy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                let cancel: @MainActor () -> Void = { store.activeSheet = nil }
                Button("Cancel", action: cancel)
                    .harnessButton("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                let act: @MainActor () -> Void = { create() }
                Button(TagWording.createButton, action: act)
                    .harnessButton(TagWording.createButton, action: act)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            nameFocused = true
            validator.start(with: name, using: store)
        }
        .onChange(of: name) { validator.edited(name, using: store) }
    }

    /// Re-checked rather than trusted to the disabled button: a verdict can land between the
    /// press and this call.
    private func create() {
        guard canCreate else { return }
        // `confirmNewTag` reads this very sheet for the commit and closes it itself.
        store.confirmNewTag(
            name: BranchNameValidator.trim(name), message: annotated ? message : nil, at: sha)
    }
}

/// The New Tag field's live check: `BranchNameValidator`'s rule — a debounce, one call into the
/// store, and a verdict believed only for the exact text it judged — over GitCore's
/// `TagNameProblem`.
@Observable @MainActor
final class TagNameValidator {
    private static let debounce = Duration.milliseconds(250)

    /// What is wrong with `checkedName`, or nil when nothing is.
    private(set) var problem: TagNameProblem?
    /// The trimmed text `problem` is about; nil while a check is in flight.
    private(set) var checkedName: String?
    /// Whether the user has typed since the sheet opened (`TagWording.fieldMessage`).
    private(set) var hasEdited = false

    private var check: Task<Void, Never>?

    func start(with text: String, using store: RepositoryStore) {
        update(text, using: store)
    }

    func edited(_ text: String, using store: RepositoryStore) {
        hasEdited = true
        update(text, using: store)
    }

    func isReady(for text: String) -> Bool {
        checkedName == BranchNameValidator.trim(text) && problem == nil
    }

    func message(for text: String) -> String? {
        guard checkedName == BranchNameValidator.trim(text) else { return nil }
        return TagWording.fieldMessage(problem, edited: hasEdited)
    }

    private func update(_ text: String, using store: RepositoryStore) {
        check?.cancel()
        let trimmed = BranchNameValidator.trim(text)
        if trimmed.isEmpty {
            settle(trimmed, .empty)
            return
        }
        checkedName = nil
        check = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let problem = await store.validateNewTagName(trimmed)
            guard !Task.isCancelled else { return }
            settle(trimmed, problem)
        }
    }

    private func settle(_ name: String, _ problem: TagNameProblem?) {
        checkedName = name
        self.problem = problem
    }
}
