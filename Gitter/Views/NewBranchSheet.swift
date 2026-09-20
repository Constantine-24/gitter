import SwiftUI

/// The New Branch form: a name, where it starts from, and whether to go there.
///
/// Nothing here predicts git's answer. The name is checked by the store (which asks
/// `git check-ref-format` and then the refs), and Create stays disabled until a verdict has come
/// back **for the text that is in the field** — a name whose check is still in flight is not a
/// name this sheet will act on.
struct NewBranchSheet: View {
    /// The revision the branch starts at; nil means HEAD, which is git's own default.
    let startPoint: String?
    /// What to call that revision on screen; HEAD's label is not a revision, and a revision is
    /// not always what the user clicked.
    let startLabel: String

    @Environment(RepositoryStore.self) private var store
    @State private var name = ""
    @State private var wantsSwitch = true
    @State private var validator = BranchNameValidator()
    @FocusState private var nameFocused: Bool

    /// Switching is refused mid-operation, so the toggle is forced off and says why. Read
    /// wherever the answer matters rather than mirrored into `wantsSwitch`: the state the user
    /// set stays theirs, and what is *done* is decided here.
    private var blockedReason: String? { store.branchSwitchingBlockedReason }

    private var switchesToIt: Bool { wantsSwitch && blockedReason == nil }

    private var canCreate: Bool {
        !store.isMutating && validator.isReady(for: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("New Branch")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    // A visible label as well as the placeholder: the placeholder disappears the
                    // moment anything is typed, which is exactly when a form should still say
                    // what the field is.
                    Text("Name:")
                    TextField("Branch name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .accessibilityLabel("Branch name")
                }
                if let message = validator.message(for: name) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }

            Text("From: \(startLabel)")
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 4) {
                Toggle(
                    "Switch to the new branch",
                    isOn: Binding(get: { switchesToIt }, set: { wantsSwitch = $0 })
                )
                .disabled(blockedReason != nil)
                if let blockedReason {
                    Text(blockedReason)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            HStack {
                Spacer()
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button("Create") { create() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear {
            nameFocused = true
            validator.start(with: name, using: store)
        }
        .onChange(of: name) { validator.edited(name, using: store) }
    }

    /// Re-checked rather than trusted to the disabled button: a verdict can land between the
    /// press and this call, and the one thing that must not happen is creating a name nothing
    /// has vouched for.
    private func create() {
        guard canCreate else { return }
        // First, because `createBranch` does not close its own sheet — and because the sheet it
        // may open in a moment (the detached-HEAD confirmation) must not be cleared by this.
        store.activeSheet = nil
        store.createBranch(
            named: BranchNameValidator.trim(name), startPoint: startPoint,
            switchTo: switchesToIt)
    }
}
