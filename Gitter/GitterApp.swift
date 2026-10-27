import AppKit
import SwiftUI

/// The app's composition root: the window registry, built once, outside `GitterApp`.
///
/// SwiftUI runs `GitterApp.init` more than once and keeps only the first `@State` value — two
/// stores were measured being built (Task 11) — so nothing is built there. Each window builds its
/// own store, once, through the registry (`RepositoryWindowView`, M3.1); the delegate, `QuitFlow`
/// and `QuitGuard` find the stores here, and the menus act on the front window's
/// (`FocusedValues.repositoryStore`).
@MainActor
enum AppModel {
    /// The composition root of the app's defaults: the user's own domain, here and nowhere else.
    /// Everything a store and its schedule remember goes through `store.defaults`, which is this.
    ///
    /// Neither the test host nor a scripted launch writes the open-repositories list into it
    /// (Ruling 4): the one is not the user's launch, and the other opens scratch fixtures — as
    /// neither adds to Open Recent (B3 Ruling 7).
    ///
    /// Every store's git reports to the app's log, and every window's events are told there
    /// (`AppLog`, P1 Task 2) — nowhere under the test host, which has no log file.
    static let windows = WindowRegistry(
        defaults: UserDefaults.standard, recordsOpenList: recordsOpenList, commandLog: AppLog.commandLog,
        eventLog: AppLog.events)

    private static var recordsOpenList: Bool {
        #if DEBUG
            !(TestHost.isRunningTests || DebugLaunchGuard.isScripted(ProcessInfo.processInfo.environment))
        #else
            !TestHost.isRunningTests
        #endif
    }

    /// The repository windows' scene id, for `openWindow(id:)`: an empty window.
    static let windowID = "main"

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

    var body: some Scene {
        // One store per window (`RepositoryWindowView`). Gitter reopens its windows itself, from
        // its own list (`WindowRegistry.launchPaths`), so macOS restoration is off: no killed launch
        // can leave saved state that restores no window.
        WindowGroup(id: AppModel.windowID, for: RepositoryWindow.self) { $value in
            RepositoryWindowView(value: $value)
        }
        .defaultSize(width: 1200, height: 760)
        // A Finder open (or "Open Recent") is opened by `AppDelegate`, through the registry's
        // routing. Left to itself the scene answered the same event with new windows onto that
        // same store — two per open, measured in Task 11's review.
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
            RepositoryCommands()
            // B3: ⌘F into the sidebar's filter (⇧⌘F is Fetch).
            SidebarFilterCommands()
            // P1: the version, build and commit (`AboutPanel`), and the diagnostics log's folder.
            CommandGroup(replacing: .appInfo) {
                Button("About Gitter") { AboutPanel.show() }
            }
            CommandGroup(after: .help) {
                Button("Show Logs") { AppLog.showLogs() }
            }
        }
    }
}

/// The commands that act on a repository — File's Open Repository…, View's Refresh, the
/// Repository and Remotes menus — on the **front window's** store (`@FocusedValue`, M3.3): the key
/// window's, kept while its sheet is up. With no window open it is nil and every item here is off
/// but Open Repository… and the app-wide Fetch Automatically.
struct RepositoryCommands: Commands {
    @FocusedValue(\.repositoryStore) private var store
    /// "Fetch Automatically". Read by the schedule at every tick (`AutoFetchScheduler.isEnabled`)
    /// from each store's `defaults`, which is `.standard` (`AppModel.windows`) — the domain this
    /// binds to.
    @AppStorage(AutoFetchScheduler.enabledKey) private var autoFetchEnabled = true

