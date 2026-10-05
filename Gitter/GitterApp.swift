import AppKit
import SwiftUI

/// The one `RepositoryStore` of the app, built once, outside `GitterApp`.
///
/// SwiftUI runs `GitterApp.init` more than once and keeps only the first `@State` value — two
/// stores were measured being built (Task 11) — so a store made there, or captured there, may be
/// one nobody sees. It was worse than idle: `open()` starts the automatic fetch, so the discarded
/// store that `onOpenURL` had captured fetched a repository nobody could see every interval,
/// unseen by Stop, by "Fetch Automatically" and by `QuitGuard` (measured in Task 11's review:
/// a Finder open logged two schedules 76 ms apart and paired ticks). A static is built once, on
/// first use, and the window, the menus and both delegate hooks read this same one — including
/// an open event that arrives at launch before the window's `onAppear`.
@MainActor
enum AppModel {
    static let store = RepositoryStore()

    /// The main window's scene id, for `openWindow`.
    static let windowID = "main"

    /// Opens a main window: set by the first window to appear, from its `openWindow`, so that
    /// `AppDelegate` — which has no SwiftUI environment — can show the repository a Finder open
    /// has just opened when every window has been closed.
    static var openWindow: (() -> Void)?
}

/// Whether this process is the host of a test bundle (`GitterTests`) rather than the app a
/// person launched: Xcode's test runner sets `XCTestConfigurationFilePath` in the host's
/// environment.
///
/// Under a test host the app reopens no repository (`reopenLastRepository`) and starts no
/// automatic fetch (`AutoFetchScheduler.start`), so a test run never opens, let alone fetches,
/// whatever repository the user last had open.
enum TestHost {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

/// Hands the window's `openWindow` action to `AppModel.openWindow`.
private struct RemembersHowToOpenTheWindow: ViewModifier {
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            let openWindow = openWindow
            AppModel.openWindow = { openWindow(id: AppModel.windowID) }
        }
    }
}

@main
struct GitterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    private var store: RepositoryStore { AppModel.store }
    /// "Fetch Automatically". Read by the schedule at every tick (`AutoFetchScheduler.isEnabled`).
    @AppStorage(AutoFetchScheduler.enabledKey) private var autoFetchEnabled = true

    var body: some Scene {
        WindowGroup(id: AppModel.windowID) {
            MainWindow()
                .environment(store)
                .modifier(RemembersHowToOpenTheWindow())
                .onAppear {
                    Task {
                        await store.checkGitAvailability()
                        // Not over a repository a Finder open at launch has already opened.
                        if store.root == nil { store.reopenLastRepository() }
                        #if DEBUG
                            DebugLaunchHooks.run(store: store)
                        #endif
                    }
                }
        }
        .defaultSize(width: 1200, height: 760)
        // A Finder open (or "Open Recent") is opened in the one store by `AppDelegate`, which
        // also brings a window back if none is open. Left to itself the scene answered the same
        // event with new windows onto that same store — two per open, measured in Task 11's
        // review.
        .handlesExternalEvents(matching: [])
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
            //
            // **And all four are off while a sheet is up** (final review's fix wave). The
            // toolbar is behind the sheet; the menu's key equivalents are not, and a sheet is a
            // question the user has not answered yet. Measured with the harness in the final
            // review: ⇧⌘P under an open merge sheet pushed `main` to `origin` while the sheet
            // was still asking. Stop is included so that no key pressed while a sheet has the
            // user's attention acts on the network lane behind it.
            CommandMenu("Repository") {
                Button("Fetch") { store.fetch() }
                    .keyboardShortcut("f", modifiers: [.command, .shift])
                    .disabled(store.activeSheet != nil || store.fetchBlockedReason != nil)
                Button("Pull") { store.pull() }
                    .keyboardShortcut("l", modifiers: [.command, .shift])
                    .disabled(store.activeSheet != nil || store.pullBlockedReason != nil)
                Button(store.pushButtonTitle) { store.push() }
                    .keyboardShortcut("p", modifiers: [.command, .shift])
                    .disabled(store.activeSheet != nil || store.pushBlockedReason != nil)
                Button("Stop") { store.cancelRemoteActivity() }
                    .keyboardShortcut(".", modifiers: .command)
                    .disabled(store.activeSheet != nil || store.remoteActivity == nil)
                Divider()
                // Off while a sheet is up for the same reason as the four above;
                // `stashBlockedReason` says so itself, and why otherwise.
                Button("Stash Changes…") { store.requestStash() }
                    .keyboardShortcut("s", modifiers: [.command, .option])
                    .disabled(store.activeSheet != nil || store.stashBlockedReason != nil)
                Divider()
                // Off also stops an automatic fetch that is running; on waits for the next tick.
                Toggle(
                    "Fetch Automatically",
                    isOn: Binding(
                        get: { autoFetchEnabled },
                        set: { enabled in
                            autoFetchEnabled = enabled
                            store.autoFetchSettingChanged(enabled: enabled)
                        }))
            }
            // B2: housekeeping of the remotes. Each item says why it is off (`MenuReasons`).
            CommandMenu("Remotes") {
                RemotesMenuContent(store: store)
            }
            // B3: ⌘F into the sidebar's filter (⇧⌘F is Fetch).
            SidebarFilterCommands()
        }
    }
}

/// "Filter Sidebar" (⌘F) in the Edit menu, after its text-editing items: puts the keyboard in the
/// sidebar's filter field of the window in front. Off with no repository open, where there is no
/// sidebar.
struct SidebarFilterCommands: Commands {
    @FocusedValue(\.focusSidebarFilter) private var focusSidebarFilter

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Button("Filter Sidebar") { focusSidebarFilter?.focus() }
                .keyboardShortcut("f")
                .disabled(focusSidebarFilter == nil)
        }
    }
}

/// Forwards "Open Recent" selections (and other Finder/system open requests) to the store, and
/// asks `QuitGuard` before the app quits. Both go to `AppModel.store`, the one the window shows.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// ⌘Q, the Dock's Quit, a logout that asks: never with git still running on its own.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            QuitGuard.shouldTerminate(AppModel.store)
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated {
            #if DEBUG
                RepositoryStore.logStores("open event: \(url.path)")
            #endif
            AppModel.store.open(url)
            // The scene no longer makes a window for the event (`handlesExternalEvents`), so
            // when none is open, one is asked for here — else the open would happen unseen.
            if !NSApp.windows.contains(where: { $0.isVisible && $0.canBecomeMain }) {
                AppModel.openWindow?()
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
