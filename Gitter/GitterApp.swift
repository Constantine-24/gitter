import AppKit
import SwiftUI

/// The app's composition root: the window registry, built once, outside `GitterApp`.
///
/// SwiftUI runs `GitterApp.init` more than once and keeps only the first `@State` value — two
/// stores were measured being built (Task 11) — so nothing is built there. Each window builds its
/// own store, once, through the registry (`RepositoryWindowView`, M3.1), and the menus, the
/// delegate, `QuitFlow` and `QuitGuard` find the stores here.
@MainActor
enum AppModel {
    /// The composition root of the app's defaults: the user's own domain, here and nowhere else.
    /// Everything a store and its schedule remember goes through `store.defaults`, which is this.
    ///
    /// Neither the test host nor a scripted launch writes the open-repositories list into it
    /// (Ruling 4): the one is not the user's launch, and the other opens scratch fixtures — as
    /// neither adds to Open Recent (B3 Ruling 7).
    static let windows = WindowRegistry(defaults: UserDefaults.standard, recordsOpenList: recordsOpenList)

    private static var recordsOpenList: Bool {
        #if DEBUG
            !(TestHost.isRunningTests || DebugLaunchGuard.isScripted(ProcessInfo.processInfo.environment))
        #else
            !TestHost.isRunningTests
        #endif
    }

    /// The repository windows' scene id, for `openWindow(id:)`: an empty window.
    static let windowID = "main"

    /// Opens a repository window — on the repository given, fronting the window that already shows
    /// it (M2.2), or an empty one for nil. Set by the first window to appear, from its `openWindow`,
    /// which still works once that window has closed (M2.4), so that `AppDelegate` — which has no
    /// SwiftUI environment — and the launch can open windows.
    static var openWindow: ((RepositoryWindow?) -> Void)?

    /// Every store a quit takes with it: the ones `QuitFlow` closes the sheets of and `QuitGuard`
    /// checks the lane of — every registered store, a closed window's whose write is still running
    /// included.
    static func quitStores() -> [RepositoryStore] { windows.stores }
}

/// Whether this process is the host of a test bundle (`GitterTests`) rather than the app a
/// person launched: Xcode's test runner sets `XCTestConfigurationFilePath` in the host's
/// environment.
///
/// Under a test host the app reopens no repository (`reopenLastRepository`), starts no
/// automatic fetch (`AutoFetchScheduler.start`) and adds nothing to Open Recent (`open(_:)`), so
/// a test run never opens, let alone fetches, whatever repository the user last had open, and
/// leaves the user's list alone. Its stores are on scratch defaults (GitterTests' `makeTestStore`).
enum TestHost {
    static var isRunningTests: Bool {
        ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
    }
}

