import AppKit
import Foundation
import GitCore
import Observation

/// Every repository window's store, and Gitter's own list of the repositories they show (E2 Task 3).
///
/// **One store per window.** Each window builds its store once, through
/// `@State private var store = AppModel.windows.makeStore()` (M3.1), and the registry keeps them in
/// the order they were made. `QuitFlow` and `QuitGuard` take every one of them
/// (`AppModel.quitStores()`); the menus act on the front window's (`FocusedValues.repositoryStore`).
///
/// **Every open is routed here** (`route`, `open`, E2 Task 4): a repository a window already shows
/// comes to the front; Open Repository… takes an empty front window; a folder that is not a
/// repository is refused in the front window's banner; everything else gets a window of its own
/// (`openWindow`). No open happens unseen.
///
/// **A closed window lingers** (M3.2): its `NSWindow` stays in `NSApp.windows` and its view tree —
/// with its store — is not released. So a close is told here explicitly (`windowClosed`, from the
/// window's `willCloseNotification`, or its `onDisappear` as the fallback), and the store is closed
/// (`RepositoryStore.close()`). A store whose lane is busy stays registered, windowless, until the
/// lane frees — a write is never cut short, and `QuitGuard` still sees it — and then leaves.
///
/// **The open-repositories list** (`openRepositoriesKey` in `defaults`, a `[String]` of
/// `RepositoryWindow` paths) is what launch reopens, instead of macOS restoration (which is off,
/// M2.1):
/// - a store opening a repository adds it; replacing one in place swaps it at the same index;
/// - a window closing removes its repository — unless another window still shows it, or the app is
///   terminating (`beginAppTermination`), so the list survives the quit;
/// - it never holds a path twice; `launchPaths()` rewrites it clean (RF5).
///
/// A registry that `recordsOpenList` false never writes the list: a scripted launch and the test
/// host (Ruling 4), whose registry is on the user's own domain — like Open Recent (B3 Ruling 7).
@Observable @MainActor
final class WindowRegistry {
    static let openRepositoriesKey = "openRepositoryPaths"

    /// Where the stores and the list keep what they remember: `.standard` in the app (`AppModel`),
    /// a scratch suite under test.
    @ObservationIgnored let defaults: UserDefaults

    /// Whether the open-repositories list is written at all.
    @ObservationIgnored let recordsOpenList: Bool

    /// Every registered store, in the order made: one per open window, and a closed window's for as
    /// long as its lane is busy.
    private(set) var stores: [RepositoryStore] = []

    /// The stores whose window is still open, in order.
    var liveStores: [RepositoryStore] { stores.filter { !$0.isClosed } }

    /// Set once the app is quitting for sure — `QuitGuard`'s `.terminateNow` or reply of true — and
    /// cleared if a quit is called off: while it is set, closing windows leaves the list alone.
    @ObservationIgnored private(set) var isTerminating = false

    /// Whether the first window has taken the launch's repositories (`launchPaths`) — once.
    @ObservationIgnored var launchHandled = false

    /// An open that needed a window of its own before the first window had taken the launch (a
    /// Finder open at launch): the first window opens it first, and the launch's other
    /// repositories after it (`takePendingOpen`, `launchPlan`).
    @ObservationIgnored private(set) var pendingOpen: URL?

    /// Whether the first window's launch has taken `pendingOpen`: from then on a new window is
    /// opened at once.
    @ObservationIgnored private var launchTookPendingOpen = false

    /// Opens a repository window: on the repository given — fronting the window that already
    /// holds that value (M2.2) — or an empty one for nil. Set by the first window to appear, from
    /// its `openWindow`, which still works once that window has closed (M2.4); a recorder in tests.
    @ObservationIgnored var openWindow: ((RepositoryWindow?) -> Void)?

    @ObservationIgnored private var windows: [ObjectIdentifier: WeakWindow] = [:]
    @ObservationIgnored private var closeObservers: [ObjectIdentifier: any NSObjectProtocol] = [:]

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    init(defaults: UserDefaults, recordsOpenList: Bool) {
        self.defaults = defaults
        self.recordsOpenList = recordsOpenList
    }

