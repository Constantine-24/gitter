import AppKit
import SwiftUI

/// The repository a window shows: the value of `WindowGroup(for: RepositoryWindow.self)` (E2 Task 3).
/// A standardized path with its links resolved, so one repository has one value however it was
/// spelled (RF2), and `openWindow(value:)` with it fronts the window already showing it (M2.2). An
/// empty window's value is nil.
struct RepositoryWindow: Codable, Hashable, Sendable {
    var path: String

    init(url: URL) {
        path = url.standardizedFileURL.resolvingSymlinksInPath().path
    }
}

/// One repository window: its own store, made once (M3.1), registered with `AppModel.windows`,
/// and closed when the window closes (M3.2).
///
/// - The value follows the store: when `root` changes the binding is written, so the value is
///   always what the window shows.
/// - The store follows the value: a value set from outside — `openWindow(value:)` made this window
///   for a path, at creation or later (M2.1) — is opened, and a value that cannot be opened goes
///   back to what is shown.
/// - The first window to appear takes the launch (`WindowRegistry.launchHandled`, `launchPlan`): a
///   Finder open that came with it, or else the first of the list's repositories, here, and a
///   window each for the rest; then, in DEBUG, the harness's hooks run for its store, once.
struct RepositoryWindowView: View {
    @Binding var value: RepositoryWindow?
    // The initializer form, never `State(initialValue:)` in an `init` (M3.1): exactly one store per
    // window, built the first time SwiftUI needs it.
    @State private var store = AppModel.windows.makeStore()
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        MainWindow()
            .environment(store)
            .background(WindowAccessor { window in AppModel.windows.attach(window, to: store) })
            .onAppear { appeared() }
            // The fallback signal, for a store whose window was never attached: with a window,
            // its `willCloseNotification` (`attach`) comes about 1 ms after this at a close (M3.2)
            // and is the one taken — this view may also disappear without its window closing (a
            // window tab moved behind another was not measured), and that must not close it.
            .onDisappear {
                if AppModel.windows.window(of: store) == nil { AppModel.windows.windowClosed(store) }
            }
            .onChange(of: store.root) { _, root in
                let shown = root.map(RepositoryWindow.init(url:))
                if value != shown { value = shown }
            }
            .onChange(of: value) { _, wanted in follow(wanted) }
    }

    private func appeared() {
        if AppModel.openWindow == nil {
            // From the first window, kept: an `openWindow` from a window since closed still opens
            // one (M2.4). Nil is an empty window, by the scene's id.
            let openWindow = openWindow
            AppModel.openWindow = { value in
                if let value {
                    openWindow(value: value)
                } else {
                    openWindow(id: AppModel.windowID)
                }
            }
        }
        // Claimed now, not after the wait below: a second window appearing meanwhile must not take
        // the launch as well.
        let takesTheLaunch = !AppModel.windows.launchHandled
        AppModel.windows.launchHandled = true
        Task {
            await store.checkGitAvailability()
            follow(value)
            if takesTheLaunch { launch() }
        }
    }

    /// Opens `wanted` unless this window shows it already; a value that does not open (not a
    /// repository any more, a write still running) goes back to what the window shows.
    private func follow(_ wanted: RepositoryWindow?) {
        guard let wanted else { return }
        guard store.root.map(RepositoryWindow.init(url:)) != wanted else { return }
        store.open(URL(fileURLWithPath: wanted.path))
        let shown = store.root.map(RepositoryWindow.init(url:))
        if shown != wanted { value = shown }
    }

    /// The launch (`WindowRegistry.launchPlan`, Ruling 9): a Finder open that came with it first —
    /// already in this store (`application(_:open:)`), or waiting in `pendingOpen` — then the
    /// list's other repositories, a window each. A refused launch (a test host, a scripted launch)
    /// opens only the Finder open.
    private func launch() {
        let registry = AppModel.windows
        let pending = registry.pendingOpen ?? store.root
        registry.pendingOpen = nil
        let rest = store.reopenLastRepository { refused in
            WindowRegistry.launchPlan(pending: pending, refused: refused) { registry.launchPaths() }
        }
        for url in rest { AppModel.openWindow?(RepositoryWindow(url: url)) }
        #if DEBUG
            DebugLaunchHooks.run(store: store)
        #endif
    }
}

/// Reports the `NSWindow` its view is in, whenever that changes.
private struct WindowAccessor: NSViewRepresentable {
    let found: @MainActor (NSWindow) -> Void

    func makeNSView(context: Context) -> NSView {
        ReportingView(found: found)
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    private final class ReportingView: NSView {
        let found: @MainActor (NSWindow) -> Void

        init(found: @escaping @MainActor (NSWindow) -> Void) {
            self.found = found
            super.init(frame: .zero)
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let window { found(window) }
        }
    }
}
