import AppKit
import SwiftUI

@main
struct GitterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var store = RepositoryStore()

    init() {
        // Capture the initial @State instance so the AppDelegate hook (a static closure,
        // since AppDelegate is created by the adaptor and can't be handed the store) can
        // forward "Open Recent"/Finder opens to the same store the scene uses.
        let store = store
        AppDelegate.onOpenURL = { url in store.open(url) }
    }

    var body: some Scene {
        WindowGroup {
            MainWindow()
                .environment(store)
                .onAppear {
                    Task {
                        await store.checkGitAvailability()
                        store.reopenLastRepository()
                        #if DEBUG
                            DebugLaunchHooks.run(store: store)
                        #endif
                    }
                }
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
            // The toolbar's three network items and Stop. Disabled for the same reasons as
            // the toolbar, but the reasons are not spelled out here: a menu item shows no
            // tooltip, and the titles stay the plain verbs. The toolbar carries the "why".
            CommandMenu("Repository") {
                Button("Fetch") { store.fetch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(store.fetchBlockedReason != nil)
                Button("Pull") { store.pull() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(store.pullBlockedReason != nil)
                Button(store.pushButtonTitle) { store.push() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(store.pushBlockedReason != nil)
                Button("Stop") { store.cancelRemoteActivity() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(store.remoteActivity == nil)
                Divider()
                // Task 11: the "Fetch Automatically" toggle goes here, below the divider.
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
