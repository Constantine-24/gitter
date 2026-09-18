import AppKit
import SwiftUI

@main
struct GitterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = RepositoryStore()

    init() {
        let store = store
        AppDelegate.onOpenURL = { url in store.open(url) }
    }

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

/// Forwards "Open Recent" selections (and other Finder/system open requests) to the store.
/// The App struct owns the store, so this delegate holds a closure set from `GitterApp.init`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var onOpenURL: ((URL) -> Void)?

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated {
            AppDelegate.onOpenURL?(url)
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
