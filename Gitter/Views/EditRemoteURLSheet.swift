import GitCore
import SwiftUI

/// Edit URL… of a remote: its URLs **as the configuration writes them** (promise 5, R20), never
/// the `insteadOf`-rewritten ones `git remote -v` prints — where git really connects is only an
/// information line beside them (`connectsTo`). Every configured URL on screen is redacted
/// (`displayURL`); a field never starts with a credential in it: it starts empty and an empty
/// field keeps the configured URL (`urlToWrite`, carried note 1).
///
/// One fetch URL and a push choice: push to the fetch URL (no `pushurl`), or a push URL of its
/// own — the tri-state `PushURLChange`. A remote with several `url` values is shown read-only with
/// the reason (R22: a plain `set-url` fails on it); several `pushurl` values are shown read-only
/// and left as they are. A remote with no URL gets one here (carried note 3).
///
/// A form: Save answers Return, Escape cancels. `confirmEditURL` compares the URLs once more with
/// the ones shown before it writes.
struct EditRemoteURLSheet: View {
    let urls: RemoteURLs
    let remote: String

    @Environment(RepositoryStore.self) private var store
    @State private var fetchField: String
    @State private var pushField: String
    @State private var ownPushURL: Bool
    @FocusState private var fetchFocused: Bool

    init(urls: RemoteURLs, remote: String) {
        self.urls = urls
        self.remote = remote
        var fetch = RemoteAdminWording.urlFieldStart(urls.fetch.first)
        var push = urls.push.count == 1 ? RemoteAdminWording.urlFieldStart(urls.push.first) : ""
        var own = !urls.push.isEmpty
        #if DEBUG
            // The harness cannot type into a sheet (carried note 9): it sets the fields here.
            let prefill = DebugLaunchHooks.sheetPrefill
            fetch = prefill["fetch"] ?? fetch
            push = prefill["push"] ?? push
            own = prefill["own"].map { $0 == "1" } ?? own
        #endif
        _fetchField = State(initialValue: fetch)
        _pushField = State(initialValue: push)
        _ownPushURL = State(initialValue: own)
    }

    /// A plain `set-url` fails on several `url` values (R22): nothing here is editable then.
    private var editable: Bool { urls.fetch.count <= 1 }
    private var pushEditable: Bool { urls.push.count <= 1 }

    private var fetchToWrite: String {
        RemoteAdminWording.urlToWrite(field: fetchField, configured: urls.fetch.first)
    }

    private var pushToWrite: PushURLChange {
        RemoteAdminWording.pushChange(ownPushURL: ownPushURL, field: pushField, configured: urls.push)
    }

    /// What is wrong with what is typed. An empty field gets no line — Save is off for it, and
    /// "Enter a URL." in red over a field nobody has touched yet is a complaint, not a prompt.
    private var problems: [String] {
        var found: [String] = []
        if editable, !fetchField.isEmpty, let problem = RemoteAdminWording.urlProblem(fetchToWrite) {
            found.append(RemoteAdminWording.fetchURLLabel + " " + problem)
        }
        if !pushField.isEmpty, case .set(let url) = pushToWrite, let problem = RemoteAdminWording.urlProblem(url) {
            found.append(RemoteAdminWording.pushToOwnURL + " " + problem)
        }
        return found
    }

    private var canSave: Bool {
        editable && !store.isMutating && RemoteAdminWording.urlProblem(fetchToWrite) == nil
            && problemFreePush && RemoteAdminWording.editURLWrites(urls, fetch: fetchToWrite, push: pushToWrite)
    }

    private var problemFreePush: Bool {
        guard case .set(let url) = pushToWrite else { return true }
        return RemoteAdminWording.urlProblem(url) == nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(RemoteAdminWording.editURLSheetTitle(remote))
                .font(.headline)

            if urls.fetch.isEmpty {
                note(RemoteAdminWording.noURLYet)
            }

            if editable {
                fetchSection
            } else {
                readOnlyList(RemoteAdminWording.fetchURLLabel, urls.fetch)
                RemoteAdminWording.severalFetchURLs(urls, remote: remote).map(note)
            }
            RemoteAdminWording.connectsTo(urls).map(note)

            Divider()

            pushSection

            ForEach(problems, id: \.self) { problem in
                Text(problem)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if store.isMutating {
                note(RemoteWording.mutationBusy)
            }

            HStack {
                Spacer()
                if editable {
                    Button("Cancel") { store.activeSheet = nil }
                        .keyboardShortcut(.cancelAction)
                    Button(RemoteAdminWording.saveURLButton) { save() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!canSave)
                } else {
                    Button("Close") { store.activeSheet = nil }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .padding(20)
        .frame(width: 520)
        .onExitCommand { store.activeSheet = nil }
        .onAppear { fetchFocused = editable }
    }

    private var fetchSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(RemoteAdminWording.fetchURLLabel)
                TextField("A path, or an address", text: $fetchField)
                    .textFieldStyle(.roundedBorder)
                    .focused($fetchFocused)
                    .accessibilityLabel("Fetch URL")
            }
            if let configured = urls.fetch.first, RemoteAdminWording.hidesCredential(configured) {
                note(RemoteAdminWording.displayURL(configured) + " — " + RemoteAdminWording.credentialKept)
            }
        }
    }

    @ViewBuilder
    private var pushSection: some View {
        if pushEditable {
            VStack(alignment: .leading, spacing: 6) {
                Picker("", selection: $ownPushURL) {
                    Text(RemoteAdminWording.pushToFetchURL).tag(false)
                    Text(RemoteAdminWording.pushToOwnURL).tag(true)
                }
                .pickerStyle(.radioGroup)
                .labelsHidden()
                .disabled(!editable)
                if ownPushURL {
                    TextField("A path, or an address", text: $pushField)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("Push URL")
                        .disabled(!editable)
                    if let configured = urls.push.first, RemoteAdminWording.hidesCredential(configured) {
                        note(RemoteAdminWording.displayURL(configured) + " — " + RemoteAdminWording.credentialKept)
                    }
                }
            }
        } else {
            readOnlyList("Push URLs:", urls.push)
            RemoteAdminWording.severalPushURLs(urls, remote: remote).map(note)
        }
    }

    /// Several URLs as written, redacted, selectable to copy into a terminal.
    private func readOnlyList(_ label: String, _ list: [String]) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
            ForEach(Array(list.enumerated()), id: \.offset) { _, url in
                Text(RemoteAdminWording.displayURL(url))
                    .font(.callout.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
        }
    }

    private func note(_ text: String) -> some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func save() {
        guard canSave else { return }
        // `confirmEditURL` reads this very sheet and closes it itself.
        store.confirmEditURL(remote, fetch: fetchToWrite, push: pushToWrite)
    }
}
