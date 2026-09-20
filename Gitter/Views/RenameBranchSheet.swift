import SwiftUI

/// The Rename form. Same live check as New Branch, and the same rule about acting only on a
/// name a verdict has come back for.
///
/// The field opens prefilled and fully selected, so typing replaces the old name and Escape
/// leaves it alone. The branch's own name is not reported as "already exists" — it is simply not
/// a rename, which is what disables the button.
struct RenameBranchSheet: View {
    let branch: String

    @Environment(RepositoryStore.self) private var store
    @State private var name: String
    @State private var selection: TextSelection?
    @State private var validator: BranchNameValidator
    @FocusState private var nameFocused: Bool

    init(branch: String) {
        self.branch = branch
        _name = State(initialValue: branch)
        _validator = State(initialValue: BranchNameValidator(ownName: branch))
    }

    private var isUnchanged: Bool { BranchNameValidator.trim(name) == branch }

    private var canRename: Bool {
        !store.isMutating && !isUnchanged && validator.isReady(for: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Branch")
                .font(.headline)

            Text("Renaming \"\(branch)\"")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Branch name", text: $name, selection: $selection)
                    .textFieldStyle(.roundedBorder)
                    .focused($nameFocused)
                if let message = validator.message(for: name) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { rename() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            nameFocused = true
            // Selected, not just focused: the old name is the answer to "what is it called", and
            // the next keystroke should be the start of the new name rather than an append.
            selection = TextSelection(range: name.startIndex..<name.endIndex)
            validator.start(with: name, using: store)
        }
        .onChange(of: name) { validator.edited(name, using: store) }
    }

    /// Re-checked rather than trusted to the disabled button; see `NewBranchSheet.create()`.
    private func rename() {
        guard canRename else { return }
        // `rename` does not close its own sheet.
        store.activeSheet = nil
        store.rename(branch, to: BranchNameValidator.trim(name))
    }
}
