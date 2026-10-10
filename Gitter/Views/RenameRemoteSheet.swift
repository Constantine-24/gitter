import SwiftUI

/// Rename… of a remote: the new name, checked live (`RemoteNameValidator` — git's rule, a leading
/// `-`, `HEAD`, `@`, a remote of that name or nested with it, compared ignoring case).
///
/// The field opens prefilled and selected, as Rename Branch's does. `confirmRenameRemote` runs
/// `git remote rename` on the lane, never beside a fetch (R21); a failure is read back and worded
/// with what git left. Not destructive — nothing is deleted — so Rename answers Return.
struct RenameRemoteSheet: View {
    let remote: String

    @Environment(RepositoryStore.self) private var store
    @State private var name: String
    @State private var selection: TextSelection?
    @State private var validator: RemoteNameValidator
    @FocusState private var nameFocused: Bool

    init(remote: String) {
        self.remote = remote
        var start = remote
        #if DEBUG
            // The harness cannot type into a sheet (carried note 9): it sets the field here.
            start = DebugLaunchHooks.sheetPrefill["name"] ?? remote
        #endif
        _name = State(initialValue: start)
        _validator = State(initialValue: RemoteNameValidator(ownName: remote))
    }

    private var isUnchanged: Bool { BranchNameValidator.trim(name) == remote }

    private var canRename: Bool {
        store.sheetBusyReason == nil && !isUnchanged && validator.isReady(for: name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RemoteAdminWording.renameRemoteSheetTitle(remote))
                .font(.headline)

            Text(RemoteAdminWording.renameRemoteIntro(remote))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("Name:")
                    TextField("Remote name", text: $name, selection: $selection)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .accessibilityLabel("Remote name")
                        .harnessField("Name", text: $name)
                }
                if let message = validator.message(for: name) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if let busy = store.sheetBusyReason {
                Text(busy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Spacer()
                let cancel: @MainActor () -> Void = { store.activeSheet = nil }
                let renameRemote: @MainActor () -> Void = { rename() }
                Button("Cancel", action: cancel)
                    .harnessButton("Cancel", action: cancel)
                    .keyboardShortcut(.cancelAction)
                Button(RemoteAdminWording.renameButton, action: renameRemote)
                    .harnessButton(RemoteAdminWording.renameButton, action: renameRemote)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canRename)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear {
            nameFocused = true
            selection = TextSelection(range: name.startIndex..<name.endIndex)
            validator.start(with: name, using: store)
        }
        .onChange(of: name) { validator.edited(name, using: store) }
    }

    /// Re-checked rather than trusted to the disabled button.
    private func rename() {
        guard canRename else { return }
        // `confirmRenameRemote` reads this very sheet and closes it itself.
        store.confirmRenameRemote(remote, to: BranchNameValidator.trim(name))
    }
}