    // MARK: - Stores

    /// A new store on the registry's defaults, registered last, its opens reported to the list.
    func makeStore(backend: RepositoryStore.Backend = CLIGitBackend()) -> RepositoryStore {
        let store = RepositoryStore(backend: backend, defaults: defaults)
        store.registry = self
        store.onRootChange = { [weak self, weak store] old, new in
            guard let self, let store else { return }
            rootChanged(store, from: old, to: new)
        }
        stores.append(store)
        #if DEBUG
            RepositoryStore.noteRegistered()
        #endif
        return store
    }

    /// The open window's store showing `url`, compared as `RepositoryWindow` paths: links followed,
    /// `.`, `..` and a trailing slash gone (RF2).
    func store(showing url: URL) -> RepositoryStore? {
        let wanted = RepositoryWindow(url: url)
        return liveStores.first { $0.root.map(RepositoryWindow.init(url:)) == wanted }
    }

    // MARK: - Opening

    /// Where `url` opens (spec §2, Open routing):
    /// - shown in an open window, by any spelling (RF2) → `.front`, whatever asked;
    /// - Open Repository… with a front window that shows nothing → `.useFront`;
    /// - Open Worktree with its window open → `.useFront`: that window switches to it;
    /// - a folder that is not a repository (`RepositoryStore.notARepository`), with a front window
    ///   open and the launch taken → `.refused`: the front window says so and no window is made
    ///   for a banner, as before E2 (Ruling 17). With no front window the open makes one, which
    ///   shows the banner; before the launch it is held for the first window, as any open is;
    /// - otherwise — Open Recent, a Finder open, Open in New Window, or a front window that shows a
    ///   repository — `.newWindow`.
    func route(_ url: URL, kind: OpenKind, front: RepositoryStore?) -> OpenRoute {
        if let shown = store(showing: url) { return .front(shown) }
        if let front, !front.isClosed {
            switch kind {
            case .openPanel where front.root == nil, .worktreeHere: return .useFront(front)
            default: break
            }
            if launchTookPendingOpen, RepositoryStore.notARepository(url) != nil { return .refused(front) }
        }
        return .newWindow(RepositoryWindow(url: url))
    }

    /// Opens `url` where `route` says: brings its window to the front (made key, out of the Dock
    /// if it was there), opens it in the empty front window, shows the front window's banner for a
    /// folder that is not a repository, or asks for a new window — held in
    /// `pendingOpen` for the first window while the launch has not taken it yet (Ruling 9), so a
    /// Finder open at launch comes first and the open list's repositories follow it.
    @discardableResult
    func open(_ url: URL, kind: OpenKind, front: RepositoryStore?) -> OpenRoute {
        let route = route(url, kind: kind, front: front)
        switch route {
        case .front(let store): window(of: store)?.makeKeyAndOrderFront(nil)
        case .useFront(let store): store.open(url)
        case .refused(let store):
            if let refusal = RepositoryStore.notARepository(url) { store.showStickyError(refusal) }
        case .newWindow(let value):
            if launchTookPendingOpen, let openWindow {
                openWindow(value)
            } else {
                pendingOpen = url
            }
        }
        return route
    }

    /// The first window's launch takes the open waiting for it, if any; every later new window
    /// opens at once (`open`).
    func takePendingOpen() -> URL? {
        launchTookPendingOpen = true
        defer { pendingOpen = nil }
        return pendingOpen
    }

    /// The open window's store whose window is `window` — or whose window `window` is a sheet of,
    /// since with a sheet up the sheet is the key window. Nil for no window, one that is not a
    /// repository window, and a closed one.
    func store(of window: NSWindow?) -> RepositoryStore? {
        var candidate = window
        while let current = candidate {
            if let store = liveStores.first(where: { self.window(of: $0) === current }) { return store }
            candidate = current.sheetParent
        }
        return nil
    }

