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
/// **A window still working hides instead of closing** (E3 Task 5, spec Design §3): `attach` puts a
/// `WindowCloseProxy` in as the window's delegate, and a user's close of a window whose store runs a
/// write on its lane or a local change (`closeDecision`) hides it (`hide`): ordered out, its
/// repository off the list, the store marked `isHidden` but not closed. An open of its repository
/// fronts it again, and every way it comes back clears that (`cameBack`, from its
/// `didBecomeKeyNotification`). If its work ends while it is still hidden, the window is closed for
/// real — or, when the work ended with something to read, an alert says so first (`HiddenEnding`).
/// What is done to the window goes through `hiddenWindows` (`HiddenWindowEnvironment`), recorded in
/// tests.
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

    /// Every registered store, in the order made: one per open window — a hidden one's too — and a
    /// closed window's for as long as its lane is busy.
    private(set) var stores: [RepositoryStore] = []

    /// The stores whose window is still open, in order: on screen, or hidden (`hide`).
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
    /// Each store's window's `didBecomeKeyNotification` observer (`cameBack`), by store.
    @ObservationIgnored private var keyObservers: [ObjectIdentifier: any NSObjectProtocol] = [:]

    /// What hiding does to a window: AppKit in the app, a recorder in tests.
    @ObservationIgnored let hiddenWindows: HiddenWindowEnvironment

    /// Each window's `WindowCloseProxy`, by window — its delegate holds it weakly (C1). Kept with
    /// the window it was made for, since a window freed can leave its address to the next.
    @ObservationIgnored private var proxies: [ObjectIdentifier: (window: WeakWindow, proxy: WindowCloseProxy)] = [:]

    /// What a hidden store had to read when it was hidden, and which hide that was: a store shown
    /// again and hidden again is watched by the newest hide only. By store.
    @ObservationIgnored private var hidden: [ObjectIdentifier: HiddenAt] = [:]
    /// Where a hidden store's repository was in the open list, for `cameBack` to put it back there.
    @ObservationIgnored private var listPlaces: [ObjectIdentifier: Int] = [:]
    @ObservationIgnored private var hides = 0

    private struct HiddenAt {
        let serial: Int
        let errorAtHide: String?
        let messagesAtHide: Int
    }

    private struct WeakWindow {
        weak var window: NSWindow?
    }

    init(defaults: UserDefaults, recordsOpenList: Bool, hiddenWindows: HiddenWindowEnvironment = .live) {
        self.defaults = defaults
        self.recordsOpenList = recordsOpenList
        self.hiddenWindows = hiddenWindows
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
    /// `.`, `..` and a trailing slash gone (RF2). A hidden window's store is one of them: it is
    /// live, and an open of its repository brings it back (`open`, `.front`).
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
        case .front(let store): show(store)
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
            if let store = store(in: current) { return store }
            candidate = current.sheetParent
        }
        return nil
    }

    // MARK: - Windows

    /// `window` shows `store` (weakly held): from now on its `willCloseNotification` closes the
    /// store, its `didBecomeKeyNotification` brings a hidden one back (`cameBack`), and a user's
    /// close of it asks `closeDecision` first, through the `WindowCloseProxy` put in as its
    /// delegate — once per window, keeping the delegate it had (SwiftUI's) as the original. Again
    /// for the same window does nothing; nothing for a closed store.
    func attach(_ window: NSWindow, to store: RepositoryStore) {
        guard !store.isClosed else { return }
        let key = ObjectIdentifier(store)
        if windows[key]?.window === window { return }
        for observers in [closeObservers, keyObservers] {
            if let observer = observers[key] { NotificationCenter.default.removeObserver(observer) }
        }
        windows[key] = WeakWindow(window: window)
        closeObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification, object: window, queue: .main
        ) { [weak self, weak store] _ in
            MainActor.assumeIsolated {
                guard let self, let store else { return }
                self.windowClosed(store)
            }
        }
        keyObservers[key] = NotificationCenter.default.addObserver(
            forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
        ) { [weak self, weak store] _ in
            MainActor.assumeIsolated {
                guard let self, let store else { return }
                self.cameBack(store)
            }
        }
        installProxy(on: window)
    }

    /// The open window's store whose own window is `window` (not a sheet of it).
    private func store(in window: NSWindow) -> RepositoryStore? {
        liveStores.first { self.window(of: $0) === window }
    }

    /// Whether the registry still holds a proxy for `window` (internal for tests).
    func hasProxy(on window: NSWindow) -> Bool {
        proxies[ObjectIdentifier(window)].map { $0.window.window === window } ?? false
    }

    /// Puts a `WindowCloseProxy` in as `window`'s delegate, unless it has one already. The proxy
    /// asks about whichever store the window shows when the close comes.
    private func installProxy(on window: NSWindow) {
        let id = ObjectIdentifier(window)
        if let installed = proxies[id], installed.window.window === window { return }
        let proxy = WindowCloseProxy(
            original: window.delegate,
            shouldHide: { [weak self, weak window] in
                guard let self, let window, let store = self.store(in: window) else { return false }
                return Self.closeDecision(remoteActivity: store.remoteActivity, isMutating: store.isMutating) == .hide
            },
            hide: { [weak self, weak window] in
                guard let self, let window, let store = self.store(in: window) else { return }
                self.hide(store)
            })
        proxies[id] = (WeakWindow(window: window), proxy)
        window.delegate = proxy
    }

    /// The window showing `store`; nil before it is attached and once it has closed.
    func window(of store: RepositoryStore) -> NSWindow? {
        windows[ObjectIdentifier(store)]?.window
    }

    /// `store`'s window has closed: the store is closed (`RepositoryStore.close()`), its repository
    /// leaves the list unless another window shows it or the app is terminating, and the store
    /// leaves the registry — now, or once its busy lane frees. A hidden one is hidden no more. A
    /// second call does nothing.
    func windowClosed(_ store: RepositoryStore) {
        guard stores.contains(where: { $0 === store }), !store.isClosed else { return }
        store.close()
        let key = ObjectIdentifier(store)
        for observer in [closeObservers.removeValue(forKey: key), keyObservers.removeValue(forKey: key)] {
            if let observer { NotificationCenter.default.removeObserver(observer) }
        }
        hidden[key] = nil
        listPlaces[key] = nil
        store.setHidden(false)
        if let window = windows[key]?.window { dropProxy(of: window) }
        windows[key] = nil
        leaveList(store)
        dropWhenLaneFree(store)
    }

    /// Lets go of `window`'s proxy — on the next turn, not now: this runs inside the window's
    /// `willCloseNotification`, which AppKit may still be delivering to the delegate (SwiftUI's own
    /// `windowWillClose:`, through the proxy), and the window holds its delegate weakly. The
    /// window's own delegate (SwiftUI's) is put back first, so a closed window that lingers (M3.2)
    /// keeps it rather than a nil one.
    private func dropProxy(of window: NSWindow) {
        let id = ObjectIdentifier(window)
        guard let installed = proxies[id], installed.window.window === window else { return }
        let proxy = installed.proxy
        Task { @MainActor [weak self, weak window] in
            guard let self, self.proxies[id]?.proxy === proxy else { return }
            if let window, window.delegate === proxy { window.delegate = proxy.original }
            self.proxies[id] = nil
        }
    }

    /// Leaves the registry once `store`'s lane is free: at once, or when it frees (watched through
    /// Observation, so the write's own completion is what lets the store go).
    private func dropWhenLaneFree(_ store: RepositoryStore) {
        whenFree(store, busy: { $0.remoteActivity != nil }) { [weak self] store in
            self?.stores.removeAll { $0 === store }
        }
    }

    /// Runs `then` once `busy` is false for `store`: at once, or when what it reads changes so
    /// (watched through Observation, so the work's own ending is what runs it). `then` is not run
    /// for a store gone meanwhile; `busy` itself decides when the watching stops.
    private func whenFree(
        _ store: RepositoryStore, busy: @escaping @MainActor (RepositoryStore) -> Bool,
        then: @escaping @MainActor (RepositoryStore) -> Void
    ) {
        let isBusy = withObservationTracking {
            busy(store)
        } onChange: { [weak self, weak store] in
            Task { @MainActor in
                guard let self, let store else { return }
                self.whenFree(store, busy: busy, then: then)
            }
        }
        if !isBusy { then(store) }
    }

    // MARK: - Hiding a window still working (E3 Task 5)

    /// What a user's close of a window does (the proxy's `windowShouldClose`): **hide** when its
    /// store's lane runs a write (`remoteActivity?.isWrite == true`) or a change is running
    /// (`isMutating`: a commit, a merge, a pull's merge, a prune's deletes…); otherwise **close**,
    /// as before E3 — a read on the lane is then stopped by `close()`.
    static func closeDecision(remoteActivity: RemoteActivity?, isMutating: Bool) -> CloseDecision {
        remoteActivity?.isWrite == true || isMutating ? .hide : .close
    }

    /// Hides `store`'s window instead of closing it (its proxy, on a close `closeDecision` says
    /// to hide): ordered out — out of the Window menu, with nothing that means "closed" firing
    /// (C2) — the store marked `isHidden` (not closed: its watcher, lane and change go on), its
    /// repository off the list as a closed window's is, and what it had to read noted
    /// (`lastError`, `laneMessagesToRead`). Then watched: once its work is no longer busy
    /// (`closeDecision`) while it is still hidden, `HiddenEnding.decide` says whether the window
    /// closes for real or an alert comes first. Nothing for a closed, hidden or windowless store; a
    /// store not busy (the proxy never hides one) is decided at once, so its window closes for real
    /// — or alerts — before this returns.
    func hide(_ store: RepositoryStore) {
        guard !store.isClosed, !store.isHidden, let window = window(of: store) else { return }
        hiddenWindows.orderOut(window)
        store.setHidden(true)
        let key = ObjectIdentifier(store)
        listPlaces[key] = leaveList(store)
        hides += 1
        let serial = hides
        hidden[key] = HiddenAt(serial: serial, errorAtHide: store.lastError, messagesAtHide: store.laneMessagesToRead)
        whenFree(store, busy: { [weak self] store in
            // A store shown again, closed, or hidden again since is this hide's no more: stop.
            guard let self, self.hidden[key]?.serial == serial, store.isHidden, !store.isClosed else { return false }
            return Self.closeDecision(remoteActivity: store.remoteActivity, isMutating: store.isMutating) == .hide
        }) { [weak self] store in
            guard let self, let at = self.hidden[key], at.serial == serial, store.isHidden, !store.isClosed else { return }
            self.workEnded(store, hiddenAt: at)
        }
    }

    /// `store`'s window is back on screen (its `didBecomeKeyNotification`: an open of its
    /// repository, SwiftUI's `openWindow(value:)` — which fronts the hidden window itself (C2) —
    /// the alert's Show, `QuitGuard` fronting it to ask): no longer hidden, its repository back on
    /// the list at the place it had there, and its work no longer watched — it ends on screen as
    /// anyone's does. Nothing for a store that is not hidden.
    func cameBack(_ store: RepositoryStore) {
        guard store.isHidden, !store.isClosed else { return }
        store.setHidden(false)
        let key = ObjectIdentifier(store)
        hidden[key] = nil
        let place = listPlaces.removeValue(forKey: key)
        if !isTerminating, let root = store.root {
            let path = RepositoryWindow(url: root).path
            var list = openRepositoryPaths
            if !list.contains(path) {
                // Back where it was (Minor 8), so a hide and a show keep the next launch's order.
                list.insert(path, at: min(place ?? list.count, list.count))
                writeList(list)
            }
        }
    }

    /// Brings `store`'s window to the front — made key, out of the Dock if it was there — and, if
    /// it was hidden, back (`cameBack`; its own signal would say so too, a moment later).
    func show(_ store: RepositoryStore) {
        guard let window = window(of: store) else { return }
        hiddenWindows.front(window)
        cameBack(store)
    }

    /// The work of hidden `store` has ended: its window is closed for real, or the alert comes
    /// first with what it has to read (`HiddenEnding`). Show brings the window back with its
    /// banner; Close closes it for real — if it is still this hide's (not shown again since).
    private func workEnded(_ store: RepositoryStore, hiddenAt at: HiddenAt) {
        hidden[ObjectIdentifier(store)] = nil
        let ending = HiddenEnding.decide(
            repository: store.root?.lastPathComponent, errorAtHide: at.errorAtHide, errorNow: store.lastError,
            messagesAtHide: at.messagesAtHide, messagesNow: store.laneMessagesToRead,
            lastMessage: store.lastLaneMessageToRead)
        switch ending {
        case .close:
            closeForReal(store)
        case .alert(let text):
            // Told here: a held quit's call-off says it no second time (`QuitGuard.hasWindow`).
            store.noteLaneMessagesTold()
            hiddenWindows.alert(text) { [weak self, weak store] choice in
                guard let self, let store, !store.isClosed else { return }
                switch choice {
                case .show: self.show(store)
                case .close:
                    // Shown again while the alert was up (or hidden again since): it is on screen,
                    // or watched by its newer hide.
                    guard store.isHidden, self.hidden[ObjectIdentifier(store)] == nil else { return }
                    self.closeForReal(store)
                }
            }
        }
    }

    /// Closes hidden `store`'s window for real (`HiddenWindowEnvironment.realClose`: ordered in
    /// first, or it is never freed, C3), then `windowClosed` as for any close — its lane is free of
    /// a write, so the store leaves the registry (a read still on it is stopped by `close()`).
    private func closeForReal(_ store: RepositoryStore) {
        if let window = window(of: store) { hiddenWindows.realClose(window) }
        // The close's own `willCloseNotification` has run this already in the app; a recorder
        // closes nothing.
        windowClosed(store)
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
    /// skipping any that is no longer a folder with a `.git` (`RepositoryStore.notARepository`, the
    /// rule every open makes) — or, with none of those, the last
    /// repository (`RepositoryStore.lastRepositoryToReopen`), as before E2. A list that was there is
    /// rewritten as the clean one (RF5), so a bad entry is gone for the next launch too.
    func launchPaths() -> [URL] {
        let stored = defaults.object(forKey: Self.openRepositoriesKey)
        var clean: [String] = []
        for case let path as String in stored as? [Any] ?? [] {
            let window = RepositoryWindow(url: URL(fileURLWithPath: path))
            guard !clean.contains(window.path),
                RepositoryStore.notARepository(URL(fileURLWithPath: window.path)) == nil
            else { continue }
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

    /// `store`'s window has left the screen (closed or hidden): its repository leaves the list,
    /// unless another window on screen shows it or the app is terminating. The index it had, if it
    /// was removed.
    @discardableResult
    private func leaveList(_ store: RepositoryStore) -> Int? {
        guard !isTerminating, let root = store.root else { return nil }
        let path = RepositoryWindow(url: root).path
        guard !isShown(path, besides: store) else { return nil }
        let list = openRepositoryPaths
        let place = list.firstIndex(of: path)
        writeList(list.filter { $0 != path })
        return place
    }

    /// Whether an open window other than `store`'s shows `path` — on screen: a hidden one shows
    /// nothing.
    private func isShown(_ path: String, besides store: RepositoryStore) -> Bool {
        liveStores.contains {
            $0 !== store && !$0.isHidden && $0.root.map { RepositoryWindow(url: $0).path } == path
        }
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

/// What a user's close of a repository window does (`WindowRegistry.closeDecision`).
enum CloseDecision: Equatable {
    case close
    case hide
}

/// How the work of a hidden window ended (`WindowRegistry.hide`).
enum HiddenEnding: Equatable {
    /// Nothing new to read: the window closes for real.
    case close
    /// `<repository>: <the message>`, for the alert (`RemoteWording.closedWindowFailedTitle`).
    case alert(String)

    /// Pure: the store had something new to read since it was hidden — a lane ending counted
    /// (`laneMessagesToRead` moved; its own words, `lastMessage`), or a banner that was not up
    /// when it was hidden (`lastError`) — → the alert; otherwise close. A banner already up before
    /// the hide, and unchanged, was seen.
    static func decide(
        repository: String?, errorAtHide: String?, errorNow: String?,
        messagesAtHide: Int, messagesNow: Int, lastMessage: String?
    ) -> HiddenEnding {
        let message: String?
        if messagesNow != messagesAtHide, let lastMessage {
            message = lastMessage
        } else if let errorNow, errorNow != errorAtHide {
            message = errorNow
        } else {
            message = nil
        }
        guard let message else { return .close }
        return .alert(repository.map { "\($0): \(message)" } ?? message)
    }
}

/// What hiding a window does to it (`WindowRegistry.hiddenWindows`): AppKit in the app (`live`); a
/// test records the calls instead.
struct HiddenWindowEnvironment {
    /// What the alert's two buttons answer.
    enum Choice: Equatable {
        case show, close
    }

    var orderOut: @MainActor (NSWindow) -> Void
    var front: @MainActor (NSWindow) -> Void
    /// The real close of a hidden window.
    var realClose: @MainActor (NSWindow) -> Void
    /// The app-modal alert for a hidden window's ending, its text the informative text; `answer`
    /// gets the button pressed.
    var alert: @MainActor (_ text: String, _ answer: @escaping @MainActor (Choice) -> Void) -> Void

    static let live = HiddenWindowEnvironment(
        orderOut: { $0.orderOut(nil) },
        front: { $0.makeKeyAndOrderFront(nil) },
        // Ordered in first, in the same turn: a window closed while hidden fires `willClose` but is
        // never freed, its view tree and store with it (C3); ordered in at alpha 0 it is, without a
        // flash.
        realClose: { window in
            window.alphaValue = 0
            window.orderFront(nil)
            window.close()
        },
        alert: { text, answer in
            let alert = NSAlert()
            alert.alertStyle = .warning
            alert.messageText = RemoteWording.closedWindowFailedTitle
            alert.informativeText = text
            // First button: the default, Return.
            alert.addButton(withTitle: RemoteWording.closedWindowShow)
            alert.addButton(withTitle: RemoteWording.closedWindowClose)
            // From the run loop, so every other window's work goes on under it (C3).
            ModalAlert.raise(alert) { response in
                answer(response == .alertFirstButtonReturn ? .show : .close)
            }
        })
}
