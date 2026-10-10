import AppKit
import Foundation
import GitCore
import Observation

/// Every repository window's store, and Gitter's own list of the repositories they show (E2 Task 3).
///
/// **One store per window.** Each window builds its store once, through
/// `@State private var store = AppModel.windows.makeStore()` (M3.1), and the registry keeps them in
/// the order they were made. `QuitFlow` and `QuitGuard` take every one of them
/// (`AppModel.quitStores()`), the menus take the first open one until they follow the front window.
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
    /// long as its lane is busy. Observed: the menus follow it.
    private(set) var stores: [RepositoryStore] = []

    /// The stores whose window is still open, in order.
    var liveStores: [RepositoryStore] { stores.filter { !$0.isClosed } }

    /// Set once the app is quitting for sure — `QuitGuard`'s `.terminateNow` or reply of true — and
    /// cleared if a quit is called off: while it is set, closing windows leaves the list alone.
    @ObservationIgnored private(set) var isTerminating = false

    /// Whether the first window has taken the launch's repositories (`launchPaths`) — once.
    @ObservationIgnored var launchHandled = false

    /// A Finder open that arrived before any window had a store to open it in: the first window
    /// opens it first, and the launch's other repositories after it (`launchPlan`).
    @ObservationIgnored var pendingOpen: URL?

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