    var body: some Commands {
        // After the scene's own New Window (⌘N), which `replacing:` would remove (M2.3).
        CommandGroup(after: .newItem) {
            Button("Open Repository…") { RepositoryOpener.run(front: store) }
                .keyboardShortcut("o")
        }
        CommandGroup(after: .toolbar) {
            Button("Refresh") { Task { await store?.refresh() } }
                .keyboardShortcut("r")
                .disabled(Self.refreshIsOff(store))
        }
        // The toolbar's three network items and Stop. Disabled for the same reasons as the
        // toolbar, but the reasons are not spelled out here: a menu item shows no tooltip, and
        // the titles stay the plain verbs. The toolbar carries the "why".
        //
        // **And all four are off while a sheet is up** (final review's fix wave) — the front
        // window's sheet. The toolbar is behind the sheet; the menu's key equivalents are not, and
        // a sheet is a question the user has not answered yet. Measured with the harness in the
        // final review: ⇧⌘P under an open merge sheet pushed `main` to `origin` while the sheet
        // was still asking. Stop is included so that no key pressed while a sheet has the user's
        // attention acts on the network lane behind it.
        CommandMenu("Repository") {
            Button("Fetch") { store?.fetch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
                .disabled(isOff(\.fetchBlockedReason))
            Button("Pull") { store?.pull() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
                .disabled(isOff(\.pullBlockedReason))
            Button(store?.pushButtonTitle ?? RemoteWording.pushTitle(.push)) { store?.push() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(isOff(\.pushBlockedReason))
            Button("Stop") { store?.cancelRemoteActivity() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(store?.activeSheet != nil || store?.remoteActivity == nil)
            Divider()
            // Off while a sheet is up for the same reason as the four above;
            // `stashBlockedReason` says so itself, and why otherwise.
            Button("Stash Changes…") { store?.requestStash() }
                .keyboardShortcut("s", modifiers: [.command, .option])
                .disabled(isOff(\.stashBlockedReason))
            Divider()
            // B3: two pickers, A preset to the current branch.
            Button(CompareWording.compareBranchesTitle) { store?.requestCompareBranches(a: nil, b: nil) }
                .disabled(store?.root == nil || isOff(\.compareBranchesBlockedReason))
            // B3 Task 5: the Worktrees section shows only with a second worktree, so the first
            // one is added from here (or a branch's menu).
            Button(WorktreeWording.addTitle) { store?.requestAddWorktree(branch: nil) }
                .disabled(isOff(\.addWorktreeBlockedReason))
            Divider()
            // App-wide. Off also stops an automatic fetch that is running, in every window; on
            // waits for the next tick.
            Toggle(
                "Fetch Automatically",
                isOn: Binding(
                    get: { autoFetchEnabled },
                    set: { enabled in
                        autoFetchEnabled = enabled
                        for store in AppModel.windows.liveStores { store.autoFetchSettingChanged(enabled: enabled) }
                    }))
        }
        // B2: housekeeping of the remotes. Each item says why it is off (`MenuReasons`).
        CommandMenu("Remotes") {
            RemotesMenuContent(store: store)
        }
    }

    private func isOff(_ reason: (RepositoryStore) -> String?) -> Bool { Self.isOff(store, reason) }

    /// Whether a Repository item is off: with no window open, while the front window's sheet is
    /// up, or for the store's own reason.
    static func isOff(_ store: RepositoryStore?, _ reason: (RepositoryStore) -> String?) -> Bool {
        guard let store else { return true }
        return store.activeSheet != nil || reason(store) != nil
    }

    /// Whether Refresh is off: with no window open, no repository in the front window, or while
    /// that window's sheet is up — like the Repository items (Ruling 17).
    static func refreshIsOff(_ store: RepositoryStore?) -> Bool {
        store?.root == nil || store?.activeSheet != nil
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

/// Routes "Open Recent" selections (and other Finder/system open requests) to a window, takes
/// the quit Apple Event into `QuitFlow`, and asks `QuitGuard` before the app quits, over
/// `AppModel.quitStores()`.
final class AppDelegate: NSObject, NSApplicationDelegate {
    /// The quit Apple Event (the Dock's Quit, a logout, a shutdown) goes straight to AppKit's
    /// `_shouldTerminate`, past the menu, and is swallowed with a sheet up (M1.6). A handler
    /// installed here, before launch finishes, sees it first and quits through `QuitFlow`, which
    /// closes the sheets and then terminates — where AppKit's own handler would have ended up.
    /// The handler holds the event's reply until the quit's outcome (`QuitEventReplies`), as
    /// AppKit's own handler does (A1), so that the sender learns whether Gitter quit.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSAppleEventManager.shared().setEventHandler(
            self, andSelector: #selector(handleQuit(_:withReplyEvent:)),
            forEventClass: AEEventClass(kCoreEventClass), andEventID: AEEventID(kAEQuitApplication))
    }

    @objc func handleQuit(_ event: NSAppleEventDescriptor, withReplyEvent reply: NSAppleEventDescriptor) {
        MainActor.assumeIsolated {
            // Here, in the handler, while the event is current: nothing later can (A2).
            QuitFlow.holdCurrentQuitEvent()
            QuitFlow.request(.appleEvent)
        }
    }

    /// The log's launch header (P1 Task 2), once: Gitter's version, macOS's and git's, the last
    /// read off the main actor — so it may follow the first window's first lines. No header under
    /// the test host, which has no log. And, at every launch, a window if none came
    /// (`askForAWindowIfNoneCame`).
    func applicationDidFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            // Before the guard: every launch, not only one with a log.
            DispatchQueue.main.async { Self.askForAWindowIfNoneCame() }
            guard AppLog.writer != nil else { return }
            let info = Bundle.main.infoDictionary ?? [:]
            Task {
                AppLog.events.write(await AppLog.header(info: info, gitPath: "/usr/bin/git"))
            }
        }
    }

    /// B4 Task 5: with "Close windows when quitting" off, macOS hands SwiftUI saved state holding no
    /// window and SwiftUI opens none (`.restorationBehavior(.disabled)`; measured on a probe, where
    /// `.defaultLaunchBehavior(.presented)` changed nothing) — so no `onAppear` runs the launch, and
    /// there is no `openWindow` to call. One run-loop turn after launch, with no window taken and
    /// none on screen (`WindowRegistry.launchNeedsWindow`), Gitter asks for one the way a Dock click
    /// does: a reopen Apple Event to its own port, from a background thread (E3, C2b), answered by
    /// `applicationShouldHandleReopen` with the scene's empty window, whose `appeared` runs the
    /// launch. It checks again a turn later, just before asking; and a reopen that lands with a
    /// window already up opens nothing (C2b, and the B4 probe), so a late SwiftUI window never gets a
    /// second one.
    @MainActor private static func askForAWindowIfNoneCame() {
        // The test host shows no repository window by design: it must not log or send a reopen.
        guard !TestHost.isRunningTests else { return }
        let launchHandled = AppModel.windows.launchHandled
        let visible = visibleMainWindows()
        // Once, so a launch left with no window and no ask below says why (the user's checklist).
        if !launchHandled { AppLog.events.write("launch: \(visible) main windows visible, launch handled: false") }
        guard WindowRegistry.launchNeedsWindow(launchHandled: launchHandled, visibleMainWindows: visible) else { return }
        DispatchQueue.main.async {
            guard
                WindowRegistry.launchNeedsWindow(
                    launchHandled: AppModel.windows.launchHandled, visibleMainWindows: visibleMainWindows())
            else { return }
            let events = AppLog.events
            events.write("launch: no window, asking for one")
            Thread.detachNewThread {
                var port = AEGetRegisteredMachPort()
                guard
                    let me = NSAppleEventDescriptor(
                        descriptorType: DescType(typeMachPort), bytes: &port, length: MemoryLayout.size(ofValue: port))
                else {
                    events.write("launch: asking for a window failed: no descriptor for the app's Mach port")
                    return
                }
                let reopen = NSAppleEventDescriptor(
                    eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                    targetDescriptor: me, returnID: AEReturnID(kAutoGenerateReturnID),
                    transactionID: AETransactionID(kAnyTransactionID))
                do {
                    _ = try reopen.sendEvent(options: [.noReply], timeout: 5)
                } catch {
                    events.write("launch: asking for a window failed: \(error.localizedDescription)")
                }
            }
        }
    }

    /// The windows that count as a launch's window: on screen and able to be main. A normal launch
    /// has one, the repository window; the input method's `TUINSWindow` (500×500, appearing later)
    /// is neither visible nor able to be main, so it never counts (B4 Task 5 fix, measured).
    @MainActor private static func visibleMainWindows() -> Int {
        NSApp.windows.filter { $0.isVisible && $0.canBecomeMain }.count
    }

    /// The net: a quit event still held when the app goes is answered 0 before exit (A2b). And
    /// every line given to the log so far is written before the process ends — waited for at most
    /// `AppLog.quitFlushLimit`, so a write stuck on a hung volume cannot hold the quit.
    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            QuitFlow.answerHeldQuitEvents(quitting: true)
            AppLog.flushBeforeQuit(AppLog.writer)
        }
    }

