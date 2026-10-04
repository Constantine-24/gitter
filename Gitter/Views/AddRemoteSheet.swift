import GitCore
import Observation
import SwiftUI

/// Add Remote…: a name, checked live (`RemoteNameValidator`, GitCore's `remoteNameProblem`), a
/// URL, checked as typed (`RemoteAdminWording.urlProblem`), and whether to fetch from it straight
/// after.
///
/// A form like New Branch: adding a remote loses nothing (Remove… takes it away again), so Add
/// Remote answers Return, and Escape cancels. `confirmAddRemote` writes it with `remote add` —
/// never `-f` (R19) — and fetches afterwards with Gitter's own fetch, on the lane. GitCore checks
/// the name and the URL once more before git runs.
struct AddRemoteSheet: View {
    @Environment(RepositoryStore.self) private var store
    @State private var name: String
    @State private var url: String
    @State private var fetchAfter = true
    @State private var validator = RemoteNameValidator()
    @FocusState private var nameFocused: Bool

    init() {
        var name = ""
        var url = ""
        #if DEBUG
            // The harness cannot type into a sheet (carried note 9): it sets the fields here.
            name = DebugLaunchHooks.sheetPrefill["name"] ?? ""
            url = DebugLaunchHooks.sheetPrefill["url"] ?? ""
        #endif
        _name = State(initialValue: name)
        _url = State(initialValue: url)
    }

    private var urlProblem: String? { RemoteAdminWording.urlProblem(url) }

    private var canAdd: Bool {
        !store.isMutating && validator.isReady(for: name) && urlProblem == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RemoteAdminWording.addRemoteSheetTitle)
                .font(.headline)

            Text(RemoteAdminWording.addRemoteIntro)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    label("Name:")
                    TextField("Remote name", text: $name)
                        .textFieldStyle(.roundedBorder)
                        .focused($nameFocused)
                        .accessibilityLabel("Remote name")
                }
                if let message = validator.message(for: name) {
                    caption(message)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    label("URL:")
                    // What the user typed is shown as typed (carried note 1): only what Gitter
                    // displays of a configured URL is redacted.
                    TextField("A path, or an address such as https://host/owner/repo.git", text: $url)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Remote URL")
                }
                if !url.isEmpty, let problem = urlProblem {
                    caption(problem)
                }
            }

            Toggle(RemoteAdminWording.fetchAfterAdding, isOn: $fetchAfter)

            if store.isMutating {
                Text(RemoteWording.mutationBusy)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            HStack {
                Spacer()
                Button("Cancel") { store.activeSheet = nil }
                    .keyboardShortcut(.cancelAction)
                Button(RemoteAdminWording.addButton) { add() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
        }
        .padding(20)
        .frame(width: 480)
        .onAppear {
            nameFocused = true
            validator.start(with: name, using: store)
        }
        .onChange(of: name) { validator.edited(name, using: store) }
    }

    /// The two labels share one width, so both fields start at the same place.
    private func label(_ text: String) -> some View {
        Text(text).frame(width: Self.labelWidth, alignment: .leading)
    }

    /// Under its field, from the field's leading edge.
    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.red)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, Self.labelWidth + 8)
    }

    private static let labelWidth: CGFloat = 44

    /// Re-checked rather than trusted to the disabled button: a verdict can land between the
    /// press and this call.
    private func add() {
        guard canAdd else { return }
        // `confirmAddRemote` reads this very sheet and closes it itself.
        store.confirmAddRemote(
            name: BranchNameValidator.trim(name), url: url.trimmingCharacters(in: .whitespacesAndNewlines),
            fetchAfter: fetchAfter)
    }
}

/// The remote-name field's live check, for Add Remote… and Rename…: `BranchNameValidator`'s rule
/// — a debounce, one call into the store, and a verdict believed only for the exact text it
/// judged — over GitCore's `RemoteNameProblem`.
@Observable @MainActor
final class RemoteNameValidator {
    private static let debounce = Duration.milliseconds(250)

    /// What is wrong with `checkedName`, or nil when nothing is.
    private(set) var problem: RemoteNameProblem?
    /// The trimmed text `problem` is about; nil while a check is in flight.
    private(set) var checkedName: String?
    /// Whether the user has typed since the sheet opened: an untouched empty field gets no line.
    private(set) var hasEdited = false

    /// The remote being renamed: git counts its own name as taken, which is no news — Rename is
    /// off on the separate ground that nothing changed.
    private let ownName: String?
    private var check: Task<Void, Never>?

    init(ownName: String? = nil) {
        self.ownName = ownName
    }

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
        guard let problem, checkedName == BranchNameValidator.trim(text) else { return nil }
        guard problem != .empty || hasEdited else { return nil }
        return RemoteAdminWording.remoteNameProblem(problem)
    }

    private func update(_ text: String, using store: RepositoryStore) {
        check?.cancel()
        let trimmed = BranchNameValidator.trim(text)
        if trimmed.isEmpty {
            settle(trimmed, .empty)
            return
        }
        if trimmed == ownName {
            settle(trimmed, nil)
            return
        }
        checkedName = nil
        check = Task { [weak self] in
            try? await Task.sleep(for: Self.debounce)
            guard !Task.isCancelled, let self else { return }
            let problem = await store.remoteNameProblem(trimmed)
            guard !Task.isCancelled else { return }
            settle(trimmed, problem)
        }
    }

    private func settle(_ name: String, _ problem: RemoteNameProblem?) {
        checkedName = name
        self.problem = problem
    }
}