    // MARK: - Windows

    /// `window` shows `store` (weakly held): from now on its `willCloseNotification` closes the
    /// store. Again for the same window does nothing; nothing for a closed store.
    func attach(_ window: NSWindow, to store: RepositoryStore) {
        guard !store.isClosed else { return }
        let key = ObjectIdentifier(store)
        if windows[key]?.window === window { return }
        if let observer = closeObservers[key] { NotificationCenter.default.removeObserver(observer) }
        windows[key] = WeakWindow(window: window)
        closeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak store] _ in
            MainActor.assumeIsolated {
                guard let self, let store else { return }
                self.windowClosed(store)
            }
        }
    }

    /// The window showing `store`; nil before it is attached and once it has closed.
    func window(of store: RepositoryStore) -> NSWindow? {
        windows[ObjectIdentifier(store)]?.window
    }

    /// `store`'s window has closed: the store is closed (`RepositoryStore.close()`), its repository
    /// leaves the list unless another window shows it or the app is terminating, and the store
    /// leaves the registry — now, or once its busy lane frees. A second call does nothing.
    func windowClosed(_ store: RepositoryStore) {
        guard stores.contains(where: { $0 === store }), !store.isClosed else { return }
        store.close()
        let key = ObjectIdentifier(store)
        if let observer = closeObservers.removeValue(forKey: key) {
            NotificationCenter.default.removeObserver(observer)
        }
        windows[key] = nil
        if !isTerminating, let root = store.root {
            let path = RepositoryWindow(url: root).path
            if !isShown(path, besides: store) { writeList(openRepositoryPaths.filter { $0 != path }) }
        }
        dropWhenLaneFree(store)
    }

    /// Leaves the registry once `store`'s lane is free: at once, or when it frees (watched through
    /// Observation, so the write's own completion is what lets the store go).
    private func dropWhenLaneFree(_ store: RepositoryStore) {
        let busy = withObservationTracking {
            store.remoteActivity != nil
        } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                self.dropWhenLaneFree(store)
            }
        }
        if !busy { stores.removeAll { $0 === store } }
    }

    // MARK: - Quitting

    // `QuitGuard`: on `.terminateNow` and before every reply of true.
    func beginAppTermination() {
        isTerminating = true
    }

    // `QuitGuard`: on every reply of false.
    func endAppTermination() {
        isTerminating = false
    }

    // MARK: - The open-repositories list

    /// The list as stored: its strings, in order; empty when there is none or it is no list.
    var openRepositoryPaths: [String] {
        (defaults.array(forKey: Self.openRepositoriesKey) ?? []).compactMap { $0 as? String }
    }

    /// What launch opens, in order: the list's repositories — each once, by `RepositoryWindow` path,
    /// skipping any that is no longer a folder with a `.git` — or, with none of those, the last
    /// repository (`RepositoryStore.lastRepositoryToReopen`), as before E2. A list that was there is
    /// rewritten as the clean one (RF5), so a bad entry is gone for the next launch too.
    func launchPaths(fileManager: FileManager = .default) -> [URL] {
        let stored = defaults.object(forKey: Self.openRepositoriesKey)
        var clean: [String] = []
        for case let path as String in stored as? [Any] ?? [] {
            let window = RepositoryWindow(url: URL(fileURLWithPath: path))
            guard !clean.contains(window.path), Self.isRepository(window.path, fileManager) else { continue }
            clean.append(window.path)
        }
        if stored != nil { writeList(clean) }
        if clean.isEmpty {
            return RepositoryStore.lastRepositoryToReopen(in: defaults).map { [$0] } ?? []
        }
        return clean.map { URL(fileURLWithPath: $0) }
    }

    /// What launch opens: the first window's repository, and one window each for the rest, in order.
    struct LaunchPlan: Equatable {
        var first: URL?
        var rest: [URL]
    }

    /// The launch, decided (Ruling 9). `pending` is a Finder open that came with the launch — the
    /// one the first window already shows, or `pendingOpen`. It comes first, and the list's
    /// repositories follow, each once (`RepositoryWindow`), so that every repository left in the
    /// list has a window and none lingers there unseen. A refused launch (`reopenRefusal`: a test
    /// host, a scripted launch) opens the Finder open alone and never reads the list.
    static func launchPlan(pending: URL?, refused: Bool, launchPaths: () -> [URL]) -> LaunchPlan {
        if refused { return LaunchPlan(first: pending, rest: []) }
        let paths = launchPaths()
        guard let pending else { return LaunchPlan(first: paths.first, rest: Array(paths.dropFirst())) }
        let shown = RepositoryWindow(url: pending)
        return LaunchPlan(first: pending, rest: paths.filter { RepositoryWindow(url: $0) != shown })
    }

    /// A folder with a `.git` in it — a directory, or a linked worktree's file.
    private static func isRepository(_ path: String, _ fileManager: FileManager) -> Bool {
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return false
        }
        return fileManager.fileExists(atPath: (path as NSString).appendingPathComponent(".git"))
    }

    /// `store` opened `new` in place of `old`: the new repository takes the old one's place in the
    /// list — unless another window still shows the old one, or the new one is listed already —
    /// and is added at the end otherwise.
    private func rootChanged(_ store: RepositoryStore, from old: URL?, to new: URL?) {
        let oldPath = old.map { RepositoryWindow(url: $0).path }
        let newPath = new.map { RepositoryWindow(url: $0).path }
        guard oldPath != newPath else { return }
        var list = openRepositoryPaths
        if let oldPath, let index = list.firstIndex(of: oldPath), !isShown(oldPath, besides: store) {
            if let newPath, !list.contains(newPath) {
                list[index] = newPath
            } else {
                list.remove(at: index)
            }
        } else if let newPath, !list.contains(newPath) {
            list.append(newPath)
        }
        writeList(list)
    }

    /// Whether an open window other than `store`'s shows `path`.
    private func isShown(_ path: String, besides store: RepositoryStore) -> Bool {
        liveStores.contains { $0 !== store && $0.root.map { RepositoryWindow(url: $0).path } == path }
    }

    /// Writes the list — never when this registry keeps none, and not when nothing changed.
    private func writeList(_ list: [String]) {
        guard recordsOpenList else { return }
        let stored = defaults.object(forKey: Self.openRepositoriesKey)
        if let current = stored as? [String], current == list { return }
        if stored == nil, list.isEmpty { return }
        defaults.set(list, forKey: Self.openRepositoriesKey)
    }
}

