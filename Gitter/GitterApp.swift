import AppKit
import SwiftUI

@main
struct GitterApp: App {
    @State private var store = RepositoryStore()

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(store)
                .onAppear { store.reopenLastRepository() }
        }
        .defaultSize(width: 1200, height: 760)
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { RepositoryOpener.run(store: store) }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await store.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(store.root == nil)
            }
        }
    }
}

/// The "Open Repository…" panel, shared by the menu command and the empty state.
@MainActor
enum RepositoryOpener {
    static func run(store: RepositoryStore) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Git repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        store.open(url)
    }
}