@main
struct GitterApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    /// The store the menus act on: the first window's that is open, until the menus follow the
    /// front window (E2 Task 4). Nil with no window open.
    private var store: RepositoryStore? { AppModel.windows.liveStores.first }
    /// "Fetch Automatically". Read by the schedule at every tick (`AutoFetchScheduler.isEnabled`)
    /// from each store's `defaults`, which is `.standard` (`AppModel.windows`) — the domain this
    /// binds to.
    @AppStorage(AutoFetchScheduler.enabledKey) private var autoFetchEnabled = true

    var body: some Scene {
        // One store per window (`RepositoryWindowView`). Gitter reopens its windows itself, from
        // its own list (`WindowRegistry.launchPaths`), so macOS restoration is off: no killed launch
        // can leave saved state that restores no window.
        WindowGroup(id: AppModel.windowID, for: RepositoryWindow.self) { $value in
            RepositoryWindowView(value: $value)
        }
        .defaultSize(width: 1200, height: 760)
        // A Finder open (or "Open Recent") is opened by `AppDelegate`, which also brings a window
        // back if none is open. Left to itself the scene answered the same event with new windows
        // onto that same store — two per open, measured in Task 11's review.
        .handlesExternalEvents(matching: [])
        .restorationBehavior(.disabled)
        .commands {
            // AppKit refuses every quit while a sheet is attached (M1.4), the stock Quit's too;
            // this one closes the sheets first (`QuitFlow`) and stays enabled with a sheet up,
            // where ⌘Q still reaches it (M1.6). "Quit and Keep Windows" (⌥⌘Q) goes with the
            // stock item (M1.6).
            CommandGroup(replacing: .appTermination) {
                Button("Quit Gitter") { QuitFlow.request(.menu) }
                    .keyboardShortcut("q")
            }
            CommandGroup(replacing: .newItem) {
                Button("Open Repository…") { RepositoryOpener.run(store: store) }
                    .keyboardShortcut("o")
            }
            CommandGroup(after: .toolbar) {
                Button("Refresh") { Task { await store?.refresh() } }
                    .keyboardShortcut("r")
                    .disabled(store?.root == nil)
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
            //
            // Empty with no window open, until the menus follow the front window (E2 Task 4).
            CommandMenu("Repository") {
                if let store {
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
                    // B3: two pickers, A preset to the current branch.
                    Button(CompareWording.compareBranchesTitle) { store.requestCompareBranches(a: nil, b: nil) }
                        .disabled(
                            store.activeSheet != nil || store.root == nil || store.compareBranchesBlockedReason != nil)
                    // B3 Task 5: the Worktrees section shows only with a second worktree, so the first
                    // one is added from here (or a branch's menu).
                    Button(WorktreeWording.addTitle) { store.requestAddWorktree(branch: nil) }
                        .disabled(store.activeSheet != nil || store.addWorktreeBlockedReason != nil)
                    Divider()
                }
                // Off also stops an automatic fetch that is running, in every window; on waits for
                // the next tick.
                Toggle(
                    "Fetch Automatically",
                    isOn: Binding(
                        get: { autoFetchEnabled },
                        set: { enabled in
                            autoFetchEnabled = enabled
                            for store in AppModel.windows.stores { store.autoFetchSettingChanged(enabled: enabled) }
                        }))
            }
            // B2: housekeeping of the remotes. Each item says why it is off (`MenuReasons`).
            CommandMenu("Remotes") {
                if let store { RemotesMenuContent(store: store) }
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

/// Forwards "Open Recent" selections (and other Finder/system open requests) to the store, takes
/// the quit Apple Event into `QuitFlow`, and asks `QuitGuard` before the app quits, over
/// `AppModel.quitStores()`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The quit Apple Event (the Dock's Quit, a logout, a shutdown) goes straight to AppKit's
    /// `_shouldTerminate`, past the menu, and is swallowed with a sheet up (M1.6). A handler
    /// installed here, before launch finishes, sees it first and quits through `QuitFlow`, which
    /// closes the sheets and then terminates — where AppKit's own handler would have ended up.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuit(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc func handleQuit(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated {
            QuitFlow.request(.appleEvent)
        }
    }

    /// ⌘Q, the Dock's Quit, a logout that asks: never with git still running on its own.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            QuitFlow.delegateWasAsked()
            return QuitGuard.shouldTerminate(AppModel.quitStores())
        }
    }

    /// Opened in the first open window's store, which comes to the front; with no window open, in a
    /// new window; and before any window has a store, by the first window (`pendingOpen`). Routing
    /// every open to its own window is E2 Task 4's.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated {
            #if DEBUG
                RepositoryStore.logStores("open event: \(url.path)")
            #endif
            let registry = AppModel.windows
            if let store = registry.liveStores.first {
                store.open(url)
                // The scene makes no window for the event (`handlesExternalEvents`): a window that
                // is hidden or in the Dock is brought back, else the open would happen unseen.
                registry.window(of: store)?.makeKeyAndOrderFront(nil)
            } else if let openWindow = AppModel.openWindow {
                openWindow(RepositoryWindow(url: url))
            } else {
                registry.pendingOpen = url
            }
        }
    }
}

/// The "Open Repository…" panel, shared by the menu command and the empty state.
@MainActor
enum RepositoryOpener {
    /// Opens the chosen repository in `store`, or — with no window open — in a new window.
    static func run(store: RepositoryStore?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Git repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if let store {
            store.open(url)
        } else {
            AppModel.openWindow?(RepositoryWindow(url: url))
        }
    }
}