/// What asked for an open: how `WindowRegistry.route` decides where it goes.
enum OpenKind: Sendable {
    /// Open Repository… (⌘O), the menu's or the empty window's button.
    case openPanel
    /// Open Recent, or a Finder open (`application(_:open:)`).
    case recentOrFinder
    /// A worktree's Open in New Window.
    case worktreeNewWindow
    /// Open Worktree — the row's menu, its double-click, the add notice's Open: this window
    /// switches to it, unless another window shows it already (Ruling 11).
    case worktreeHere
}

/// Where an open goes (`WindowRegistry.route`).
enum OpenRoute: Equatable {
    /// The window already showing it: brought to the front, nothing reopened.
    case front(RepositoryStore)
    /// The front window, which shows nothing: it opens there.
    case useFront(RepositoryStore)
    /// Not a repository (`RepositoryStore.notARepository`): the front window says so in its banner
    /// and keeps what it shows; no window is made (Ruling 17).
    case refused(RepositoryStore)
    /// A window of its own, for this value.
    case newWindow(RepositoryWindow)

    static func == (lhs: OpenRoute, rhs: OpenRoute) -> Bool {
        switch (lhs, rhs) {
        case (.front(let a), .front(let b)), (.useFront(let a), .useFront(let b)),
            (.refused(let a), .refused(let b)):
            a === b
        case (.newWindow(let a), .newWindow(let b)): a == b
        default: false
        }
    }
}