    /// ⌘Q, the Dock's Quit, a logout that asks: never with git still running on its own.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            QuitFlow.delegateWasAsked()
            return QuitGuard.shouldTerminate(AppModel.quitStores())
        }
    }

    /// A Finder open or an Open Recent choice, routed (`WindowRegistry.open`, `.recentOrFinder`):
    /// the window already showing it comes to the front — out of the Dock or from behind — a
    /// folder that is not a repository is refused in the front window's banner, and otherwise it
    /// gets a window of its own; before the first window has taken the launch, that
    /// window opens it first (`pendingOpen`). The front is the key window's store — a sheet's
    /// parent's, with a sheet up.
    func application(_ application: NSApplication, open urls: [URL]) {
        guard let url = urls.first else { return }
        MainActor.assumeIsolated {
            #if DEBUG
                RepositoryStore.logStores("open event: \(url.path)")
            #endif
            let registry = AppModel.windows
            registry.open(url, kind: .recentOrFinder, front: registry.store(of: NSApp.keyWindow))
        }
    }

    /// A Dock click (or a Finder reactivation) with no window open: true lets SwiftUI open its one
    /// window, an empty one (M2.4). With a window open it changes nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        true
    }
}

/// The "Open Repository…" panel, shared by the menu command and the empty state.
@MainActor
enum RepositoryOpener {
    /// Opens the chosen repository where routing says (`.openPanel`): the window already showing
    /// it, `front` when it shows nothing, or a new window.
    static func run(front: RepositoryStore?) {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Open"
        panel.message = "Choose a Git repository"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        AppModel.windows.open(url, kind: .openPanel, front: front)
    }
}
